-- harness/stuck6869.lua -- T0108: reproduces the room 69 walk-stall.
--
-- !! THIS REPRODUCTION IS INVALID -- READ BEFORE USING (T0108 re-diagnosis) !!
-- It warps Dizzy to room 69 at (8,168), which is ON the room's hearth,
-- inside the four fireplace flames at x=4..32, y=144..168 (the other half
-- of the same fireplace is at room 68's right edge). The hazard code kills
-- him (caller: hazard_scan, via kill_dizzy -- no message), the checkpoint
-- respawns him at the same spot, and he dies again until the lives run
-- out. The SPACE taps below dismiss every death box, so from outside it
-- looked like "crawls one step at a time, then stalls". There is no walk
-- stall. See NOTES.md T0108 re-diagnosis. Kept only as a record.
--
-- (Original header follows.)
-- NOT YET DIAGNOSED. Warp to room 69 near x=8-28 (where Dizzy lands
-- after the 68->69 transition), hold RIGHT (no jump), and he crawls in
-- fits of one WALK_STEP (4px) every so often instead of continuously --
-- and past roughly x=28-30 he stops advancing at all, even after 900+
-- frames of RIGHT held continuously.
--
-- WHAT'S BEEN RULED OUT (all confirmed on the target, not assumed):
--   * NOT the room transition -- it lands him correctly at x=8,y=168.
--   * NOT check_wall/the collision mask -- room69_data.asm's mask is
--     provably clear at every probe height (y-10/-14/-18) across the
--     whole x=8..56 span; check_wall genuinely returns "not blocked"
--     when it runs.
--   * NOT T0102/T0103's actor collision -- n_solid reads 0 throughout
--     (room 69's only actor, the dagger, is dull/non-solid).
--   * NOT a hard geometric wall -- from a DIFFERENT start (x=40, x=60)
--     on the SAME floor, he walks and falls through the x=56..112 gap
--     into room 53 below normally.
--
-- WHAT'S GENUINELY STRANGE, instrumented directly (not inferred): a
-- temporary counter at the top of mainloop confirmed passes keep
-- completing at a roughly normal rate throughout the stall, but a
-- second counter placed at ml_noleft's own "RIGHT held" branch
-- (target/room36.asm, the walk-right handler) stopped incrementing
-- after exactly ONE successful step, even though keyflags sampled from
-- Lua showed RIGHT continuously held (bit 3 set) the whole time. That
-- combination -- mainloop completing real passes, but ml_noleft's own
-- label never being reached again -- was not resolved before the
-- session moved on. Next step: instrument WHICH branch mainloop is
-- actually taking each pass during the stall (a counter per major
-- jsr between scankeys and ml_noleft would localize it directly,
-- rather than guessing which one to bisect first).
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
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or done then return end
  if f%14==0 then key("SPACE",(f//14)%2==0) end
  if not live then
    if mem:read_u8(SYM.cur_room)==36 and mem:read_u8(SYM.dizzy_y)~=0 then
      live=f+30
      mem:write_u8(SYM.respawn_room,69); mem:write_u8(SYM.respawn_x,tonumber(os.getenv("SX") or "8"))
      mem:write_u8(SYM.respawn_y,168);   mem:write_u8(SYM.killed,1)
    end
    return
  end
  local a=f-live
  if a<0 then return end
  key("RIGHT", true)
  if a%30==0 then
    print(string.format("DBG a=%d room=%d x=%d y=%d floor=%d keyflags=%d",a,
      mem:read_u8(SYM.cur_room),mem:read_u8(SYM.dizzy_x),mem:read_u8(SYM.dizzy_y),
      mem:read_u8(SYM.dizzy_floor),mem:read_u8(SYM.keyflags)))
  end
  if a==900 then done=true; print("STUCK6869 final x="..mem:read_u8(SYM.dizzy_x)) end
end)
