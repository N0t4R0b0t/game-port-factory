-- Lookup into the original game's text, by key "X-ALL:<line>[#n]" (1-based line of X-ALL.TXT, ordinal when a
-- line holds several strings). The strings themselves are the original's and are never committed: they
-- live in harness/orig_text.lua, which `textsplit export-lua` writes from YOUR extracted/game_text.json
-- (tools/bootstrap.sh step harness_text). Usage:  local OT = dofile("harness/orig.lua");  OT("X-ALL:733")
-- Run from the port root (as the verify_*.sh scripts do).
local ok, t = pcall(dofile, "harness/orig_text.lua")
if not ok or type(t) ~= "table" then
  error("harness/orig_text.lua is missing: it is generated from your own X-ALL.TXT. Run "
    .. "tools/bootstrap.sh --steps extract,harness_text (see docs/PROVENANCE.md). Underlying: " .. tostring(t), 0)
end
return function(key)
  -- one value only: a bare `return assert(...)` would also return the message, and as the last item of a
  -- table constructor that adds a bogus extra element
  local s = t[key]
  if s == nil then error("harness/orig_text.lua has no original string " .. key .. " (different X-ALL.TXT revision?)", 2) end
  return s
end
