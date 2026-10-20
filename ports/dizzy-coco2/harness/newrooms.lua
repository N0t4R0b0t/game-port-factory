-- harness/newrooms.lua -- acceptance test for a NEWLY BUILT room.
--
-- Three things have to hold before a room counts as built, and only the
-- first is visible from the assembler:
--   1. its data decodes (harness/lzverify.lua covers the whole image);
--   2. its collision mask is right -- Dizzy stands, walks and climbs in
--      it without falling out of the world;
--   3. the transition INTO it fires, instead of being refused and
--      stranding him above the play window (NOTES.md T0081).
--
-- Edit the T table: {room, x, y, direction, frames, what you expect}. Take
-- the start positions from `tools/roomview.py <room> --surfaces` -- never
-- from a screenshot. Direction "NONE" places him and lets physics run,
-- which is how you exercise an up-transition: it is driven by the feet
-- crossing TOP_TRANSITION_Y in ml_floorfound, not by holding a key.
--
-- T0120: STATE-DRIVEN. Each case warps by the respawn poke (a death), waits
-- for Dizzy to ARRIVE at the start point and for the death/new-life audio
-- to finish, and only then runs its frames -- the old fixed 50-frame settle
-- predates ~100 frames of blocking respawn audio. Lives are topped up before
-- every warp: with the original's 2 spare lives (T0114) the third warp was a
-- real game over.
--
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none \
--     -seconds_to_run 240 -autoboot_script harness/newrooms.lua
--
-- A start point on a ledge narrower than Dizzy's 20px body will fall
-- off before landing: the floor probes sit at BODY_L and BODY_R. That
-- is correct behaviour, not a failed transition -- check the ledge width
-- in roomview before filing a bug.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local row3 = manager.machine.ioport.ports[":row3"]
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

-- {room, x, y, direction, frames, what we expect}
local T = {
  -- T0094
  {84,120,112,"RIGHT",110,"stand+climb the castle staircase"},
  {68, 16, 48,"NONE" ,110,"68 -> 84 up-transition"},
  {69, 12, 48,"NONE" ,110,"69 -> 85 up-transition"},
  -- T0120
  {67,200, 48,"NONE" ,110,"67 -> 83 up-transition (ledge y=48 x=184..248)"},
  {84, 60, 48,"NONE" ,110,"84 -> 100 up-transition (ledge y=48 x=32..168)"},
  {84,212, 48,"NONE" ,110,"84 -> 100 from the right ledge (x=208..224)"},
  {83,192, 48,"NONE" ,110,"83 roof peak: up is 99, EMPTY and unbuilt -> climb refused, stays in 83"},
  {83,200,176,"RIGHT",200,"83 floor, walk right -> 84"},
  {86,200,176,"LEFT" ,300,"stand on the cloud, walk off left -> 70 (empty) -> 54, as the original"},
  {100,100,176,"RIGHT",200,"attic floor, walk right into the floor gap -> 84"},
  -- 85 is a tower on the LEFT third with open sky to its right; its floor
  -- at x=64 is walled in (x stays 64), so the way east is off the roof's
  -- right slope and out over the drop, as the room's name says.
  {85, 88, 68,"RIGHT",300,"85 roof, right slope: walk off east over the drop (86 is the longjump cloud)"},
  -- T0122
  {86,224,176,"JUMPRIGHT",200,"the long jump: off the cloud's right end into 87"},
  {87,120,160,"LEFT" ,200,"87 lower platform (y=160 x=96..160), walk left off it -> falls toward 71 (unbuilt until T0124)"},
  {87,200, 96,"RIGHT",150,"87 upper floor (y=96 x=128..248), walk right -> 88 unbuilt: edge"},
}
local function in_audio() local p=cpu.state["PC"].value return p>=SYM.play_tone and p<SYM.play_chirp end
local f,loaded,stage,t,n,clear = 0,false,"boot",0,1,0
local out, fell, rooms_seen = {}, false, {}
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if mem:read_u8(SYM.cur_room)==36 and mem:read_u8(SYM.dizzy_floor)==1 and mem:read_u8(SYM.troll_launching)==0 and f>200 then
      key("SPACE",false); stage="warp" end
    return
  end
  local c=T[n]
  if stage=="warp" then
    key("RIGHT",false); key("LEFT",false); key("UP",false)
    mem:write_u8(SYM.lives,2)
    mem:write_u8(SYM.respawn_room,c[1]); mem:write_u8(SYM.respawn_x,c[2])
    mem:write_u8(SYM.respawn_y,c[3]);    mem:write_u8(SYM.killed,1)
    fell=false; rooms_seen={}; clear=0; stage="arrive"; t=f
  elseif stage=="arrive" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end        -- dismiss the death box
    -- arrival = Dizzy at the start X, alive, audio done. NOT "in room c[1]":
    -- a start point above the transition line (the up-transition cases)
    -- leaves the room on the very first pass, before this ever sees it.
    local r0=mem:read_u8(SYM.cur_room)
    if #rooms_seen==0 or rooms_seen[#rooms_seen]~=r0 then rooms_seen[#rooms_seen+1]=r0 end
    -- ...and the warp must have LANDED: the target room seen at least once
    -- since the warp. x alone matched a case whose start x equalled where the
    -- previous case left Dizzy, in the previous case's room (T0124).
    local landed=false
    for _,rr in ipairs(rooms_seen) do if rr==c[1] then landed=true end end
    if landed and mem:read_u8(SYM.dizzy_x)==c[2] and mem:read_u8(SYM.killed)==0 and not in_audio() then
      clear=clear+1; if clear>=3 then key("SPACE",false); stage="run"; t=f end
    else clear=0 end
    if f-t>900 then out[n]=string.format("start %d @%3d,%3d  NEVER ARRIVED   (%s)",c[1],c[2],c[3],c[6]); stage="next" end
  elseif stage=="run" then
    local a=f-t
    if c[4]=="JUMPRIGHT" then key("RIGHT",true); key("UP",a<8)
    elseif c[4]~="NONE" then key(c[4],true) end
    local r,x,y,g=mem:read_u8(SYM.cur_room),mem:read_u8(SYM.dizzy_x),mem:read_u8(SYM.dizzy_y),mem:read_u8(SYM.dizzy_floor)
    if #rooms_seen==0 or rooms_seen[#rooms_seen]~=r then rooms_seen[#rooms_seen+1]=r end
    if y>190 then fell=true end
    if mem:read_u8(SYM.killed)~=0 then fell=true end
    if a>=c[5] then
      out[n]=string.format("start %3d @%3d,%3d %-5s -> room=%3d x=%3d y=%3d floor=%d rooms=%s%s   (%s)",
        c[1],c[2],c[3],c[4],r,x,y,g,table.concat(rooms_seen,">"),(fell and "  FELL-OUT/KILLED" or ""),c[6])
      stage="next"
    end
  elseif stage=="next" then
    key("RIGHT",false); key("LEFT",false); key("UP",false)
    n=n+1
    if n>#T then
      for i=1,#T do print("NEW "..(out[i] or "?")) end
      stage="done"; manager.machine:exit()
    else stage="warp" end
  end
end)
