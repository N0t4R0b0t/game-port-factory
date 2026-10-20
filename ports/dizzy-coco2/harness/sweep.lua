-- harness/sweep.lua -- BEHAVIOURAL DIFF between two builds.
--
-- WHY THIS EXISTS: a playtester reports "I can't make that jump any
-- more". You do not know the route, and the screenshot does not tell
-- you. Guessing the route burned most of a session on T0093: three
-- hand-written jump tests all "passed" on both builds because they held
-- a direction and re-jumped on a cycle, so they measured "possible in
-- unlimited attempts", not "reachable". The bug was two surfaces away
-- from where every one of those tests looked.
--
-- So do not guess. Run the SAME input script from EVERY walkable start
-- position in the room against both binaries and diff the outcomes.
-- T0093 fell out in one run: from (120,152) holding RIGHT, the good
-- build reaches apex y=92 and the bad one stops at y=113.
--
--   for v in good bad; do
--     DIZZY_BIN=/tmp/$v.bin DIZZY_MAP=/tmp/$v.map \
--       mame coco2b -ext "" -nothrottle -video none -sound none \
--       -seconds_to_run 90 -autoboot_script harness/sweep.lua \
--     | grep "^SWEEP " > /tmp/sweep.$v.txt
--   done
--   diff /tmp/sweep.good.txt /tmp/sweep.bad.txt
--
-- Read SURF below out of `tools/roomview.py <room> --surfaces`. The
-- x clamp to DIZZY_MINX/MAXX matters: a start point at x=224 is at the
-- room edge, so holding RIGHT triggers a room transition and the trial
-- measures nothing.
--
-- LIMITATION -- READ BEFORE BELIEVING A DIFF. Input is driven on a
-- REAL-TIME clock, so this measures drawing time as well as physics.
-- Change how long draw_ui takes and trials move, with the physics
-- untouched: T0092 shifted 20 of 36 that way while the frame rate stayed
-- pegged at 15.0 passes/sec and the room image stayed byte-identical.
--
-- So a diff after a RENDERING change is expected and is not evidence of
-- a gameplay regression; corroborate with harness/rate.lua (passes/sec
-- unchanged?) and harness/lzverify.lua (room image unchanged?) before
-- concluding anything. A diff after a PHYSICS change still means what
-- you think it means.
--
-- A pass clock would fix this and was tried: rng_ctr is NOT usable as
-- one. It only steps when something consumes randomness, so in a quiet
-- room it never ticks and the sweep stalls with zero trials -- which is
-- also why rate.lua warps to rooms that have actors. Adding a real pass
-- counter would mean changing the binary under test.
--
-- SPACE is toggled for the WHOLE run (NOTES.md T0061): msg_wait_dismiss
-- blocks the main loop, and a frozen game reads as a failed jump. The
-- first version of this script stopped toggling after boot and every
-- single trial reported "never left room 36".
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local row3 = manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local function load_decb(path)
  local fh=io.open(path,"rb"); local data=fh:read("*all"); fh:close(); local pos=1
  local allram=false
  while pos<=#data do local t=data:byte(pos)
    if t==0 then local len=data:byte(pos+1)*256+data:byte(pos+2)
      local addr=data:byte(pos+3)*256+data:byte(pos+4)
      if addr>=0x8000 and not allram then mem:write_u8(0xffdf,0); allram=true end
      for i=0,len-1 do mem:write_u8(addr+i,data:byte(pos+5+i)) end
      pos=pos+5+len
    elseif t==0xFF then return data:byte(pos+3)*256+data:byte(pos+4) else break end end
end
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end

-- (x,y) start points: a few along each walkable surface of room 35,
-- clamped to DIZZY_MINX/DIZZY_MAXX.
local SURF = {{80,232,248},{112,224,232},{120,168,192},{128,160,168},
              {136,152,160},{136,192,200},{144,144,152},{152,104,144},
              {152,200,208},{160,208,224},{168,224,248}}
local P = {}
local seen = {}
for _,s in ipairs(SURF) do
  local y,x0,x1 = s[1],s[2],s[3]
  for x=x0,x1-1,8 do
    -- Clamp to the standing range, then DEDUPE. Without the dedupe a
    -- surface running past DIZZY_MAXX yields the same start point
    -- several times, and that point is at the room edge where holding a
    -- direction transitions immediately -- so its trials disagree with
    -- EACH OTHER inside one run and read as a build difference in the
    -- diff. Cost a real investigation once; do not remove.
    local cx = x < 8 and 8 or (x > 224 and 224 or x)
    local k = cx .. "," .. y
    if not seen[k] then seen[k] = true; P[#P+1] = {cx,y} end
  end
end
-- Two input scripts per start point: hold RIGHT+jump, and hold LEFT+jump.
local DIRS = {"RIGHT","LEFT"}
local SETTLE, ARC = 40, 80
local PER = SETTLE + ARC
local f,loaded,done,started = 0,false,false,nil
local best, out = 255, {}
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded then return end
  local rel=f-30
  if rel%14==0 then key("SPACE",(rel//14)%2==0) end
  -- Wait for the game to be LIVE rather than for a fixed frame count.
  -- A fixed count ties every trial's phase to how long boot takes, so
  -- anything that changes boot (T0092 added a title screen and a
  -- wait-for-SPACE) shifts all the trials and shows up in the diff as
  -- six "behaviour changes" that are nothing of the kind.
  if not started then
    if mem:read_u8(SYM.cur_room)==36 and mem:read_u8(SYM.dizzy_y)~=0 then
      started = rel + 60      -- let the first room settle
    end
    return
  end
  if rel < started then return end
  local t=rel-started
  local n = t//PER + 1
  local total = #P * #DIRS
  if n > total then
    if not done then done=true
      for i=1,total do print("SWEEP "..out[i]) end
      print("SWEEP-END "..total)
    end
    return
  end
  local pi  = (n-1)//#DIRS + 1
  local dir = DIRS[(n-1)%#DIRS + 1]
  local p   = t%PER
  if p==0 then
    key("RIGHT",false); key("LEFT",false); key("UP",false)
    mem:write_u8(SYM.respawn_room,35); mem:write_u8(SYM.respawn_x,P[pi][1])
    mem:write_u8(SYM.respawn_y,P[pi][2]); mem:write_u8(SYM.killed,1)
    best=255; return
  end
  if p < SETTLE then return end
  local a = p-SETTLE
  key(dir,true); key("UP", (a%24)<6)
  local r,x,y = mem:read_u8(SYM.cur_room),mem:read_u8(SYM.dizzy_x),mem:read_u8(SYM.dizzy_y)
  if r==35 and y<best then best=y end
  if a==ARC-1 then
    out[n]=string.format("%3d,%3d %-5s -> room=%d x=%3d y=%3d apex=%3d",
                         P[pi][1],P[pi][2],dir,r,x,y,best)
  end
end)
