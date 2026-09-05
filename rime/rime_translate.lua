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
--   translate/max_entries_horizontal: 2   # horizontal layout: show N words
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

local DEFAULTS = {
    enabled = true,
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
local mem_cache = {}      -- zh -> en string (pipe separated); false = pending
local hot_cache = {}      -- _rev = version from helper
local requested = {}      -- words already written to the request file

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
local function hot_meta()
    local content = read_file(HOME .. "/Library/Rime/rime_translate_cache.meta")
    if not content then return nil end
    local base, off, rev = content:match("base=(%d+) delta_off=(%d+) rev=(%d+)")
    if not rev then return nil end
    return tonumber(base), tonumber(off), tonumber(rev)
end

-- full read of the base TSV -- only on init or when the helper rebuilt it
local function load_base(path, rev)
    local new_cache = {}
    local count = 0
    local ok, err = pcall(function()
        for line in io.lines(path) do
            if not line:match("^#") then
                local zh, en = line:match("^(.-)\t(.+)$")
                if zh and en and en ~= "" then
                    new_cache[zh] = en
                    count = count + 1
                end
            end
        end
    end)
    if not ok then
        trace("hot cache load ERROR: %s", tostring(err))
        return false
    end
    hot_cache = new_cache
    hot_cache._base = rev
    -- entries may have been filled: retry everything pending this session
    mem_cache = {}
    requested = {}
    trace("hot cache base loaded: %d entries (rev=%s)", count, tostring(rev))
    return true
end

local function load_hot_cache()
    local base, off, rev = hot_meta()
    if rev == nil then
        -- legacy helper (no meta file): fall back to the TSV #rev header
        local f = io.open(HOME .. "/Library/Rime/rime_translate_cache.tsv", "rb")
        if not f then
            trace("hot cache: unreadable or missing")
            return false
        end
        local head = f:read(40) or ""
        f:close()
        rev = tonumber(head:match("#rev=(%d+)"))
        if rev == nil then return false end
        if hot_cache._base == rev then return false end
        return load_base(HOME .. "/Library/Rime/rime_translate_cache.tsv", rev)
    end

    if hot_cache._base ~= base then
        return load_base(HOME .. "/Library/Rime/rime_translate_cache.tsv", base)
    end
    -- base unchanged: merge only the new delta bytes (a few lines)
    local delta_done = hot_cache._delta or 0
    if off <= delta_done then return false end
    local path = HOME .. "/Library/Rime/rime_translate_cache.delta"
    local f = io.open(path, "rb")
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
        local zh, en = line:match("^(.-)\t(.+)$")
        if zh and en and en ~= "" then
            hot_cache[zh] = en
            added = added + 1
        end
    end
    -- publish even if parse failed: never re-read the same bytes forever
    hot_cache._delta = off
    if added > 0 then mem_cache = {} end
    trace("hot cache delta: +%d (off=%d rev=%d)", added, off, rev)
    return added > 0
end

-- fire-and-forget miss reporting: a plain file append, never blocks.
-- The helper drains this file each second and refills the hot cache.
local function request_word(zh)
    if requested[zh] then return end
    requested[zh] = true
    local f = io.open(HOME .. "/Library/Rime/rime_translate_requests.txt", "a")
    if not f then return end
    f:write(zh, "\n")
    f:close()
    trace("requested: %s", zh)
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

local function lookup(zh)
    local hit = mem_cache[zh]
    if hit ~= nil then
        return hit == false and nil or hit
    end
    hit = hot_cache[zh]
    if hit then
        mem_cache[zh] = hit
        return hit
    end
    -- miss: ask the helper asynchronously (file append, zero blocking);
    -- a few keystrokes later the refilled hot cache answers on its own
    load_hot_cache()
    hit = hot_cache[zh]
    if hit then
        mem_cache[zh] = hit
        trace("hot hit (after reload): %s", zh)
        return hit
    end
    request_word(zh)
    mem_cache[zh] = false
    return nil
end

--------------------------------------------------------------------
-- entry points
--------------------------------------------------------------------

function M.init(env)
    local ok, err = pcall(function()
        open_debug()
        load_config(env)
        load_hot_cache()
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
    -- annotate_first_only: annotate at most the first translatable candidate
    -- in this composition (per-keystroke, so it tracks the highlighted word)
    local first_done = false
    for cand in input:iter() do
        local handled = false
        if cfg.enabled and is_cjk(cand.text) and cand.type ~= "raw"
            and not (cfg.annotate_first_only and first_done) then
            local ok, en = pcall(lookup, cand.text)
            if ok and en then
                local rendered = render(en)
                if rendered then
                    first_done = true
                    -- shadow candidates created by the simplifier do not
                    -- render comments assigned afterwards; replace them
                    -- with an equivalent plain candidate instead
                    if cand.type == "simplified" or cand.type == "shadow" then
                        local ok2, err2 = pcall(function()
                            local repl = Candidate("simplified", cand.start,
                                cand._end, cand.text, "  " .. rendered)
                            repl.quality = cand.quality
                            handled = true
                            trace("replaced: %s [%s]", cand.text, rendered)
                            yield(repl)
                        end)
                        if not ok2 then
                            trace("replace FAILED (%s): %s", cand.text, tostring(err2))
                        end
                    else
                        -- some librime candidate types reject comment writes;
                        -- never let annotation break the candidate stream
                        local ok2, err2 = pcall(function()
                            cand.comment = (cand.comment or "") .. "  " .. rendered
                        end)
                        if not ok2 then
                            trace("comment FAILED (%s): %s", cand.text, tostring(err2))
                        end
                        trace("annotated: %s [%s] type=%s", cand.text, rendered, cand.type)
                    end
                end
            end
        end
        if not handled then
            yield(cand)
        end
    end
end

return M
