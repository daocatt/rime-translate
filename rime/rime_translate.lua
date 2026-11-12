-- rime_translate.lua
--
-- RIME (librime-lua) filter that annotates Chinese candidates with English
-- translations from the rime-translate offline dictionary (ECDICT, MIT).
--
-- Data sources:
--   1. in-memory session cache
--   2. hot cache TSV exported by rime-translate-helper
--      (~/Library/Rime/rime_translate_cache.tsv, reloaded when its #rev
--       header changes -- checking it reads one line, never spawns a process)
--   3. misses are appended to rime_translate_requests.txt; the helper drains
--      that file every second (SQLite / Cloudflare Workers AI) and refills
--      the hot cache. Typing is NEVER blocked by network or subprocesses.
--
-- Configuration (~/Library/Rime/rime_translate.custom.yaml):
--
--   patch:
--     translate/enabled: true
--     translate/switch_name: "rime_translate"
--     translate/phonetic_enabled: true
--     translate/phonetic_switch_name: "rime_translate_phonetic"
--     translate/phonetic_format: "/%s/"
--     translate/max_entries_horizontal: 2   # horizontal layout: show N words
--     translate/max_entries_vertical: 5     # vertical layout: show M words
--     translate/separator: " / "
--     translate/comment_format: "%s"        # printf-style, e.g. "〔%s〕"
--     translate/max_comment_chars: 0        # truncate comment to N chars (0=off)
--     translate/annotate_first_only: false  # annotate only the first candidate
--     translate/orientation_override: auto  # auto | horizontal | vertical
--     translate/helper_port: 61899
--     translate/max_candidate_len: 12       # skip longer phrases
--
-- Schema wiring:
--   engine/filters/+:
--     - lua_filter@*rime_translate
--   switches/+:
--     - name: rime_translate
--       reset: 1
--       states: [ 译关, 译开 ]

local DEFAULTS = {
    enabled = true,
    switch_name = "rime_translate",
    phonetic_enabled = true,
    phonetic_switch_name = "rime_translate_phonetic",
    phonetic_format = "/%s/",
    max_entries_horizontal = 2,
    max_entries_vertical = 5,
    separator = " / ",
    orientation = "auto",
    helper_port = 61899,
    max_candidate_len = 12,
    comment_format = "%s",          -- rendered text, printf-style
    max_comment_chars = 0,          -- 0 = no truncation
    annotate_first_only = false,    -- annotate only the first candidate
}

