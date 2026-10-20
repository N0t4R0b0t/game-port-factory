-- harness/tape_hawk.lua -- T0239: room 49's hawk (X-ALL.TXT hawkrou).
-- (1) patrols: x sweeps ~32..160 px at y=52 cycling frames 97-99;
-- (2) with Dizzy in the strip below it, dives (var1=1, frame 97, y+=8)
-- and (3) kills with killedbyhawk (death_msg == msg_killedbyhawk).
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 120 \
--     -autoboot_script harness/tape_hawk.lua
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
local ROU_HAWK = 7
local function r(s) return mem:read_u8(SYM[s]) end
local function hawk()
  for i=0,NACT_T-1 do local b=SYM.actor_init_tape+i*8
    if mem:read_u8(b+1)==ROU_HAWK then return b end end
end
local f,loaded,stage,t=0,false,"boot",0
local boot_live,settle_count=0,0
local xmin,xmax=255,0
local frames={}
local dive_y0,dived=nil,false
local function fail(msg) print("TAPEHAWK FAIL at "..stage..": "..msg); stage="done"; manager.machine:exit() end
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
      -- stand OUTSIDE the dive strip first (x=40) to watch the patrol
      mem:write_u8(SYM.respawn_room,49); mem:write_u8(SYM.respawn_x,40)
      mem:write_u8(SYM.respawn_y,176); mem:write_u8(SYM.killed,1)
      stage="arrive"; t=f
    end
    return
  end
  if r("lives")<2 then mem:write_u8(SYM.lives,2) end
  if stage=="arrive" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if r("cur_room")==49 and r("killed")==0 then key("SPACE",false); stage="settle"; t=f end
    if f-t>1000 then fail("never arrived in room 49") end
  elseif stage=="settle" then
    settle_count=(r("dizzy_floor")==1) and settle_count+1 or 0
    if settle_count>=10 then print(string.format("TAPEHAWK settled x=%d y=%d", r("dizzy_x"), r("dizzy_y"))); stage="patrol"; t=f end
    if f-t>1200 then fail("never landed") end
  elseif stage=="patrol" then
    local hb=hawk()
    local x,y,fr,v1=mem:read_u8(hb+2),mem:read_u8(hb+3),mem:read_u8(hb+4),mem:read_u8(hb+5)
    if x<xmin then xmin=x end
    if x>xmax then xmax=x end
    frames[fr]=true
    if f-t>=600 then
      local n=0 for _ in pairs(frames) do n=n+1 end
      if y~=52 or v1~=0 then return fail(string.format("hawk should patrol at y=52 var1=0, got y=%d v1=%d", y, v1)) end
      if xmax-xmin<100 or n<3 then return fail(string.format("patrol range %d..%d, %d frames", xmin, xmax, n)) end
      print(string.format("TAPEHAWK PASS patrol: x %d..%d (want ~32..160), %d frames, y=52", xmin, xmax, n))
      -- now step into the strip
      mem:write_u8(SYM.dizzy_x,100); mem:write_u8(SYM.dizzy_y,176); mem:write_u8(SYM.dizzy_dy,0)
      stage="dive"; t=f
    end
  elseif stage=="dive" then
    local hb=hawk()
    local y,v1=mem:read_u8(hb+3),mem:read_u8(hb+5)
    if v1==1 and not dived then dived=true; dive_y0=y; print(string.format("TAPEHAWK dive started hawk x=%d y=%d dizzy x=%d", mem:read_u8(hb+2), y, r("dizzy_x"))) end
    if r("killed")~=0 then
      kseen=(kseen or 0)+1
      -- the sound effect inside kill_dizzy_msg runs before it stores
      -- death_msg and MAME can sample mid-routine: wait a few frames
    end
    if (kseen or 0)>=4 then
      local dm=mem:read_u8(SYM.death_msg)*256+mem:read_u8(SYM.death_msg+1)
      -- T0237: death_msg is stored AFTER kill_dizzy_msg's blocking play_killed returns (tape_dragon40.lua, T0223): wait for it (up to 30 frames)
      if dm==0 and kseen<30 then return end
      local ok = dived and dm==SYM.msg_killedbyhawk
      print(string.format("TAPEHAWK %s kill: dived=%s hawk y=%d death_msg=%04x (want %04x)", ok and "PASS" or "FAIL", tostring(dived), y, dm, SYM.msg_killedbyhawk))
      stage="done"; manager.machine:exit()
    end
    if f-t>1500 then fail(string.format("no kill (dived=%s hawk y=%d)", tostring(dived), y)) end
  end
end)
