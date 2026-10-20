-- harness/tape_items227.lua -- T0227: the rug + room 94's daggers and carpets, the bag, the
-- black hole, the whiskey, manure and the inventory names (X-ALL.TXT proxrug 3481, daggerrou 3395,
-- checkholdinghole 2520, droppingwhiskey 5858, checkifdrunk 2947, pickupmanure 2365).
-- Real inventory drops / DOWN pickups / LEFT-RIGHT walking; memory is POKED only to set a start state
-- and READ to judge.  Every feature has a CONTROL and a game-over reset check.
--
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map [DUMPDIR=/tmp/x] \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 900 \
--     -autoboot_script harness/tape_items227.lua
-- Prints "ITEMS227 PASS|FAIL <what>" and "ITEMS227 SUMMARY pass=N fail=N".
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
for _,s in ipairs({"cdt_rug","ud94_daggers","msg_userug","msg_daggers","kill_dizzy_msg",
                   "actor_ram","actor_init_tape","inv","inv_cursor","inv_occupied","cur_buf","msg_active","show_inventory","msg_wait_dismiss","fb_stablekeys","stalk_grown","play_tone","play_chirp","find_room_name"}) do
  if not SYM[s] then print("ITEMS227 FAIL symbol "..s.." missing from the map"); manager.machine:exit() end
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
  print(string.format("ITEMS227 %s %s", ok and "PASS" or "FAIL", what))
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
    print(string.format("ITEMS227 INFO drop try %d: no reaction (%s)",try,tostring(why)))
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

