-- harness/items.lua -- pick up and put down EVERY pickupable in the built rooms.
--
-- For each ROU_PICKUPABLE actor in actor_ram whose room is built (or the ids in
-- ONLY=idx,idx), with an empty inventory:
--   1. warp Dizzy beside it (respawn poke; x = item x - 8, dropped from just
--      above so he lands on whatever it stands on) and wait until he stands
--   2. DOWN: expect the item carried -- its room byte 255 and index+1 in inv --
--      or, for a person (frames 32..39, Denzil in room 68), a message and
--      nothing carried
--   3. DOWN opens the inventory (cursor on EXIT), UP to the item, SPACE drops
--      it: expect it back in this room at Dizzy's feet (drop_to_world) and not
--      in inv
--   4. restore the actor record exactly as it was, clear inv, next item
-- Prints ITEM lines and ITEMSUM.
--
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 3000 \
--     -autoboot_script harness/items.lua
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
local NACT, STRIDE = SYM.ACTOR_COUNT or 33, 8
local SPOTS={}
if os.getenv("ITEMSPOTS") then
  for line in io.lines(os.getenv("ITEMSPOTS")) do
    local i,rm,x,y=line:match("^(%d+),(%d+),(%d+),(%d+)")
    if i then SPOTS[tonumber(i)]={x=tonumber(x),y=tonumber(y)} end
  end
end
local ROU_PICKUPABLE = 2

local function r(s) return mem:read_u8(SYM[s]) end
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
local function in_inventory()
  local p=pc()
  return (p>=SYM.show_inventory and p<SYM.inv) or stack_has(SYM.show_inventory,SYM.inv)
end
local function inv_has(idx) for s=0,3 do if mem:read_u8(SYM.inv+s)==idx+1 then return true end end return false end
local function inv_clear() for s=0,3 do mem:write_u8(SYM.inv+s,0) end end
local function rec(idx) local b=SYM.actor_ram+idx*STRIDE local t={} for j=0,7 do t[j]=mem:read_u8(b+j) end return t,b end
local function release() key("LEFT",false); key("RIGHT",false); key("UP",false); key("DOWN",false); key("SPACE",false) end

local built={}
do
  local asm=io.open("target/room36.asm"):read("*all")
  local tbl=asm:match("room_desc_table(.-)fdb 0")
  for n in tbl:gmatch("fdb r(%d+)_room_desc") do built[tonumber(n)]=true end
end

