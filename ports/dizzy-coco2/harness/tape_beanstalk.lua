-- harness/tape_beanstalk.lua -- T0223: the shopkeeper -> bean -> plant -> water
-- -> BEANSTALK chain in the TAPE build (X-ALL.TXT shopkeeperrou 3012,
-- proxshopkeeper 3028, shoptalk 577, proxbean 3003, proxfullbucket 2990,
-- checkbeanstalk 5478).  Everything below is driven by REAL inventory drops
-- (the inventory UI, as tape_log48.lua does), real DOWN pickups, and real
-- walking/jumping input; memory is only POKED to set up a start state
-- (warp = the respawn poke every harness uses, the cow/bucket into the
-- inventory when the test is about the DROP, not the carry) and READ to judge.
--
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--     [CMASK_STALK=target/cmask_stalk_expected.bin] [DUMPDIR=/tmp/x] \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 900 \
--     -autoboot_script harness/tape_beanstalk.lua
-- Prints "BEANSTALK PASS|FAIL <what>" lines and "BEANSTALK SUMMARY pass=N fail=N".
-- CMASK_STALK (optional but the verify command passes it): the offline mask for
-- room 58 + room 1 (python3 tools/derive_cmask.py --dump-stalk PATH).
-- DUMPDIR: framebuffer dumps (raw 6144 bytes; harness/pmode4_to_png.py).
-- EXPLORE=route: print the climb search instead of asserting (development aid).
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
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
for _,s in ipairs({"TB_SHOP1","TB_SHOP2","TB_BEAN","shop_count","shop_junk","stalk_grown","stalk_places",
                   "room_place_count","CUR_ROOM_CMASK","actor_ram","actor_init_tape","actor_init_tape_template",
                   "inv","inv_cursor","inv_occupied","cur_buf","room_load_seq","msg_active","tape_room_hook",
                   "cdt_shop","cdt_tape","update_shop","full_bucket","show_inventory","msg_wait_dismiss","fb_stablekeys"}) do
  if not SYM[s] then print("BEANSTALK FAIL symbol "..s.." missing from the map"); manager.machine:exit() end
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
  print(string.format("BEANSTALK %s %s", ok and "PASS" or "FAIL", what))
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
    print(string.format("BEANSTALK INFO drop try %d: no reaction (%s)",try,tostring(why)))
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
    -- T0236: the jump lockout outlives the landing (the port slides like the original), so a direction still held when the lockout
    -- ends walks him off the leaf: release the direction with the jump key (the bot's UL/UR macros), and wait for the lockout to end
    local hold = (jl==0) or t<delay+jl
    key("LEFT",dir<0 and hold); key("RIGHT",dir>0 and hold)
    key("UP",t>=delay and t<delay+jl)
    coroutine.yield()
    if r("cur_room")~=room0 or r("killed")~=0 then break end
    if r("dizzy_floor")==0 then seen_air=true; stable=0 else stable=stable+1 end
    if seen_air and stable>=8 and r("jump_on")==0 then break end
  end
  key("LEFT",false); key("RIGHT",false); key("UP",false)
  wait(6)
  return r("dizzy_x"),r("dizzy_y"),r("cur_room")
end
-- the climb: 3 jumps up the stalk's leaves, then out of the top into room 74
-- (the bot's hops, harness/playthrough_route.lua 'Up the beanstalk': walk R to x=136, UR, UL, UR, then R until the room changes)
local ROUTE={ {1,36,4}, {-1,0,4}, {1,0,4}, {1,0,4} }
local function climb(skip_last)
  local log={}
  for i,st in ipairs(ROUTE) do
    if skip_last and i==#ROUTE then break end   -- T0236: the control skips the exit hop (without the stalk it would walk off into room 59 and the warp back would stall)
    local x,y,room=step(st[1],st[2],st[3],st[4] or 260)
    log[#log+1]=string.format("(%d,%d)r%d",x,y,room)
    if room~=58 then break end
  end
  return table.concat(log," > "),r("cur_room")
end

local D={}
local function script()
  -- ---- boot ----
  local live=0
  waitfor(function()
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    live=(r("cur_room")==36 and r("dizzy_y")~=0) and live+1 or 0
    return live>=60
  end,3000)
  key("SPACE",false)

  -- ---- boot state: the table rows, nothing in the world ----
  local s1,s2,bn=SYM.TB_SHOP1,SYM.TB_SHOP2,SYM.TB_BEAN
  local a1,a2,ab=trec(s1),trec(s2),trec(bn)
  report(a1[4]==105 and a2[4]==105 and ab[4]==2 and a1[1]==2 and a2[1]==15 and ab[1]==2,
    string.format("table rows 1,2,3 = shopkeeper (frame 105, pickupable), mirrored half (105, routine 15), bean (frame 2): frames %d/%d/%d routines %d/%d/%d",
      a1[4],a2[4],ab[4],a1[1],a2[1],ab[1]))
  report(a1[0]==255 and a2[0]==255 and ab[0]==255,"shopkeeper x2 and bean start NOT in the world (room 255)")
  report(a2[7]>=128 and a1[7]<128,string.format("second half has colour bit 7 (mirror): colours %d / %d",a1[7],a2[7]))
  report(ab[2]==120 and ab[3]==144,string.format("bean starts at orig (62,144) raw = px (120,144): (%d,%d)",ab[2],ab[3]))
  report(r("shop_count")==255 and r("stalk_grown")==0 and r("shop_junk")==0,
    string.format("shop_count=%d stalk_grown=%d shop_junk=%d at boot",r("shop_count"),r("stalk_grown"),r("shop_junk")))
  local cow,cowi=find_base(58,7)
  -- T0226: the FULL bucket starts in room 255 (tape build, as in the original); full_bucket
  -- (tape_item_code.asm) points at its base record. The EMPTY one (83, frame 5) must be filled
  -- at the well in room 60 (proxmtbucket) -- the knocker -> door -> 83 -> bucket -> 60 chain.
  local bucket=mem:read_u8(SYM.full_bucket)*256+mem:read_u8(SYM.full_bucket+1)
  local bucketi=(bucket-SYM.actor_ram)//8
  local mtb,mtbi=find_base(83,5)
  local knock,knocki
  for i=0,NACT_T-1 do local b=SYM.actor_init_tape+i*8
    if mem:read_u8(b+4)==21 and mem:read_u8(b)==89 then knock,knocki=b,i end end
  local door=find_base(84,177)
  if not cow or not mtb or not knock or not door or bucket<SYM.actor_ram or bucket>=SYM.actor_ram+NACT*8 then
    report(false,"cow (58/7), empty bucket (83/5), knocker (tape 89/21), door (84/177) or the full_bucket pointer missing"); return end
  report(mem:read_u8(bucket)==255 and mem:read_u8(bucket+4)==5,"the FULL bucket starts in room 255 (no longer pre-placed in room 60)")
  report(true,string.format("cow at base slot %d (room 58), empty bucket slot %d (room 83), full bucket slot %d (room 255)",cowi,mtbi,bucketi))
  -- an item that is "junk" for the shopkeeper: the base-table apple
  local junk,junki=find_base(36,17)

  -- ---- the shopkeeper box in room 22 BEFORE he appears ----
  do
    if not warp(22,140,100) then report(false,"warp to room 22"); return end
    wait(10)
    report(r("cur_room")==22 and mem:read_u8(s1)==255,"in room 22, shopkeeper not there yet")
    -- cow dropped in his box before he has appeared: nothing happens
    local ok=carry_and_drop(cow,cowi+1,true)
    report(ok and mem:read_u8(bn)==255 and r("msg_active")==0,"control: cow dropped in the box BEFORE he appears -> no trade, no bean")
    mem:write_u8(cow,255)
  end
  -- ... he appears after shopkeepercount (255) passes in room 22
  local before_count=r("shop_count")
  local t0=f
  local appeared=waitfor(function() return mem:read_u8(s1)==22 end,3200)
  report(appeared,string.format("shopkeeper appears in room 22 (both records) after the delay: count %d -> %d, %d video frames",before_count,r("shop_count"),f-t0))
  report(mem:read_u8(s1)==22 and mem:read_u8(s2)==22 and r("shop_count")==0,"both shopkeeper records are in room 22 and the countdown stopped at 0")
  report(waitfor(function() return in_msgwait() end,200),"shopkeeperappearsmess is up")
  dismiss_msg()
  wait(40)
  D.shop=dump_fb()
  save_dump("room22_shopkeeper",D.shop)
  -- box = (136,160,32,16): the shopkeeper sits at x 144..176, y 136..175
  local ink=0
  for row=136,174 do for c=18,21 do if D.shop[row*32+c]~=0 then ink=ink+1 end end end
  report(ink>20,string.format("the shopkeeper is DRAWN: %d inked bytes in his 32x39 box",ink))

  -- ---- DOWN next to him opens the inventory (X-ALL pickupablerou `cp 105 / jp z,inventoryrou`); he is not picked up ----
  do
    local jb=junk or find_base(nil,19)
    mem:write_u8(jb,255)
    for s=0,3 do mem:write_u8(SYM.inv+s,0) end
    mem:write_u8(SYM.inv,junki+1)
    local opened=false
    local t1=f
    while f-t1<120 and not opened do
      key("DOWN",f-t1>=5 and f-t1<60)
      coroutine.yield()
      if in_inventory() then opened=true end
    end
    key("DOWN",false)
    wait(20)
    if in_inventory() then key("SPACE",true); wait(10); key("SPACE",false); wait(30) end
    wait(30)
    report(opened and mem:read_u8(s1)==22 and mem:read_u8(s2)==22 and mem:read_u8(SYM.inv)==junki+1,
      string.format("DOWN next to the shopkeeper opens the inventory and does NOT pick him up (inventory opened=%s, records still room %d/%d, inv0=%d)",tostring(opened),mem:read_u8(s1),mem:read_u8(s2),mem:read_u8(SYM.inv)))
  end

  -- ---- junk: anything but the cow gets the grumble; every 4th is the "stop giving us all that trash" box ----
  do
    local jb=junk or find_base(nil,19)
    local counts,boxes_ok={},true
    for k=1,4 do
      local ok=carry_and_drop(jb,junki+1,false)
      counts[#counts+1]=r("shop_junk")
      if not (ok and r("msg_active")==1) then boxes_ok=false end
      dismiss_msg()
    end
    report(boxes_ok and counts[1]==1 and counts[2]==2 and counts[3]==3 and counts[4]==0,
      string.format("junk (apple) x4 in his box: a message each time, counter 1,2,3,0 (stopgivingjunkmess on the 4th): %d,%d,%d,%d",counts[1],counts[2],counts[3],counts[4]))
    report(mem:read_u8(bn)==255,"junk trade gives no bean")
    mem:write_u8(jb,255)
  end
  -- outside the box: no reaction. Warp left of him, drop the cow, nothing.
  do
    if not warp(22,40,100) then report(false,"warp to room 22 (left)"); return end
    local jc=r("shop_junk")
    local ok=carry_and_drop(cow,cowi+1,true)
    report(ok and mem:read_u8(bn)==255 and r("shop_junk")==jc and r("msg_active")==0,"control: cow dropped OUTSIDE the box (x=40) -> no trade, no junk reply")
    mem:write_u8(cow,255)
  end

  -- ---- the cow trade ----
  if not warp(22,140,100) then report(false,"warp to room 22 (box)"); return end
  wait(10)
  local ok=carry_and_drop(cow,cowi+1,false)
  report(ok,"cow dropped for real in the shopkeeper's box -> shoptalk starts")
  local boxes=dismiss_all(12)
  report(boxes>=8,string.format("the whole bargaining conversation is shown (%d boxes seen)",boxes))
  report(mem:read_u8(cow)==255,"the cow is consumed (room 255)")
  local bb=trec(bn)
  report(bb[0]==22 and bb[2]==120 and bb[3]==144,string.format("the bean appears in room 22 at (%d,%d) (record: room %d)",bb[2],bb[3],bb[0]))
  wait(30)
  D.bean=dump_fb()
  save_dump("room22_bean",D.bean)
  report(diff_bytes(D.shop,D.bean,14,17,144,159)>0,"the bean is drawn on screen after the trade")
  -- junk counter wrap: 4th junk -> stopgivingjunkmess is separate; counter state
  -- is read, not re-driven here (covered by the 1st junk above).

  -- ---- pick the bean up for real ----
  do
    for s=0,3 do mem:write_u8(SYM.inv+s,0) end
    -- stand left of the bean on the floor and press DOWN
    local got=false
    for _,sx in ipairs({112,104,120}) do
      if not warp(22,sx,100) then break end
      local t1=f
      while f-t1<80 and not got do
        key("DOWN",f-t1>=5 and f-t1<40)
        coroutine.yield()
        if mem:read_u8(bn)==255 then got=true end
      end
      key("DOWN",false)
      if got then break end
    end
    -- the inventory screen opens on a pickup: leave it (cursor defaults to EXIT)
    waitfor(function() return in_inventory() end,120)
    if in_inventory() then key("SPACE",true); wait(10); key("SPACE",false); wait(30) end
    wait(40)
    local has=false
    for s=0,3 do if mem:read_u8(SYM.inv+s)==100+3+1 then has=true end end
    report(got and has,string.format("the bean is picked up for real (record room %d, inv has slot %d: %s)",mem:read_u8(bn),100+3+1,tostring(has)))
    if not has then mem:write_u8(bn,255); mem:write_u8(SYM.inv,100+3+1) end
  end

  -- ---- room 58: plant, then water ----
  if not warp(58,140,100) then report(false,"warp to room 58"); return end
  wait(10)
  D.r58_before=dump_fb()
  save_dump("room58_before",D.r58_before)
  local cm0={} for i=0,1535 do cm0[i]=mem:read_u8(SYM.CUR_ROOM_CMASK+i) end
  report(r("room_place_count")==44,string.format("room 58 has 44 placements before the stalk (%d)",r("room_place_count")))
  -- CONTROL for the climb: the same input script with NO stalk (room 58 as shipped
  -- before the water) must NOT end in room 74.
  do
    if not warp(58,100,100) then report(false,"warp for the climb control"); return end
    local path,room=climb(true)
    report(room~=74,string.format("control: the same climb input WITHOUT the stalk does not reach room 74 (ends in room %d: %s)",room,path))
    if not warp(58,140,100) then report(false,"warp back after the control"); return end
  end
  -- plant
  do
    local ok=carry_and_drop(bn,100+3+1,false)
    report(ok and r("msg_active")==1,"bean dropped for real in room 58's box -> plantbeanmess (unable to grow)")
    dismiss_msg()
    report(mem:read_u8(bn)==255 and r("stalk_grown")==0,"the bean is consumed, but nothing grows without water")
    report(r("room_place_count")==44,"room 58 unchanged after planting")
  end
  D.r58_planted=dump_fb()
  save_dump("room58_planted",D.r58_planted)
  -- Dizzy's own idle animation (blink/look, cols 16..21 around x=140) moves between the two
  -- dumps whatever the timing; the bean's absence is judged everywhere else
  local dpl=diff_bytes(D.r58_before,D.r58_planted,0,31,66,149)+diff_bytes(D.r58_before,D.r58_planted,0,15,150,191)
            +diff_bytes(D.r58_before,D.r58_planted,22,31,150,191)
  report(dpl==0,string.format("planting changes nothing on screen (bean consumed, no sprite; Dizzy's own box excluded): %d bytes differ",dpl))

  -- T0226: the bucket goes through the original's chain: the knocker dropped in room 84's door
  -- box opens the door, the EMPTY bucket is picked up in room 83, dropped in room 60's well box
  -- (-> the full bucket appears there), the full one is picked up for real, then it waters.
  do
    local function settle84()
      wait(10)
      if r("msg_active")==1 or in_msgwait() then dismiss_msg() end
    end
    local fired=false
    for _,sx in ipairs({20,22,24,26,28}) do
      if not warp(84,sx,176) then break end
      settle84()
      if carry_and_drop(knock,100+knocki+1,false) then fired=true; break end
    end
    dismiss_msg()
    report(fired and mem:read_u8(door)==255,string.format("chain 1/4: knocker dropped for real in room 84's box -> the door opens (door record room %d)",mem:read_u8(door)))
    for s=0,3 do mem:write_u8(SYM.inv+s,0) end
    local bx=mem:read_u8(mtb+2)
    local got=false
    for _,sx in ipairs({bx-8,bx-16,bx+8,bx-24}) do
      if not warp(83,sx,100) then break end
      local t1=f
      while f-t1<80 and not got do
        key("DOWN",f-t1>=5 and f-t1<40); coroutine.yield()
        if mem:read_u8(mtb)==255 then got=true end
      end
      key("DOWN",false)
      if got then break end
    end
    waitfor(function() return in_inventory() end,120)
    if in_inventory() then key("SPACE",true); wait(10); key("SPACE",false); wait(30) end
    wait(40)
    local has=false
    for s=0,3 do if mem:read_u8(SYM.inv+s)==mtbi+1 then has=true end end
    report(got and has,string.format("chain 2/4: the EMPTY bucket is picked up for real in room 83 (record room %d, in inventory: %s)",mem:read_u8(mtb),tostring(has)))
    if not has then mem:write_u8(mtb,255); mem:write_u8(SYM.inv,mtbi+1) end
    local filled=false
    for _,sx in ipairs({56,60,52,64,48}) do
      if not warp(60,sx,100) then break end
      wait(10)
      if carry_and_drop(mtb,mtbi+1,false) then filled=true; break end
    end
    dismiss_msg()
    local fr=trec(bucket)
    report(filled and fr[0]==60 and mem:read_u8(mtb)==255,string.format("chain 3/4: the empty bucket dropped in room 60's well box -> the FULL bucket appears in room %d at (%d,%d)",fr[0],fr[2],fr[3]))
    for s=0,3 do mem:write_u8(SYM.inv+s,0) end
    local bx,by=mem:read_u8(bucket+2),mem:read_u8(bucket+3)
    got=false
    for _,sx in ipairs({bx-8,bx-16,bx+8}) do
      if not warp(60,sx,100) then break end
      local t1=f
      while f-t1<80 and not got do
        key("DOWN",f-t1>=5 and f-t1<40)
        coroutine.yield()
        if mem:read_u8(bucket)==255 then got=true end
      end
      key("DOWN",false)
      if got then break end
    end
    waitfor(function() return in_inventory() end,120)
    if in_inventory() then key("SPACE",true); wait(10); key("SPACE",false); wait(30) end
    wait(40)
    has=false
    for s=0,3 do if mem:read_u8(SYM.inv+s)==bucketi+1 then has=true end end
    report(got and has,string.format("chain 4/4: the full bucket is picked up from room 60 (record room %d, in inventory: %s)",mem:read_u8(bucket),tostring(has)))
    if not has then mem:write_u8(bucket,255); mem:write_u8(SYM.inv,bucketi+1) end
  end
  if not warp(58,140,100) then report(false,"warp back to room 58"); return end
  wait(10)
  local dx0=r("dizzy_x")
  local ok=carry_and_drop(bucket,bucketi+1,false)
  report(ok and r("msg_active")==1,"full bucket dropped for real in the same box -> throwwateronbeanmess")
  dismiss_msg()
  wait(60)
  report(r("stalk_grown")==1 and mem:read_u8(bucket)==255,"stalk_grown=1, bucket consumed")
  report(r("dizzy_x")==dx0-40,string.format("Dizzy is shoved left by 40 px (x %d -> %d)",dx0,r("dizzy_x")))
  report(r("room_place_count")==56,string.format("room 58 now has 44+12 placements (%d)",r("room_place_count")))
  D.r58_after=dump_fb()
  save_dump("room58_after",D.r58_after)
  -- the stalk is DRAWN: the trunk column (x 160..183 = byte cols 20..22) gets ink
  local changed=diff_bytes(D.r58_before,D.r58_after,17,25,66,175)
  report(changed>150,string.format("the stalk is drawn: %d bytes differ in its box (cols 17..25, rows 66..175)",changed))
  -- the collision mask changed in the stalk's columns and matches the offline derivation
  local cm1={} for i=0,1535 do cm1[i]=mem:read_u8(SYM.CUR_ROOM_CMASK+i) end
  local nd=0 for i=0,1535 do if cm0[i]~=cm1[i] then nd=nd+1 end end
  report(nd>20,string.format("room 58's collision mask gained the stalk (%d mask bytes differ)",nd))
  local exp=os.getenv("CMASK_STALK")
  if exp then
    local fh=io.open(exp,"rb")
    if fh then
      local e=fh:read("*all"); fh:close()
      local bad=0
      for i=0,1535 do if cm1[i]~=e:byte(i+1) then bad=bad+1 end end
      report(#e>=1536 and bad==0,string.format("room 58 + stalk mask == offline derivation (derive_cmask --dump-stalk): %d bytes differ",bad))
    else report(false,"CMASK_STALK file unreadable") end
  end
  -- a second load of room 58 (leave + re-enter) keeps the stalk and does not stack it
  do
    if not warp(60,100,100) then report(false,"warp 60"); return end
    if not warp(58,140,100) then report(false,"warp 58 again"); return end
    report(r("room_place_count")==56,string.format("re-entering room 58 keeps exactly 56 placements (%d)",r("room_place_count")))
    local cm2={} local nb=0
    for i=0,1535 do if mem:read_u8(SYM.CUR_ROOM_CMASK+i)~=cm1[i] then nb=nb+1 end end
    report(nb==0,"re-entering room 58: identical mask")
  end

  -- ---- climb: from where the shove left him (x=100, the ground), real input ----
  do
    if not warp(58,100,100) then report(false,"warp to the foot of the stalk"); return end
    local path,room=climb()
    report(room==74,string.format("WITH the stalk the same input climbs 58 -> 74 (cur_room=%d: %s)",room,path))
    wait(60)
    D.top=dump_fb(); save_dump("room74_arrival",D.top)
    report(r("killed")==0,"Dizzy is alive in room 74")
  end

  -- ---- game over resets everything ----
  do
    -- the state to clear: shopkeeper there, cow/bucket/bean consumed or moved,
    -- stalk grown, junk counter bumped
    report(r("stalk_grown")==1 and mem:read_u8(s1)==22 and r("shop_junk")==0,"before game over: stalk grown, shopkeeper present")
    mem:write_u8(SYM.shop_junk,2)    -- a non-zero counter for the reset check below
    mem:write_u8(SYM.lives,0); mem:write_u8(SYM.killed,1)
    local boxn=0
    local ok=waitfor(function()
      boxn=boxn+1
      key("SPACE",(boxn%26)<8)
      return r("cur_room")==36 and r("lives")==2 and r("dizzy_y")~=0 and boxn>200
    end,2400)
    key("SPACE",false)
    report(ok,string.format("game over -> new game (room %d, lives %d)",r("cur_room"),r("lives")))
    wait(30)    -- the periodic callback can land mid-new_game: let actors_init + reset_tape_actors finish
    local a1,a2,ab=trec(s1),trec(s2),trec(bn)
    report(a1[0]==255 and a2[0]==255 and ab[0]==255,string.format("shopkeeper x2 and bean back to room 255 (%d,%d,%d)",a1[0],a2[0],ab[0]))
    report(ab[2]==120 and ab[3]==144 and ab[4]==2,string.format("bean record restored: (%d,%d) frame %d",ab[2],ab[3],ab[4]))
    report(r("shop_count")==255 and r("shop_junk")==0 and r("stalk_grown")==0,string.format("shop_count=%d shop_junk=%d stalk_grown=%d (want 255/0/0)",r("shop_count"),r("shop_junk"),r("stalk_grown")))
    report(mem:read_u8(cow)==58 and mem:read_u8(bucket)==255 and mem:read_u8(mtb)==83 and mem:read_u8(door)==84,string.format("cow back in room 58 (%d), FULL bucket back in room 255 (%d), empty bucket back in room 83 (%d), door back in room 84 (%d)",mem:read_u8(cow),mem:read_u8(bucket),mem:read_u8(mtb),mem:read_u8(door)))
    if not warp(58,140,100) then report(false,"warp to room 58 after the reset"); return end
    wait(10)
    D.r58_reset=dump_fb()
    report(r("room_place_count")==44,string.format("room 58 is back to 44 placements (%d)",r("room_place_count")))
    local d=diff_bytes(D.r58_before,D.r58_reset,17,25,66,175)
    report(d==0,string.format("room 58 has no stalk after the reset (%d bytes differ from the pre-stalk screen in the stalk box)",d))
    -- the shopkeeper is gone and the countdown restarts when entering room 22
    if not warp(22,140,100) then report(false,"warp to room 22 after the reset"); return end
    wait(120)
    report(mem:read_u8(s1)==255 and r("shop_count")<255 and r("shop_count")>200,string.format("room 22 after the reset: no shopkeeper yet, countdown restarted (%d)",r("shop_count")))
  end

  -- ---- TAPE_LOW_REGION3 survived the whole run (nothing writes it but the 3 state bytes) ----
  do
    local fh=io.open(os.getenv("DIZZY_BIN"),"rb"); local d=fh:read("*all"); fh:close()
    local lo,hi=SYM.tape_low3_slot_start,SYM.tape_low3_slot_end
    local pos,bad,found=1,0,false
    while pos<=#d and d:byte(pos)==0 do
      local len=d:byte(pos+1)*256+d:byte(pos+2); local addr=d:byte(pos+3)*256+d:byte(pos+4)
      if addr<=lo and addr+len>=hi then
        found=true
        -- declared state living in the slot: full_bucket's pointer (T0226) and the joystick vars (T0240)
        local state={}
        for _,n in ipairs{"joy_f","joy_acc","joy_armed"} do if SYM[n] then state[SYM[n]]=true end end
        for a=lo+3,hi-1 do
          if a~=SYM.full_bucket and a~=SYM.full_bucket+1 and not state[a] and mem:read_u8(a)~=d:byte(pos+5+(a-addr)) then bad=bad+1 end end
      end
      pos=pos+5+len
    end
    report(found and bad==0,string.format("TAPE_LOW_REGION3 ($%04X-$%04X) content unchanged after the whole run except its 3 state bytes + full_bucket's pointer (T0226) + the joystick vars (T0240) (%d bytes differ)",lo,hi,bad))
    -- and its free tail (never loaded: bytes are whatever RAM held) is not touched by the
    -- game: the real-boot proof is harness/tape_boot_regions.py's pattern test
  end

  print(string.format("BEANSTALK SUMMARY pass=%d fail=%d",pass,fail))
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
  if not ok then print("BEANSTALK FAIL harness error: "..tostring(err)); manager.machine:exit() end
  if coroutine.status(co)=="dead" and not os.getenv("NOEXIT") then manager.machine:exit() end
end)
