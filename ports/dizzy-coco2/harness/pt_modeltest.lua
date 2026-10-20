-- pt_modeltest: differential test of the Lua physics model against the emulator.
-- Plans random reachable standing positions in the CURRENT room (room 36 after boot) and runs them with
-- real key input; every macro's end state is compared with the model's (exec_plan does that).
-- Prints MODELTEST PASS|FAIL.  PT_MT_N = number of random goals (default 25), PT_MT_ROOMS unused.
return function(PT)
  local E = PT.env
  -- PT_FROM=N (with PT_MODE=modeltest): test in whatever room checkpoint N-1 left Dizzy in (no troll avoidance then); default: boot, room 36
  local from = tonumber(os.getenv("PT_FROM") or "1")
  if from > 1 then PT.resume_from_checkpoint() else PT.boot() end
  local room0 = E.getsnap() and E.getsnap().room or 36
  local N = tonumber(os.getenv("PT_MT_N") or "25")
  local seed = tonumber(os.getenv("PT_MT_SEED") or "1")
  math.randomseed(seed)
  local nav = PT.nav
  local ok_n, bad_n, macros = 0, 0, 0
  for i = 1, N do
    nav.settle_free("mt")
    local s = E.getsnap()
    local M = nav.mk_model()
    local avoid = (from == 1) and function(x, y) return x > 160 or x < 64 end or nil   -- keep clear of the troll (knock-back is not in the model)
    local _, dist = nav.plan(M, s, { goal = function() return false end, avoid = avoid })
    local keys = {}
    for k, d in pairs(dist) do keys[#keys + 1] = k end
    table.sort(keys)
    local k = keys[math.random(#keys)]
    local gx, gy = k // 256, k % 256
    local acts = nav.plan(M, s, { goal = function(st) return st.x == gx and st.y == gy end, avoid = avoid })
    if acts then
      macros = macros + #acts
      local ok, why = nav.exec_plan(acts, "mt")
      if ok then ok_n = ok_n + 1 else bad_n = bad_n + 1; E.say("MODELTEST mismatch goal #%d (%d,%d) from (%d,%d): %s", i, gx, gy, s.x, s.y, why) end
    end
    if E.getsnap().room ~= room0 then E.say("MODELTEST left room %d; stopping", room0); break end
  end
  E.say("MODELTEST %s goals_ok=%d goals_bad=%d macros=%d nodes", bad_n == 0 and "PASS" or "FAIL", ok_n, bad_n, macros)
end
