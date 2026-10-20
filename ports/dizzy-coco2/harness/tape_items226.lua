-- harness/tape_items226.lua -- T0226: tape-only room banners, door knocker,
-- empty bucket filled at the well, pickaxe + rock (X-ALL.TXT proxdoor 3410,
-- proxmtbucket 2982, proxpickaxe 3449, buckethere 1642, rockhere 1705).
-- Everything is driven by REAL inventory drops (the inventory UI), real DOWN
-- pickups and real LEFT/RIGHT walking; memory is only POKED to set up a start
-- state (warp = the respawn poke every harness uses; an item into the inventory
-- when the test is about the DROP) and READ to judge.  Each feature has a
-- CONTROL (behaviour absent without the trigger) and a game-over reset check.
--
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map [DUMPDIR=/tmp/x] \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 900 \
--     -autoboot_script harness/tape_items226.lua
-- Prints "ITEMS226 PASS|FAIL <what>" lines and "ITEMS226 SUMMARY pass=N fail=N".
-- DUMPDIR: framebuffer dumps (raw 6144 bytes; harness/pmode4_to_png.py).
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
for _,s in ipairs({"TB_BEAN","full_bucket","ti_reset","cdt_bucket","cdt_knocker","cdt_pickaxe","tape_names_tab","tape_names_end","msg_usedoorknocker","msg_fillbucket","msg_usepickaxe",
                   "actor_ram","actor_init_tape","inv","inv_cursor","inv_occupied","cur_buf","msg_active","show_inventory","msg_wait_dismiss","fb_stablekeys","stalk_grown","play_tone","play_chirp","find_room_name"}) do
  if not SYM[s] then print("ITEMS226 FAIL symbol "..s.." missing from the map"); manager.machine:exit() end
end
local NACT=SYM.ACTOR_COUNT or 43
local NACT_T=SYM.ACTOR_COUNT_tape or 23
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
local function find_base(room,frame)
  for i=0,NACT-1 do local b=SYM.actor_ram+i*8
    if mem:read_u8(b+4)==frame and (room==nil or mem:read_u8(b)==room) then return b,i end end
end
local function trec(a) local t={} for j=0,7 do t[j]=mem:read_u8(a+j) end return t end

-- ---- coroutine scaffolding: script() runs one step per video frame ----
local f=0
local pass,fail=0,0
local function report(ok,what)
  if ok then pass=pass+1 else fail=fail+1 end
  print(string.format("ITEMS226 %s %s", ok and "PASS" or "FAIL", what))
end
local function wait(n) for _=1,n do coroutine.yield() end end
local function waitfor(pred,timeout)
  for _=1,timeout do if pred() then return true end coroutine.yield() end
  return pred()