local function carpets_rooms() local a,b=find_tape(nil,210) return a end
local function find_all_tape(frame) local t={} for i=0,NACT_T-1 do local b=SYM.actor_init_tape+i*8
    if mem:read_u8(b+4)==frame then t[#t+1]=b end end return t end
local function slot_of_tape(rec) return 100+(rec-SYM.actor_init_tape)//8+1 end
-- poke Dizzy to (x,y feet), standing nowhere in particular: he falls
local function drop_at(x,y)
  mem:write_u8(SYM.dizzy_x,x); mem:write_u8(SYM.dizzy_y,y); mem:write_u8(SYM.dizzy_dy,0); mem:write_u8(SYM.dizzy_floor,0)
end
-- wait for the death box sequence to finish (killed counts down, box, respawn)
local function die_and_recover()
  local n,seen=0,false
  waitfor(function() n=n+1; key("SPACE",(n%26)<8)
    if r("msg_active")==1 then seen=true end
    return seen and r("killed")==0 and r("msg_active")==0 and not in_msgwait() and not in_audio() end,1500)
  key("SPACE",false); wait(60)
end


-- ---- glyph tables (target/font_data.asm: glyph index == ASCII, 8x8, 1 byte per row) ----
local GLYPH={}
for line in io.lines("target/font_data.asm") do
  local n,rest=line:match("^glyph_(%d+)%s+fcb%s+(.*)$")
  if n then local t={} for h in rest:gmatch("%$(%x%x)") do t[#t+1]=tonumber(h,16) end GLYPH[tonumber(n)]=t end
end
-- find text `str` (the original's ':'-for-space encoding) at a byte-aligned cell in a framebuffer dump
local function find_text(fb,str)
  for y=0,184 do for col=0,32-#str do
    local ok=true
    for i=1,#str do
      local g=GLYPH[str:byte(i)]
      for rr=0,7 do if fb[(y+rr)*32+col+i-1]~=g[rr+1] then ok=false break end end
      if not ok then break end
    end
    if ok then return y,col end
  end end
  return nil
end
local function slot_of_base(rec) return (rec-SYM.actor_ram)//8+1 end
-- open the inventory with a real DOWN (nothing pickupable nearby), dump it, close it with SPACE
-- (the cursor starts on EXIT, so nothing is dropped)
local function open_dump_close(name)
  -- press DOWN until the inventory box (it always lists EXIT) shows in either buffer
  local d
  local function snap()
    local a=dump_fb()
    local base=mem:read_u8(SYM.cur_buf)==0 and 0x6000 or 0x4000
    local o={} for i=0,6143 do o[i]=mem:read_u8(base+i) end
    if find_text(a,"EXIT") then return a end
    if find_text(o,"EXIT") then return o end
  end
  local n=0
  local ok=waitfor(function() n=n+1; key("DOWN",(n%40)<20); if n%5==0 then d=snap() end return d~=nil end,400)
  key("DOWN",false)
  if not ok then return nil end
  wait(20)
  d=snap() or d
  save_dump(name,d)
  key("SPACE",true); wait(10); key("SPACE",false); wait(40)
  return d
end
local function set_inv(a,b,c,d)
  for s=0,3 do mem:write_u8(SYM.inv+s,0) end
  local t={a,b,c,d}
  for s=1,4 do if t[s] then mem:write_u8(SYM.inv+s-1,t[s]) end end
end
local function count_inv() local n=0 for s=0,3 do if mem:read_u8(SYM.inv+s)~=0 then n=n+1 end end return n end

local function script()
  local live=0
  waitfor(function()
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    live=(r("cur_room")==36 and r("dizzy_y")~=0) and live+1 or 0
    return live>=60
  end,3000)
  key("SPACE",false)

  -- ================= boot state: rug / daggers / carpets =================
  local dag=find_all_tape(169)
  local car=find_all_tape(210)
  local rug,rugi=find_tape(40,12)
  report(#dag==2 and #car==2 and rug~=nil,string.format("tape table: %d daggers (169), %d carpets (210), rug (40/12)",#dag,#car))
  if not (#dag==2 and #car==2 and rug) then return end
  report(mem:read_u8(dag[1])==94 and mem:read_u8(dag[2])==94 and mem:read_u8(dag[1]+1)==13,"daggers: room 94, routine 13 (ROU_DAGGER)")
  report(mem:read_u8(car[1])==255 and mem:read_u8(car[2])==255,"carpets start in room 255 (not in the world)")
  local d1,d2=trec(dag[1]),trec(dag[2]); local c1,c2=trec(car[1]),trec(car[2])
  report(d1[2]==40 and d1[3]==152 and d2[2]==72 and d2[3]==152 and c1[2]==32 and c1[3]==152 and c2[2]==56 and c2[3]==152,
    string.format("positions: daggers (%d,%d) (%d,%d) = raw (42,152) (50,152) -> px; carpets (%d,%d) (%d,%d) = raw (40,152) (46,152) -> px",d1[2],d1[3],d2[2],d2[3],c1[2],c1[3],c2[2],c2[3]))
  report(c1[7]==2 and (d1[7]&0x40)~=0 and mem:read_u8(car[1]+1)==15,"carpets colour 2 (solid), static (routine 15); daggers dull (non-solid)")
  report(car[1]==rug+8 and car[2]==rug+16,"the carpets are the two records right after the rug (cdt_rug relies on it)")

  -- ================= 1. CONTROL: the dagger kills before the rug =================
  if not warp(94,12,168) then report(false,"warp 94"); return end
  drop_at(44,140)
  local killed_ctl=waitfor(function() return r("killed")~=0 end,200)
  report(killed_ctl,string.format("control: falling onto the floor beside the dagger (x=44) kills (killed=%d, y=%d)",r("killed"),r("dizzy_y")))
  die_and_recover()
  -- the same by a real walk from the left
  if not warp(94,12,168) then report(false,"warp 94 (walk)"); return end
  local t0=f
  while f-t0<200 and r("killed")==0 do key("RIGHT",true); coroutine.yield()
end
  key("RIGHT",false)
  report(r("killed")~=0,string.format("control: walking right along the floor into the dagger kills (x=%d)",r("dizzy_x")))
  die_and_recover()

  -- ================= 2. control: the rug dropped OUTSIDE its box does nothing =================
  if not warp(94,200,168) then report(false,"warp 94 (far)"); return end
  report(carry_and_drop(rug,slot_of_tape(rug),true),"rug dropped (real inventory drop) at x=200, outside the box (the room-94 coin is at x=112: DOWN there would take it)")
  report(mem:read_u8(car[1])==255 and mem:read_u8(car[2])==255 and mem:read_u8(rug)==94,string.format("control: carpets stay out (%d,%d), rug lies in room 94 (%d)",mem:read_u8(car[1]),mem:read_u8(car[2]),mem:read_u8(rug)))
  -- ================= 3. the rug in the box =================
  if not warp(94,12,168) then report(false,"warp 94 (box)"); return end
  report(carry_and_drop(rug,slot_of_tape(rug),false),"rug dropped (real inventory drop) at x=12, in proxrug's box")
  D.msg_seen=in_msgwait()
  report(D.msg_seen,"userugmess box shown")
  wait(20); save_dump("rug_message",dump_fb())
  dismiss_msg()
  report(mem:read_u8(rug)==255,string.format("rug consumed (room %d)",mem:read_u8(rug)))
  report(mem:read_u8(car[1])==94 and mem:read_u8(car[2])==94,string.format("both carpets now in room 94 (%d,%d)",mem:read_u8(car[1]),mem:read_u8(car[2])))
  wait(20)
  -- Dizzy must be clear of the carpet to see it drawn: he stands at x=12
  D.carpets=dump_fb(); save_dump("rug_carpets_drawn",D.carpets)

  -- ================= 4. safe to cross after the rug =================
  drop_at(44,140)
  wait(60)
  report(r("killed")==0 and r("dizzy_y")==152 and r("dizzy_floor")==1,string.format("after the rug: dropped onto the carpet at x=44 he stands ON it (y=%d, floor %d) and lives (killed=%d)",r("dizzy_y"),r("dizzy_floor"),r("killed")))
  save_dump("rug_standing_on_carpet",dump_fb())
  -- real walk along the top of the carpets, over dagger 1 (x 40..47) and onto dagger 2's spot (x 72..79);
  -- the ledge at x=96 (y 139..146) stops him at x=72, so the walk ends there
  local t0=f; local okk=true
  while f-t0<260 do key("RIGHT",true); coroutine.yield()
    if r("killed")~=0 then okk=false break end end
  key("RIGHT",false); wait(30)
  report(okk and r("killed")==0 and r("dizzy_x")>=72 and r("dizzy_y")==152,string.format("real walk RIGHT along the carpets crosses dagger 1's spot and reaches dagger 2's alive (x=%d, y=%d, killed=%d)",r("dizzy_x"),r("dizzy_y"),r("killed")))
  save_dump("rug_walked_over_daggers",dump_fb())
  -- and the daggers still kill where there is no carpet (between them is covered too; the far side of dagger 2: x just left of 40)
  if not warp(94,12,168) then report(false,"warp 94 (after)"); return end
  drop_at(8,140)
  -- T0228: room 94's pass rate dropped (Daisy is redrawn every pass, 13.2 -> 11.2 passes/s): wait for the
  -- landing on the floor (a settled stand: floor 1 at y=168), not a frame count
  waitfor(function() return r("dizzy_floor")==1 and r("dizzy_y")==168 end,400)
  report(r("killed")==0 and r("dizzy_y")==168,string.format("left of the carpets (x=8) he stands on the floor at y=168, safe (killed=%d, y=%d)",r("killed"),r("dizzy_y")))


  -- ================= 6. inventory names (per record, tape build) =================
  local rock=find_base(35,139)
  do
    local fbp=mem:read_u8(SYM.full_bucket)*256+mem:read_u8(SYM.full_bucket+1)
    local knock=find_tape(89,21)
    local mtb=find_base(83,5)
    report(fbp~=0 and knock~=nil and mtb~=nil and rock~=nil,"name test records found (full bucket, knocker, empty bucket, rock)")
    if not warp(94,200,168) then report(false,"warp 94 (names)"); return end
    -- the rug was consumed (255) earlier in this run; carry it for the display
    set_inv(slot_of_base(fbp),slot_of_tape(knock),slot_of_tape(rug))
    local d=open_dump_close("inv_names_new")
    report(d~=nil,"inventory opened by a real DOWN with the full bucket, the door knocker and the rug carried")
    if d then
      report(find_text(d,"A:BUCKET:OF:WATER")~=nil,"full bucket is named A BUCKET OF WATER (record-keyed, frame 5 is shared with the empty bucket)")
      report(find_text(d,"BRASS:DOOR:KNOCKER")~=nil,"door knocker is named BRASS DOOR KNOCKER (was AN OBJECT)")
      report(find_text(d,"AN:OLD:THICK:RUG")~=nil,"rug is named AN OLD THICK RUG (was AN OBJECT)")
      report(find_text(d,"AN:EMPTY:BUCKET")==nil and find_text(d,"AN:OBJECT")==nil,"control: neither AN EMPTY BUCKET nor AN OBJECT is shown for them")
      report(find_text(d,"EXIT")~=nil,"control: the text finder sees EXIT (the search itself works)")
    end
    set_inv(slot_of_base(mtb),slot_of_base(rock))
    local d2=open_dump_close("inv_names_old")
    report(d2~=nil and find_text(d2,"AN:EMPTY:BUCKET")~=nil and find_text(d2,"A:HEAVY:BOULDER")~=nil,"control: the EMPTY bucket is still AN EMPTY BUCKET and a rock still A HEAVY BOULDER (frame table untouched)")
    set_inv()
  end

  -- ================= 7. the bag (room 55): capacity 3 -> 4 =================
  local bagrec=find_base(55,1)
  local jug=find_base(36,19)
  local loaf=find_base(36,20)
  local bone=find_base(100,6)
  local whiskey=find_base(53,18)
  report(bagrec~=nil and jug~=nil and loaf~=nil and bone~=nil and rock~=nil and whiskey~=nil,"bag test records found (bag 55/1, jug, loaf, bone, rock, whiskey)")
  report(r("inv_cap")==3,string.format("control: usable inventory slots = %d before the bag",r("inv_cap")))
  do
    set_inv()
    local took=pickup(bagrec,55,{60,56,64,52,48,68},176)
    if not took then took=pickup(bagrec,55,{60,56,64,52,48,68},160) end
    report(took,"the bag picked up with a real DOWN in room 55 (record left the world)")
    report(r("inv_cap")==4,string.format("inv_cap = %d after the bag",r("inv_cap")))
    report(count_inv()==0,"the bag itself is not an inventory item (inventory still empty)")
    -- 3 carried (poked), then a REAL 4th pickup: with the bag nothing is auto-dropped
    set_inv(slot_of_base(rock),slot_of_base(bone),slot_of_base(whiskey))
    for _,b in ipairs({rock,bone,whiskey}) do mem:write_u8(b,255) end
    mem:write_u8(jug,36); mem:write_u8(loaf,36)
    local took4=pickup(jug,36,{136,132,140,128},144)
    report(took4 and count_inv()==4,string.format("with the bag the 4th pickup (jug) fills slot 4 (count %d, inv=%d,%d,%d,%d)",count_inv(),r("inv"),mem:read_u8(SYM.inv+1),mem:read_u8(SYM.inv+2),mem:read_u8(SYM.inv+3)))
    report(mem:read_u8(whiskey)==255 and mem:read_u8(bone)==255 and mem:read_u8(rock)==255,"nothing was auto-dropped by the 4th pickup (whiskey, bone, rock still carried)")
    local took5=pickup(loaf,36,{136,132,140,128,144},144)
    report(took5 and count_inv()==4,string.format("the 5th pickup (loaf) takes it and keeps 4 (count %d)",count_inv()))
    report(mem:read_u8(whiskey)==36,string.format("... and auto-drops the OLDEST (whiskey, slot 4) into room 36 (room %d)",mem:read_u8(whiskey)))
  end

  -- ================= 8. the black hole (built only when TAPE_HOLE=1) =================
  if SYM.tape_hole_check then
    local hole=find_base(72,11)
    report(hole~=nil,"hole record found (72/11)")
    set_inv(slot_of_base(bone),slot_of_base(whiskey))
    for _,b in ipairs({bone,whiskey}) do mem:write_u8(b,255) end
    -- real DOWN on the cloud at the hole (120,144); the inventory screen opens with the hole in slot 0
    local seen255,sawmsg=false,false
    for _,sx in ipairs({112,116,108,120}) do
      if not warp(72,sx,160) then report(false,"warp 72"); break end
      local t1=f
      while f-t1<120 do key("DOWN",f-t1>=5 and f-t1<40); coroutine.yield()
        if mem:read_u8(hole)==255 then seen255=true break end end
      key("DOWN",false)
      if seen255 then break end
    end
    report(seen255,"the hole picked up with a real DOWN in room 72 (record left the world, inventory screen open)")
    report(r("inv")==slot_of_base(hole),string.format("the hole is in slot 0 of the inventory (inv0=%d, want %d)",r("inv"),slot_of_base(hole)))
    wait(30)
    -- close the inventory (cursor on EXIT): checkholdinghole fires
    local t2=f
    while f-t2<300 do key("SPACE",((f-t2)%30)<10); coroutine.yield(); if r("msg_active")==1 then sawmsg=true break end end
    key("SPACE",false)
    report(sawmsg,"holdingholemess box shown once the inventory closed")
    wait(10); save_dump("hole_message",dump_fb())
    dismiss_msg()
    report(count_inv()==0,string.format("everything dropped: inventory empty (count %d)",count_inv()))
    report(mem:read_u8(bone)==72 and mem:read_u8(whiskey)==72 and mem:read_u8(hole)==72,string.format("bone, whiskey and the hole itself lie in room 72 (%d,%d,%d)",mem:read_u8(bone),mem:read_u8(whiskey),mem:read_u8(hole)))
  else
    print("ITEMS227 INFO black hole not built (TAPE_HOLE=0): section skipped")
  end

  -- ================= 9. game over resets =================
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
    report(mem:read_u8(car[1])==255 and mem:read_u8(car[2])==255,string.format("carpets back in room 255 (%d,%d)",mem:read_u8(car[1]),mem:read_u8(car[2])))
    report(mem:read_u8(rug)==40,string.format("rug back in room 40 (%d)",mem:read_u8(rug)))
    report(mem:read_u8(dag[1])==94 and mem:read_u8(dag[2])==94,"daggers still in room 94")
    report(r("inv_cap")==3 and mem:read_u8(bagrec)==55,string.format("bag back in room 55 (%d) and inv_cap back to 3 (%d)",mem:read_u8(bagrec),r("inv_cap")))
    if not warp(94,12,168) then report(false,"warp 94 after reset"); return end
    drop_at(44,140)
    report(waitfor(function() return r("killed")~=0 end,200),"after the reset the dagger kills again")
  end

  print(string.format("ITEMS227 SUMMARY pass=%d fail=%d",pass,fail))
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
  if not ok then print("ITEMS227 FAIL harness error: "..tostring(err)); manager.machine:exit() end
  if coroutine.status(co)=="dead" and not os.getenv("NOEXIT") then manager.machine:exit() end
end)
