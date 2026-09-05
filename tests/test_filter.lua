-- Offline test harness for rime_translate.lua (no librime required).
-- Stubs the librime-lua globals and runs the filter against fake candidates.
--
--   lua tests/test_filter.lua

package.path = "rime/?.lua;" .. package.path

-- ---- stubs ------------------------------------------------------------
-- HOME is taken from the environment; run with:
--   HOME=tests/fixtures/home lua tests/test_filter.lua

log = { info = function(...) print("[log]", ...) end }

local yielded = {}
function yield(cand) yielded[#yielded + 1] = cand end

Candidate = {}
function Candidate.new(text, cmt, ctype)
    return { text = text, comment = cmt or "", type = ctype or "table" }
end
-- emulate librime-lua's constructor: Candidate(type, start, end_, text, comment)
setmetatable(Candidate, {
    __call = function(_, t, s, e, text, cmt)
        return { text = text, comment = cmt or "", type = t, start = s, _end = e }
    end,
})

-- fake helper responses keyed by query
HelperResponses = {
    ["\xe6\x9c\xaa\xe7\x9f\xa5\xe8\xaf\x8d"] = '{"q":"未知词","en":"","source":"pending"}',
}

local real_popen = io.popen
function io.popen(cmd)
    local q = cmd:match("q=(%S+)'") or cmd:match("%%E") and "" or nil
    -- decode simple percent-encoded utf-8
    if q then
        local decoded = q:gsub("%%(%x%x)", function(h)
            return string.char(tonumber(h, 16))
        end)
        if HelperResponses[decoded] then
            local f = { read = function(_, _) return HelperResponses[decoded] end, close = function() end }
            return f
        end
    end
    return real_popen(cmd)
end

-- stat stub: report a fixed mtime for the sample cache file only
local real_stat_popen_used = false

-- ---- run --------------------------------------------------------------
local M = require("rime_translate")

local env = { engine = { context = {}, schema = {} } }
M.init(env)

local function run_case(name, candidates, expect)
    yielded = {}
    local iter_idx = 0
    local input = {
        iter = function()
            return function()
                iter_idx = iter_idx + 1
                return candidates[iter_idx]
            end
        end,
    }
    M.func(input, env)
    local got = {}
    for i, c in ipairs(yielded) do
        got[i] = c.text .. "|" .. (c.comment or "")
    end
    local ok = true
    for i, e in ipairs(expect) do
        if got[i] ~= e then ok = false end
    end
    if ok then
        print("PASS " .. name)
    else
        print("FAIL " .. name)
        for i = 1, math.max(#got, #expect) do
            print("   got:     " .. tostring(got[i]))
            print("   expect:  " .. tostring(expect[i]))
        end
    end
end

local layout = os.getenv("EXPECT_LAYOUT") or "vertical"

if layout == "horizontal" then
    run_case("horizontal layout shows up to 2", {
        Candidate.new("跑"),
    }, { "跑|  run / operate" })
else
    if not os.getenv("FIXTURE") then
        run_case("offline hit via hot cache", {
            Candidate.new("苹果"),
        }, { "苹果|  apple" })

        run_case("vertical layout shows up to 5", {
            Candidate.new("果实"),
        }, { "果实|  apple / fruit" })

        run_case("vertical caps at configured max (6th word dropped)", {
            Candidate.new("跑"),
        }, { "跑|  run / operate / manage / race / walk" })
    end
end

run_case("non-CJK untouched", {
    Candidate.new("hello world"),
}, { "hello world|" })

run_case("unknown word -> no comment, still yielded", {
    Candidate.new("未知词"),
}, { "未知词|" })

-- shadow candidate replacement path (default fixtures only; home3 uses a
-- custom comment_format, so the exact comment differs)
ShadowCandidate = Candidate
if not os.getenv("FIXTURE") then
    run_case("shadow candidate gets replaced with comment", {
        Candidate.new("苹果", "", "simplified"),
    }, { "苹果|  apple" })
end

-- comment display overrides (tests/fixtures/home3)
if os.getenv("FIXTURE") == "home3" then
    -- comment_format wraps; max_comment_chars caps bytes but never splits
    -- a UTF-8 char ("〔apple / fruit〕" is 25 bytes; cap 10 -> "〔apple /")
    run_case("comment_format + max_comment_chars", {
        Candidate.new("果实"),
    }, { "果实|  〔apple /" })

    -- "〔apple〕" is 11 bytes; cap 10 backs off to the valid boundary "〔apple"
    run_case("annotate_first_only + boundary-safe truncation", {
        Candidate.new("苹果"),
        Candidate.new("跑"),
    }, { "苹果|  〔apple", "跑|" })
end
