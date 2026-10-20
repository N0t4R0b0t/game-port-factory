-- harness/edgejump.lua -- T0117: run-jump across a room's RIGHT edge and log
-- what happens to the jump, for comparison with the original game doing the
-- same move (harness/zx_warp.lua STRAT=jumpthen from the same spot; original
-- x = port x / 4, y identical).
--
-- Drops Dizzy at (X,Y) in ROOM via the respawn poke, waits for him to land,
-- then walks RIGHT and jumps once when x reaches JUMPX (default 220, the
-- original's x=55). Also prints a y trace from the jump, in ORIGINAL x units. Prints the room change with dy at that moment, every
-- landing, and a final line.
--
--   ROOM=52 X=200 Y=60 DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 60 \
--     -autoboot_script harness/edgejump.lua
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
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end
local ROOM,X,Y=tonumber(os.getenv("ROOM")),tonumber(os.getenv("X")),tonumber(os.getenv("Y"))
local TAG=os.getenv("TAG") or ("r"..ROOM)
local function r(s) return mem:read_u8(SYM[s]) end
local function s8(v) return v>127 and v-256 or v end
local function in_audio() local p=cpu.state["PC"].value return p>=SYM.play_tone and p<SYM.play_chirp end
local f,loaded,stage,t,clear,arrived=0,false,"boot",0,0,false
local log,last={},{}
local JUMPX=tonumber(os.getenv("JUMPX") or "220")
local jumped,trace=nil,{}
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    -- NOT the instant the game starts: the troll's opening shove is still in
    -- the air then, and troll_launching carries through the respawn --
    -- stepping Dizzy 4px left per pass in the NEW room until he lands (seen:
    -- respawned at 196, standing at 192, on top of a block the original's
    -- Dizzy stands beside).
    if r("cur_room")==36 and r("dizzy_y")~=0 and r("dizzy_floor")==1 and r("troll_launching")==0 and f>200 then
      mem:write_u8(SYM.respawn_room,ROOM); mem:write_u8(SYM.respawn_x,X)
      mem:write_u8(SYM.respawn_y,Y); mem:write_u8(SYM.killed,1); stage="tele"; t=f end
  elseif stage=="tele" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if not arrived then arrived = r("cur_room")==ROOM and r("dizzy_x")==X
    elseif not in_audio() then clear=clear+1; if clear>=3 then key("SPACE",false); stage="settle"; t=f end
    else clear=0 end
  elseif stage=="settle" then
    if r("dizzy_floor")==1 and f-t>30 then
      log[#log+1]=string.format("start r%d x=%d y=%d",r("cur_room"),r("dizzy_x"),r("dizzy_y"))
      stage="act"; t=f end
    if f-t>600 then print("EDGEJUMP "..TAG.." never landed"); stage="done" end
  elseif stage=="act" then
    local a=f-t
    key("RIGHT", a<400)
    -- jump once, when x reaches JUMPX (default 220 = the original's x=55,
    -- where its SPACE was held in the zx_film comparison run)
    if not jumped and r("dizzy_x")>=JUMPX and r("dizzy_floor")==1 then jumped=a end
    key("UP", jumped~=nil and a-jumped<12)
    if jumped and a%2==0 and a-jumped<=110 then trace[#trace+1]=string.format("%d:r%d,%d,%d",a-jumped,r("cur_room"),r("dizzy_x")//4,r("dizzy_y")) end
    local rm,x,y,dy,flo,k=r("cur_room"),r("dizzy_x"),r("dizzy_y"),s8(r("dizzy_dy")),r("dizzy_floor"),r("killed")
    if last.rm and rm~=last.rm then log[#log+1]=string.format("a=%d ROOM %d->%d x=%d y=%d dy_before=%d dy_after=%d",a,last.rm,rm,x,y,last.dy,dy) end
    if last.flo==0 and flo==1 then log[#log+1]=string.format("a=%d LAND r%d x=%d y=%d",a,rm,x,y) end
    if (last.k or 0)==0 and k~=0 then log[#log+1]=string.format("a=%d KILLED r%d x=%d y=%d",a,rm,x,y) end
    if last.rm==rm and last.dy and last.dy<0 and dy==0 and flo==0 then log[#log+1]=string.format("a=%d BONK r%d x=%d y=%d",a,rm,x,y) end
    last={rm=rm,dy=dy,flo=flo,k=k}
    if a==480 then
      key("RIGHT",false); key("UP",false)
      print(string.format("EDGEJUMP %s | %s | final r%d x=%d y=%d floor=%d",TAG,table.concat(log," ; "),rm,x,y,flo))
      print("EDGETRACE "..TAG.." (frames since jump:room,orig_x,y) "..table.concat(trace," "))
      stage="done"; manager.machine:exit()
    end
  end
end)
