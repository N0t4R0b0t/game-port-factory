-- harness/denzilchat.lua -- T0198: does Denzil's conversation show ALL
-- FOUR boxes, with their full text?
--
-- Playtest: "the Denzil conversation is just one text box, there should
-- be a few, like on the troll." X-ALL.TXT's `denziltalking` is four
-- boxes driven through `chatter`; this port showed one condensed box.
--
-- Counts msg_active rising edges (one per box, T0154) and, for each box,
-- reports how many of the banner-free play rows carry ink -- a box whose
-- last line never renders shows up as fewer inked rows than its text.
--
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none \
--     -seconds_to_run 240 -autoboot_script harness/denzilchat.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,fd in pairs(row3.fields) do fl[n]=fd end
local function key(n,d) if fl[n] then fl[n]:set_value(d and 1 or 0) end end
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
local f,loaded,staged,live,boot=0,false,false,nil,0
local boxes,prev,lastrows=0,0,nil
local function inkrows()
  local base = mem:read_u8(SYM.cur_buf)==0 and 0x4000 or 0x6000
  local n=0
  for r=48,191 do
    for c=0,31 do if mem:read_u8(base+r*32+c)~=0 then n=n+1; break end end
  end
  return n
end
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded then return end
  if not staged then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if f%40==0 and SYM.msg_active then
      local v=mem:read_u8(SYM.msg_active)
      if v~=0 then print("  boot: msg_active="..v.." (detector works)") end
    end
    if mem:read_u8(SYM.cur_room)~=0 and mem:read_u8(SYM.dizzy_floor)==1 then boot=boot+1 end
    if boot>=60 then
      mem:write_u8(SYM.respawn_room,68); mem:write_u8(SYM.respawn_x,188)
      mem:write_u8(SYM.respawn_y,176);   mem:write_u8(SYM.killed,1)
      staged=true; boot=0
    end
    return
  end
  if not live then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if mem:read_u8(SYM.cur_room)==68 and mem:read_u8(SYM.dizzy_floor)==1 then
      boot=boot+1
      if boot>=120 then key("SPACE",false); live=f end
    end
    return
  end
  local a=f-live
  key("DOWN", a>=10 and a<40)                 -- talk to Denzil
  if a>=80 and (a//25)%2==0 then key("SPACE",true) else key("SPACE",false) end
  if a==20 then
    for i=0,42 do local b=SYM.actor_ram+i*8
      if mem:read_u8(b+4)==33 then
        print(string.format("  DENZIL slot %d: room=%d rou=%d x=%d y=%d frame=%d colour=%d",
          i, mem:read_u8(b), mem:read_u8(b+1), mem:read_u8(b+2), mem:read_u8(b+3),
          mem:read_u8(b+4), mem:read_u8(b+7)))
      end
    end
  end
  if a%10==0 and a<200 then
    print(string.format("  dbg a=%d room=%d x=%d y=%d floor=%d kf=%02x msg_active=%d",
      a, mem:read_u8(SYM.cur_room), mem:read_u8(SYM.dizzy_x), mem:read_u8(SYM.dizzy_y),
      mem:read_u8(SYM.dizzy_floor), mem:read_u8(SYM.keyflags),
      SYM.msg_active and mem:read_u8(SYM.msg_active) or -1)
      .. string.format(" ptimer=%d inv0=%d", SYM.pickup_timer and mem:read_u8(SYM.pickup_timer) or -1, SYM.inv and mem:read_u8(SYM.inv) or -1))
  end
  -- T0198: msg_active and pickup_timer CANNOT be read by their map
  -- addresses -- they live in staged blocks, so the map gives the
  -- pre-relocation address and they read a constant forever. (msg_active
  -- read 0 straight through the BOOT messages, which is how this was
  -- caught; use target/staged_syms.asm for staged symbols.)
  -- Detect boxes from the SCREEN instead: each box draws a solid
  -- horizontal border, and the four boxes sit at different y (the
  -- source's own 96/48/96/48), so the border row identifies them.
  local act = 0
  local base = mem:read_u8(SYM.cur_buf)==0 and 0x4000 or 0x6000
  local border=0
  for r=48,175 do
    local n=0
    for c=1,30 do if mem:read_u8(base+r*32+c)==255 then n=n+1 end end
    if n>=18 then border=r; break end
  end
  if border~=prev then
    if border~=0 then
      boxes=boxes+1
      print(string.format("DENZILCHAT box %d: top border at y=%d", boxes, border))
    end
    prev=border
  end
  if false then
    local base = mem:read_u8(SYM.cur_buf)==0 and 0x4000 or 0x6000
    print(string.format("  --- screen at a=%d ---", a))
    for r=48,150,6 do
      local line=""
      for c=0,31 do
        local b=mem:read_u8(base+r*32+c)
        line = line .. (b==0 and "." or (b==255 and "#" or "+"))
      end
      print("  |"..line.."|")
    end
  end
  if a==4 or a>560 then
    for i=0,42 do local b=SYM.actor_ram+i*8
      if mem:read_u8(b+4)==14 and mem:read_u8(b+1)==2 then
        print(string.format("  ROPE at a=%d: room=%d x=%d y=%d", a, mem:read_u8(b), mem:read_u8(b+2), mem:read_u8(b+3)))
      end
    end
  end
  if a>560 then
    print(string.format("DENZILCHAT TOTAL %d box(es)  (original denziltalking = 4)", boxes))
    manager.machine:exit()
  end
end)
