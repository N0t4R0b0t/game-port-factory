-- harness/tape_boxreset.lua -- T0258 (D1): the box-close reset. X-ALL: every message box ends with
-- windowrou1 -> resetuproom -> roomsetup -> resetroommoving, which re-runs each room actor's reset routine
-- (Armorog falls back asleep unless fed, the hawk resets its dive, the dragon's breath ends, the flames/water
-- counters restart). The port does it with box_reset (room36.asm).
--
-- For rooms 50 (Armorog), 49 (hawk), 54 (dragon + flames) and 24 (fed Armorog is NOT reset: checked in 50):
-- warp in, let a real box open (ratloaf_msg_pending -> show_pending_messages -> msg_chatter), poke the actor
-- state WHILE the box is up (the game is frozen), dismiss with SPACE, and read the state the first frames after.
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 200 \
--     -autoboot_script harness/tape_boxreset.lua
-- Prints TAPEBOXRESET PASS / FAIL. (ratloaf: a ONE-box message; the apple one is a 4-box chatter, so msg_active drops between its boxes.)
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end
local function stray_fix(path)
  local fh=io.open(path,"rb"); local d=fh:read("*all"); fh:close(); local pos=1
  while pos<=#d and d:byte(pos)==0 do
    local len=d:byte(pos+1)*256+d:byte(pos+2); local addr=d:byte(pos+3)*256+d:byte(pos+4)
    for i=0,len-1 do local a=addr+i
      if a>=0x0E00 and a<0x8000 and mem:read_u8(a)~=d:byte(pos+5+i) then mem:write_u8(a,d:byte(pos+5+i)) end end
    pos=pos+5+len
  end
end
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end
local function r(s) return mem:read_u8(SYM[s]) end
local function w(s,v) mem:write_u8(SYM[s],v) end
-- record of routine `rou` in room `room`, in the base table or the tape table
local function rec(room,rou)
  for _,t in ipairs{{SYM.actor_ram,SYM.ACTOR_COUNT},{SYM.actor_init_tape,SYM.ACTOR_COUNT_tape}} do
    for i=0,t[2]-1 do local b=t[1]+i*8
      if mem:read_u8(b+1)==rou and (mem:read_u8(b)==room) then return b end end end
end
local ROU_ARMOROG, ROU_HAWK = 3, 7
-- per room: setup (run while the box is up) and check (run on the first frames after the dismiss)
local cases = {
  {room=50, x=16, name="Armorog running -> asleep",
   setup=function() local b=rec(50,ROU_ARMOROG); mem:write_u8(b+2,120); mem:write_u8(b+5,2) end,
   check=function() local b=rec(50,ROU_ARMOROG); local x,v=mem:read_u8(b+2),mem:read_u8(b+5)
     return x==SYM.ARM_START_X and v==0, string.format("x=%d v1=%d (want x=%d v1=0)",x,v,SYM.ARM_START_X) end},
  {room=50, x=16, name="Armorog fed (v1=4) is kept",
   setup=function() local b=rec(50,ROU_ARMOROG); mem:write_u8(b+2,78); mem:write_u8(b+5,4) end,
   check=function() local b=rec(50,ROU_ARMOROG); local x,v=mem:read_u8(b+2),mem:read_u8(b+5)
     return x==78 and v==4, string.format("x=%d v1=%d (want 78/4)",x,v) end},
  {room=49, x=40, name="hawk dive -> patrol",
   setup=function() local b=rec(49,ROU_HAWK); mem:write_u8(b+3,100); mem:write_u8(b+5,1) end,
   check=function() local b=rec(49,ROU_HAWK); local y,v=mem:read_u8(b+3),mem:read_u8(b+5)
     return y==52 and v==0, string.format("y=%d v1=%d (want 52/0)",y,v) end},
  {room=54, x=40, name="dragon breath ends, flame counter restarts",
   setup=function() w("dragon_fire",20); w("flame_ctr",9); w("water_ctr",2) end,
   check=function() local d,fc=r("dragon_fire"),r("flame_ctr")
     return d<=2 and fc<=3, string.format("dragon_fire=%d flame_ctr=%d (want <=2, <=3: frozen at 20/9 without the reset)",d,fc) end},
}
local f,loaded,stage,t,ci=0,false,"boot",0,1
local boot_live,fails=0,0
local after=0
local function fail(msg) print("TAPEBOXRESET FAIL at "..stage..": "..msg); stage="done"; manager.machine:exit() end
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  if f==31 then stray_fix(os.getenv("DIZZY_BIN")) end
  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    boot_live=(r("cur_room")==36 and r("dizzy_y")~=0) and boot_live+1 or 0
    if boot_live>=60 then key("SPACE",false); stage="warp"; t=f end
    return
  end
  if r("lives")<2 then w("lives",2) end
  local c=cases[ci]
  if stage=="warp" then
    w("respawn_room",c.room); w("respawn_x",c.x); w("respawn_y",176); w("killed",1)
    stage="arrive"; t=f
  elseif stage=="arrive" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if r("cur_room")==c.room and r("killed")==0 then key("SPACE",false); stage="settle"; t=f end
    if f-t>1500 then fail("never arrived in room "..c.room) end
  elseif stage=="settle" then
    if f-t>=60 then w("ratloaf_msg_pending",1); stage="boxup"; t=f end
  elseif stage=="boxup" then
    if r("msg_active")==1 and f-t>=5 then c.setup(); key("SPACE",false); stage="hold"; t=f end
    if f-t>600 then fail("no box opened in room "..c.room) end
  elseif stage=="hold" then
    if f-t>=20 then key("SPACE",true); stage="press"; t=f end
  elseif stage=="press" then
    if r("msg_active")==0 then key("SPACE",false); stage="after"; after=0 end
    if f-t>200 then fail("box never closed") end
  elseif stage=="after" then
    after=after+1
    if after==3 then
      local ok,info=c.check()
      print(string.format("TAPEBOXRESET %s room %d: %s: %s", ok and "ok  " or "FAIL", c.room, c.name, info))
      if not ok then fails=fails+1 end
      ci=ci+1
      if ci>#cases then
        print(fails==0 and "TAPEBOXRESET PASS" or ("TAPEBOXRESET FAIL "..fails))
        stage="done"; manager.machine:exit()
      else stage="warp" end
    end
  end
end)
