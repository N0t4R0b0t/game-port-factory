-- harness/roomcmp_rec.lua -- T0255: the recorder half of tools/roomcmp.sh.  Loads a MAME state saved at the FIRST entry into a room
-- (PT_ENTRY_SAVE=1 in either bot: entry_<room>) and records, with NO keys pressed, one line group per ACTOR TICK of that machine (the tick is
-- defined in harness/roomcmp_lib.lua; tick n = the state after n actor ticks counted from the saved moment).
-- Run through the bots' engine (it provides the machine layer, the map, the state load plumbing):
--   PT_MODE=probe PT_PROBE=harness/roomcmp_rec.lua PT_EARLY=harness/roomcmp_rec.lua PT_STATE=entry_<room> RC_OUT=<file> [RC_TICKS=400] [PT_MACHINE=zx]
-- (tools/roomcmp.sh does it).  TWO PHASES: phase 1 is called by the frame driver at the first frame after the state load (PT_EARLY) and installs the
-- taps, so sample 1 is the very first actor tick after the saved moment; phase 2 (the engine's probe call, once scripts may run) waits for the
-- samples, dismisses message boxes, writes the file and exits.
-- Output (text, one trace per run; the comparer is tools/roomcmp/):
--   H machine=<zx|coco> room=<R> ticks=<N>
--   I <id> <room,x,y,frame,rou>           port only: the pristine record of slot <id> ("b07" base table, "t03" tape table)
--   T <n> f=<video frame> room= dx= dy= ff= seq= an= fl= coins= lives= killed= dont=      (Dizzy, in each machine's own units)
--   A <id> <hex bytes of the record>      ZX: 16-byte movingdata record "z<idx>".  Port: 8-byte record, id as in I
--   F <count> <x,y,ctr> ...   W <count> <x,y,ctr> ...   V name=hex ...      flames / water / extra state
--   B <n> <room>                          a message box went up during tick n (dismissed with a key; no text is recorded here)
-- Nothing in the trace is original text.
return function(PT)
  if PT.rc then return PT.rc.finish() end
  local E = PT.env
  local OUT = os.getenv("RC_OUT") or error("RC_OUT not set")
  local NT = tonumber(os.getenv("RC_TICKS") or "400")
  local L = dofile("harness/roomcmp_lib.lua")(PT)
  local R = { lines = {} }
  PT.rc = R
  local function put(fmt, ...) R.lines[#R.lines + 1] = string.format(fmt, ...) end
  local room0 = L.room()
  put("H machine=%s room=%d ticks=%d", L.ZX and "zx" or "coco", room0, NT)
  for _, l in ipairs(L.init_lines()) do R.lines[#R.lines + 1] = l end
  local samples = 0
  L.on_tick(function(n, flame_ov, water_ov)
    if samples >= NT then return end
    samples = samples + 1
    local r = L.room()
    put("T %d f=%d %s", n, E.getf(), L.dizzy_line())
    L.each_record(function(id, a, len, rm, orm)
      if rm == r or rm == room0 or orm == room0 then put("A %s %s", id, L.hexs(a, len)) end
    end)
    L.hazard_lines(put, flame_ov, water_ov)
  end)

  function R.finish()
    local prevbox, guard = false, 0
    E.setkeys(0)
    while samples < NT do
      E.yield()
      guard = guard + 1
      if guard > NT * 12 + 3000 then put("X timeout samples=%d ticks=%d", samples, L.ticks); break end
      local boxup = E.rd("msg_active") == 1 or E.in_msgwait()
      if boxup and not prevbox then put("B %d %d", L.ticks, E.rd("cur_room")) end
      prevbox = boxup
      E.setkeys(boxup and (((guard % 26) < 8) and E.K_SPACE or 0) or 0)
    end
    E.setkeys(0)
    local fh = assert(io.open(OUT, "w"))
    fh:write(table.concat(R.lines, "\n"), "\n")
    fh:close()
    print(string.format("ROOMCMP REC machine=%s room=%d samples=%d ticks=%d -> %s", L.ZX and "zx" or "coco", room0, samples, L.ticks, OUT))
    manager.machine:exit()
  end
end
