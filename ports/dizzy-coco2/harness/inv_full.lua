-- harness/inv_full.lua -- playtest bug (2026-10-02): picking up a 4th
-- item auto-drops the oldest, but the drop "didn't really happen" and
-- picking the dropped item back up DUPLICATED it in the inventory.
-- Root cause: tp_reallytake stored room=255 through Y AFTER inv_insert,
-- whose auto-drop (drop_to_world -> update_item_triggers) walks the
-- actor table in Y -- the store hit the wrong actor.
-- Scenario (base actor table, so it runs on BOTH builds): carry bone,
-- rock, whiskey (whiskey oldest); in room 36 pick up the jug (4th item)
-- -> whiskey must land in room 36, jug must leave the world; then pick
-- the whiskey back up -> no duplicates. Invariant checked after every
-- step: every inv entry's actor has room 255, no inv value repeats, and
-- no carried item is still lying in the room.
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 120 \
--     -autoboot_script harness/inv_full.lua
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
local BONE,ROCK,WHISKEY,JUG=6,7,14,30           -- actor_data.asm slots
local function aroom(i) return mem:read_u8(SYM.actor_ram+i*STRIDE) end
local function invs() local t={} for s=0,3 do t[s]=mem:read_u8(SYM.inv+s) end return t end
local results={ok=0,fail=0}
local function check(ok,what) if ok then results.ok=results.ok+1 else results.fail=results.fail+1 end
  print(string.format("INVFULL %s %s", ok and "PASS" or "FAIL", what)) end
local function invariant(tag)
  local t=invs(); local seen={}; local dup=false; local bad={}
  for s=0,3 do local v=t[s]
    if v~=0 then
      if seen[v] then dup=true end; seen[v]=true
      if v<100 and aroom(v-1)~=255 then bad[#bad+1]=string.format("slot%d=actor%d room=%d",s,v-1,aroom(v-1)) end
    end end
  check(not dup and #bad==0, string.format("%s: inv=[%d,%d,%d,%d] no duplicates=%s carried-but-in-world=%s",
    tag,t[0],t[1],t[2],t[3],tostring(not dup),#bad==0 and "none" or table.concat(bad," ")))
  return t
end
local f,loaded,stage,t,boot_live,stood,busyn=0,false,"boot",0,0,0,0
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  if f==31 then stray_fix(os.getenv("DIZZY_BIN")) end
  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    boot_live=(r("cur_room")==36 and r("dizzy_y")~=0) and boot_live+1 or 0
    if boot_live>=60 then
      release()
      for s=0,3 do mem:write_u8(SYM.inv+s,0) end
      -- carried: newest first; whiskey is the OLDEST (slot 2)
      mem:write_u8(SYM.inv+0,ROCK+1); mem:write_u8(SYM.inv+1,BONE+1); mem:write_u8(SYM.inv+2,WHISKEY+1)
      for _,i in ipairs({BONE,ROCK,WHISKEY}) do mem:write_u8(SYM.actor_ram+i*STRIDE,255) end
      mem:write_u8(SYM.respawn_room,36); mem:write_u8(SYM.respawn_x,136); mem:write_u8(SYM.respawn_y,144)
      mem:write_u8(SYM.killed,1); stage="arrive"; t=f; step=1
    end
    return
  end
  if r("lives")<2 then mem:write_u8(SYM.lives,2) end
  if stage=="arrive" then
    if in_msgwait() or in_audio() or r("killed")~=0 then busyn=busyn+1; key("SPACE",(busyn//14)%2==0) else key("SPACE",false) end
    if r("cur_room")==36 and r("killed")==0 and not in_msgwait() and not in_audio() then
      stood = r("dizzy_floor")==1 and stood+1 or 0
      if stood>=20 then stage="pickup"; t=f end
    end
    if f-t>1500 then check(false,"never settled in room 36"); stage="end" end
  elseif stage=="pickup" then
    key("DOWN", f-t>=10 and f-t<50)
    if f-t>=60 and f-t<400 then key("SPACE", ((f-t)//14)%2==0) end   -- close the inventory display
    if f-t==420 then
      key("SPACE",false)
      if step==1 then
        local inv=invariant("after 4th pickup (jug)")
        check(aroom(JUG)==255 and inv[0]==JUG+1, string.format("jug left the world and is newest (jug room=%d inv0=%d)",aroom(JUG),inv[0]))
        check(aroom(WHISKEY)==36, string.format("whiskey (oldest) auto-dropped INTO room 36 (room=%d)",aroom(WHISKEY)))
        step=2; t=f   -- pick the whiskey straight back up (it is at Dizzy's feet)
      else
        local inv=invariant("after picking the auto-dropped whiskey back up")
        local n=0; for s=0,3 do if inv[s]==WHISKEY+1 then n=n+1 end end
        check(n==1 and aroom(WHISKEY)==255, string.format("whiskey in inventory exactly once (count=%d room=%d)",n,aroom(WHISKEY)))
        check(aroom(BONE)==36, string.format("bone (now oldest) auto-dropped into room 36 (room=%d)",aroom(BONE)))
        stage="end"
      end
    end
  elseif stage=="end" then
    print(string.format("INVFULL SUMMARY pass=%d fail=%d", results.ok, results.fail))
    stage="done"; manager.machine:exit()
  end
end)