-- debug tracing to /tmp/rime_translate_debug.log, OFF by default.
-- enable per session with the environment variable RIME_TRANSLATE_DEBUG=1
-- (e.g. via launchd plist env or `open`), then tail the file.
local dbg = nil
local dbg_buf = {}
local function trace(fmt, ...)
    if not dbg then return end
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = "?" end
    -- buffer writes; flush in batches to keep the typing path syscall-free
    dbg_buf[#dbg_buf + 1] = os.date("%H:%M:%S ") .. msg .. "\n"
    if #dbg_buf >= 32 then
        pcall(dbg.write, dbg, table.concat(dbg_buf))
        dbg_buf = {}
    end
end

local function open_debug()
    if os.getenv("RIME_TRANSLATE_DEBUG") ~= "1" then return end
    -- keep the debug log bounded (512 KB): start fresh when oversized
    local path = "/tmp/rime_translate_debug.log"
    local f = io.open(path, "a")
    if not f then return end
    if f:seek("end") > 524288 then
        f:close()
        f = io.open(path, "w")
        if not f then return end
    end
    dbg = f
    trace("=== session start, lua=%s popen=%s ===",
        _VERSION and tostring(_VERSION) or "?",
        type(io.popen))
end

local M = {}

local HOME = os.getenv("HOME") or ""
local cfg = {}
local has_translate_switch = false
local has_phonetic_switch = false

local function make_cache_store(prefix, req_name)
    return {
        base_path = HOME .. "/Library/Rime/" .. prefix .. ".tsv",
        delta_path = HOME .. "/Library/Rime/" .. prefix .. ".delta",
        meta_path = HOME .. "/Library/Rime/" .. prefix .. ".meta",
        req_path = HOME .. "/Library/Rime/" .. req_name,
        mem = {},       -- key -> value; false = pending
        hot = {},       -- _base, _delta
        requested = {},
    }
end

local zh_store = make_cache_store("rime_translate_cache", "rime_translate_requests.txt")
local en_store = make_cache_store("rime_translate_phonetic", "rime_translate_phonetic_requests.txt")

--------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

-- naive scan of "key: value" lines in yaml-ish files
local function scan_yaml_value(path, key_pattern)
    local content = read_file(path)
    if not content then return nil end
    return content:match(key_pattern)
end

-- detect Squirrel horizontal/vertical layout from user theme config
local function detect_orientation()
    if cfg.orientation == "horizontal" or cfg.orientation == "vertical" then
        return cfg.orientation
    end
    local files = {
        HOME .. "/Library/Rime/squirrel.custom.yaml",
        "/Library/Input Methods/Squirrel.app/Contents/SharedSupport/squirrel.yaml",
    }
    -- modern themes: candidate_list_layout (linear=horizontal, stacked=vertical)
    -- (no $ anchor: these keys sit mid-file, before other lines)
    for _, p in ipairs(files) do
        local v = scan_yaml_value(p, "candidate_list_layout:%s*(%a+)")
        if v == "linear" then return "horizontal" end
        if v == "stacked" then return "vertical" end
        v = scan_yaml_value(p, "text_orientation:%s*(%a+)")
        if v == "horizontal" then return "horizontal" end
        if v == "vertical" then return "vertical" end
        -- legacy key: `horizontal: true` or `style/horizontal: true`
        v = scan_yaml_value(p, "horizontal:%s*(%a+)")
        if v == "true" then return "horizontal" end
        if v == "false" then return "vertical" end
    end
    return "vertical"
end

local function load_config(env)
    for k, v in pairs(DEFAULTS) do cfg[k] = v end
    -- user overrides
    local content = read_file(HOME .. "/Library/Rime/rime_translate.custom.yaml")
    if content then
        local function num(key, default)
            local n = tonumber(content:match(key .. ":%s*(-?[%d%.]+)"))
            return n or default
        end
        local en = content:match("translate/enabled:%s*(%a+)")
        if en == "false" then cfg.enabled = false end
        local sw = content:match('translate/switch_name:%s*[\'"]?([%w_%-]+)[\'"]?')
        if sw and sw ~= "" then cfg.switch_name = sw end
        local pe = content:match("translate/phonetic_enabled:%s*(%a+)")
        if pe == "false" then cfg.phonetic_enabled = false end
        local psw = content:match('translate/phonetic_switch_name:%s*[\'"]?([%w_%-]+)[\'"]?')
        if psw and psw ~= "" then cfg.phonetic_switch_name = psw end
        local pfmt = content:match('translate/phonetic_format:%s*[\'"]([^\'"]*)[\'"]')
        if pfmt then cfg.phonetic_format = pfmt end
        cfg.max_entries_horizontal = num("translate/max_entries_horizontal", cfg.max_entries_horizontal)
        cfg.max_entries_vertical = num("translate/max_entries_vertical", cfg.max_entries_vertical)
        cfg.helper_port = num("translate/helper_port", cfg.helper_port)
        cfg.max_candidate_len = num("translate/max_candidate_len", cfg.max_candidate_len)
        local sep = content:match('translate/separator:%s*[\'"]([^\'"]*)[\'"]')
        if sep then cfg.separator = sep end
        local fmt = content:match('translate/comment_format:%s*[\'"]([^\'"]*)[\'"]')
        if fmt then cfg.comment_format = fmt end
        cfg.max_comment_chars = num("translate/max_comment_chars", cfg.max_comment_chars)
        local first_only = content:match("translate/annotate_first_only:%s*(%a+)")
        if first_only == "true" then cfg.annotate_first_only = true end
        local ori = content:match("translate/orientation_override:%s*(%a+)")
        if ori then cfg.orientation = ori end
    end
    cfg.layout = detect_orientation()
end

-- cheap freshness check: read only the meta file (one short line).
-- Format from the helper: "base=<rev> delta_off=<bytes> rev=<rev>"
local function hot_meta(store)
    local content = read_file(store.meta_path)
    if not content then return nil end
    local base, off, rev = content:match("base=(%d+) delta_off=(%d+) rev=(%d+)")
    if not rev then return nil end
    return tonumber(base), tonumber(off), tonumber(rev)
end

-- full read of the base TSV -- only on init or when the helper rebuilt it
local function load_base(store, rev)
    local new_cache = {}
    local count = 0
    local ok, err = pcall(function()
        for line in io.lines(store.base_path) do
            if not line:match("^#") then
                local k, v = line:match("^(.-)\t(.+)$")
                if k and v and v ~= "" then
                    new_cache[k] = v
                    count = count + 1
                end
            end
        end
    end)
    if not ok then
        trace("hot cache load ERROR (%s): %s", store.base_path, tostring(err))
        return false
    end
    store.hot = new_cache
    store.hot._base = rev
    -- entries may have been filled: retry everything pending this session
    store.mem = {}
    store.requested = {}
    trace("hot cache base loaded (%s): %d entries (rev=%s)", store.base_path, count, tostring(rev))
    return true
end

local function load_store(store)
    local base, off, rev = hot_meta(store)
    if rev == nil then
        -- legacy helper (no meta file): fall back to the TSV #rev header
        local f = io.open(store.base_path, "rb")
        if not f then
            trace("hot cache (%s): unreadable or missing", store.base_path)
            return false
        end
        local head = f:read(40) or ""
        f:close()
        rev = tonumber(head:match("#rev=(%d+)"))
        if rev == nil then return false end
        if store.hot._base == rev then return false end
        return load_base(store, rev)
    end

    if store.hot._base ~= base then
        return load_base(store, base)
    end
    -- base unchanged: merge only the new delta bytes (a few lines)
    local delta_done = store.hot._delta or 0
    if off <= delta_done then return false end
    local f = io.open(store.delta_path, "rb")
    if not f then return false end
    f:seek("set", delta_done)
    local chunk = f:read("*a")
    f:close()
    if not chunk or chunk == "" then return false end
    -- only consume complete lines; the torn tail is picked up next time
    local cut = chunk:match("()[^\n]*$")
    local complete = chunk:sub(1, cut - 1)
    if complete == "" then return false end
    local added = 0
    for line in complete:gmatch("[^\n]+") do
        local k, v = line:match("^(.-)\t(.+)$")
        if k and v and v ~= "" then
            store.hot[k] = v
            added = added + 1
        end
    end
    -- publish even if parse failed: never re-read the same bytes forever
    store.hot._delta = off
    if added > 0 then store.mem = {} end
    trace("hot cache delta (%s): +%d (off=%d rev=%d)", store.delta_path, added, off, rev)
    return added > 0
end

-- fire-and-forget miss reporting: a plain file append, never blocks.
-- The helper drains this file each second and refills the hot cache.
local function request_word(store, key)
    if store.requested[key] then return end
    store.requested[key] = true
    local f = io.open(store.req_path, "a")
    if not f then return end
    f:write(key, "\n")
    f:close()
    trace("requested (%s): %s", store.req_path, key)
end

local function is_cjk(text)
    if not text or text == "" then return false end
    -- fast reject: wrong length or invalid utf8 (utf8.len fails on bad input)
    local n = utf8.len(text)
    if not n or n == 0 or n > cfg.max_candidate_len then return false end
    for _, cp in utf8.codes(text) do
        if not ((cp >= 0x3400 and cp <= 0x9FFF) or (cp >= 0xF900 and cp <= 0xFAFF)) then
            return false
        end
    end
    return true
end

local function is_english_word(text)
    if not text or text == "" or #text > 40 then return false end
    return text:match("^[A-Za-z]$") ~= nil
        or text:match("^[A-Za-z][A-Za-z'%-]*[A-Za-z]$") ~= nil
end

-- Detect forced pinyin segmentation (e.g. "a p p le", "co o l") where a lone
-- consonant letter was matched via single-letter initial abbreviation.
local function has_isolated_consonant(preedit)
    if not preedit or preedit == "" then return false end
    for seg in preedit:gmatch("%S+") do
        if seg:match("^[bcdfghjklmnpqrstwxyzBCDFGHJKLMNPQRSTWXYZ]$") then
            return true
        end
    end
    return false
end

-- pick first N english words out of "w1|w2|w3|..." joined by separator,
-- then apply comment_format and max_comment_chars
local function render(en)
    if not en or en == "" then return nil end
    local limit = (cfg.layout == "horizontal") and cfg.max_entries_horizontal
        or cfg.max_entries_vertical
    local parts = {}
    local count = 0
    for w in en:gmatch("[^|]+") do
        count = count + 1
        if count > limit then break end
        parts[#parts + 1] = w:match("^%s*(.-)%s*$")  -- trim
    end
    if count == 0 then return nil end
    local text = cfg.comment_format == "%s" and table.concat(parts, cfg.separator)
        or string.format(cfg.comment_format, table.concat(parts, cfg.separator))
    if cfg.max_comment_chars > 0 and #text > cfg.max_comment_chars then
        -- byte cap, but never split a UTF-8 char: back off until the byte
        -- after the cut starts a new character
        local cut = cfg.max_comment_chars
        while cut > 0 and math.floor(text:byte(cut + 1) / 64) == 2 do
            cut = cut - 1
        end
        if cut > 0 then text = text:sub(1, cut) else text = "" end
    end
    return text
end

local function normalize_ipa(ipa)
    if not ipa or ipa == "" then return "" end
    -- normalize narrow linguistic IPA to dictionary-friendly broad IPA:
    -- turned-r 'ɹ' (U+0279) -> 'r'
    -- dark-l 'ɫ' (U+026B) -> 'l'
    return ipa:gsub("ɹ", "r"):gsub("ɫ", "l")
end

local function render_phonetic(ipa)
    if not ipa or ipa == "" then return nil end
    local clean_ipa = normalize_ipa(ipa)
    if cfg.phonetic_format == "%s" then return clean_ipa end
    local ok, text = pcall(string.format, cfg.phonetic_format, clean_ipa)
    if not ok then
        trace("phonetic_format ERROR: %s", tostring(text))
        return nil
    end
    return text
end

local function lookup_store(store, key)
    local hit = store.mem[key]
    if hit ~= nil then
        return hit == false and nil or hit
    end
    hit = store.hot[key]
    if hit then
        store.mem[key] = hit
        return hit
    end
    -- miss: ask the helper asynchronously (file append, zero blocking);
    -- a few keystrokes later the refilled hot cache answers on its own
    load_store(store)
    hit = store.hot[key]
    if hit then
        store.mem[key] = hit
        trace("hot hit (after reload): %s", key)
        return hit
    end
    request_word(store, key)
    store.mem[key] = false
    return nil
end

-- Check whether a switch name is declared in schema `switches` list.
-- When absent, the feature stays enabled by default without requiring schema edits.
local function schema_has_switch(env, name)
    if not name or name == "" then return false end
    local ok, found = pcall(function()
        local cfg_obj = env and env.engine and env.engine.schema and env.engine.schema.config
        if not cfg_obj or not cfg_obj.get_list then return false end
        local list = cfg_obj:get_list("switches")
        if not list then return false end
        for i = 0, list.size - 1 do
            local item = list:get_at(i)
            local map = item and item:get_map()
            local val = map and map:get_value("name")
            if val and val:get_string() == name then
                return true
            end
        end
        return false
    end)
    return ok and found == true
end

local function annotate_candidate(cand, rendered)
    -- shadow candidates created by the simplifier do not
    -- render comments assigned afterwards; replace them
    -- with an equivalent plain candidate instead
    if cand.type == "simplified" or cand.type == "shadow" then
        local ok2, err2 = pcall(function()
            local repl = Candidate("simplified", cand.start,
                cand._end, cand.text, "  " .. rendered)
            repl.quality = cand.quality
            trace("replaced: %s [%s]", cand.text, rendered)
            yield(repl)
        end)
        if ok2 then return true end
        trace("replace FAILED (%s): %s", cand.text, tostring(err2))
        return false
    end
    -- some librime candidate types reject comment writes;
    -- never let annotation break the candidate stream
    local ok2, err2 = pcall(function()
        cand.comment = (cand.comment or "") .. "  " .. rendered
    end)
    if not ok2 then
        trace("comment FAILED (%s): %s", cand.text, tostring(err2))
    else
        trace("annotated: %s [%s] type=%s", cand.text, rendered, cand.type)
    end
    return false
end

--------------------------------------------------------------------
-- entry points
--------------------------------------------------------------------

function M.init(env)
    local ok, err = pcall(function()
        open_debug()
        load_config(env)
        has_translate_switch = schema_has_switch(env, cfg.switch_name)
        has_phonetic_switch = schema_has_switch(env, cfg.phonetic_switch_name)
        load_store(zh_store)
        load_store(en_store)
    end)
    if not ok then trace("init ERROR: %s", tostring(err)) end
end

function M.fini(env)
    if dbg then
        pcall(dbg.write, dbg, table.concat(dbg_buf))
        pcall(dbg.close, dbg)
        dbg = nil
    end
end

function M.func(input, env)
    local ctx = env and env.engine and env.engine.context
    local translate_on = cfg.enabled
    if translate_on and has_translate_switch and ctx and ctx.get_option then
        translate_on = ctx:get_option(cfg.switch_name)
    end
    local phonetic_on = cfg.phonetic_enabled
    if phonetic_on and has_phonetic_switch and ctx and ctx.get_option then
        phonetic_on = ctx:get_option(cfg.phonetic_switch_name)
    end

    -- annotate_first_only: annotate at most the first translatable candidate
    -- in this composition (per-keystroke, so it tracks the highlighted word)
    local first_done = false
    local cand_idx = 0
    for cand in input:iter() do
        cand_idx = cand_idx + 1
        local handled = false
        if cand_idx == 1 and phonetic_on then
            local word, from_input = nil, false
            if is_english_word(cand.text) then
                word = cand.text:lower()
            elseif ctx and ctx.input and #ctx.input >= 3 and is_english_word(ctx.input) then
                -- Fallback for pure-Chinese schemas (e.g. luna_pinyin_simp) without an English translator.
                -- Plain pinyin such as "shi"/"shixian" is also ASCII, so a character-class
                -- check alone would annotate Chinese candidates with English IPA. Only treat
                -- the raw input as English when the schema clearly failed to segment it:
                -- a sentence candidate or forced pinyin segmentation ("a p p le").
                local genuine = cand.get_genuine and cand:get_genuine() or cand
                local gtype = genuine.type or cand.type
                local preedit_txt = genuine.preedit or cand.preedit or ""
                if preedit_txt == "" and ctx.get_preedit then
                    local ok_p, pe = pcall(function() return ctx:get_preedit().text end)
                    if ok_p and pe then preedit_txt = pe end
                end
                if gtype == "sentence" or has_isolated_consonant(preedit_txt) then
                    word = ctx.input:lower()
                    from_input = true
                end
            end
            if word then
                local ok, ipa = pcall(lookup_store, en_store, word)
                if ok and ipa then
                    local rendered = render_phonetic(ipa)
                    if rendered then
                        if from_input then
                            local ok2, err2 = pcall(function()
                                local repl = Candidate("english", cand.start,
                                    cand._end, ctx.input, "  " .. rendered)
                                repl.quality = cand.quality
                                yield(repl)
                            end)
                            if ok2 then
                                handled = true
                            else
                                trace("english replace FAILED (%s): %s", ctx.input, tostring(err2))
                            end
                        else
                            handled = annotate_candidate(cand, rendered)
                        end
                    end
                end
            end
        end
        if not handled and translate_on and is_cjk(cand.text) and cand.type ~= "raw"
            and not (cfg.annotate_first_only and first_done) then
            local ok, en = pcall(lookup_store, zh_store, cand.text)
            if ok and en then
                local rendered = render(en)
                if rendered then
                    first_done = true
                    handled = annotate_candidate(cand, rendered)
                end
            end
        end
        if not handled then
            yield(cand)
        end
    end
end

return M
