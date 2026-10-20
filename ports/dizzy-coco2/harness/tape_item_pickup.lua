-- harness/tape_item_pickup.lua -- T0234: per-item pickup check for the
-- tape-only region's own actor table (actor_init_tape), the same real
-- warp->stand->DOWN->check proof harness/items.lua already uses for the
-- -run build's actor_ram, trimmed to a small FIXED list (this table has
-- 12 slots total, not the -run build's 43 -- no need for items.lua's own
-- auto-discovery/restore-and-continue machinery).
--
-- Checks, per item: after standing beside it and holding DOWN, the
-- ACTOR RECORD's room byte flips to 255 (removed from the world) AND
-- `inv` gains the tape-table encoding (100 + 0-based slot + 1 -- see
-- actors.asm's own try_pickup/tp_take note, T0234). Does NOT drop it
-- back (items.lua's own job on the base table; not attempted here).
--
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 90 \
--     -autoboot_script harness/tape_item_pickup.lua
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
local function stray_fix(path)
  local fh=io.open(path,"rb"); local d=fh:read("*all"); fh:close(); local pos=1
  while pos<=#d and d:byte(pos)==0 do
    local len=d:byte(pos+1)*256+d:byte(pos+2); local addr=d:byte(pos+3)*256+d:byte(pos+4)
    for i=0,len-1 do local a=addr+i
      if a>=0x0E00 and a<0x8000 and mem:read_u8(a)~=d:byte(pos+5+i) then mem:write_u8(a,d:byte(pos+5+i)) end end
    pos=pos+5+len
  end
end
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end
local STRIDE=8
local function r(s) return mem:read_u8(SYM[s]) end
local function release() key("LEFT",false); key("RIGHT",false); key("UP",false); key("DOWN",false); key("SPACE",false) end
local function rec(slot) local b=SYM.actor_init_tape+slot*STRIDE local t={} for j=0,7 do t[j]=mem:read_u8(b+j) end return t end
local function inv_has(v) for s=0,3 do if mem:read_u8(SYM.inv+s)==v then return true end end return false end
local function pc() return cpu.state["PC"].value end
local function stack_has(lo,hi)
  local sp=cpu.state["S"].value
  for i=0,24 do if sp+i+1>=0x100 then break end local w=mem:read_u8(sp+i)*256+mem:read_u8(sp+i+1)
    if w>=lo and w<hi then return true end end
  return false
end
local function in_audio() local p=pc() return p>=SYM.play_tone and p<SYM.play_chirp end
local function in_msgwait()
  local p=pc()
  return (p>=SYM.msg_wait_dismiss and p<SYM.fb_stablekeys) or stack_has(SYM.msg_wait_dismiss,SYM.fb_stablekeys)
end

-- slot (0-based, actor_data_tape.asm's own source order), room, wx, wy
-- T0239: slots shift whenever tape actors are inserted earlier in
-- actor_init_tape (8 -> 10 -> 12 -> 13 so far) -- look them up by
-- (room, frame) instead of hardcoding.
local function slot_of(room,frame)
  -- parse the assembled-from source: slot = fcb line order after the label
  local i=-1; local inside=false
  for line in io.lines("target/actor_data_tape.asm") do
    if line:match("^actor_init_tape%s*$") then inside=true
    elseif inside then
      local rm,_,_,_,fr=line:match("^%sfcb (%d+),(%d+),(%d+),(%d+),(%d+)")
      if rm then i=i+1; if tonumber(rm)==room and tonumber(fr)==frame then return i end
      elseif line:match("^%S") and not line:match("^;") then break end
    end
  end
  error("no tape actor room "..room.." frame "..frame)
end
local LIST={
  -- T0234: NOT wx=56 (item x-8, items.lua's usual formula) -- room 88
  -- also has doughere right next to it (x=40, 24px wide, right edge 64,
  -- SAME room, scanned EARLIER in actor_init_tape than crowbarhere) and
  -- doughere is a person (frame 36, tp_reallytake's own 32..39 test) --
  -- overlapping BOTH boxes lets try_pickup's tape pass hit doughere
  -- first and open Denzil's generic chatter box instead (the ALREADY-
  -- SHIPPED "wrong text" simplification T0234's own regen_art.sh note
  -- documents, not a new bug -- but it blocks reaching crowbarhere from
  -- this exact spot). wx=64 sits exactly on doughere's own right edge
  -- (excluded by actor_hit's own >= boundary) while still overlapping
  -- crowbarhere (x=64..80) -- verified against actor_hit's real AABB
  -- arithmetic, not guessed.
  -- T0238/T0239: slot keeps shifting as more tape-only actors are
  -- inserted earlier in actor_init_tape's own source order than
  -- crowbarhere (roompack's real, unhardcoded order) -- 8 (T0234) ->
  -- 10 (T0238, lifts+switch1) -> 12 (T0239, room 48's log+key 4).
  -- Re-verify against target/actor_data_tape.asm directly, don't
  -- increment by habit.
  -- T0229: the crowbar now starts in room 255 (Doug's first talk materialises it, tape_people229.lua
  -- tests THAT path end to end). THIS is the isolated pickup unit test: put it into room 88 by hand.
  -- slot_of looks it up by its source room, which is now 255.
  {name="crowbarhere (room 88)", slot=slot_of(255,4), room=88, wx=64, wy=96, setroom=88},
  -- T0218 made the potion start in room 255 (Dozy's first talk materialises it); T0223:
  -- look it up there and put it into room 45 for this test (setroom).
  {name="sleepingpotionhere (room 45)", slot=slot_of(255,15), room=45, wx=184, wy=128, setroom=45},
}
if os.getenv("ONLY") then
  local keep={}
  for it in os.getenv("ONLY"):gmatch("%d+") do keep[tonumber(it)]=true end
  local filtered={}
  for i,it in ipairs(LIST) do if keep[i] then filtered[#filtered+1]=it end end
  LIST=filtered
end

local f,loaded,stage,t=0,false,"boot",0
local li,cur,stood,busyn,boot_live=1,nil,0,0,0
local results={ok=0,fail=0}
local function report(ok,what)
  if ok then results.ok=results.ok+1 else results.fail=results.fail+1 end
  print(string.format("TAPEITEM %s %s: %s", ok and "PASS" or "FAIL", cur.name, what))
end

emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  if f==31 then stray_fix(os.getenv("DIZZY_BIN")) end
  if stage~="boot" and r("lives")<2 then mem:write_u8(SYM.lives,2) end

  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    boot_live=(r("cur_room")==36 and r("dizzy_y")~=0) and boot_live+1 or 0
    if boot_live>=60 then
      release()
      for s=0,3 do mem:write_u8(SYM.inv+s,0) end
      stage="next"; t=f
    end
    return
  end

  if stage=="next" then
    cur=LIST[li]
    if not cur then
      print(string.format("TAPEITEMSUM %d ok, %d fail", results.ok, results.fail))
      stage="done"; manager.machine:exit(); return
    end
    for s=0,3 do mem:write_u8(SYM.inv+s,0) end
    if cur.setroom then mem:write_u8(SYM.actor_init_tape+cur.slot*8,cur.setroom) end
    mem:write_u8(SYM.respawn_room,cur.room); mem:write_u8(SYM.respawn_x,cur.wx)
    mem:write_u8(SYM.respawn_y,cur.wy); mem:write_u8(SYM.killed,1)
    stood=0; stage="arrive"; t=f

  elseif stage=="arrive" then
    if in_msgwait() or in_audio() or r("killed")~=0 then busyn=busyn+1; key("SPACE",(busyn//14)%2==0) else key("SPACE",false) end
    if r("cur_room")==cur.room and r("dizzy_x")==cur.wx and r("killed")==0 and not in_msgwait() and not in_audio() then
      stood = r("dizzy_floor")==1 and stood+1 or 0
      if stood>=10 then stage="pickup"; t=f end
    end
    if f-t>1500 then report(false, string.format("never stood beside it (room=%d x=%d y=%d)", r("cur_room"), r("dizzy_x"), r("dizzy_y"))); li=li+1; stage="next" end

  elseif stage=="pickup" then
    key("DOWN", f-t>=10 and f-t<50)
    if os.getenv("TAPEDBG") and f-t<=88 and (f-t)%2==0 then
      print(string.format("TAPEDBG a=%d x=%d y=%d floor=%d keyflags=%02X pickup_timer=%d room_byte=%d rng=%d pc=%04X killed=%d",
        f-t, r("dizzy_x"), r("dizzy_y"), r("dizzy_floor"), r("keyflags"), r("pickup_timer"), rec(cur.slot)[0], r("rng_ctr"), pc(), r("killed")))
    end
    if f-t==90 then
      key("DOWN",false)
      local want_inv = 100+cur.slot+1
      local t_=rec(cur.slot)
      local room_flipped = t_[0]==255
      local inv_got = inv_has(want_inv)
      report(room_flipped and inv_got,
        string.format("room byte=%d (want 255) inv has %d=%s", t_[0], want_inv, tostring(inv_got)))
      li=li+1; stage="next"
    end
  end
end)
