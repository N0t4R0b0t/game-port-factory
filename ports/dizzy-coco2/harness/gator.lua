-- harness/gator.lua -- T0101: can Dizzy stand on the gator?
--
-- Walks right along room 53's floor toward the crocodile (x=152) and
-- reports the highest surface he ends up standing on. Before actor
-- collision existed he walked straight through it; standing ON it means
-- dizzy_floor=1 at a y ABOVE the floor he started from.
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
local f,loaded,live,done=0,false,nil,false
local best,bestx,shot=255,nil,false
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or done then return end
  if f%14==0 then key("SPACE",(f//14)%2==0) end
  if not live then
    if mem:read_u8(SYM.cur_room)==36 and mem:read_u8(SYM.dizzy_y)~=0 then
      live=f+40
      mem:write_u8(SYM.respawn_room,53)
      mem:write_u8(SYM.respawn_x,tonumber(os.getenv("GX") or "100"))
      mem:write_u8(SYM.respawn_y,tonumber(os.getenv("GY") or "160"))
      mem:write_u8(SYM.killed,1)
    end
    return
  end
  local a=f-live
  if a<30 then return end
  key("RIGHT", true)
  key("UP", (a%26)<6)
  local r,x,y,g = mem:read_u8(SYM.cur_room), mem:read_u8(SYM.dizzy_x),
                  mem:read_u8(SYM.dizzy_y), mem:read_u8(SYM.dizzy_floor)
  if r==53 and g==1 and y<best then best=y; bestx=x end
  -- photograph the moment he is standing ON the gator (x past 128, and
  -- higher than room 53's own floor at y=152)
  if r==53 and g==1 and x>=132 and y<=152 and not shot then
    shot=true
    local base=mem:read_u8(SYM.draw_base)*256+mem:read_u8(SYM.draw_base+1)
    local shown = base==0x4000 and 0x6000 or 0x4000
    local fh=io.open("/tmp/fb_gator.bin","wb")
    for i=0,6143 do fh:write(string.char(mem:read_u8(shown+i))) end
    fh:close()
  end
  if a==200 then
    done=true
    -- and dump the crocodile actor's LIVE state: standing on an
    -- invisible box means the solid rect and the drawn sprite disagree
    local cb
    for i=0,19 do
      local b=SYM.actor_ram+i*8
      if mem:read_u8(b+1)==5 then cb=b end     -- ROU_CROCODILE
    end
    print(string.format("GATOR highest standing y=%s at x=%s   final room=%d x=%d y=%d floor=%d",
      tostring(best), tostring(bestx), r, x, y, g))
    if cb then
      print(string.format("CROC room=%d x=%d y=%d frame=%d v1=%d v2=%d colour=%d",
        mem:read_u8(cb), mem:read_u8(cb+2), mem:read_u8(cb+3), mem:read_u8(cb+4),
        mem:read_u8(cb+5), mem:read_u8(cb+6), mem:read_u8(cb+7)))
    end
  end
end)