end
local function s8(v) return v>127 and v-256 or v end
local function warp(room,x,y)
  mem:write_u8(SYM.lives,2)
  mem:write_u8(SYM.respawn_room,room); mem:write_u8(SYM.respawn_x,x)
  mem:write_u8(SYM.respawn_y,y); mem:write_u8(SYM.killed,1)
  local n=0
  local seen_box=false      -- the death box ([X-ALL.TXT line 991]) must have come and gone, or a
  local ok=waitfor(function() -- warp to the SAME x as Dizzy's current one would read as done at once
    n=n+1
    if n%14==0 then key("SPACE",(n//14)%2==0) end
    if r("msg_active")==1 then seen_box=true end
    return seen_box and r("cur_room")==room and r("dizzy_x")==x and r("killed")==0 and r("msg_active")==0
      and not in_audio() and not in_msgwait()
  end,900)
  key("SPACE",false)
  if not ok then return false end
  local floor_n=0
  return waitfor(function() floor_n = r("dizzy_floor")==1 and floor_n+1 or 0; return floor_n>=10 end,300)
end
-- like warp() but does not wait for a floor: for rooms with nothing to stand on (room 91's
-- collision mask is empty).  Returns true when the banner machinery has run for `room`
-- (cur_room == room and ui_last_room == room), polled every frame; the caller dumps at once.
local function warp_loose(room,x,y)
  mem:write_u8(SYM.lives,2)
  mem:write_u8(SYM.respawn_room,room); mem:write_u8(SYM.respawn_x,x)
  mem:write_u8(SYM.respawn_y,y); mem:write_u8(SYM.killed,1)
  local n=0
  for _=1,900 do
    n=n+1
    if n%14==0 then key("SPACE",(n//14)%2==0) end
    coroutine.yield()
    if r("cur_room")==room and mem:read_u8(SYM.ui_last_room)==room and r("killed")==0 and r("msg_active")==0 then
      key("SPACE",false)
      coroutine.yield()      -- the periodic callback can land mid-draw_ui: let the pass finish
      return r("cur_room")==room
    end
  end
  key("SPACE",false)
  return false
end
local function dismiss_msg()
  local n=0
  local ok=waitfor(function()
    n=n+1
    key("SPACE",(n%26)<8)
    return not in_msgwait() and not in_audio() and r("msg_active")==0
  end,600)
  key("SPACE",false)
  wait(40)
  return ok
end
-- dismiss every box of a multi-box chatter run; returns the number of boxes
-- seen (a box = a rising edge of msg_active)
local function dismiss_all(maxboxes)
  local boxes,prev=0,0
  local idle=0
  local n=0
  while idle<120 and n<maxboxes*400 do
    n=n+1
    local a=r("msg_active")
    if a==1 and prev==0 then boxes=boxes+1 end
    prev=a
    key("SPACE",(n%26)<8)
    if a==0 and not in_msgwait() and not in_audio() then idle=idle+1 else idle=0 end
    coroutine.yield()
  end
  key("SPACE",false)
  wait(40)
  return boxes
end
local function dump_fb()
  local base = mem:read_u8(SYM.cur_buf)==0 and 0x4000 or 0x6000
  local t={} for i=0,6143 do t[i]=mem:read_u8(base+i) end
  return t
end
local function save_dump(name,d)
  local dir=os.getenv("DUMPDIR"); if not dir then return end
  local fh=io.open(dir.."/"..name..".raw","wb")
  for i=0,6143 do fh:write(string.char(d[i])) end fh:close()
end
local function diff_bytes(a,b,c0,c1,r0,r1)
  local n=0
  for row=r0,r1 do for c=c0,c1 do if a[row*32+c]~=b[row*32+c] then n=n+1 end end end
  return n
end

-- Real inventory drop of whatever sits in inv slot 0 (slot = actor index+1,
-- >100 for the tape table); returns true once the inventory closed.
local function drop_slot0_once()
  local opened=false
  local ok=waitfor(function()
    key("DOWN",true)
    if in_inventory() and mem:read_u8(SYM.inv_occupied)>=1 then opened=true end
    return opened
  end,300)
  key("DOWN",false)
  if not ok then return false,"inventory never opened" end
  wait(30)
  local t0=f
  while mem:read_u8(SYM.inv_cursor)~=0 and f-t0<600 do
    key("UP",((f-t0)%30)<10); coroutine.yield()
  end
  key("UP",false); wait(20)
  key("SPACE",true); wait(10); key("SPACE",false)
  return true
end
-- put the actor at record address `rec` (slot value `slot`) into inv[0], drop it
-- for real, and wait for the drop's reaction (a message box, or none for
-- `quiet`).  Retries: the inventory UI sometimes eats the first SPACE.
local function carry_and_drop(rec,slot,quiet)
  for try=1,6 do
    wait(7*(try-1))          -- shift the key-press phase between tries (the UI can miss an edge)
    mem:write_u8(rec,255)
    for s=0,3 do mem:write_u8(SYM.inv+s,0) end
    mem:write_u8(SYM.inv,slot)
    local ok,why=drop_slot0_once()
    if ok then
      if quiet then wait(60); return true end
      if waitfor(function() return in_msgwait() end,150) then return true end
    end
    print(string.format("ITEMS226 INFO drop try %d: no reaction (%s)",try,tostring(why)))
    if in_inventory() then key("SPACE",true); wait(10); key("SPACE",false); wait(30) end
    wait(30)
  end
  return false
end

-- One input step from wherever Dizzy stands: hold `dir` (-1 left, 0 none, 1 right)
-- for the whole step, press UP from frame `delay` for `jl` frames, then wait
-- until he is standing again (floor=1 for 8 frames after being airborne) or the
-- room changes.  Returns x,y,room.
local function step(dir,delay,jl,tmax)
  local t0=f
  local room0=r("cur_room")
  local stable,seen_air=0,false
  while f-t0<tmax do
    local t=f-t0
    key("LEFT",dir<0); key("RIGHT",dir>0)
    key("UP",t>=delay and t<delay+jl)
    coroutine.yield()
    if r("cur_room")~=room0 or r("killed")~=0 then break end
    if r("dizzy_floor")==0 then seen_air=true; stable=0 else stable=stable+1 end
    if seen_air and stable>=8 then break end
  end
  key("LEFT",false); key("RIGHT",false); key("UP",false)
  wait(6)
  return r("dizzy_x"),r("dizzy_y"),r("cur_room")
end
-- the climb: 3 jumps up the stalk's leaves, then out of the top into room 74
local ROUTE={ {1,24,3}, {-1,0,3}, {1,0,30}, {0,0,3} }
local function climb()
  local log={}
  for i,st in ipairs(ROUTE) do
    local x,y,room=step(st[1],st[2],st[3],260)
    log[#log+1]=string.format("(%d,%d)r%d",x,y,room)
    if room~=58 then break end
  end
  return table.concat(log," > "),r("cur_room")
end

local D={}
local function trec(a) local t={} for j=0,7 do t[j]=mem:read_u8(a+j) end return t end
local function find_tape(room,frame)
  for i=0,NACT_T-1 do local b=SYM.actor_init_tape+i*8
    if mem:read_u8(b+4)==frame and (room==nil or mem:read_u8(b)==room) then return b,i end end
end
local function walk(dir,n)
  local x0=r("dizzy_x")
  for _=1,n do key("LEFT",dir<0); key("RIGHT",dir>0); coroutine.yield()
    if r("cur_room")~=room0 and false then break end end
  key("LEFT",false); key("RIGHT",false); wait(6)
end
-- hold a direction until the room changes or n frames pass; returns room,x
local function walk_until_room(dir,n,room0)
  for _=1,n do key("LEFT",dir<0); key("RIGHT",dir>0); coroutine.yield()
    if r("cur_room")~=room0 then break end end
  key("LEFT",false); key("RIGHT",false); wait(8)
  return r("cur_room"),r("dizzy_x")
end
-- real DOWN at an item until its record leaves `room` (picked up) -- tries several x offsets
local function pickup(rec,room,xs,y)
  for _,sx in ipairs(xs) do
    if not warp(room,sx,y) then return false end
    local t1=f
    while f-t1<80 do
      key("DOWN",f-t1>=5 and f-t1<40); coroutine.yield()
      if mem:read_u8(rec)==255 then break end
    end
    key("DOWN",false)
    if mem:read_u8(rec)==255 then
      waitfor(function() return in_inventory() end,120)
      if in_inventory() then key("SPACE",true); wait(10); key("SPACE",false); wait(30) end
      wait(40)
      return true
    end
  end
  return false
end
-- room 84's pocket: standing still in proxknox the FIRST time shows knockandentermess
-- (a blocking chatter box, logic_low.asm T0134); dismiss it so input works.
local function settle84()
  wait(10)
  if r("msg_active")==1 or in_msgwait() then dismiss_msg() end
end
local function in_inv(slot) for s=0,3 do if mem:read_u8(SYM.inv+s)==slot then return true end end return false end
local BAND_R0,BAND_R1=24,31
local function band(d) local t={} for row=BAND_R0,BAND_R1 do for c=2,29 do t[#t+1]=d[row*32+c] end end return t end
local function band_ink(b) local n=0 for _,v in ipairs(b) do if v~=0 then n=n+1 end end return n end
local function band_key(b) return table.concat(b,",") end
local function empty_inv() for s=0,3 do mem:write_u8(SYM.inv+s,0) end end

local function script()
  local live=0
  waitfor(function()
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    live=(r("cur_room")==36 and r("dizzy_y")~=0) and live+1 or 0
    return live>=60
  end,3000)
  key("SPACE",false)

  -- ================= boot state =================
  local door=find_base(84,177)
  local mtb,mtbi=find_base(83,5)
  local fullp=SYM.full_bucket and (mem:read_u8(SYM.full_bucket)*256+mem:read_u8(SYM.full_bucket+1)) or 0
  local rock,rocki=find_tape(41,146)
  local knock,knocki=find_tape(89,21)
  local pick,picki=find_base(87,9)
  report(door~=nil and rock~=nil and knock~=nil and pick~=nil and mtb~=nil,"table: door (84/177), rock (tape table, 41/146), knocker (tape 89/21), pickaxe (87/9), empty bucket (83/5) all present")
  if not (door and rock and knock and pick and mtb) then return end
  local rr=trec(rock)
  report(rr[1]==15 and rr[2]==16 and rr[3]==101 and rr[7]==10,string.format("rock record: routine %d (crowbar=static), (x,y)=(%d,%d) = raw (36,101) -> px (16,101), colour %d (2+8: solid)",rr[1],rr[2],rr[3],rr[7]))
  local fb=fullp
  report(fb>=SYM.actor_ram and fb<SYM.actor_ram+NACT*8 and mem:read_u8(fb+4)==5,string.format("full_bucket points at a base actor record with frame 5 (%04X)",fb))
  report(mem:read_u8(fb)==255,string.format("FULL bucket starts in room 255 in the tape build (record room %d)",mem:read_u8(fb)))
  report(mem:read_u8(mtb)==83 and mem:read_u8(door)==84 and mem:read_u8(rock)==41,"empty bucket room 83, door room 84, rock room 41 at boot")
  local fbi=(fb-SYM.actor_ram)//8
  report(fbi==mtbi+1,string.format("full bucket is the record right after the empty one (slots %d, %d) as in X-ALL buckethere",mtbi,fbi))

  -- ================= 1. door knocker =================
  do
    local rec=trec(door)
    -- control: before the knocker, walking left along the floor does NOT leave room 84
    if not warp(84,24,176) then report(false,"warp 84"); return end
    settle84()
    D.door_before=dump_fb(); save_dump("room84_door_closed",D.door_before)
    print(string.format("ITEMS226 INFO 84 pre-walk: msg %d x %d y %d seq %d floor %d killed %d doorv1 %d",r("msg_active"),r("dizzy_x"),r("dizzy_y"),r("dizzy_seq"),r("dizzy_floor"),r("killed"),mem:read_u8(door+5)))
    local room,x=walk_until_room(-1,240,84)
    report(room==84 and x>=12 and x<=20,string.format("control: BEFORE the knocker, 240 frames of LEFT from x=24 in room 84 stop at the door (room %d, x=%d)",room,x))
    -- the knocker dropped OUTSIDE the box does nothing
    if not warp(84,100,176) then report(false,"warp 84 (outside)"); return end
    local ok=carry_and_drop(knock,100+knocki+1,true)
    report(ok and mem:read_u8(door)==84 and r("msg_active")==0,"control: knocker dropped outside the door box (x=100) -> door stays, no message")
    -- the real drop in the box
    local fired=false
    for _,sx in ipairs({20,22,24,26,28}) do
      if not warp(84,sx,176) then break end
      settle84()
      if carry_and_drop(knock,100+knocki+1,false) then fired=true; break end
    end
    report(fired and r("msg_active")==1,"knocker dropped for real in room 84's box -> usedoorknockermess")
    dismiss_msg()
    wait(30)
    report(mem:read_u8(door)==255,string.format("doorhere+room := 255 (record room %d)",mem:read_u8(door)))
    report(mem:read_u8(knock)==84,string.format("the knocker is not consumed (record room %d)",mem:read_u8(knock)))
    D.door_after=dump_fb(); save_dump("room84_door_open",D.door_after)
    -- the door sprite (8x32 at x=8,y=144 -> byte col 1, rows 144..175) is gone from the screen
    local before,after=0,0
    for row=144,175 do if D.door_before[row*32+1]~=0 then before=before+1 end if D.door_after[row*32+1]~=0 then after=after+1 end end
    report(before>=20 and after<before,string.format("the door is drawn before (%d inked rows in its column) and gone after (%d)",before,after))
    -- walk left for real: room 84 -> 83
    if not warp(84,24,176) then report(false,"warp 84 again"); return end
    settle84()
    local room,x=walk_until_room(-1,300,84)
    report(room==83,string.format("AFTER the knocker, the same LEFT walk leaves room 84 for room 83 (cur_room=%d, x=%d)",room,x))
    wait(30)
    D.r83=dump_fb(); save_dump("room83",D.r83)
  end

  -- ================= 2. empty bucket filled at the well =================
  do
    -- control: the full bucket is NOT pre-placed in room 60 any more -- standing where it used
    -- to lie and pressing DOWN opens no inventory and picks nothing up
    empty_inv()
    for _,sx in ipairs({40,48,56,64}) do
      if not warp(60,sx,100) then break end
      local t1=f
      while f-t1<70 do
        key("DOWN",f-t1>=5 and f-t1<50); coroutine.yield()
      end
      key("DOWN",false)
      if in_inventory() then key("SPACE",true); wait(10); key("SPACE",false); wait(30) end
    end
    local anyinv=false
    for s=0,3 do if mem:read_u8(SYM.inv+s)~=0 then anyinv=true end end
    report(not anyinv and mem:read_u8(fb)==255,"control: in room 60 where the full bucket used to be pre-placed, DOWN at x=40..64 picks nothing up (inventory empty, record room still 255)")
    empty_inv()
    -- real pickup of the EMPTY bucket in room 83
    local bx,by=mem:read_u8(mtb+2),mem:read_u8(mtb+3)
    local got=pickup(mtb,83,{bx-8,bx-16,bx+8,bx-24},100)
    report(got and in_inv(mtbi+1),string.format("the empty bucket is picked up for real in room 83 (record room %d, inventory has slot %d: %s)",mem:read_u8(mtb),mtbi+1,tostring(in_inv(mtbi+1))))
    if not in_inv(mtbi+1) then mem:write_u8(mtb,255); empty_inv(); mem:write_u8(SYM.inv,mtbi+1) end
    -- control: the empty bucket dropped in room 58's bean box does NOT water the bean
    if not warp(58,140,100) then report(false,"warp 58"); return end
    wait(10)
    local ok=carry_and_drop(mtb,mtbi+1,true)
    report(ok and r("stalk_grown")==0 and r("msg_active")==0 and mem:read_u8(mtb)==58,string.format("control: EMPTY bucket dropped in room 58's box: no message, stalk_grown=%d, bucket stays in room 58",r("stalk_grown")))
    -- pick it up again from room 58 (real), then drop outside the well box in room 60
    empty_inv()
    local got2=pickup(mtb,58,{mem:read_u8(mtb+2)-8,mem:read_u8(mtb+2)-16,mem:read_u8(mtb+2)+8},100)
    if not got2 then mem:write_u8(mtb,255); mem:write_u8(SYM.inv,mtbi+1) end
    if not warp(60,150,100) then report(false,"warp 60 (outside)"); return end
    wait(10)
    D.r60_empty=dump_fb(); save_dump("room60_no_bucket",D.r60_empty)
    ok=carry_and_drop(mtb,mtbi+1,true)
    report(ok and mem:read_u8(fb)==255 and r("msg_active")==0,"control: empty bucket dropped in room 60 but OUTSIDE the well box (x=150): no fill, full bucket still in room 255")
    -- fill it: real drop in the box
    local fired=false
    for _,sx in ipairs({56,60,52,64,48}) do
      if not warp(60,sx,100) then break end
      wait(10)
      if carry_and_drop(mtb,mtbi+1,false) then fired=true; break end
    end
    report(fired and r("msg_active")==1,"empty bucket dropped for real in room 60's well box -> fillbucketmess")
    dismiss_msg()
    wait(30)
    local fr=trec(fb)
    report(mem:read_u8(mtb)==255 and fr[0]==60 and fr[2]==56 and fr[3]==144,string.format("empty bucket consumed (room %d), full bucket now in room %d at (%d,%d)",mem:read_u8(mtb),fr[0],fr[2],fr[3]))
    -- the full bucket is DRAWN: same room, Dizzy standing away from it, vs the dump taken before the fill
    if warp(60,150,100) then
      wait(10)
      D.r60_full=dump_fb(); save_dump("room60_full_bucket",D.r60_full)
      local nb=diff_bytes(D.r60_empty,D.r60_full,6,9,144,159)
      report(nb>15,string.format("the full bucket is drawn at (56,144): %d bytes differ in its 16x16 box vs the pre-fill screen",nb))
    end
    -- pick up the full bucket (real), control: dropping it in room 60's box does nothing
    empty_inv()
    local got3=pickup(fb,60,{40,48,56,64,72},100)
    report(got3 and in_inv(fbi+1),string.format("the full bucket is picked up for real in room 60 (inventory has slot %d: %s)",fbi+1,tostring(in_inv(fbi+1))))
    if not in_inv(fbi+1) then mem:write_u8(fb,255); empty_inv(); mem:write_u8(SYM.inv,fbi+1) end
    if not warp(60,56,100) then report(false,"warp 60 (box, full bucket)"); return end
    wait(10)
    ok=carry_and_drop(fb,fbi+1,true)
    report(ok and r("msg_active")==0 and mem:read_u8(fb)==60,"control: FULL bucket dropped in room 60's well box does nothing (no message, stays in room 60)")
    empty_inv()
    got3=pickup(fb,60,{40,48,56,64,72},100)
    if not got3 then mem:write_u8(fb,255); empty_inv(); mem:write_u8(SYM.inv,fbi+1) end
    -- the full bucket waters the bean in room 58 (T0223's chain continues to work)
    if not warp(58,140,100) then report(false,"warp 58 (water)"); return end
    wait(10)
    ok=carry_and_drop(fb,fbi+1,false)
    report(ok and r("msg_active")==1,"full bucket dropped in room 58's box -> throwwateronbeanmess")
    dismiss_msg(); wait(60)
    report(r("stalk_grown")==1 and mem:read_u8(fb)==255,"stalk_grown=1, full bucket consumed: the knocker -> door -> 83 -> bucket -> well -> 58 chain reaches the stalk")
  end

  -- ================= 3. pickaxe and rock =================
  do
    if not warp(41,52,100) then report(false,"warp 41"); return end
    wait(20)
    print(string.format("ITEMS226 INFO room 41 stand: x=%d y=%d",r("dizzy_x"),r("dizzy_y")))
    D.rock_before=dump_fb(); save_dump("room41_rock",D.rock_before)
    -- the rock is drawn: ink in its 24x23 box (byte cols 2..4, rows 101..123)
    local ink=0 for row=101,123 do for c=2,4 do if D.rock_before[row*32+c]~=0 then ink=ink+1 end end end
    report(ink>25,string.format("the rock is DRAWN in room 41 (%d inked bytes in its 24x23 box)",ink))
    local sx0=r("dizzy_x")
    local room,x=walk_until_room(-1,200,41)
    report(room==41 and x>=30,string.format("control: BEFORE the pickaxe, LEFT along the ledge stops at the rock (x %d -> %d, rock spans x 16..39)",sx0,x))
    -- pickaxe dropped outside its box: nothing
    if not warp(41,200,100) then report(false,"warp 41 (outside)"); return end
    wait(10)
    local ok=carry_and_drop(pick,picki+1,true)
    report(ok and mem:read_u8(rock)==41 and r("msg_active")==0,"control: pickaxe dropped outside the rock box (x=200): rock stays, no message")
    -- real drop in the box
    local fired=false
    for _,sx in ipairs({52,56,48,60,44}) do
      if not warp(41,sx,127) then break end
      wait(10)
      if carry_and_drop(pick,picki+1,false) then fired=true; break end
    end
    report(fired and r("msg_active")==1,"pickaxe dropped for real in room 41's box -> usepickaxemess")
    dismiss_msg(); wait(30)
    report(mem:read_u8(rock)==255,string.format("rockhere+room := 255 (record room %d)",mem:read_u8(rock)))
    report(mem:read_u8(pick)==41,string.format("the pickaxe is not consumed (record room %d)",mem:read_u8(pick)))
    D.rock_after=dump_fb(); save_dump("room41_rock_gone",D.rock_after)
    local ink2=0 for row=101,123 do for c=2,4 do if D.rock_after[row*32+c]~=0 then ink2=ink2+1 end end end
    report(ink2<ink,string.format("the rock is gone from the screen (%d -> %d inked bytes in its box)",ink,ink2))
    if not warp(41,52,100) then report(false,"warp 41 again"); return end
    wait(20)
    local sx1=r("dizzy_x")
    local room,x=walk_until_room(-1,200,41)
    report(x<28,string.format("AFTER the pickaxe, the same LEFT walk passes where the rock was (x %d -> %d)",sx1,x))
  end

  -- ================= 5. banners (last before the reset: the cloud/lift rooms leave Dizzy in odd states) =================
  local ROOMS={74,75,63,91,92,45,48,49,94,89,41,73,88,93,40,46,31,47,77}
  local bands,keys,seen={}, {}, {}
  local okall=true
  local comp={}
  for _,rm in ipairs(ROOMS) do
    local got=false
    for _,wy in ipairs({100,140,60,176}) do
      for _,wx in ipairs({100,60,150,30,200,120,80}) do
        warp(rm,wx,wy)
        if r("cur_room")==rm and mem:read_u8(SYM.ui_last_room)==rm then got=true; break end
      end
      if got then break end
    end
    if not got then
      -- nothing to stand on (room 91): poll for the banner pass instead
      got=warp_loose(rm,100,100)
    end
    local d=dump_fb()
    if seen[band_key(band(d))] or band_ink(band(d))<=100 then
      -- the on-screen buffer may not have been flipped to the new banner yet (a room Dizzy
      -- falls out of at once): look at the other buffer too
      local base=mem:read_u8(SYM.cur_buf)==0 and 0x6000 or 0x4000
      local t={} for i=0,6143 do t[i]=mem:read_u8(base+i) end
      if not seen[band_key(band(t))] and band_ink(band(t))>100 then d=t end
    end
    local b=band(d)
    local ink=band_ink(b)
    local k=band_key(b)
    local dup=seen[k]
    seen[k]=rm
    local ok=got and ink>100 and not dup
    if not ok then okall=false end
    report(ok,string.format("banner room %d: in room=%s, band ink bytes %d%s",rm,tostring(got),ink,dup and (" IDENTICAL to room "..dup.."'s band (stale/blank)") or ""))
    if D.keep==nil then D.keep={} end
    save_dump("banner_room"..rm,d)
  end
  report(okall,"all 19 tape-only rooms show a banner, pairwise different")
  -- control: a base room's banner is unchanged by the fallback (room 53)
  do
    warp(53,100,100); wait(6)
    local b=band(dump_fb())
    report(r("cur_room")==53 and band_ink(b)>100 and not seen[band_key(b)],"control: base room 53 still shows its own (distinct) banner")
  end

  -- ================= 6. game over resets everything =================
  do
    mem:write_u8(SYM.lives,0); mem:write_u8(SYM.killed,1)
    local boxn=0
    local ok=waitfor(function()
      boxn=boxn+1
      key("SPACE",(boxn%26)<8)
      return r("cur_room")==36 and r("lives")==2 and r("dizzy_y")~=0 and boxn>200
    end,2400)
    key("SPACE",false)
    report(ok,string.format("game over -> new game (room %d, lives %d)",r("cur_room"),r("lives")))
    wait(30)
    report(mem:read_u8(door)==84,string.format("door back in room 84 (%d)",mem:read_u8(door)))
    report(mem:read_u8(rock)==41,string.format("rock back in room 41 (%d)",mem:read_u8(rock)))
    report(mem:read_u8(fb)==255,string.format("full bucket back in room 255 (%d)",mem:read_u8(fb)))
    report(mem:read_u8(mtb)==83,string.format("empty bucket back in room 83 (%d)",mem:read_u8(mtb)))
    report(mem:read_u8(knock)==89 and mem:read_u8(pick)==87,string.format("knocker back in room 89 (%d), pickaxe in room 87 (%d)",mem:read_u8(knock),mem:read_u8(pick)))
    local fp=mem:read_u8(SYM.full_bucket)*256+mem:read_u8(SYM.full_bucket+1)
    report(fp==fb,"full_bucket still points at the full bucket's record")
    -- the door blocks again (real walk)
    if not warp(84,24,176) then report(false,"warp 84 after reset"); return end
    settle84()
    local room,x=walk_until_room(-1,240,84)
    report(room==84,string.format("after the reset the door blocks again (LEFT stays in room 84, x=%d)",x))
  end

  print(string.format("ITEMS226 SUMMARY pass=%d fail=%d",pass,fail))
  manager.machine:exit()
end

local co,loaded=nil,false
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if f==31 and loaded then stray_fix(os.getenv("DIZZY_BIN")) end
  if not loaded or f<32 then return end
  if not co then co=coroutine.create(script) end
  if coroutine.status(co)=="dead" then return end
  local ok,err=coroutine.resume(co)
  if not ok then print("ITEMS226 FAIL harness error: "..tostring(err)); manager.machine:exit() end
  if coroutine.status(co)=="dead" and not os.getenv("NOEXIT") then manager.machine:exit() end
end)
