-- harness/tape_items230.lua -- T0230: the whiskey (droppingwhiskey X:5858 + checkifdrunk X:2947),
-- the manure (pickupmanure X:2365) and the inventory names of the egg, potion, crowbar, window
-- frame and the empty bottle (X:1085-1115). Real inventory drops / DOWN presses / held keys;
-- memory is POKED only to set a start state (carried items, warps, re-centring Dizzy between
-- tumbles) and READ to judge.  Controls and a game-over reset check for each feature.
--
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map [DUMPDIR=/tmp/x] \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 1800 \
--     -autoboot_script harness/tape_items230.lua
-- Prints "ITEMS230 PASS|FAIL <what>" and "ITEMS230 SUMMARY pass=N fail=N".
local OT=dofile("harness/orig.lua")   -- the original's message text, looked up from the user's own X-ALL.TXT
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
  if not SYM[s] then print("ITEMS230 FAIL symbol "..s.." missing from the map"); manager.machine:exit() end
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
  print(string.format("ITEMS230 %s %s", ok and "PASS" or "FAIL", what))
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
    if in_inventory() and mem:read_u8(SYM.inv_occupied)>=1 and f%4==0 and EXIT_VISIBLE() then opened=true end   -- the stack scan alone can match a stale return address
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
    print(string.format("ITEMS230 INFO drop try %d: no reaction (%s) rec room=%d var1=%d inv0=%d cursor=%d occ=%d drunk=%d msg=%d",try,tostring(why),mem:read_u8(rec),mem:read_u8(rec+5),mem:read_u8(SYM.inv),r("inv_cursor"),r("inv_occupied"),r("drunk"),r("msg_active")))
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

