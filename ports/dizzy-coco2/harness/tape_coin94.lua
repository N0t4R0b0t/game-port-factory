-- harness/tape_coin94.lua -- T0239: room 94's coin (X-ALL cointable raw 60,152
-- -> px 112,152) by WALKING: warp to the room's main floor (WX,WY env, default
-- 200,168), walk to x~96 and press DOWN.
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
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
local f,loaded,stage,t=0,false,"boot",0
local boot_live,settle,busy,phase=0,0,0,1
local WX,WY=tonumber(os.getenv("WX") or "200"),tonumber(os.getenv("WY") or "168")
local function fail(m) print("COIN94 FAIL at "..stage..": "..m); stage="done"; manager.machine:exit() end
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  if f==31 then stray_fix(os.getenv("DIZZY_BIN")) end
  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    boot_live=(r("cur_room")==36 and r("dizzy_y")~=0) and boot_live+1 or 0
    if boot_live>=60 then key("SPACE",false)
      mem:write_u8(SYM.respawn_room,tonumber(os.getenv("RM") or "94")); mem:write_u8(SYM.respawn_x,WX); mem:write_u8(SYM.respawn_y,WY); mem:write_u8(SYM.killed,1)
      stage="arrive"; t=f end
    return
  end
  if r("lives")<2 then mem:write_u8(SYM.lives,2) end
  if stage=="arrive" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if r("cur_room")==tonumber(os.getenv("RM") or "94") and r("killed")==0 and r("dizzy_x")==WX then key("SPACE",false); stage="settle"; t=f end
    if f-t>1200 then fail("never arrived") end
  elseif stage=="settle" then
    settle=(r("dizzy_floor")==1) and settle+1 or 0
    if settle>=10 then print(string.format("COIN94 standing x=%d y=%d",r("dizzy_x"),r("dizzy_y"))); stage=(os.getenv("ROUTE") and "route" or "walk"); t=f end
    if f-t>800 then fail("no floor") end
  elseif stage=="route" then
    -- 1) lower the lift by walking the shelf into the switch, 2) from the
    -- top platform walk/jump right toward the lift column and log the path.
    local lb=nil
    for i=0,SYM.ACTOR_COUNT_tape-1 do local b=SYM.actor_init_tape+i*8
      if mem:read_u8(b)==94 and mem:read_u8(b+1)==9 then lb=b end end
    local ly=mem:read_u8(lb+3)
    if phase==1 then
      key("RIGHT",true)
      if ly>=100 then key("RIGHT",false); phase=2; mem:write_u8(SYM.respawn_room,94); mem:write_u8(SYM.respawn_x,120); mem:write_u8(SYM.respawn_y,40); mem:write_u8(SYM.killed,1); t=f; stage="arrive2" end
    end
    if f-t>1500 then fail("lift never lowered") end
  elseif stage=="arrive2" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if r("cur_room")==94 and r("killed")==0 and r("dizzy_x")==120 then key("SPACE",false); stage="top"; t=f; print("COIN94 on top at "..r("dizzy_x")..","..r("dizzy_y")) end
    if f-t>1200 then fail("no arrive2") end
  elseif stage=="top" then
    -- right along the top platform, then (once he has dropped onto the
    -- lowered lift's top, y>=100) back LEFT to fall down the side
    if r("dizzy_y")>=100 then key("RIGHT",false); key("LEFT",true) else key("RIGHT",true) end
    if f%20==0 then print(string.format("COIN94 top f=%d x=%d y=%d floor=%d room=%d",f,r("dizzy_x"),r("dizzy_y"),r("dizzy_floor"),r("cur_room"))) end
    if r("dizzy_y")>=164 and r("cur_room")==94 then print("COIN94 ROUTE reached the main floor from the top platform at x="..r("dizzy_x")); stage="done"; manager.machine:exit() end
    if f-t>900 then fail(string.format("route not found (x=%d y=%d)",r("dizzy_x"),r("dizzy_y"))) end
  elseif stage=="walk" then
    local x=r("dizzy_x")
    if f%40==0 then print(string.format("COIN94 f=%d x=%d y=%d room=%d",f,x,r("dizzy_y"),r("cur_room"))) end
    if os.getenv("FROM93") and r("cur_room")==94 then print(string.format("COIN94 FROM93 entered room 94 at x=%d y=%d floor=%d", r("dizzy_x"), r("dizzy_y"), r("dizzy_floor"))) stage="done"; manager.machine:exit() return end
    if os.getenv("FROM93") then key("RIGHT",true); key("LEFT",false) return end
    if r("cur_room")~=94 then print(string.format("COIN94 left room 94 -> room %d at x=%d y=%d", r("cur_room"), r("dizzy_x"), r("dizzy_y"))); stage="done"; manager.machine:exit() return end
    if os.getenv("EXITLEFT") then key("LEFT",true) elseif x>96 then key("LEFT",true); key("RIGHT",false) elseif x<92 then key("RIGHT",true); key("LEFT",false)
    else key("LEFT",false); key("RIGHT",false); stage="pick"; t=f; print("COIN94 at the coin x="..x.." y="..r("dizzy_y")) end
    if f-t>1500 then fail("never reached x~96") end
  elseif stage=="pick" then
    local c0=r("coins")
    key("DOWN", f-t<30)
    if r("coins")>0 then print("COIN94 PASS coin collected by walking on the room floor (coins="..r("coins")..")"); stage="done"; manager.machine:exit() end
    if f-t>200 then fail(string.format("no pickup at x=%d y=%d", r("dizzy_x"), r("dizzy_y"))) end
  end
end)
