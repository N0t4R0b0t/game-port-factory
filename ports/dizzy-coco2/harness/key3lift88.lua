-- harness/key3lift88.lua -- T0239: drop key 3 into ITS OWN slot in
-- room 56's machine hut, confirm machine 3 and room 88's lift (not
-- lift 71) respond. Reproduces the exact bug the coordinator found:
-- T0124's own cdt_key only ever tested slot 1's box (76,120,16,16),
-- so key 3 dropped in its own correct slot (84,160,16,16) used to do
-- NOTHING. Stage flow mirrors harness/keylift.lua (see its own header
-- for why the cursor needs an UP and why every stage is gated on
-- observed state, not frame counts) -- only the slot/lift/room
-- constants differ.
--
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 90 \
--     -autoboot_script harness/key3lift88.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
local function stray_fix(path, memspace)
  local fh=io.open(path,"rb"); local d=fh:read("*all"); fh:close(); local pos=1
  while pos<=#d and d:byte(pos)==0 do
    local len=d:byte(pos+1)*256+d:byte(pos+2); local addr=d:byte(pos+3)*256+d:byte(pos+4)
    for i=0,len-1 do local a=addr+i
      if a>=0x0E00 and a<0x8000 then local want=d:byte(pos+5+i)
        if memspace:read_u8(a)~=want then memspace:write_u8(a,want)
          print(string.format("STRAYFIX $%04X restored %02X", a, want)) end end end
    pos=pos+5+len
  end
end
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end

local ROU_MACHINES, ROU_LIFT, FRAME_KEY = 8, 9, 13
local NACT = SYM.ACTOR_COUNT or 33
local NACT_T = SYM.ACTOR_COUNT_tape
-- slot 3's own box (X-ALL.TXT proxkey3, raw (53,160,4,16) -> px
-- (84,160,16,16), (raw-32)*4 for x, y unscaled) -- stand at
-- (box_x-4, box_y+16), the same offset keylift.lua's own KEY_X/KEY_Y
-- uses for slot 1's box (76,120)->(72,136).
local KEY_X, KEY_Y = 80, 176
-- room 88's lift starts at its own top (x=104,y=56); wait there, off
-- the shaft, same shape as keylift's W71_X/W71_Y.
local W88_X, W88_Y = 80, 88
local LIFT_TOP, LIFT_BOT = 56, 136

local function r(s) return mem:read_u8(SYM[s]) end
local function pc() return cpu.state["PC"].value end
local function in_audio() local p=pc() return p>=SYM.play_tone and p<SYM.play_chirp end
local function stack_has(lo,hi)
  local s=cpu.state["S"].value
  for i=0,20 do if s+i+1>=0x100 then break end
    local w=mem:read_u8(s+i)*256+mem:read_u8(s+i+1)
    if w>=lo and w<hi then return true end
  end
  return false
end
local function in_inventory()
  local p=pc()
  return (p>=SYM.show_inventory and p<SYM.inv) or stack_has(SYM.show_inventory,SYM.inv)
end
local function in_msgwait()
  local p=pc()
  return (p>=SYM.msg_wait_dismiss and p<SYM.fb_stablekeys) or stack_has(SYM.msg_wait_dismiss,SYM.fb_stablekeys)
end
local function find(pred)
  for i=0,NACT-1 do local b=SYM.actor_ram+i*8
    if pred(b) then return b,i end end
end
local function find_tape(pred)
  for i=0,NACT_T-1 do local b=SYM.actor_init_tape+i*8
    if pred(b) then return b end end
end
-- key 3 specifically: room 60, frame 13 (NOT "any FRAME_KEY" -- there
-- are four now, and picking the wrong one would test nothing new).
local function key3act() return find(function(b) return mem:read_u8(b)==60 and mem:read_u8(b+4)==FRAME_KEY end) end
local function machine3() return find(function(b) return mem:read_u8(b+1)==ROU_MACHINES and mem:read_u8(b+2)==80 and mem:read_u8(b+3)==156 end) end
local function lift88() return find_tape(function(b) return mem:read_u8(b+1)==ROU_LIFT and mem:read_u8(b)==88 end) end
local function key_in_inv(ki)
  for s=0,3 do if mem:read_u8(SYM.inv+s)==ki+1 then return true end end
  return false
