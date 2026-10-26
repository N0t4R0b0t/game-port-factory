-- harness/talkers.lua -- T0100: are frames 32..39 TALKED to, not pocketed?
--
-- Walks Dizzy right along room 68's floor tapping DOWN, so it sweeps past
-- Denzil (frame 33, x=192) instead of guessing one spot -- the first
-- version of this test picked a fixed position, never reached him, and
-- reported "not pocketed" for a build that pocketed him fine. It prints
-- the closest approach so a null result can be told from a miss.
--
-- Denzil's actor room byte is the verdict: 68 = still in the world,
-- 255 = picked up. It also dumps BOTH framebuffers at the moment the
-- conversation is up, because the box is drawn into the back buffer while
-- the front one still shows the plain room.
--
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none \
--     -seconds_to_run 16 -autoboot_script harness/talkers.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end
local function slot_of_frame(fr)
  for i=0,19 do
    local b=SYM.actor_ram+i*8
    if mem:read_u8(b+4)==fr then return b end
  end
end
local f,loaded,live,done=0,false,nil,false
local near,neary=nil,nil
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or done then return end
  -- dismiss the title, but STOP once we are in room 68 so the
  -- conversation box stays up long enough to photograph
  if f%14==0 and mem:read_u8(SYM.cur_room)~=68 then key("SPACE",(f//14)%2==0) end
  if not live then
    if mem:read_u8(SYM.cur_room)==36 and mem:read_u8(SYM.dizzy_y)~=0 then
      live=f+40
      mem:write_u8(SYM.respawn_room,68); mem:write_u8(SYM.respawn_x,140)
      mem:write_u8(SYM.respawn_y,176);   mem:write_u8(SYM.killed,1)
      -- Take the ROPE out of the world first. It sits at x=176, inside
      -- Dizzy's reach from Denzil at x=192, and tp_loop returns the
      -- first matching actor -- so without this the rope is picked up
      -- and its inventory box is what gets photographed.
      local rope = slot_of_frame(14)
      if rope then mem:write_u8(rope, 255) end
    end
    return
  end
  local a=f-live
  local dx0=mem:read_u8(SYM.dizzy_x)
  if a<20 then return end
  -- Press DOWN only when standing ON Denzil (x=192). Tapping it the
  -- whole way picks up the ROPE at x=176 first and opens the inventory,
  -- whose box then gets photographed and mistaken for the conversation.
  key("RIGHT", math.abs(dx0-192) > 4)
  key("DOWN",  math.abs(dx0-192) <= 4)
  local dx=mem:read_u8(SYM.dizzy_x)
  if math.abs(dx-192) < (near or 999) then near=math.abs(dx-192); neary=mem:read_u8(SYM.dizzy_y) end
  if a==90 then
    done=true
    for _,pair in ipairs({{0x4000,"A"},{0x6000,"B"}}) do
      local fh=io.open("/tmp/fb_talk_"..pair[2]..".bin","wb")
      for i=0,6143 do fh:write(string.char(mem:read_u8(pair[1]+i))) end
      fh:close()
    end
    local b=slot_of_frame(33)
    print(string.format("TALKERS denzil_room=%s (68=in world, 255=pocketed)  closest |x-192|=%s at y=%s",
      b and mem:read_u8(b) or "?", tostring(near), tostring(neary)))
  end
end)