-- like find_text but at any 4-px unit (the original's message x is in 4-px units): bit-exact compare
local function find_text_px(fb,str)
  for y=0,184 do for ux=0,63-2*#str do
    local p0=ux*4
    local ok=true
    for i=1,#str do
      local g=GLYPH[str:byte(i)]
      for rr=0,7 do
        local row=g[rr+1]; local base=(y+rr)*32
        for k=0,7 do
          local p=p0+8*(i-1)+k
          if ((fb[base+(p>>3)]>>(7-(p&7)))&1)~=((row>>(7-k))&1) then ok=false break end
        end
        if not ok then break end
      end
      if not ok then break end
    end
    if ok then return y,ux end
  end end
  return nil
end
function EXIT_VISIBLE()
  local a=dump_fb()
  local base=mem:read_u8(SYM.cur_buf)==0 and 0x6000 or 0x4000
  local o={} for i=0,6143 do o[i]=mem:read_u8(base+i) end
  return find_text(a,"EXIT")~=nil or find_text(o,"EXIT")~=nil
end
local function snap_both()
  local a=dump_fb()
  local base=mem:read_u8(SYM.cur_buf)==0 and 0x6000 or 0x4000
  local o={} for i=0,6143 do o[i]=mem:read_u8(base+i) end
  return a,o
end
local function box_up() return r("msg_active")==1 or in_msgwait() end
local function wait_box(maxf) return waitfor(function() return box_up() end,maxf) end

local function script()
  local live=0
  waitfor(function()
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    live=(r("cur_room")==36 and r("dizzy_y")~=0) and live+1 or 0
    return live>=60
  end,3000)
  key("SPACE",false)
  local whiskey=find_base(53,18)
  local manure=find_base(58,3)
  local bone=find_base(nil,2) and nil
  report(whiskey~=nil and manure~=nil,"records found: whiskey (53/18), manure (58/3)")
  if not (whiskey and manure) then return end
  report(SYM.tape_drop_hook and SYM.tape_drunk_tick and SYM.drunk,"symbols tape_drop_hook / tape_drunk_tick / drunk present")
  report(r("drunk")==0 and mem:read_u8(whiskey+5)==0 and mem:read_u8(manure+5)==0,"boot: drunk 0, whiskey var1 0, manure var1 0")
  local jug=find_base(nil,19)

  -- ================= 1. whiskey: controls =================
  if not warp(36,136,144) then report(false,"warp 36"); return end
  -- control: dropping a different item from the inventory (the jug) does nothing special
  report(carry_and_drop(jug,(jug-SYM.actor_ram)//8+1,true),"control: the jug dropped from the inventory (real drop)")
  report(r("drunk")==0 and mem:read_u8(jug+5)==0 and r("msg_active")==0,string.format("control: a non-whiskey drop leaves drunk at 0 (drunk=%d)",r("drunk")))
  -- control: auto-drop of the whiskey (bag full -> oldest falls out) does NOT start the effect
  do
    local loaf=find_base(nil,20); local rope=find_base(nil,14)
    mem:write_u8(jug,36)
    set_inv((loaf-SYM.actor_ram)//8+1,(rope-SYM.actor_ram)//8+1,(whiskey-SYM.actor_ram)//8+1)
    for _,b in ipairs({loaf,rope,whiskey}) do mem:write_u8(b,255) end
    local took=pickup(jug,36,{136,132,140,128,144},144)
    report(took and mem:read_u8(whiskey)==36,string.format("control: the 4th pickup auto-drops the whiskey (oldest) into room 36 (room %d)",mem:read_u8(whiskey)))
    report(r("drunk")==0 and mem:read_u8(whiskey+5)==0 and r("msg_active")==0,string.format("control: ... and that auto-drop does NOT start the drunk timer or flip the bottle (drunk=%d var1=%d)",r("drunk"),mem:read_u8(whiskey+5)))
    set_inv(); mem:write_u8(jug,36)
  end
  mem:write_u8(whiskey,255); mem:write_u8(jug,36)

  -- ================= 2. whiskey: the real drop =================
  if not warp(36,136,144) then report(false,"warp 36 b"); return end
  -- inventory name before the drop
  set_inv((whiskey-SYM.actor_ram)//8+1)
  local d=open_dump_close("inv_whiskey_full")
  report(d~=nil and find_text(d,"A:BOTTLE:OF:WHISKEY")~=nil,"inventory before the drop names it A BOTTLE OF WHISKEY")
  local saw=carry_and_drop(whiskey,(whiskey-SYM.actor_ram)//8+1,false)
  report(saw,"the whiskey dropped with a real inventory drop: a message box appeared")
  report(r("drunk")==255 and mem:read_u8(whiskey+5)==1,string.format("drunk := 255 and the bottle's var1 := 1 (drunk=%d var1=%d)",r("drunk"),mem:read_u8(whiskey+5)))
  wait(15)
  local fb=dump_fb()
  local base=mem:read_u8(SYM.cur_buf)==0 and 0x6000 or 0x4000
  local o={} for i=0,6143 do o[i]=mem:read_u8(base+i) end
  save_dump("whiskey_box",find_text_px(fb,OT("X-ALL:969")) and fb or o)
  local lines={OT("X-ALL:968"),OT("X-ALL:969"),OT("X-ALL:970"),OT("X-ALL:971"),OT("X-ALL:972")}
  local okl=true
  for _,l in ipairs(lines) do if not (find_text_px(fb,l) or find_text_px(o,l)) then okl=false; print("ITEMS230 INFO line not found: "..l) end end
  report(okl,"dropwhiskeymess: all 5 lines pixel-matched against the font (X-ALL.TXT lines 968-972)")
  local d0=r("drunk")
  dismiss_msg()
  -- the whiskey now lies at Dizzy's feet; keep him standing still: no keys.  The drunk timer was started
  report(r("drunk")<=d0 and r("drunk")>=d0-6 or r("drunk")>0,string.format("after the box closes the timer is counting (drunk=%d)",r("drunk")))

  -- ================= 3. the timer and the tumbles =================
  -- Sample every frame.  An event = the first frame drunk == V (V = 192,128,64,0, i.e. ticks 63,127,191,255).
  -- Dizzy is standing (no key): after each event he must start a tumble (jump_on=1), end up displaced, and
  -- nothing else may move him.  Re-centre him after each tumble (a poke of dizzy_x) so he cannot random-walk out.
  local EV={192,128,64,0}
  local results={}
  local edges=0
  local xhome=136
  local ctl_held,ctl_stuck=0,0
  local gate_hold=0
  local prev_jo=0
  local t0=f
  for i=1,4 do
    local cur=nil
    local released=(i~=2)
    if i==2 then mem:write_u8(SYM.dizzy_x,96); wait(12) end   -- room to walk right while the key is held
    local t_i=f
    while f-t_i<2500 do
      local dr,jo=r("drunk"),r("jump_on")
      if jo~=0 and prev_jo==0 then edges=edges+1; if cur then cur.edge_drunk=dr; cur.edge_f=f end end
      prev_jo=jo
      -- approach: x0 = Dizzy's x just before the event pass; for event 2 RIGHT is held (sequence 2) around it
      if i==2 and not released then
        if dr<=EV[2]+3 then key("RIGHT",true) end
        if dr<=EV[2]+1 then
          gate_hold=gate_hold+1
          if jo==0 and (dr==EV[2] or dr==EV[2]+1) then ctl_held=ctl_held+1 end
          if jo~=0 then ctl_stuck=ctl_stuck+1 end
          if gate_hold>=24 then released=true; key("RIGHT",false) end
        end
        if cur==nil and dr<=EV[2]+1 then cur={gated=true} end
        if cur then cur.x0=r("dizzy_x") end
      else
        key("LEFT",false); key("RIGHT",false)
        if cur==nil and dr<=EV[i]+1 and jo==0 then cur={x0=r("dizzy_x")} end
      end
      if cur and jo~=0 and released then
        -- the slide: until the lockout ends (jump_on back to 0) with a floor under him
        cur.jumped=true
        cur.anims=cur.anims or {}
        cur.anims[r("jump_anim")]=true
        cur.dir=r("dizzy_dir")
        if cur.f_start==nil then cur.f_start=f end
      end
      if cur and cur.jumped and jo==0 and r("dizzy_floor")==1 then
        cur.dx=r("dizzy_x")-cur.x0; cur.drunk_end=dr; cur.frames=f-cur.f_start
        break
      end
      coroutine.yield()
    end
    key("LEFT",false); key("RIGHT",false)
    results[#results+1]=cur or {}
    wait(20)
    mem:write_u8(SYM.dizzy_x,xhome)       -- re-centre between tumbles
    wait(10)
    prev_jo=0
  end
  key("RIGHT",false)
  report(#results==4 and results[4].jumped==true,string.format("four tumbles observed (%d), the last one too",#results))
  for i,res in ipairs(results) do
    local na=0 for _ in pairs(res.anims or {}) do na=na+1 end
    print(string.format("ITEMS230 INFO tumble %d: rising edge at drunk=%s (tick %s), dx=%s, dir=%s, anim steps seen=%d, lasted %s frames, gated=%s",i,tostring(res.edge_drunk),res.edge_drunk and tostring(255-res.edge_drunk) or "?",tostring(res.dx),tostring(res.dir),na,tostring(res.frames),tostring(res.gated)))
  end
  local ticks_ok=true
  for i,res in ipairs(results) do
    if not res.edge_drunk then ticks_ok=false
    elseif i~=2 and math.abs(res.edge_drunk-EV[i])>1 then ticks_ok=false
    elseif i==2 and math.abs(res.edge_drunk-EV[i])>1 then ticks_ok=false end
  end
  report(ticks_ok,"tumbles start at ticks 63 / 127 / 191 / 255 after the drop (drunk 192 / 128 / 64 / 0)")
  local moved=true
  for _,res in ipairs(results) do if not (res.jumped and res.dx and math.abs(res.dx)>=16) then moved=false end end
  report(moved,"every tumble slid Dizzy involuntarily >= 16 px with no key held (the original's 7-step lockout): dx = "..(function() local t={} for _,x in ipairs(results) do t[#t+1]=tostring(x.dx) end return table.concat(t,",") end)())
  local dirs_ok=true
  for i,res in ipairs(results) do
    if i~=2 then
      if res.dx and res.dir==1 and res.dx>0 then dirs_ok=false end
      if res.dx and res.dir==2 and res.dx<0 then dirs_ok=false end
    end
  end
  report(dirs_ok,"the slide direction follows the random bit (dizzy_dir 1 = left: dx<0, 2 = right: dx>0)")
  report(edges==4,string.format("exactly four tumbles in the whole run (jump_on rising edges = %d)",edges))
  report(ctl_held>=5 and ctl_stuck==0,string.format("control: with RIGHT held (sequence 2) the fall at drunk 128 was refused for %d samples (no tumble while the key was down), retried",ctl_held))
  report(results[2] and results[2].jumped and results[2].edge_drunk and results[2].edge_drunk<=EV[2],"... and it happened once the key was released (late tumble, drunk <= 128)")
  -- after tick 255 the effect is over
  wait(120)
  report(r("drunk")==0,"after the last tumble drunk stays 0")
  local jo=0 for _=1,300 do if r("jump_on")==1 then jo=jo+1 end coroutine.yield() end
  report(jo==0,"control: no further involuntary tumble after the timer ended (300 frames)")

  -- ================= 4. a later drop has no effect; names =================
  if not warp(36,136,144) then report(false,"warp 36 c"); return end
  set_inv((whiskey-SYM.actor_ram)//8+1)
  mem:write_u8(whiskey,255)
  local d2=open_dump_close("inv_whiskey_empty")
  report(d2~=nil and find_text(d2,"AN:EMPTY:BOTTLE")~=nil and not find_text(d2,"A:BOTTLE:OF:WHISKEY"),"after the first drop the inventory names it AN EMPTY BOTTLE")
  report(carry_and_drop(whiskey,(whiskey-SYM.actor_ram)//8+1,true),"the empty bottle dropped again (real drop)")
  wait(40)
  report(r("drunk")==0 and r("msg_active")==0 and not in_msgwait(),string.format("control: a LATER whiskey drop shows no message and starts no timer (drunk=%d)",r("drunk")))

  -- ================= 5. inventory names of the tape-table frames =================
  mem:write_u8(whiskey,53)      -- (the dropped bottle lies at x=136 in room 36: a DOWN there would pick it up)
  if not warp(94,200,168) then report(false,"warp 94 names"); return end
  local egg=find_tape(nil,10); local potion=find_tape(nil,15); local crow=find_tape(nil,4); local win=find_tape(nil,204)
  report(egg and potion and crow and win,"tape records found: egg 10, potion 15, crowbar 4, window frame 204")
  if egg and potion and crow and win then
    for _,rec in ipairs({egg,potion,crow,win}) do mem:write_u8(rec,255) end
    set_inv(slot_of_tape(egg),slot_of_tape(potion),slot_of_tape(crow))
    local d3=open_dump_close("inv_names_a")
    report(d3~=nil and find_text(d3,"A:HEAVY:DRAGON:EGG") and find_text(d3,"SOME:SLEEPING:POTION") and find_text(d3,"A:STRONG:CROWBAR") and true or false,"inventory: A HEAVY DRAGON EGG / SOME SLEEPING POTION / A STRONG CROWBAR")
    set_inv(slot_of_tape(win),(whiskey-SYM.actor_ram)//8+1)
    local d4=open_dump_close("inv_names_b")
    report(d4~=nil and find_text(d4,"A:WINDOW:FRAME") and find_text(d4,"AN:EMPTY:BOTTLE") and true or false,"inventory: A WINDOW FRAME / AN EMPTY BOTTLE")
    set_inv()
  end

  -- ================= 6. manure =================
  mem:write_u8(whiskey,53)
  local mx,my=mem:read_u8(manure+2),mem:read_u8(manure+3)
  set_inv()
  local sawbox,var1_after=false,0
  for _,sx in ipairs({mx-8,mx-4,mx,mx+4,mx-12}) do
    if not warp(58,sx,168) then report(false,"warp 58"); break end
    -- control: just standing next to it shows nothing
    wait(20)
    if r("msg_active")==1 then break end
    local t1=f
    while f-t1<100 do key("DOWN",f-t1>=5 and f-t1<40); coroutine.yield()
      if box_up() then sawbox=true break end end
    key("DOWN",false)
    if sawbox then break end
  end
  report(sawbox,"manure: DOWN beside it shows a message box")
  wait(15)
  local m1=dump_fb()
  local base2=mem:read_u8(SYM.cur_buf)==0 and 0x6000 or 0x4000
  local m2={} for i=0,6143 do m2[i]=mem:read_u8(base2+i) end
  save_dump("manure_box",find_text_px(m1,OT("X-ALL:873")) and m1 or m2)
  local okm=true
  for _,l in ipairs({OT("X-ALL:873"),OT("X-ALL:874"),OT("X-ALL:875")}) do
    if not (find_text_px(m1,l) or find_text_px(m2,l)) then okm=false; print("ITEMS230 INFO line not found: "..l) end end
  report(okm,"pickupmanuremess: all 3 lines pixel-matched against the font")
  report(mem:read_u8(manure)==58 and mem:read_u8(manure+5)==1 and count_inv()==0,string.format("the manure is NOT picked up (room %d), var1 := 1, inventory empty (%d)",mem:read_u8(manure),count_inv()))
  dismiss_msg()
  -- second DOWN with something carried: the inventory screen, no message, still not picked up
  set_inv((whiskey-SYM.actor_ram)//8+1); mem:write_u8(whiskey,255)
  local inv_seen,box2=false,false
  local t3=f
  while f-t3<120 do key("DOWN",f-t3>=5 and f-t3<40); coroutine.yield()
    if in_inventory() then inv_seen=true break end
    if box_up() then box2=true break end end
  key("DOWN",false)
  report(inv_seen and not box2,"second DOWN at the manure opens the inventory (tryputtingdown1), no message again")
  if inv_seen then wait(20); key("SPACE",true); wait(10); key("SPACE",false); wait(40) end
  report(mem:read_u8(manure)==58 and count_inv()==1,string.format("... and the manure still lies in room 58 (%d), nothing new carried (%d)",mem:read_u8(manure),count_inv()))
  set_inv()

  -- ================= 7. game over resets =================
  -- start a fresh effect so the reset has something to clear
  mem:write_u8(SYM.drunk,200)
  mem:write_u8(whiskey+5,1)
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
  report(r("drunk")==0,string.format("game over cleared the drunk timer (%d)",r("drunk")))
  report(mem:read_u8(whiskey+5)==0 and mem:read_u8(whiskey)==53 and mem:read_u8(manure+5)==0 and mem:read_u8(manure)==58,
    string.format("whiskey back in room 53 with var1 0 (%d,%d), manure var1 0 (%d)",mem:read_u8(whiskey),mem:read_u8(whiskey+5),mem:read_u8(manure+5)))
  -- the whiskey works again after the reset
  -- (room 94, x=200: after the reset the jug lies at x=136 in room 36 and a DOWN there would pick it up first)
  if not warp(94,200,168) then report(false,"warp 94 d"); return end
  set_inv(); mem:write_u8(whiskey,255)
  report(carry_and_drop(whiskey,(whiskey-SYM.actor_ram)//8+1,false) and r("drunk")==255,string.format("after the reset the first drop starts the effect again (drunk=%d)",r("drunk")))
  dismiss_msg()

  print(string.format("ITEMS230 SUMMARY pass=%d fail=%d",pass,fail))
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
  if not ok then print("ITEMS230 FAIL harness error: "..tostring(err)); manager.machine:exit() end
  if coroutine.status(co)=="dead" and not os.getenv("NOEXIT") then manager.machine:exit() end
end)
