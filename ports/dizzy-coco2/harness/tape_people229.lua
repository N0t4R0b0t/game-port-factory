-- harness/tape_people229.lua -- T0229: Dylan (room 59, frame 34, X-ALL.TXT dylantalking 674 /
-- trancemess 691 / dylanrou 2427) and Doug (room 88, frame 36, dougtalking 796 / goonmysonmess 832 /
-- dougrou 2424) in the TAPE build, with REAL talk input (DOWN next to the person, try_pickup) and real
-- inventory drops.  The original's talkingtopeople: 1st talk = the person's stream (+ the leading `defw`
-- poke: Doug's is crowbarhere+room), every later talk = the person's routine (one box).
--   * boot: crowbar record in room 255 (control), talk flags 0
--   * Dylan 1st talk: 3 boxes in order; repeats: trancemess (box 1 of the single box)
--   * Doug: control before the talk (crowbar absent from the record and from the screen); 1st talk:
--     6 boxes in order, the crowbar record -> room 88 at its own x/y and it is DRAWN afterwards
--     (framebuffer differs in its box); pick it up for real; repeat talks: goonmysonmess only, no 2nd crowbar
--   * the crowbar dropped for real in room 55's well box opens the lid (cdt_crowbar path)
--   * game over -> new game: crowbar hidden again (255), talk flags 0, Dylan/Doug talk "first time" again
--   PEOPLE_DUMP=dir: framebuffer dumps (box1 of each person: dylanN.raw, dougN.raw; raw 6144 B, harness/pmode4_to_png.py)
--
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 900 \
--     -autoboot_script harness/tape_people229.lua
-- Prints "PEOPLE229 PASS|FAIL ..." lines and "PEOPLE229 SUMMARY pass=N fail=N".
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
for _,s in ipairs({"actor_init_tape","msg_active","msg_dozy_end","msg_dylantalking","msg_trance","msg_dougtalking","msg_goonmyson",
                   "tape_low4_slot_end","tt_dylan","tt_doug","DOUG_CROWBAR","inv","inv_cursor","inv_occupied",
                   "cur_buf","dizzy_x","dizzy_y","lives","killed","cur_room","show_inventory"}) do
  if not SYM[s] then print("PEOPLE229 FAIL symbol "..s.." missing from the map"); manager.machine:exit() end
end
local NACT=SYM.ACTOR_COUNT or 43
local NACT_T=SYM.ACTOR_COUNT_tape or 29
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
local function find_tape(room,rou,frame)
  for i=0,NACT_T-1 do local b=SYM.actor_init_tape+i*8
    if mem:read_u8(b)==room and (rou==nil or mem:read_u8(b+1)==rou) and (frame==nil or mem:read_u8(b+4)==frame) then return b,i end end
end

-- ---- coroutine scaffolding: script() runs one step per video frame ----
local f=0
local pass,fail=0,0
local function report(ok,what)
  if ok then pass=pass+1 else fail=fail+1 end
  print(string.format("PEOPLE229 %s %s", ok and "PASS" or "FAIL", what))
end
local function wait(n) for _=1,n do coroutine.yield() end end
-- wait until pred() or timeout frames; returns true when pred held
local function waitfor(pred,timeout)
  for _=1,timeout do if pred() then return true end coroutine.yield() end
  return pred()
end
local function warp(room,x,y)
  mem:write_u8(SYM.lives,2)
  mem:write_u8(SYM.respawn_room,room); mem:write_u8(SYM.respawn_x,x)
  mem:write_u8(SYM.respawn_y,y); mem:write_u8(SYM.killed,1)
  local n=0
  local ok=waitfor(function()
    n=n+1
    if n%14==0 then key("SPACE",(n//14)%2==0) end
    return r("cur_room")==room and r("dizzy_x")==x and r("killed")==0 and not in_audio() and not in_msgwait()
  end,900)
  key("SPACE",false)
  if not ok then return false end
  local floor_n=0
  return waitfor(function() floor_n = r("dizzy_floor")==1 and floor_n+1 or 0; return floor_n>=10 end,300)
end

local function trec(a) local t={} for j=0,7 do t[j]=mem:read_u8(a+j) end return t end
local function dump_fb()
  local base = mem:read_u8(SYM.cur_buf)==0 and 0x4000 or 0x6000
  local t={} for i=0,6143 do t[i]=mem:read_u8(base+i) end
  return t
end
local function save_dump(name,d)
  local dir=os.getenv("PEOPLE_DUMP"); if not dir then return end
  local fh=io.open(dir.."/"..name..".raw","wb")
  for i=0,6143 do fh:write(string.char(d[i])) end fh:close()
end
local function diff_box(a,b,c0,c1,r0,r1)
  local n=0
  for row=r0,r1 do for c=c0,c1 do if a[row*32+c]~=b[row*32+c] then n=n+1 end end end
  return n
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
-- Which message is up: msg_chatter's saved X (just past the showing box's terminator) is on the stack.
-- The streams: Dylan (msg_dylantalking, msg_trance], trance (msg_trance, tape_low4_slot_end],
-- Doug (msg_dougtalking, msg_goonmyson], goon (msg_goonmyson, msg_dozy_end].  Box k of a stream = the
-- number of 0 bytes between its label and X.
local STREAMS={
  {"dylan",SYM.msg_dylantalking,SYM.msg_trance},
  {"trance",SYM.msg_trance,SYM.tape_low4_slot_end},
  {"doug",SYM.msg_dougtalking,SYM.msg_goonmyson},
  {"goon",SYM.msg_goonmyson,SYM.msg_dozy_end},
}
local function which_msg()
  local s=cpu.state["S"].value
  for i=0,40 do
    local w=mem:read_u8(s+i)*256+mem:read_u8(s+i+1)
    for _,st in ipairs(STREAMS) do
      if w>st[2] and w<=st[3] then
        local n=0
        for a=st[2],w-1 do if mem:read_u8(a)==0 then n=n+1 end end
        return st[1]..n
      end
    end
  end
  return nil
end
-- one real talk: DOWN next to the person until a box is up
local function talk()
  local seen=nil
  local ok=waitfor(function()
    key("DOWN",true)
    if in_msgwait() and r("msg_active")==1 then seen=which_msg() return true end
    return false
  end,300)
  key("DOWN",false)
  return ok,seen
end
-- a whole conversation: box 1 is already up (talk() returned); dismiss each in turn, collect names
local function run_conversation(tag,dumpname)
  local ok,seen=true,nil
  local order={}
  local first=true
  return function(already_seen)
    seen=already_seen
    local k=0
    while seen and k<12 do
      k=k+1
      order[#order+1]=seen
      if k==1 and dumpname then wait(20); save_dump(dumpname,dump_fb()) end
      dismiss_msg()
      local ok2=waitfor(function() return in_msgwait() and r("msg_active")==1 end,60)
      seen=ok2 and which_msg() or nil
    end
    waitfor(function() return r("msg_active")==0 and not in_msgwait() end,200)
    wait(40)
    return order
  end
end
local function expect(order,prefix,n)
  local want={} for i=1,n do want[i]=prefix..i end
  return table.concat(order,",")==table.concat(want,","),table.concat(want,",")
end
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
local function find_tape(room,rou,frame)
  for i=0,NACT_T-1 do local b=SYM.actor_init_tape+i*8
    if (room==nil or mem:read_u8(b)==room) and (rou==nil or mem:read_u8(b+1)==rou) and mem:read_u8(b+4)==frame then return b,i end end
end
local function inv_has(v) for s=0,3 do if mem:read_u8(SYM.inv+s)==v then return true end end return false end

local function script()
  local live=0
  waitfor(function()
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    live=(r("cur_room")==36 and r("dizzy_y")~=0) and live+1 or 0
    return live>=60
  end,3000)
  key("SPACE",false)
  for s=0,3 do mem:write_u8(SYM.inv+s,0) end
  local CB=SYM.DOUG_CROWBAR
  local cbrec=trec(CB)
  report(cbrec[4]==4 and cbrec[1]==2 and find_tape(nil,2,4)==CB,string.format("DOUG_CROWBAR %04X is the crowbar record (frame %d routine %d)",CB,cbrec[4],cbrec[1]))
  report(cbrec[0]==255,string.format("boot: crowbar starts hidden, room %d (orig_room 255)",cbrec[0]))
  report(cbrec[2]==64 and cbrec[3]==80,string.format("crowbar record x,y = %d,%d (orig 48,80 -> px 64,80)",cbrec[2],cbrec[3]))
  report(r("tt_dylan")==0 and r("tt_doug")==0,"boot: talk flags 0")
  local dougb=find_tape(88,2,36)
  local dylanb=nil
  for i=0,(SYM.ACTOR_COUNT or 43)-1 do local b=SYM.actor_ram+i*8
    if mem:read_u8(b+4)==34 and mem:read_u8(b)==59 then dylanb=b end end
  report(dougb~=nil and dylanb~=nil,string.format("records: Doug (tape, frame 36, room 88) %s, Dylan (base, frame 34, room 59) %s",tostring(dougb),tostring(dylanb)))
  if not (dougb and dylanb) then return end
  local DYX=tonumber(os.getenv("DYLAN_X") or "152")
  local DYY=tonumber(os.getenv("DYLAN_Y") or "140")

  -- ================= Dylan =================
  if not warp(59,DYX,DYY) then report(false,"warp to room 59"); return end
  wait(20)
  print(string.format("PEOPLE229 INFO room 59: dizzy x=%d y=%d floor=%d",r("dizzy_x"),r("dizzy_y"),r("dizzy_floor")))
  do
    local ok,seen=talk()
    report(ok and seen=="dylan1","Dylan talk 1: box 1 of his stream is up (got "..tostring(seen)..")")
    if not ok then return end
    local conv=run_conversation("dylan","dylan1")
    local order=conv(seen)
    local good,want=expect(order,"dylan",3)
    report(good,string.format("Dylan talk 1: boxes in order = %s (want %s)",table.concat(order,","),want))
    report(r("tt_dylan")==1,"Dylan talk 1: flag set")
  end
  for n=2,3 do
    local ok,seen=talk()
    report(ok and seen=="trance1",string.format("Dylan talk %d: trancemess (got %s)",n,tostring(seen)))
    if n==2 then wait(20); save_dump("trance",dump_fb()) end
    dismiss_msg()
    local more=waitfor(function() return r("msg_active")==1 end,60)
    report(not more,string.format("Dylan talk %d: a single box, no second one",n))
    wait(30)
  end

  -- ================= Doug =================
  local DGX=tonumber(os.getenv("DOUG_X") or "40")
  local DGY=tonumber(os.getenv("DOUG_Y") or "96")
  if not warp(88,DGX,DGY) then report(false,"warp to room 88"); return end
  wait(20)
  local before=dump_fb()
  print(string.format("PEOPLE229 INFO room 88: dizzy x=%d y=%d floor=%d",r("dizzy_x"),r("dizzy_y"),r("dizzy_floor")))
  -- control: standing in the room does not materialise the crowbar; DOWN next to nobody is not a talk
  report(mem:read_u8(CB)==255,"control: crowbar still hidden after entering room 88 (record room 255)")
  do
    local ok,seen=talk()
    report(ok and seen=="doug1","Doug talk 1: box 1 of his stream is up (got "..tostring(seen)..")")
    if not ok then return end
    report(mem:read_u8(CB)==88,string.format("Doug talk 1: crowbarhere+room := roomno (record room %d) -- poked before the first box",mem:read_u8(CB)))
    local conv=run_conversation("doug","doug1")
    local order=conv(seen)
    local good,want=expect(order,"doug",6)
    report(good,string.format("Doug talk 1: boxes in order = %s (want %s)",table.concat(order,","),want))
    report(r("tt_doug")==1,"Doug talk 1: flag set")
    local cb=trec(CB)
    report(cb[0]==88 and cb[2]==64 and cb[3]==80,string.format("the crowbar is in room 88 at (%d,%d), where the original puts it (orig 48,80 -> 64,80)",cb[2],cb[3]))
    wait(40)
    local after=dump_fb()
    local d=diff_box(before,after,8,10,80,95)
    report(d>=8,string.format("the crowbar is drawn: %d framebuffer bytes differ in its box (cols 8..10, rows 80..95) vs before the talk",d))
    save_dump("crowbar_after",after)
  end
  -- pick it up for real (at the crowbar, x=64: Doug's right edge excluded, as tape_item_pickup.lua)
  if not warp(88,64,96) then report(false,"warp to the crowbar"); return end
  do
    local got=false
    local t1=f
    while f-t1<80 and not got do
      key("DOWN",f-t1>=5 and f-t1<40)
      coroutine.yield()
      if mem:read_u8(CB)==255 then got=true end
    end
    key("DOWN",false)
    waitfor(function() return in_inventory() end,120)
    if in_inventory() then key("SPACE",true); wait(10); key("SPACE",false); wait(30) end
    wait(30)
    local slot=100+select(2,find_tape(255,2,4))+1
    report(got and inv_has(slot),string.format("crowbar picked up for real (record room %d, inv has %d: %s)",mem:read_u8(CB),slot,tostring(inv_has(slot))))
    if not (got and inv_has(slot)) then return end
  end
  -- repeat talks: goonmysonmess, and no second crowbar
  if not warp(88,DGX,DGY) then report(false,"warp back to Doug"); return end
  for n=2,3 do
    local ok,seen=talk()
    report(ok and seen=="goon1",string.format("Doug talk %d: goonmysonmess (got %s)",n,tostring(seen)))
    if n==2 then wait(20); save_dump("goon",dump_fb()) end
    dismiss_msg()
    local more=waitfor(function() return r("msg_active")==1 end,60)
    report(not more,string.format("Doug talk %d: a single box, no second one",n))
    report(mem:read_u8(CB)==255,string.format("Doug talk %d: no second crowbar (record room %d, it is in the inventory)",n,mem:read_u8(CB)))
    wait(30)
  end

  -- ================= the well lid (existing cdt_crowbar path) =================
  do
    local lid=find_tape(nil,15,158) -- not in the tape table: the lid is in the base table
    local lidb=nil
    for i=0,(SYM.ACTOR_COUNT or 43)-1 do local b=SYM.actor_ram+i*8
      if mem:read_u8(b+4)==158 and mem:read_u8(b+1)==15 then lidb=b end end
    report(lidb~=nil and mem:read_u8(lidb)==55,"room 55: the well lid is in the world before the drop")
    if lidb then
      if not warp(55,64,100) then report(false,string.format("warp to room 55 (room=%d x=%d y=%d floor=%d killed=%d)",r("cur_room"),r("dizzy_x"),r("dizzy_y"),r("dizzy_floor"),r("killed"))); return end
      local slot=100+select(2,find_tape(255,2,4))+1
      local fired=false
      for try=1,6 do
        wait(7*(try-1))
        local ok=drop_slot0_once()
        if ok and waitfor(function() return in_msgwait() end,150) then fired=true break end
        if in_inventory() then key("SPACE",true); wait(10); key("SPACE",false); wait(30) end
        wait(30)
        if not inv_has(slot) then break end
      end
      report(fired and mem:read_u8(lidb)==255,string.format("the crowbar dropped for real in room 55's well box: the lid is gone (record room %d), box shown",mem:read_u8(lidb)))
      report(mem:read_u8(CB)==255 and not inv_has(slot),"the crowbar is consumed by the drop")
      dismiss_msg()
    end
  end

  -- ================= game over resets =================
  -- put the crowbar back in the world by hand so the reset has something to hide
  mem:write_u8(CB,88)
  mem:write_u8(SYM.lives,0); mem:write_u8(SYM.killed,1)
  local boxn=0
  local ok=waitfor(function()
    boxn=boxn+1
    key("SPACE",(boxn%26)<8)
    return r("cur_room")==36 and r("lives")==2 and r("dizzy_y")~=0 and boxn>200
  end,2400)
  key("SPACE",false)
  report(ok and mem:read_u8(CB)==255,string.format("game over -> new game: crowbar hidden again (room %d)",mem:read_u8(CB)))
  report(r("tt_dylan")==0 and r("tt_doug")==0,string.format("game over -> new game: talk flags reset (dylan %d doug %d)",r("tt_dylan"),r("tt_doug")))
  -- and they talk "for the first time" again
  if not warp(88,DGX,DGY) then report(false,"warp to Doug after reset"); return end
  mem:write_u8(CB,255)
  do
    local ok,seen=talk()
    report(ok and seen=="doug1","after the reset Doug starts his stream again (got "..tostring(seen)..")")
    report(mem:read_u8(CB)==88,"after the reset Doug's first talk materialises the crowbar again")
  end
  print(string.format("PEOPLE229 SUMMARY pass=%d fail=%d",pass,fail))
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
  if not ok then print("PEOPLE229 FAIL harness error: "..tostring(err)); manager.machine:exit() end
  if coroutine.status(co)=="dead" and not os.getenv("NOEXIT") then manager.machine:exit() end
end)

