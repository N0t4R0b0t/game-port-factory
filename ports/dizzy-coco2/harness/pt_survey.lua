-- pt_survey: dev aid (PT_MODE=probe PT_PROBE=harness/pt_survey.lua PT_FROM=N): resumes from checkpoint N-1 and prints
-- what the bot can do in the CURRENT room: reachable exits, actors, coins and their reachability from here.
return function(PT)
  local E = PT.env
  local SYM = E.SYM
  if tonumber(os.getenv("PT_FROM") or "1") > 1 then PT.resume_from_checkpoint() else PT.boot() end
  PT.nav.settle_free("survey")
  local s = E.getsnap()
  E.say("SURVEY room %d at (%d,%d)   %s", s.room, s.x, s.y, E.where())
  local M = PT.nav.mk_model()
  local _, dist = PT.nav.plan(M, s, { goal = function() return false end })
  local n = 0
  local rows = {}
  for k, d in pairs(dist) do n = n + 1; local x, y = k // 256, k % 256; rows[y] = rows[y] or {}; table.insert(rows[y], x) end
  local ys = {}
  for y in pairs(rows) do ys[#ys + 1] = y end
  table.sort(ys)
  E.say("  %d reachable standing nodes; surfaces (y: x ranges):", n)
  for _, y in ipairs(ys) do
    table.sort(rows[y])
    local runs, a, b = {}, nil, nil
    for _, x in ipairs(rows[y]) do
      if a and x == b + 4 then b = x else if a then runs[#runs + 1] = (a == b) and tostring(a) or (a .. ".." .. b) end a, b = x, x end
    end
    if a then runs[#runs + 1] = (a == b) and tostring(a) or (a .. ".." .. b) end
    E.say("    y=%3d: %s", y, table.concat(runs, " "))
  end
  for _, dir in ipairs({ "up", "down", "left", "right" }) do
    local acts = PT.nav.plan(M, s, { goal_ev = dir })
    if acts then
      local last = acts[#acts - 1]
      E.say("  exit %-5s reachable: %d macros, taken from (%s)", dir, #acts, last and (last.x .. "," .. last.y) or "here")
    else
      E.say("  exit %-5s NO", dir)
    end
  end
  -- actors / coins in this room
  local function rec(base, i) local a = base + i * 8 return { a = a, room = E.rd8(a), rou = E.rd8(a + 1), x = E.rd8(a + 2), y = E.rd8(a + 3), frame = E.rd8(a + 4), col = E.rd8(a + 7) } end
  for i = 0, E.NACT - 1 do local r = rec(SYM.actor_ram, i); if r.room == s.room then E.say("  actor b%02d rou=%d x=%d y=%d frame=%d", i, r.rou, r.x, r.y, r.frame) end end
  for i = 0, E.NACT_T - 1 do local r = rec(SYM.actor_init_tape, i); if r.room == s.room then E.say("  actor t%02d rou=%d x=%d y=%d frame=%d", i, r.rou, r.x, r.y, r.frame) end end
  for i = 0, 14 do local a = SYM.coin_ram + i * 3; if E.rd8(a) == s.room then E.say("  coin x=%d y=%d", E.rd8(a + 1), E.rd8(a + 2)) end end
  for i = 0, 14 do local a = SYM.coin_init_tape + i * 3; if E.rd8(a) == s.room then E.say("  coin(tape) x=%d y=%d", E.rd8(a + 1), E.rd8(a + 2)) end end
  -- screenshot
  local dump = os.getenv("PT_DUMP")
  if dump then
    E.wait(20)
    local base = E.rd8(SYM.cur_buf) == 0 and 0x4000 or 0x6000
    local fh = io.open(dump, "wb")
    for i = 0, 6143 do fh:write(string.char(E.rd8(base + i))) end
    fh:close()
  end
end
