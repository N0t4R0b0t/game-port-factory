-- harness/tape_miner.lua -- T0239: room 41's miner (X-ALL.TXT minerrou/
-- proxminerou). Walking into the box (232,120,8,32) at the right edge:
-- the miner appears (room 41, x=232, var1=1), the FIRST contact shows
-- goawaymess, the troll in room 36 is removed (actor room 255 +
-- troll_bribed) and Dizzy is shoved back with trollrou's own launch.
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 90 \
--     -autoboot_script harness/tape_miner.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
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
local NACT_T = SYM.ACTOR_COUNT_tape
local NACT = SYM.ACTOR_COUNT
local ROU_MINER, ROU_TROLL = 16, 12
local function r(s) return mem:read_u8(SYM[s]) end
local function pc() return cpu.state["PC"].value end
local function stack_has(lo,hi)
  local sp=cpu.state["S"].value
  for i=0,63 do if sp+i+1>=0x100 then break end local a=mem:read_u8(sp+i)*256+mem:read_u8(sp+i+1)
    if a>=lo and a<hi then return true end end
  return false
end
local function in_msgwait()
  local p=pc()
  return (p>=SYM.msg_wait_dismiss and p<SYM.fb_stablekeys) or stack_has(SYM.msg_wait_dismiss,SYM.fb_stablekeys)
end
local function in_audio() local p=pc() return p>=SYM.play_tone and p<SYM.play_chirp end
local function findrou(base,n,rou)
  for i=0,n-1 do local b=base+i*8 if mem:read_u8(b+1)==rou then return b end end
end
local function miner() return findrou(SYM.actor_init_tape,NACT_T,ROU_MINER) end
local function troll() return findrou(SYM.actor_ram,NACT,ROU_TROLL) end

local f,loaded,stage,t=0,false,"boot",0
local boot_live,settle_count,busy=0,0,0
local seen_launch,seen_msg=false,false
local x_at_hit=nil
local function fail(msg) print("TAPEMINER FAIL at "..stage..": "..msg); stage="done"; manager.machine:exit() end

emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  if f==31 then stray_fix(os.getenv("DIZZY_BIN")) end
  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    boot_live=(r("cur_room")==36 and r("dizzy_y")~=0) and boot_live+1 or 0
    if boot_live>=60 then
      key("SPACE",false)
      local mb=miner()
      if not mb then return fail("no miner record") end
      if mem:read_u8(mb)~=255 then return fail("miner should start out of the world (room 255), is "..mem:read_u8(mb)) end
      if mem:read_u8(troll())~=36 then return fail("troll should start in room 36") end
      mem:write_u8(SYM.respawn_room,41); mem:write_u8(SYM.respawn_x,180)
      mem:write_u8(SYM.respawn_y,160); mem:write_u8(SYM.killed,1)
      stage="arrive"; t=f
    end
    return
  end
  if r("lives")<2 then mem:write_u8(SYM.lives,2) end
  if stage=="arrive" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if r("cur_room")==41 and r("killed")==0 then key("SPACE",false); stage="settle"; t=f end
    if f-t>1000 then fail("never arrived in room 41") end
  elseif stage=="settle" then
    settle_count=(r("dizzy_floor")==1) and settle_count+1 or 0
    if settle_count>=10 then
      print(string.format("TAPEMINER settled x=%d y=%d", r("dizzy_x"), r("dizzy_y"))); stage="walk"; t=f
    end
    if f-t>1200 then fail("never landed") end
  elseif stage=="walk" then
    local mb=miner()
    if mem:read_u8(mb)==41 and not x_at_hit then x_at_hit=r("dizzy_x")
      print(string.format("TAPEMINER miner appeared room=41 x=%d var1=%d, dizzy x=%d", mem:read_u8(mb+2), mem:read_u8(mb+5), x_at_hit)) end
    if in_msgwait() then seen_msg=true; busy=busy+1; key("SPACE",(busy//14)%2==0); key("RIGHT",false)
    else key("SPACE",false); key("RIGHT", not seen_launch) end
    if r("troll_launching")~=0 then seen_launch=true end
    if seen_launch and r("troll_launching")==0 then
      key("RIGHT",false)
      local tb=troll()
      local ok = seen_msg and mem:read_u8(mb+2)==232 and mem:read_u8(mb+5)==1
        and mem:read_u8(tb)==255 and r("troll_bribed")==1 and r("dizzy_x")<x_at_hit
      print(string.format("TAPEMINER %s: msg=%s launch=yes miner(x=%d var1=%d) troll room=%d bribed=%d dizzy x %d->%d",
        ok and "PASS" or "FAIL", tostring(seen_msg), mem:read_u8(mb+2), mem:read_u8(mb+5), mem:read_u8(tb), r("troll_bribed"), x_at_hit, r("dizzy_x")))
      stage="done"; manager.machine:exit()
    end
    if f-t>2500 then key("RIGHT",false); fail(string.format("no launch (x=%d y=%d msg=%s)", r("dizzy_x"), r("dizzy_y"), tostring(seen_msg))) end
  end
end)