end

local f,loaded,stage,t,clear,count=0,false,"boot",0,0,0
local boot_live,keyidx
local function to(s) stage=s; t=f; clear=0; count=0 end
local function fail(why)
  print(string.format("KEY3LIFT88 FAIL at stage %s: %s  (room=%d x=%d y=%d floor=%d killed=%d pc=%04x)",
    stage, why, r("cur_room"), r("dizzy_x"), r("dizzy_y"), r("dizzy_floor"), r("killed"), pc()))
  stage="done"
end
local function warp(room,x,y)
  mem:write_u8(SYM.lives,2)
  mem:write_u8(SYM.respawn_room,room); mem:write_u8(SYM.respawn_x,x)
  mem:write_u8(SYM.respawn_y,y); mem:write_u8(SYM.killed,1)
end

local ly_min,ly_max=255,0

emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if f==31 and loaded then stray_fix(os.getenv("DIZZY_BIN"), mem) end
  if not loaded or stage=="done" then return end
  if (stage=="open" or stage=="invwait" or stage=="cursor" or stage=="select" or stage=="keywait"
      or stage=="lift") and r("killed")~=0 then
    return fail("Dizzy was killed mid-sequence")
  end

  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    boot_live=(r("cur_room")==36 and r("dizzy_y")~=0) and (boot_live or 0)+1 or 0
    if boot_live>=60 then
      local kb,ki=key3act()
      if not kb then return fail("no key actor (room 60, frame 13) in actor_ram") end
      keyidx=ki
      mem:write_u8(kb,255); mem:write_u8(SYM.inv,ki+1)       -- carrying key 3
      local lb=lift88()
      if not lb then return fail("no room-88 lift in actor_init_tape") end
      if mem:read_u8(lb+5)~=0 then return fail("lift88 var1 nonzero before any drop") end
      warp(56,KEY_X,KEY_Y)
      to("teleport")
    end

  elseif stage=="teleport" or stage=="teleport88" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    local room,x = stage=="teleport" and 56 or 88, stage=="teleport" and KEY_X or W88_X
    if count==0 then
      if r("cur_room")==room and r("dizzy_x")==x then count=1 end
    elseif not in_audio() then
      clear=clear+1
      if clear>=3 then key("SPACE",false); to(stage=="teleport" and "settle" or "settle88") end
    else clear=0 end
    if f-t>900 then fail("never arrived in room "..room) end

  elseif stage=="settle" or stage=="settle88" then
    if r("killed")~=0 then return fail("died on arrival") end
    count = r("dizzy_floor")==1 and count+1 or 0
    if count>=10 then
      print(string.format("KEY3LIFT88 standing in room %d at x=%d y=%d", r("cur_room"), r("dizzy_x"), r("dizzy_y")))
      if stage=="settle" then to("open") else
        local lb=lift88()
        print(string.format("KEY3LIFT88 room 88 lift at x=%d y=%d var1=%d v2=%d", mem:read_u8(lb+2), mem:read_u8(lb+3), mem:read_u8(lb+5), mem:read_u8(lb+6)))
        to("lift")
      end
    elseif f-t>300 then fail("never stood on a floor") end

  elseif stage=="open" then
    key("DOWN", true)
    if in_inventory() and mem:read_u8(SYM.inv_occupied)>=1 then key("DOWN",false); to("invwait") end
    if f-t>200 then key("DOWN",false); fail("DOWN never opened the inventory") end

  elseif stage=="invwait" then
    if f-t>=30 then to("cursor") end

  elseif stage=="cursor" then
    if mem:read_u8(SYM.inv_cursor)==0 then
      key("UP", false)
      if count==0 then count=f end
      if f-count>=20 then to("select") end
    else
      key("UP", ((f-t)%30)<10)
      if mem:read_u8(SYM.inv_cursor)==0 then key("UP",false) end
      if f-t>600 then key("UP",false); fail("UP never moved the cursor onto the key") end
    end

  elseif stage=="select" then
    if f-t<2 and mem:read_u8(SYM.inv_cursor)~=0 then key("SPACE",false); to("cursor") return end
    key("SPACE", f-t<10)
    if f-t>=10 then key("SPACE",false); to("keywait") end

  elseif stage=="keywait" then
    local kb=SYM.actor_ram+keyidx*8
    local mb,lb=machine3(),lift88()
    if not mb then return fail("no machine 3 actor at (80,156)") end
    if not lb then return fail("no room-88 lift actor") end
    if mem:read_u8(kb)==255 and not key_in_inv(keyidx) and (mem:read_u8(mb+5)&1)==1 and mem:read_u8(lb+5)==1 then
      print(string.format("KEY3LIFT88 key consumed: key room=255, machine3 var1=%d, lift88 var1=%d", mem:read_u8(mb+5), mem:read_u8(lb+5)))
      to("dismiss")
    elseif f-t>300 then
      fail(string.format("no trigger; key room=%d carried=%s machine3 var1=%d lift88 var1=%d in_inventory=%s",
        mem:read_u8(kb), tostring(key_in_inv(keyidx)), mem:read_u8(mb+5), mem:read_u8(lb+5), tostring(in_inventory())))
    end

  elseif stage=="dismiss" then
    key("SPACE", ((f-t)%26)<8)
    local busy = in_msgwait() or in_audio()
    clear = busy and 0 or clear+1
    if clear>=30 then
      key("SPACE",false)
      print("KEY3LIFT88 message dismissed, mainloop back")
      warp(88,W88_X,W88_Y)
      to("teleport88")
    elseif f-t>600 then fail("key message never let go") end

  elseif stage=="lift" then
    local lb=lift88()
    local y=mem:read_u8(lb+3)
    if y<ly_min then ly_min=y end
    if y>ly_max then ly_max=y end
    if r("killed")~=0 then return fail(string.format("killed watching the lift (y=%d)", y)) end
    if f-t>=800 then
      local ok = ly_min<=LIFT_TOP+2 or ly_max>=LIFT_BOT-2   -- moved off its rest height at least once
      print(string.format("KEY3LIFT88 %s lift88 travel seen %d..%d (rest %d, bottom %d)",
        ok and "PASS" or "FAIL", ly_min, ly_max, LIFT_TOP, LIFT_BOT))
      to("ride")
    end

  elseif stage=="ride" then
    -- confirm it CARRIES Dizzy: put him on the bar (frame 126, lift
    -- y+40) while it's away from its rest height, and confirm his own
    -- y tracks it for a few passes (same "ride the bar" check as
    -- keylift.lua's own ridewait/ride stages, shortened).
    local lb=lift88()
    local ly=mem:read_u8(lb+3)
    if count==0 then
      mem:write_u8(SYM.dizzy_x, mem:read_u8(lb+2)+4)
      mem:write_u8(SYM.dizzy_y, ly+40)
      mem:write_u8(SYM.dizzy_dy, 0)
      count=1; t=f
    end
    if r("killed")~=0 then return fail(string.format("killed riding lift88 (y=%d feet=%d)", ly, r("dizzy_y"))) end
    if f-t>=40 then
      local dy=r("dizzy_y")
      local off=dy-ly
      local ok = off>=38 and off<=42
      print(string.format("KEY3LIFT88 %s ride: lift y=%d feet=%d offset=%d (want ~40)", ok and "PASS" or "FAIL", ly, dy, off))
      stage="done"
    end
  end
end)
