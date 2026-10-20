-- harness/startitems.lua -- does -DSTART_ITEMn actually put the item in
-- Dizzy's hands, and take it out of the world?
--
-- `inv` holds an actor INDEX+1, not a frame, so this resolves each slot
-- back through actor_ram to the frame it refers to. It also checks the
-- seeded actor's room byte is 255 -- seeding that leaves the item lying
-- in the room as well as in your hands is the failure mode to catch.
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
local f,loaded,done=0,false,false
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or done then return end
  if f%14==0 then key("SPACE",(f//14)%2==0) end
  if f==400 then
    done=true
    local out={}
    for i=0,3 do
      local slot=mem:read_u8(SYM.inv+i)
      if slot==0 then out[#out+1]="-"
      else
        local base=SYM.actor_ram+(slot-1)*8
        out[#out+1]=string.format("frame%d(room=%d)", mem:read_u8(base+4), mem:read_u8(base))
      end
    end
    print(string.format("ITEMS room=%d inv=[%s]", mem:read_u8(SYM.cur_room), table.concat(out,", ")))
  end
end)
