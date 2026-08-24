-- rime_translate.lua
--
-- RIME (librime-lua) filter that annotates Chinese candidates with English
-- translations from the rime-translate offline dictionary (ECDICT, MIT).
--
-- Data sources, in order:
--   1. in-memory session cache
--   2. hot cache TSV exported by rime-translate-helper
--      (~/Library/Rime/rime_translate_cache.tsv, reloaded on mtime change)
--   3. one-shot local HTTP call to the helper (127.0.0.1), which answers
--      from SQLite instantly and kicks off Cloudflare Workers AI for misses
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
local mem_cache = {}      -- zh -> en string (pipe separated)
local neg_cache = {}      -- zh -> true, known to have no translation
local hot_mtime_checked = 0
local hot_cache = {}
local quota_second = 0    -- helper-spawn rate limiting (see query_helper)
local quota_used = 0

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

local function file_mtime(path)
    local f = io.popen("/usr/bin/stat -f %m '" .. path:gsub("'", "'\\''") .. "' 2>/dev/null")
    if not f then return nil end
    local v = f:read("*l")
    f:close()
    return tonumber(v)
end

-- naive scan of "key: value" lines in yaml-ish files
local function scan_yaml_value(path, key_pattern)
    local content = read_file(path)
    if not content then return nil end
    return content:match(key_pattern)
end

-- detect Squirrel horizontal/vertical layout
local function detect_orientation()
    if cfg.orientation == "horizontal" or cfg.orientation == "vertical" then
        return cfg.orientation
    end
    local home = os.getenv("HOME") or ""
    local candidates = {
        home .. "/Library/Rime/squirrel.custom.yaml",
        "/Library/Input Methods/Squirrel.app/Contents/SharedSupport/squirrel.yaml",
    }
    for _, p in ipairs(candidates) do
        local v = scan_yaml_value(p, "horizontal:%s*(%a+)%s*$")
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

local function load_hot_cache(force)
    local now = os.time()
    if not force and (now - hot_mtime_checked) < 3 then return end
    hot_mtime_checked = now

    local home = os.getenv("HOME") or ""
    local path = home .. "/Library/Rime/rime_translate_cache.tsv"
    local mt = file_mtime(path)
    if mt == nil then
        trace("hot cache: stat failed for %s", path)
        return
    end
    if hot_cache._mtime == mt and not force then return end

    local new_cache = { _mtime = mt }
    local count = 0
    local ok, err = pcall(function()
        for line in io.lines(path) do
            local zh, en = line:match("^(.-)\t(.+)$")
            if zh and en and en ~= "" then
                new_cache[zh] = en
                count = count + 1
            end
        end
    end)
    if not ok then
        trace("hot cache load ERROR: %s", tostring(err))
        return
    end
    hot_cache = new_cache
    trace("hot cache loaded: %d entries (mtime=%s)", count, tostring(mt))
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

local function url_encode(s)
    local out = {}
    for i = 1, #s do
        local b = s:byte(i)
        if b == 0x20 then out[#out + 1] = "%20"
        elseif (b >= 0x30 and b <= 0x39) or (b >= 0x41 and b <= 0x5a)
            or (b >= 0x61 and b <= 0x7a) or b == 0x2d or b == 0x5f then
            out[#out + 1] = string.char(b)
        else
            out[#out + 1] = string.format("%%%02X", b)
        end
    end
    return table.concat(out)
end

local function query_helper(zh)
    if type(io.popen) ~= "function" then return nil end
    -- rate limit: at most 2 helper spawns per second, typing responsiveness
    -- beats completeness (missed words are retried next session)
    local now = os.time()
    if now == quota_second then
        if quota_used >= 2 then
            trace("rate-limited: %s", zh)
            return nil
        end
        quota_used = quota_used + 1
    else
        quota_second = now
        quota_used = 1
    end
    local url = string.format(
        "http://127.0.0.1:%d/lookup?q=%s",
        cfg.helper_port, url_encode(zh))
    local ok, body = pcall(function()
        local f = io.popen("/usr/bin/curl -s --max-time 0.15 '" .. url .. "' 2>/dev/null")
        if not f then return nil end
        local b = f:read("*a")
        f:close()
        return b
    end)
    if not ok then
        trace("curl ERROR: %s", tostring(body))
        return nil
    end
    -- {"q":"..","en":"..","source":"dict"}  -- minimal json field grab
    local en = body and body:match('"en":"(.-)","source"') or nil
    if en == nil or en == "" then
        trace("helper miss: %s", zh)
        return nil
    end
    en = en:gsub('\\"', '"'):gsub("\\\\", "\\")
    en = en:gsub("\\u([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])", function(hex)
        return utf8.char(tonumber(hex, 16))
    end)
    trace("helper hit: %s -> %s", zh, en:sub(1, 40))
    return en
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
        parts[#parts + 1] = w
    end
    if count == 0 then return nil end
    return table.concat(parts, cfg.separator)
end

local function lookup(zh)
    local hit = mem_cache[zh]
    if hit ~= nil then
        return hit == false and nil or hit
    end
    load_hot_cache(false)
    hit = hot_cache[zh]
    if hit then
        mem_cache[zh] = hit
        trace("hot hit: %s", zh)
        return hit
    end
    hit = query_helper(zh)
    if hit then
        mem_cache[zh] = hit
        return hit
    end
    neg_cache[zh] = true
    mem_cache[zh] = false
    trace("neg-cached: %s", zh)
    return nil
end

--------------------------------------------------------------------
-- entry points
--------------------------------------------------------------------

function M.init(env)
    local ok, err = pcall(function()
        open_debug()
        load_config(env)
        load_hot_cache(true)
    end)
    if not ok then trace("init ERROR: %s", tostring(err)) end
end

function M.fini(env) end

function M.func(input, env)
    for cand in input:iter() do
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
                            yield(repl)
                        end)
                        if not ok2 then
                            trace("replace FAILED (%s): %s", cand.text, tostring(err2))
                        else
                            trace("replaced: %s [%s]", cand.text, rendered)
                        end
                    else
                        cand.comment = (cand.comment or "") .. "  " .. rendered
                        trace("annotated: %s [%s] type=%s", cand.text, rendered, cand.type)
                    end
                end
            end
        end
        yield(cand)
    end
end

return M
