-- harness/dragonsleep.lua -- T0133: room 54's dragon must NOT fall asleep
-- from mere proximity, only when the sleeping potion is DROPPED in
-- DRAGON_SLEEP_*. Rooms 45 (the potion) isn't built yet, so this drives
-- the debug key (see room36.asm's DEBUG_PROX_KEYS / gameplay.asm's
-- debug_prox_keys) instead of a real drop.
--
-- Two checks, sequential in one run:
--   1. STAND -- warp into the box, sit there for 90 frames doing nothing.
--      dragon_asleep must stay 0 (the OLD bug: update_dragon's own
--      proxsleep fired on proximity alone).
--   2. DEBUG KEY -- hold 'd' while still in the box. dragon_asleep must
--      latch to 1 and the message box (msg_dragonasleep) must appear.
--
-- Verdict:
--   DRAGONSLEEP PASS stand_asleep=0 key_asleep=1 msg_seen=yes
--
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -seconds_to_run 40 \
--     -autoboot_script harness/dragonsleep.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local row0=manager.machine.ioport.ports[":row0"]
local fl3={} ; for n,f in pairs(row3.fields) do fl3[n]=f end
local fl0={} ; for n,f in pairs(row0.fields) do fl0[n]=f end
local function key(n,d) fl3[n]:set_value(d and 1 or 0) end
local function dbgkey(n,d) fl0[n]:set_value(d and 1 or 0) end
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

-- inside DRAGON_SLEEP_X/Y/W/H (112,150,40,30) -- picked so Dizzy's whole
-- sprite overlaps the box, same reasoning as breathsfx.lua's own room-54 spot
local START_X, START_Y = 120, 176

local f,loaded,stage,t,clear,count=0,false,"boot",0,0,0
local msg_seen=false
local function to(s) stage=s; t=f; clear=0; count=0 end
local function fail(why)
  print(string.format("DRAGONSLEEP FAIL at stage %s: %s (room=%d x=%d y=%d dragon_asleep=%d killed=%d pc=%04x)",
    stage, why, r("cur_room"), r("dizzy_x"), r("dizzy_y"), r("dragon_asleep"), r("killed"), pc()))
  stage="done"
end

emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  -- keep rng_ctr out of the dragon's own 5/256 random-breath range while
  -- testing -- the flame is a REAL, unrelated hazard (dragon_flames) and
  -- this test's box happens to sit right under the head; not what T0133
  -- is about, same reasoning as tiecroc.lua holding the gator's mouth shut
  if (stage=="stand" or stage=="keypress" or stage=="waitmsg") and SYM.rng_ctr then
    mem:write_u8(SYM.rng_ctr, 250)
  end
  if stage~="boot" and stage~="teleport" and stage~="settle" and r("killed")~=0 then
    return fail("Dizzy was killed mid-sequence")
  end

  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    boot_live=(r("cur_room")==36 and r("dizzy_y")~=0) and (boot_live or 0)+1 or 0
    if boot_live>=60 then
      mem:write_u8(SYM.respawn_room,54); mem:write_u8(SYM.respawn_x,START_X)
      mem:write_u8(SYM.respawn_y,START_Y); mem:write_u8(SYM.killed,1)
      to("teleport")
    end

  elseif stage=="teleport" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if count==0 then
      if r("cur_room")==54 and r("dizzy_x")==START_X then count=1 end
    else
      clear=clear+1; if clear>=3 then key("SPACE",false); to("stand") end
    end
    if f-t>900 then return fail("never arrived in room 54") end

  elseif stage=="stand" then
    -- do nothing at all: no keys, no drop -- this is the whole point
    if f-t>=90 then
      if r("dragon_asleep")~=0 then
        return fail("dragon_asleep latched from mere standing (the bug this task fixes)")
      end
      print(string.format("DRAGONSLEEP stand OK: dragon_asleep=%d after 90 frames standing", r("dragon_asleep")))
      to("keypress")
    end

  elseif stage=="keypress" then
    dbgkey("d  D", true)
    if r("dragon_asleep")~=0 then
      dbgkey("d  D", false)
      print("DRAGONSLEEP debug key latched dragon_asleep=1")
      to("waitmsg")
    elseif f-t>200 then
      dbgkey("d  D", false)
      return fail("holding 'd' in the box never set dragon_asleep")
    end

  elseif stage=="waitmsg" then
    if in_msgwait() then msg_seen=true end
    clear = in_msgwait() and 0 or clear+1
    -- dismiss with SPACE once we've SEEN the message box at least once
    if msg_seen then key("SPACE", ((f-t)%26)<8) end
    if msg_seen and clear>=30 then
      key("SPACE",false)
      print(string.format("DRAGONSLEEP PASS stand_asleep=0 key_asleep=%d msg_seen=%s",
        r("dragon_asleep"), tostring(msg_seen)))
      stage="done"
    elseif f-t>600 then
      return fail(string.format("message never confirmed (msg_seen=%s)", tostring(msg_seen)))
    end
  end
end)
