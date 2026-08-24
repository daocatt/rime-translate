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
--     translate/max_entries_horizontal: 2   # horizontal layout: show N words
--     translate/max_entries_vertical: 5     # vertical layout: show M words
--     translate/separator: " / "
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
}

-- debug tracing to /tmp/rime_translate_debug.log (set env
-- RIME_TRANSLATE_DEBUG=0 in launchd/plist to disable; on by default)
local dbg = nil
local function trace(fmt, ...)
    if not dbg then return end
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = "?" end
    pcall(dbg.write, dbg, os.date("%H:%M:%S ") .. msg .. "\n")
    pcall(dbg.flush, dbg)
end

local function open_debug()
    local f = io.open("/tmp/rime_translate_debug.log", "a")
    if not f then return end
    dbg = f
    trace("=== session start, lua=%s popen=%s ===",
        _VERSION and tostring(_VERSION) or "?",
        type(io.popen))
end

local M = {}

local cfg = {}
local mem_cache = {}      -- zh -> en string (pipe separated); false = pending
local neg_cache = {}      -- kept for compatibility; unused since async mode
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
    local home = os.getenv("HOME") or ""
    local files = {
        home .. "/Library/Rime/squirrel.custom.yaml",
        "/Library/Input Methods/Squirrel.app/Contents/SharedSupport/squirrel.yaml",
    }
    -- modern themes: candidate_list_layout (linear=horizontal, stacked=vertical)
    for _, p in ipairs(files) do
        local v = scan_yaml_value(p, "candidate_list_layout:%s*(%a+)%s*$")
        if v == "linear" then return "horizontal" end
        if v == "stacked" then return "vertical" end
        v = scan_yaml_value(p, "text_orientation:%s*(%a+)%s*$")
        if v == "horizontal" then return "horizontal" end
        if v == "vertical" then return "vertical" end
        -- legacy key
        v = scan_yaml_value(p, "^%s*horizontal:%s*(%a+)%s*$")
        if v == "true" then return "horizontal" end
        if v == "false" then return "vertical" end
    end
    return "vertical"
end

local function load_config(env)
    for k, v in pairs(DEFAULTS) do cfg[k] = v end
    -- user overrides
    local home = os.getenv("HOME") or ""
    local content = read_file(home .. "/Library/Rime/rime_translate.custom.yaml")
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
        local ori = content:match("translate/orientation_override:%s*(%a+)")
        if ori then cfg.orientation = ori end
        local maxlen = num("translate/max_candidate_len", cfg.max_candidate_len)
        cfg.max_candidate_len = maxlen
    end
    cfg.layout = detect_orientation()
end

-- cheap freshness check: read only the "#rev=" header line (no subprocess)
local function cache_rev()
    local home = os.getenv("HOME") or ""
    local f = io.open(home .. "/Library/Rime/rime_translate_cache.tsv", "rb")
    if not f then return nil end
    local head = f:read(40) or ""
    f:close()
    return tonumber(head:match("#rev=(%d+)"))
end

local function load_hot_cache()
    local rev = cache_rev()
    if rev == nil then
        trace("hot cache: unreadable or missing")
        return false
    end
    if hot_cache._rev == rev then return false end

    local home = os.getenv("HOME") or ""
    local path = home .. "/Library/Rime/rime_translate_cache.tsv"
    local new_cache = { _rev = rev }
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
    -- entries may have been filled: retry everything pending this session
    mem_cache = {}
    neg_cache = {}
    requested = {}
    trace("hot cache loaded: %d entries (rev=%s)", count, tostring(rev))
    return true
end

-- fire-and-forget miss reporting: a plain file append, never blocks.
-- The helper drains this file each second and refills the hot cache.
local function request_word(zh)
    if requested[zh] then return end
    requested[zh] = true
    local home = os.getenv("HOME") or ""
    local f = io.open(home .. "/Library/Rime/rime_translate_requests.txt", "a")
    if not f then return end
    f:write(zh, "\n")
    f:close()
    trace("requested: %s", zh)
end

local function is_cjk(text)
    if not text or text == "" then return false end
    local n = 0
    local ok = pcall(function()
        for _, cp in utf8.codes(text) do
            n = n + 1
            if n > cfg.max_candidate_len then error("too_long") end
            if not ((cp >= 0x3400 and cp <= 0x9FFF) or (cp >= 0xF900 and cp <= 0xFAFF)) then
                error("not_cjk")
            end
        end
    end)
    return ok and n > 0
end

-- pick first N english words out of "w1|w2|w3|..." joined by separator
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
    return table.concat(parts, cfg.separator)
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

function M.fini(env) end

function M.func(input, env)
    for cand in input:iter() do
        local handled = false
        if cfg.enabled and is_cjk(cand.text) and cand.type ~= "raw" then
            local ok, en = pcall(lookup, cand.text)
            if ok and en then
                local rendered = render(en)
                if rendered then
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
                        cand.comment = (cand.comment or "") .. "  " .. rendered
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
