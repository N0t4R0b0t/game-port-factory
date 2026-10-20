-- harness/portcullis_block.lua -- T0115: the CLOSED gate at rest blocks
-- Dizzy and is visibly a closed lattice; a RAISED gate lets him through.
--
-- Drops Dizzy on the LEFT side of the gate (x=176) holding RIGHT.
--   default  gate untouched (closed, y=136): he stops at x=152 (his body's
--            right edge against the column), and every on-screen frame
--            from a=20 shows rows 100-140 of the column inked
--   OPEN=1   gate frozen fully raised (y=96, v1=0): he walks under it,
--            maxx 224, and on into room 52
--
--   [OPEN=1] DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 60 \
--     -autoboot_script harness/portcullis_block.lua
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
local function gate()
  -- all ACTOR_COUNT records (33 since T0124), not a hard 20
  for i=0,(SYM.ACTOR_COUNT or 20)-1 do local b=SYM.actor_ram+i*8
    if mem:read_u8(b+1)==0 and mem:read_u8(b+4)==120 then return b end end
end
local f,loaded,live,done=0,false,nil,false
local maxx=0
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or done then return end
  if f%14==0 then key("SPACE",(f//14)%2==0) end
  -- State-driven start (T0089 follow-up): the respawn now plays ~100
  -- frames of blocking audio, so `live=f+30` began tracking maxx while
  -- Dizzy was still in room 36 at its spawn x of 184 -- a polluted
  -- maxx=184 alongside a real final_x=152 (blocked). Wait for arrival in
  -- room 51, then for the CPU to leave the audio routines.
  if not poked then
    -- T0125: the mainloop must be RUNNING: new_game's set_checkpoint and
    -- gameplay_init run after `sta dizzy_y` and undo a warp poked in between
    boot_live=(mem:read_u8(SYM.cur_room)==36 and mem:read_u8(SYM.dizzy_y)~=0) and (boot_live or 0)+1 or 0
    if boot_live>=60 then
      mem:write_u8(SYM.respawn_room,51); mem:write_u8(SYM.respawn_x,140)
      mem:write_u8(SYM.respawn_y,136);   mem:write_u8(SYM.killed,1)
      poked=true
    end
    return
  end
  if not live then
    local pc=cpu.state["PC"].value
    local ina = pc>=SYM.play_tone and pc<SYM.play_chirp
    if not arrived then
      arrived = mem:read_u8(SYM.cur_room)==51 and mem:read_u8(SYM.dizzy_x)==140
    elseif not ina then
      clear=(clear or 0)+1; if clear>=3 then live=f end
    else clear=0 end
    return
  end
  local a=f-live
  -- a==1, not 0: the frame that sets `live` above returns before it gets
  -- here. With `a==0` the gate was never poked, stayed closed at y=136 --
  -- an 8x8 tile entirely BELOW Dizzy's feet -- and he walked over it and
  -- down the gap into room 52, which read as "the filled column doesn't
  -- block". Instrumented: gate bytes stayed y=136 v1=0 v2=0 all run.
  -- T0115: the CLOSED gate at rest is the blocking case now -- it is a
  -- closed lattice column until the lever is thrown, as in the original.
  -- OPEN=1 instead freezes it fully raised (y=96, v1=0), where Dizzy
  -- should walk UNDER it and on through the gap.
  if a==1 and os.getenv("OPEN") then
    local g=gate()
    if g then
      mem:write_u8(g+3, 96)
      mem:write_u8(g+5, 0)
      mem:write_u8(g+6, 0)
    end
  end
  if a<10 then return end
  -- T0115: closed mode also LOOKS at the resting gate -- its column must be
  -- a closed lattice (rows 100-140 all inked) in the ON-SCREEN buffer on
  -- every frame from a=20, both buffers seen, while Dizzy walks up to it (his damage
  -- rect reaching the column exercises draw_gate's full-column repaint).
  -- (from a=20: for the first few frames after arrival the other buffer can
  -- still hold the PREVIOUS room's picture -- room 36's art was found in
  -- the gate's column at a=10..14 -- which says nothing about the gate)
  if not os.getenv("OPEN") and a>=20 then
    local g=gate()
    if g then
      local col=mem:read_u8(g+2)//8
      local base=mem:read_u8(SYM.cur_buf)==0 and 0x4000 or 0x6000
      local inked=true
      for yy=100,140 do if mem:read_u8(base+yy*32+col)==0 then inked=false break end end
      if not inked then closed_bad=(closed_bad or 0)+1 end
      seen=seen or {} ; seen[base]=true
    end
  end
  key("RIGHT", true)
  local x = mem:read_u8(SYM.dizzy_x)
  if x > maxx then maxx = x end
  if a%10==0 then print(string.format("DBG a=%d x=%d y=%d floor=%d",a,x,mem:read_u8(SYM.dizzy_y),mem:read_u8(SYM.dizzy_floor))) end
  if a==150 then
    done=true
    print(string.format("PORTBLOCK maxx=%d room=%d final_x=%d y=%d  (176=gate x; blocked <=176-24ish, through if near 224)",
      maxx, mem:read_u8(SYM.cur_room), x, mem:read_u8(SYM.dizzy_y)))
    if not os.getenv("OPEN") then
      print(string.format("PORTBLOCK closed_gate_visible=%s (frames with gaps in the column: %d, both buffers seen: %s)",
        tostring((closed_bad or 0)==0 and seen and seen[0x4000] and seen[0x6000] or false), closed_bad or 0,
        tostring(seen and seen[0x4000] and seen[0x6000] or false)))
    end
  end
end)
