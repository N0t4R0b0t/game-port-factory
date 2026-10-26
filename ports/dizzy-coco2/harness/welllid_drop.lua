-- harness/welllid_drop.lua -- T0133: room 55's well lid must NOT retract
-- from mere proximity, only when the crowbar is DROPPED in
-- WELLLID_PROX_*. Room 88 (the crowbar) isn't built yet, so this drives
-- the debug key (see room36.asm's DEBUG_PROX_KEYS / gameplay.asm's
-- debug_prox_keys) instead of a real drop. Companion to dragonsleep.lua;
-- same two-phase shape.
--
--   1. STAND -- warp near the lid (welllidhere, ROU_CROWBAR, frame 158,
--      pixel (56,160)), sit there for 90 frames doing nothing. The lid
--      actor's room byte must stay 55 (the OLD bug: update_welllid fired
--      on proximity alone).
--   2. DEBUG KEY -- hold 'f' while still in the box. The lid's room byte
--      must go to 255 (hidden) and the message box (msg_crowbar) must
--      appear.
--
-- Verdict:
--   WELLLID PASS stand_room=55 key_room=255 msg_seen=yes
--
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -seconds_to_run 40 \
--     -autoboot_script harness/welllid_drop.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local row0=manager.machine.ioport.ports[":row0"]
local fl3={} ; for n,f in pairs(row3.fields) do fl3[n]=f end
local fl0={} ; for n,f in pairs(row0.fields) do fl0[n]=f end
local function key(n,d) fl3[n]:set_value(d and 1 or 0) end
local function dbgkey(n,d) fl0[n]:set_value(d and 1 or 0) end
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end

local ROU_CROWBAR, LID_FRAME = 15, 158
local BOX = {x=56, y=144, w=32, h=16}
local START_X, START_Y = 64, 176   -- lands on the lid (welllidhere, px 56,y160)

local function r(s) return mem:read_u8(SYM[s]) end
local function pc() return cpu.state["PC"].value end
local function stack_has(lo,hi)
  local s=cpu.state["S"].value
  for i=0,20 do if s+i+1>=0x100 then break end
    local w=mem:read_u8(s+i)*256+mem:read_u8(s+i+1)
    if w>=lo and w<hi then return true end
  end
  return false
end
local function in_msgwait()
  local p=pc()
  return (p>=SYM.msg_wait_dismiss and p<SYM.fb_stablekeys) or stack_has(SYM.msg_wait_dismiss,SYM.fb_stablekeys)
end
local function lid()
  for i=0,(SYM.ACTOR_COUNT or 33)-1 do
    local b=SYM.actor_ram+i*8
    if mem:read_u8(b+4)==LID_FRAME and mem:read_u8(b+1)==ROU_CROWBAR then return b end
  end
end
local function inside_box()
  local x,y,h=r("dizzy_x"),r("dizzy_y"),r("dizzy_h")
  local dr=math.min(x+24,255)
  local br=math.min(BOX.x+BOX.w,255)
  local horiz = dr>BOX.x and x<br
  local vert = y>BOX.y and (y-h)<(BOX.y+BOX.h)
  return horiz and vert
end

local f,loaded,stage,t,clear,count=0,false,"boot",0,0,0
local msg_seen=false
local function to(s) stage=s; t=f; clear=0; count=0 end
local function fail(why)
  local lb=lid()
  print(string.format("WELLLID FAIL at stage %s: %s (room=%d x=%d y=%d lid_room=%s killed=%d pc=%04x)",
    stage, why, r("cur_room"), r("dizzy_x"), r("dizzy_y"), lb and mem:read_u8(lb) or "?", r("killed"), pc()))
  stage="done"
end

emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  -- T0133: the well's own automatic descent (well_route, logic_low.asm) is
  -- a REAL, unrelated mechanic: standing at the well mouth carries Dizzy
  -- into room 39 within a handful of frames regardless of the lid (its
  -- actual gate is the lid's SOLID-actor collision, capped at SOLID_MAX=4
  -- solid actors in a busy room like 55 -- not something T0133 touches,
  -- and too fast/fragile to rely on for a harness). Pin position AND room
  -- from the moment he arrives so this test is purely about
  -- check_drop_trigger's cdt_crowbar/debug_prox_keys, not well physics --
  -- same reasoning as pinning rng_ctr in dragonsleep.lua.
  if (stage=="settle" or stage=="stand" or stage=="keypress" or stage=="waitmsg") and SYM.dizzy_x then
    mem:write_u8(SYM.cur_room, 55)
    mem:write_u8(SYM.dizzy_x, START_X)
    mem:write_u8(SYM.dizzy_y, 160)
    if SYM.dizzy_dy then mem:write_u8(SYM.dizzy_dy, 0) end
    if SYM.well_mode then mem:write_u8(SYM.well_mode, 0) end
  end
  if stage~="boot" and stage~="teleport" and r("killed")~=0 then
    return fail("Dizzy was killed mid-sequence")
  end

  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    boot_live=(r("cur_room")==36 and r("dizzy_y")~=0) and (boot_live or 0)+1 or 0
    if boot_live>=60 then
      mem:write_u8(SYM.respawn_room,55); mem:write_u8(SYM.respawn_x,START_X)
      mem:write_u8(SYM.respawn_y,START_Y); mem:write_u8(SYM.killed,1)
      to("teleport")
    end

  elseif stage=="teleport" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if count==0 then
      if r("cur_room")==55 and r("dizzy_x")==START_X then count=1 end
    else
      clear=clear+1; if clear>=3 then key("SPACE",false); to("settle") end
    end
    if f-t>900 then return fail("never arrived in room 55") end

  elseif stage=="settle" then
    if inside_box() then count=count+1 else count=0 end
    if count>=10 then
      print(string.format("WELLLID standing inside WELLLID_PROX_* at x=%d y=%d", r("dizzy_x"), r("dizzy_y")))
      to("stand")
    elseif f-t>300 then
      return fail(string.format("never settled inside the box (x=%d y=%d)", r("dizzy_x"), r("dizzy_y")))
    end

  elseif stage=="stand" then
    -- do nothing at all: no keys, no drop
    if f-t>=90 then
      local lb=lid()
      if not lb or mem:read_u8(lb)~=55 then
        return fail("lid actor no longer in room 55 from mere standing (the bug this task fixes)")
      end
      print("WELLLID stand OK: lid still room 55 after 90 frames standing")
      to("keypress")
    end

  elseif stage=="keypress" then
    if not inside_box() then return fail("drifted out of the box before the key could fire it") end
    dbgkey("f  F", true)
    local lb=lid()
    if lb and mem:read_u8(lb)==255 then
      dbgkey("f  F", false)
      print("WELLLID debug key hid the lid (room=255)")
      to("waitmsg")
    elseif f-t>200 then
      dbgkey("f  F", false)
      return fail("holding 'f' in the box never hid the lid")
    end

  elseif stage=="waitmsg" then
    if in_msgwait() then msg_seen=true end
    clear = in_msgwait() and 0 or clear+1
    if msg_seen then key("SPACE", ((f-t)%26)<8) end
    if msg_seen and clear>=30 then
      key("SPACE",false)
      local lb=lid()
      print(string.format("WELLLID PASS stand_room=55 key_room=%s msg_seen=%s",
        lb and tostring(mem:read_u8(lb)) or "gone", tostring(msg_seen)))
      stage="done"
    elseif f-t>600 then
      return fail(string.format("message never confirmed (msg_seen=%s)", tostring(msg_seen)))
    end
  end
end)
