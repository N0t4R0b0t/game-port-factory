-- harness/killsfx.lua -- T0109: a REAL hazard kill plays the killed sfx,
-- then the death box (box-open sfx + death tune) and the respawn tune,
-- and the game comes all the way back out the other side.
--
-- The other death tests fake it: they poke killed=1, which skips
-- kill_dizzy_msg -- and kill_dizzy_msg is exactly where the killed sfx
-- (sndfx 25) was hooked. So this one walks Dizzy into one of room 36's
-- own flames and lets the hazard code do the killing.
--
-- Flame boxes are read straight out of r2_room_flames (x,y pairs, 16x13
-- boxes) rather than hard-coded, and Dizzy is stepped through a few
-- candidate positions around the first flame until `killed` goes non-zero
-- -- a fixed guess at where his collision box overlaps would be exactly
-- the kind of silently-wrong test this harness keeps having to replace.
--
-- Verdicts it prints:
--   KILLSFX killed_by_hazard=yes  in_audio_when_killed=yes   -- sfx 25 ran
--   KILLSFX respawned=yes ... mainloop_running=yes           -- survived
--
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -seconds_to_run 40 \
--     -autoboot_script harness/killsfx.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end

local function in_audio()
  local pc=cpu.state["PC"].value
  return pc>=SYM.play_tone and pc<SYM.play_chirp
end

local f,loaded,started=0,false,false
local cands,ci,next_move={},1,0
local killed_at,audio_at_kill,dismiss_from,respawn_seen,done=nil,false,nil,nil,false
local rx,ry
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or done then return end

  if not started then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if mem:read_u8(SYM.cur_room)==36 and mem:read_u8(SYM.dizzy_y)~=0 then
      started=true; key("SPACE",false)
      -- respawn point the game will use after this death
      rx,ry=mem:read_u8(SYM.respawn_x),mem:read_u8(SYM.respawn_y)
      local fx,fy=mem:read_u8(SYM.r2_room_flames),mem:read_u8(SYM.r2_room_flames+1)
      -- candidate standing spots overlapping the first flame's 16x13 box
      for _,dx in ipairs({0,-4,-8,-12,4}) do
        for _,dy in ipairs({13,8,4,18}) do
          cands[#cands+1]={fx+dx, fy+dy}
        end
      end
      print(string.format("KILLSFX flame0 at %d,%d; %d candidate spots; respawn %d,%d",fx,fy,#cands,rx,ry))
      next_move=f+10
    end
    return
  end

  local killed=mem:read_u8(SYM.killed)
  if not killed_at then
    if killed~=0 then
      killed_at=f; audio_at_kill=in_audio()
      print(string.format("KILLSFX killed_by_hazard=yes at spot %d,%d  in_audio_when_killed=%s",
        cands[ci][1],cands[ci][2], audio_at_kill and "yes" or "no"))
    elseif f>=next_move then
      if ci>#cands then
        done=true; print("KILLSFX killed_by_hazard=NO -- no candidate spot overlapped the flame"); return
      end
      if next_move>0 and ci<=#cands then
        mem:write_u8(SYM.dizzy_x,cands[ci][1]); mem:write_u8(SYM.dizzy_y,cands[ci][2])
        mem:write_u8(SYM.dizzy_dy,0)
      end
      next_move=f+12
      -- only advance once this spot has had a chance to register
      if f>30 then ci=ci+1 end
      if ci>#cands+1 then ci=#cands+1 end
    elseif ci>=2 and ci-1<=#cands then
      -- hold him on the current spot so gravity doesn't carry him off
      mem:write_u8(SYM.dizzy_x,cands[ci-1][1]); mem:write_u8(SYM.dizzy_y,cands[ci-1][2])
      mem:write_u8(SYM.dizzy_dy,0)
    end
    return
  end

  -- dying: keep tapping SPACE so the death box gets dismissed
  key("SPACE", ((f-killed_at)%16)<6)
  -- Respawn in two stages, same trap pickupsfx.lua hit: gp_ud_respawn
  -- puts him at the respawn point BEFORE the new-life tune, and by the
  -- time the tune lets go, gravity (or room 36's troll knockback) has
  -- already moved him -- "at the point AND out of audio" never holds.
  if not respawn_seen then
    if not at_respawn then
      at_respawn = killed==0 and mem:read_u8(SYM.dizzy_x)==rx and mem:read_u8(SYM.dizzy_y)==ry
    elseif not in_audio() then
      clear=(clear or 0)+1
      if clear>=3 then respawn_seen=f; key("SPACE",false) end
    else
      clear=0
    end
  end
  if respawn_seen and f==respawn_seen+30 then
    local c0=mem:read_u8(SYM.rng_ctr)
    running_probe=c0
  end
  if respawn_seen and f==respawn_seen+60 then
    done=true
    local moved = mem:read_u8(SYM.rng_ctr)~=running_probe
    print(string.format("KILLSFX respawned=yes after %d frames  room=%d lives=%d  mainloop_running=%s",
      respawn_seen-killed_at, mem:read_u8(SYM.cur_room), mem:read_u8(SYM.lives), moved and "yes" or "NO"))
  end
  if not respawn_seen and f-killed_at>900 then
    done=true
    print(string.format("KILLSFX respawned=NO after 900 frames: room=%d x=%d y=%d killed=%d pc=%04x",
      mem:read_u8(SYM.cur_room),mem:read_u8(SYM.dizzy_x),mem:read_u8(SYM.dizzy_y),killed,cpu.state["PC"].value))
  end
end)
