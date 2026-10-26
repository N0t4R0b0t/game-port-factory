-- T0088/T0089: proves play_chirp actually fires on a real pickup, not
-- just in isolation. Warp near room 36's apple (x=104,y=136) via a
-- scripted "killed=1" respawn teleport, walk onto it, press DOWN. Run
-- this WITH -wavwrite and check the capture for a short tone burst via
-- harness/audiocheck.py.
--
-- The action sequence starts when Dizzy has ACTUALLY ARRIVED at the
-- respawn point, not N frames after the killed=1 poke. That coupling
-- cost two rounds of re-tuning magic frame numbers: any blocking sound
-- added to the respawn path (the real new-life tune plays there now)
-- delays the teleport in wall-clock terms, which slid every fixed
-- window out from under the trajectory it was aimed at. Waiting on the
-- observed position instead makes this test indifferent to how long the
-- audio takes, which is the property it actually wanted all along.
-- (Widening the windows was tried first and made it WORSE -- with more
-- time Dizzy just falls further past the apple.)
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end
local f,loaded,live,done,poked=0,false,nil,false,false
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or done then return end
  if f%14==0 then key("SPACE",(f//14)%2==0) end
  if not poked then
    -- T0125: the mainloop must be RUNNING: new_game's set_checkpoint and
    -- gameplay_init run after `sta dizzy_y` and undo a warp poked in between
    boot_live=(mem:read_u8(SYM.cur_room)==36 and mem:read_u8(SYM.dizzy_y)~=0) and (boot_live or 0)+1 or 0
    if boot_live>=60 then
      mem:write_u8(SYM.respawn_room,36); mem:write_u8(SYM.respawn_x,92)   -- T0125: 92, see below
      mem:write_u8(SYM.respawn_y,136);   mem:write_u8(SYM.killed,1)
      poked=true
    end
    return
  end
  if not live then
    -- Wait for the teleport to land AND for the CPU to have left the
    -- audio routines. Arrival alone was not enough: gp_ud_respawn sets
    -- dizzy_x/y BEFORE it plays the new-life tune, so the position reads
    -- correct while the game is still frozen inside play_tune -- and
    -- the scripted walk then spent its window pressing keys nobody was
    -- polling. It broke the moment that tune grew by 24ms. The PC range
    -- play_tone..play_chirp covers play_tone, pt_rest, pt_step and
    -- play_tune's own loop, so three consecutive frames outside it means
    -- the mainloop really is running again, whatever the tune's length.
    -- Two stages, not one combined test: by the time the tune finishes,
    -- gravity has already moved him off the exact respawn y, so
    -- "at the coordinates AND out of audio" can never be true at once.
    local pc=cpu.state["PC"].value
    local in_audio = pc>=SYM.play_tone and pc<SYM.play_chirp
    if not arrived then
      -- T0125: 92, not 100 -- 100 only reached the apple table because a troll
      -- knockback surviving the respawn slid him 8px left (fixed in gp_ud_respawn)
      arrived = mem:read_u8(SYM.dizzy_x)==92 and mem:read_u8(SYM.dizzy_y)==136
    elseif not in_audio then
      clear=(clear or 0)+1
      if clear>=3 then live=f end
    else
      clear=0
    end
    return
  end
  -- DOWN is TAPPED while Dizzy is over the apple, not pressed once at a
  -- chosen frame. After the respawn he slides down-left off x=100 on his
  -- own and is over the apple only between x=96 and x=88. Worse, a single
  -- press is phase-sensitive by design: try_pickup starts PICKUP_COOLDOWN
  -- on the first poll that sees DOWN whether or not it hit anything, so a
  -- press landing on an unlucky mainloop pass is swallowed. Measured with
  -- a sweep of single presses on the SAME build: frames 5,10,15,25,30
  -- after resume picked it up, 0 and 20 did not, 40+ was past the apple.
  -- Two earlier fixed-window versions of this test broke that way and
  -- read as game regressions; the game was fine both times.
  local a=f-live
  key("RIGHT", a<20)
  local x=mem:read_u8(SYM.dizzy_x)
  key("DOWN", x<=96 and x>=88 and (a%16)<6)
  local picked=false
  for i=0,19 do local b=SYM.actor_ram+i*8
    if mem:read_u8(b+4)==17 and mem:read_u8(b)==255 then picked=true end end
  if picked or a==200 then
    done=true
    local apple_room
    for i=0,19 do local b=SYM.actor_ram+i*8
      if mem:read_u8(b+4)==17 then apple_room=mem:read_u8(b) end end
    print(string.format("PICKUPSFX room=%d x=%d y=%d apple_room=%s (255=picked up)",
      mem:read_u8(SYM.cur_room),mem:read_u8(SYM.dizzy_x),mem:read_u8(SYM.dizzy_y),tostring(apple_room)))
  end
end)