local f,loaded,stage,t=0,false,"boot",0
local boot_live,clear,stood,busyn,quiet=0,0,0,0,0
local list,li,cur,saved,base,results={},1,nil,nil,nil,{fail=0,ok=0}
local function to(s) stage=s; t=f; clear=0 end
local function report(ok, what)
  if ok then results.ok=results.ok+1 else results.fail=results.fail+1 end
  print(string.format("ITEM %s room %3d idx %2d frame %3d at (%3d,%3d): %s", ok and "ok" or "!!", cur.room, cur.idx, cur.frame, cur.x, cur.y, what))
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
      local only
      if os.getenv("ONLY") then only={} for s in os.getenv("ONLY"):gmatch("%d+") do only[tonumber(s)]=true end end
      for i=0,NACT-1 do
        local t_=rec(i)
        if t_[1]==ROU_PICKUPABLE and built[t_[0]] and (not only or only[i]) then
          list[#list+1]={idx=i,room=t_[0],x=t_[2],y=t_[3],frame=t_[4]}
        end
      end
      print(string.format("ITEMS %d pickupables in built rooms", #list))
      to("next")
    end
    return
  end

  if stage=="next" then
    -- warp only into a quiet, live game
    if r("killed")~=0 or in_msgwait() or in_audio() then busyn=busyn+1; key("SPACE",(busyn//14)%2==0); quiet=0; return end
    key("SPACE",false); quiet=quiet+1
    if quiet<20 then return end
    quiet=0
    cur=list[li]
    if not cur then
      print(string.format("ITEMSUM %d ok, %d flagged", results.ok, results.fail))
      stage="done"; manager.machine:exit(); return
    end
    saved,base=rec(cur.idx)
    inv_clear()
    -- ITEMSPOTS (tools/itemspots.py): the floor the item rests on, not its y
    local wx,wy=math.max(8, math.min(224, ((cur.x-8)//4)*4)), math.max(60, cur.y)
    if SPOTS[cur.idx] then wx,wy=SPOTS[cur.idx].x,SPOTS[cur.idx].y end
    cur.wx=wx
    mem:write_u8(SYM.respawn_room,cur.room); mem:write_u8(SYM.respawn_x,wx)
    mem:write_u8(SYM.respawn_y,wy); mem:write_u8(SYM.killed,1)
    stood=0; to("arrive")

  elseif stage=="arrive" then
    if in_msgwait() or in_audio() or r("killed")~=0 then busyn=busyn+1; key("SPACE",(busyn//14)%2==0) else key("SPACE",false) end
    if r("cur_room")==cur.room and r("dizzy_x")==cur.wx and r("killed")==0 and not in_msgwait() and not in_audio() then
      stood = r("dizzy_floor")==1 and stood+1 or 0
      if stood>=10 then key("SPACE",false); inv_clear(); to("pickup") end
    end
    if f-t>1500 then report(false, string.format("never stood beside it (room=%d x=%d y=%d)", r("cur_room"), r("dizzy_x"), r("dizzy_y"))); to("restore") end

  elseif stage=="pickup" then
    -- nothing held for 10 frames first: a SPACE left down by the box
    -- dismissing above was still in keyflags and DOWN never registered
    key("SPACE",false); key("UP",false); key("LEFT",false); key("RIGHT",false)
    -- held until it takes (carried, or the inventory/a message opened), up to
    -- 40 frames: a short press right after SPACE's release never reached
    -- keyflags (the port waits for keys to settle)
    local took = rec(cur.idx)[0]==255 or in_inventory() or in_msgwait()
    key("DOWN", f-t>=10 and f-t<50 and not took)
    if os.getenv("ITEMDBG") and f-t<=40 and (f-t)%2==0 then
      print(string.format("ITEMDBG idx=%d a=%d x=%d y=%d floor=%d keyflags=%02X pickup_timer=%d seq=%d killed=%d pc=%04X room_byte=%d",
        cur.idx, f-t, r("dizzy_x"), r("dizzy_y"), r("dizzy_floor"), r("keyflags"), r("pickup_timer"), r("dizzy_seq"), r("killed"), pc(), rec(cur.idx)[0]))
    end
    if f-t==90 then
      key("DOWN",false)
      local t_=rec(cur.idx)
      local person = cur.frame>=32 and cur.frame<=39
      if person then
        -- a person: a message is up (or was), nothing carried
        report(t_[0]~=255 and not inv_has(cur.idx), (t_[0]~=255 and not inv_has(cur.idx)) and "a person: talked, not picked up" or "a PERSON WAS PICKED UP")
        to("restore")
      elseif t_[0]==255 and inv_has(cur.idx) then
        cur.picked=true; to("pickmsg")
      elseif in_inventory() then
        report(false, "DOWN opened the inventory instead of picking it up"); to("restore")
      else
        report(false, string.format("not picked up (room byte %d, dizzy at %d,%d)", t_[0], r("dizzy_x"), r("dizzy_y"))); to("restore")
      end
    end

  elseif stage=="pickmsg" then
    -- the pickup's own message box, if any
    if in_msgwait() or in_audio() then busyn=busyn+1; key("SPACE",(busyn//14)%2==0); clear=0
    else key("SPACE",false); clear=clear+1; if clear>=30 then to("open") end end
    if f-t>600 then report(false, "picked up, but its message never let go"); to("restore") end

  elseif stage=="open" then
    key("DOWN", true)
    if in_inventory() and mem:read_u8(SYM.inv_occupied)>=1 then key("DOWN",false); to("invwait") end
    if f-t>200 then key("DOWN",false); report(false, "picked up, but DOWN never opened the inventory"); to("restore") end

  elseif stage=="invwait" then
    if f-t>=30 then to("cursor") end

  elseif stage=="cursor" then
    if mem:read_u8(SYM.inv_cursor)==0 then
      key("UP",false)
      if f-t>=20 then to("select") end
    else
      key("UP", ((f-t)%30)<10)
      if mem:read_u8(SYM.inv_cursor)==0 then key("UP",false) end
      if f-t>600 then key("UP",false); report(false, "picked up, but the cursor never reached it"); to("restore") end
    end

  elseif stage=="select" then
    if f-t<2 and mem:read_u8(SYM.inv_cursor)~=0 then to("cursor") return end
    key("SPACE", f-t<10)
    if f-t==90 then
      key("SPACE",false)
      local t_=rec(cur.idx)
      local ok = t_[0]==cur.room and not inv_has(cur.idx)
      report(ok, ok and string.format("picked up and put down at (%d,%d)", t_[2], t_[3])
                   or string.format("picked up, but NOT put down (room byte %d, carried=%s)", t_[0], tostring(inv_has(cur.idx))))
      to("restore")
    end

  elseif stage=="restore" then
    release()
    if in_msgwait() or in_audio() or in_inventory() then busyn=busyn+1; key("SPACE",(busyn//14)%2==0); return end
    for j=0,7 do mem:write_u8(base+j, saved[j]) end
    inv_clear()
    mem:write_u8(SYM.bufA_last_x,255); mem:write_u8(SYM.bufB_last_x,255)
    li=li+1; to("next")
  end
end)
