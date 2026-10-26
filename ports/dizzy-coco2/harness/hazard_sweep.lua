-- harness/hazard_sweep.lua -- T0255: where does the room kill Dizzy?  Loads the entry state of a room (PT_STATE=entry_<R>, as roomcmp_rec.lua) on EITHER machine
-- and sweeps Dizzy over a grid of positions: at every actor tick Dizzy is put at the next grid point (x in the port's pixels, y = FEET y), the main loop
-- runs one tick, and the machine's own `killed` byte says whether anything killed him there.  Output: one line "x y" (port units: x in px, feet y) per
-- killing position, to HS_OUT; tools/hazardcmp.sh runs both machines and diffs the two lists.
--   Static hazards (flames, water, daggers, cogs, the closed gate) must give the same list; moving actors (rat, hawk, croc, lifts) are phase-dependent.
-- Env: HS_OUT, HS_X0 HS_X1 HS_XS (px, default 0 252 4), HS_Y0 HS_Y1 HS_YS (feet y, default 78 176 2).
-- ZX pokes: x = px/4 (units), y = feet-1, dy=0, floor=1, sequence=0, animation=0, killed=0, left=right=jump=0.  Port pokes: dizzy_x/y, dy=0, floor=1,
-- seq=0, killed=0, keyflags=0, troll_launching=0.  `killed` is cleared after each probe so no death box ever opens.
return function(PT)
  if PT.rc then return PT.rc.finish() end
  local E = PT.env
  local L = dofile("harness/roomcmp_lib.lua")(PT)
  local ZX, Zm, SYM, rd8, mem = L.ZX, E.Zm, E.SYM, E.rd8, E.mem
  local OUT = os.getenv("HS_OUT") or error("HS_OUT not set")
  local function num(n, d) return tonumber(os.getenv(n) or "") or d end
  local X0, X1, XS = num("HS_X0", 16), num("HS_X1", 212), num("HS_XS", 4)
  local Y0, Y1, YS = num("HS_Y0", 78), num("HS_Y1", 176), num("HS_YS", 2)
  local room0 = L.room()
  local R = { kills = {}, done = false }
  PT.rc = R
  local pts = {}
  for y = Y0, Y1, YS do for x = X0, X1, XS do pts[#pts + 1] = { x, y } end end
  local idx, state = 0, "poke"       -- poke a point, then read the verdict at the NEXT tick
  local cur = nil
  local settle = 3                   -- ticks to let the entry settle first
  local function poke(p)
    if ZX then
      local A = Zm.A
      mem:write_u8(A.x, p[1] // 4); mem:write_u8(A.y, p[2] - 1); mem:write_u8(A.dy, 0)
      mem:write_u8(A.floor, 1); mem:write_u8(A.sequence, 0); mem:write_u8(A.animation, 0); mem:write_u8(A.killed, 0)
      mem:write_u8(A.left, 0); mem:write_u8(A.right, 0); mem:write_u8(A.jump, 0)
      mem:write_u8(A.eggcount, 200)    -- the ISR's updatedizzy is `dec eggcount / ret nz`: keeping it high freezes Dizzy, so no gravity step runs between the poke and the hazard check
    else
      mem:write_u8(SYM.dizzy_x, p[1]); mem:write_u8(SYM.dizzy_y, p[2]); mem:write_u8(SYM.dizzy_dy, 0)
      mem:write_u8(SYM.dizzy_floor, 1); mem:write_u8(SYM.dizzy_seq, 0); mem:write_u8(SYM.killed, 0)
      mem:write_u8(SYM.keyflags, 0); mem:write_u8(SYM.troll_launching, 0)
    end
  end
  -- the verdict is the WRITE of a non-zero `killed` (the port's hazards set killed=1, and update_death would open the death box in the same pass, which
  -- blocks the game): the tap records the kill for the current grid point and returns 0, so no death ever starts on either machine.
  local kaddr = ZX and Zm.A.killed or SYM.killed
  PT.hs_ktap = mem:install_write_tap(kaddr, kaddr, "hs_kill", function(off, data)
    if data ~= 0 and cur and not cur.hit then cur.hit = true; R.kills[#R.kills + 1] = string.format("%d %d", cur[1], cur[2]) end
    if data ~= 0 and not ZX then return 0 end     -- ZX kills count down from >= 10 and the next poke clears them; returning 0 there corrupted the water routine's state
  end)
  local function step()
    if settle > 0 then settle = settle - 1; return end
    if L.room() ~= room0 then if os.getenv("HS_DEBUG") and not R.warned then R.warned = true; print("hs LEFT ROOM at idx", idx, L.room(), L.dizzy_line()) end return end              -- a probe took him out of the room (an exit): skip until he is back
    cur = nil
    idx = idx + 1
    if os.getenv("HS_DEBUG") and idx > 17 and idx < 40 then print("hs idx", idx, "room", L.room(), "tick", L.ticks, L.dizzy_line()) end
    if idx > #pts then R.done = true; return end
    cur = pts[idx]
    poke(cur)
  end
  -- ZX: the main-loop run (oldclock write, the hazards of the NEXT run see the poke).  Port: the END of a pass (dizzy_h write): the next pass's
  -- actors_pass runs the hazard checks BEFORE the physics moves him.
  if ZX then L.on_tick(function() step() end)
  else PT.hs_tap = mem:install_write_tap(SYM.dizzy_h, SYM.dizzy_h, "hs_pass", function() step() end) end
  function R.finish()
    E.setkeys(0)
    local guard = 0
    while not R.done and guard < (#pts + 20) * 40 do
      E.yield(); guard = guard + 1
      local boxup = E.rd("msg_active") == 1 or E.in_msgwait()      -- a proximity box (a person, a pickup) in the way: dismiss it
      E.setkeys(boxup and (((guard % 26) < 8) and E.K_SPACE or 0) or 0)
    end
    if not R.done and os.getenv("HS_DEBUG") then print("hs STUCK idx", idx, "pc", string.format("%04x", E.pc()), "msgwait", tostring(E.in_msgwait()), L.dizzy_line(), "killedtap", tostring(cur and cur.hit)) end
    local fh = assert(io.open(OUT, "w"))
    for _, l in ipairs(R.kills) do fh:write(l, "\n") end
    fh:close()
    print(string.format("HAZARD SWEEP machine=%s room=%d points=%d kills=%d done=%s -> %s", ZX and "zx" or "coco", room0, #pts, #R.kills, tostring(R.done), OUT))
    manager.machine:exit()
  end
end
