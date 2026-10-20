-- harness/tape_log48.lua -- T0216: room 48's river in the TAPE build.
-- X-ALL.TXT waterheight (2089) / addtowater (2097) / proxrock (2816) /
-- logrou (2831). Proves the GAMEPLAY outcome, not just the variables:
--
--   * the floating log bobs at 162-waterheight+b (b = 1,2,3,2)
--   * the water is 3 tiles drawn at y = 168-waterheight, and the drown
--     box follows (room_water_ptr -> tide_list)
--   * a REAL carry-and-drop of each of the three rocks (inventory UI, as
--     key3lift88.lua does for keys) from Dizzy standing in the drop box
--     shows rockinwatermess, raises waterheight 6/12/18, moves that rock
--     to (176-4*wh, 176) in room 48
--   * after 0,1,2,3 rocks, Dizzy stands on the log and tries to jump up
--     LEFT onto the key-4 ledge (left cliff, top y=112).  RESULTS are
--     printed for every count; PASS requires 0 rocks = cannot reach and
--     3 rocks = reaches it (the intermediate counts are reported, INFO)
--   * the pixels: water band top row moves up by exactly 18, nothing
--     outside the river columns changes, no trail above the log
--   * game over resets waterheight to 0 and restores the rocks
--
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 400 \
--     -autoboot_script harness/tape_log48.lua
-- Prints "LOG48 PASS|FAIL ..." lines and "LOG48 SUMMARY pass=N fail=N".
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
for _,s in ipairs({"waterheight","tide_list","update_log48","msg_active","room_water_count","room_water_ptr",
                   "actor_ram","actor_init_tape","inv","inv_cursor","inv_occupied","cur_buf"}) do
  if not SYM[s] then print("LOG48 FAIL symbol "..s.." missing from the map"); manager.machine:exit() end
end
local NACT=SYM.ACTOR_COUNT or 43
local NACT_T=SYM.ACTOR_COUNT_tape or 20
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
  print(string.format("LOG48 %s %s", ok and "PASS" or "FAIL", what))
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
local function logy() local b=find_tape(48,6) return mem:read_u8(b+3), mem:read_u8(b+5) end
local function dump_fb()
  local base = mem:read_u8(SYM.cur_buf)==0 and 0x4000 or 0x6000
  local t={} for i=0,6143 do t[i]=mem:read_u8(base+i) end
  return t
end

-- Real carry-and-drop of the rock at base record `rb` (index ri) while
-- Dizzy stands in room 48; returns true when the drop message came up.
local function drop_rock_once(rb,ri)
  mem:write_u8(rb,255)
  for s=0,3 do mem:write_u8(SYM.inv+s,0) end
  mem:write_u8(SYM.inv,ri+1)
  local opened=false
  local ok=waitfor(function()
    key("DOWN",true)
    if in_inventory() and mem:read_u8(SYM.inv_occupied)>=1 then opened=true end
    return opened
  end,300)
  key("DOWN",false)
  if not ok then return false,"inventory never opened" end
  wait(30)
  -- cursor to slot 0 (key3lift88's own cursor dance)
  local t0=f
  while mem:read_u8(SYM.inv_cursor)~=0 and f-t0<600 do
    key("UP",((f-t0)%30)<10); coroutine.yield()
  end
  key("UP",false); wait(20)
  key("SPACE",true); wait(10); key("SPACE",false)
  if waitfor(function() return in_msgwait() end,120) then return true end
  return false,string.format("no message: inv0=%d cursor=%d in_inv=%s rock_room=%d",
    mem:read_u8(SYM.inv),r("inv_cursor"),tostring(in_inventory()),mem:read_u8(rb))
end
-- the inventory UI occasionally eats the first SPACE (cursor/redraw
-- timing, same flakiness keylift.lua works around with its own retries):
-- retry the whole open/select dance up to 4 times, on observed state.
local function drop_rock(rb,ri)
  local ok,why
  for try=1,4 do
    ok,why=drop_rock_once(rb,ri)
    if ok then return true end
    print(string.format("LOG48 INFO drop try %d failed (%s)",try,tostring(why)))
    if in_inventory() then key("SPACE",true); wait(10); key("SPACE",false); wait(30) end
    -- an inventory that closed without dropping: the item is still in inv
    wait(30)
  end
  return false,why
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

-- Jump-left attempt from the log: warp Dizzy above the log at x=sx, let him
-- land, then hold LEFT and press UP (mode "tap": 3 frames, a player's tap;
-- "hold": 40 frames).  Reached = standing (floor=1) on the left cliff's
-- face/ledge: x<=72 and feet y<=116 (the cliff face is a staircase of 4px
-- steps up to the ledge top at y=112).
local function try_jump(sx,mode)
  local ly=logy()
  if not warp(48,sx,ly-20) then return nil end
  local landed=r("dizzy_y")
  local reached,minfeet,died=false,255,false
  local t0=f
  while f-t0<200 do
    key("LEFT",true); key("UP",(f-t0)<(mode=="tap" and 3 or 40))
    coroutine.yield()
    local y=r("dizzy_y")
    if y<minfeet then minfeet=y end
    if r("killed")~=0 then died=true break end
    if r("dizzy_floor")==1 and r("dizzy_x")<=72 and y<=116 then reached=true break end
  end
  key("LEFT",false); key("UP",false)
  return reached,landed,minfeet,died
end
-- every start x on the log x 2 tap lengths; returns reached-count, tries, a
-- sample landing feet, and whether Dizzy is left standing on the ledge
local function attempt_set()
  local n,tries,landed=0,0,nil
  for _,sx in ipairs({100,108,116}) do
    for _,mode in ipairs({"tap","hold"}) do
      local reached,l=try_jump(sx,mode)
      tries=tries+1
      landed=landed or l
      if reached then n=n+1 end
      if reached and os.getenv("STOPFIRST") then return n,tries,landed end
    end
  end
  return n,tries,landed
end

-- no trail above the log: sample the displayed frame across the bob cycle;
-- in the log's own byte columns (x 112..143 -> cols 14..17), above the water
-- band, no ink may sit more than 1 row above the log's current top (the
-- displayed frame is at most one bob step -- 1 row -- behind the record).
-- A moving sprite that is not erased leaves rows above its new top.
local function trail_check(wh)
  local bad,samples=0,0
  for _=1,120 do
    local y0=logy()
    local d=dump_fb()
    local y1=logy()
    local lo=math.min(y0,y1)
    local top
    for row=100,168-wh-1 do
      for c=14,17 do if d[row*32+c]~=0 then top=top or row break end end
      if top then break end
    end
    samples=samples+1
    if top and top<lo-1 then bad=bad+1 end
    wait(3)
  end
  return bad,samples
end

local R={}   -- results per rock count
local D={}   -- framebuffer dumps
local function script()
  -- ---- boot ----
  local live=0
  waitfor(function()
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    live=(r("cur_room")==36 and r("dizzy_y")~=0) and live+1 or 0
    return live>=60
  end,3000)
  key("SPACE",false)
  report(r("waterheight")==0,string.format("waterheight==0 at boot (%d)",r("waterheight")))

  local rocks={ {room=50,frame=138}, {room=35,frame=139}, {room=53,frame=136} }
  for _,rk in ipairs(rocks) do
    local b,i=find_base(rk.room,rk.frame)
    if not b then report(false,string.format("rock room %d frame %d not in actor_ram",rk.room,rk.frame)); return end
    rk.b,rk.i=b,i
  end

  -- ---- baseline (waterheight 0): stand on the right cliff ----
  if not warp(48,184,112) then report(false,"warp to room 48 right cliff"); return end
  wait(30)
  do
    local ys,seen,n={}, {}, 0
    for _=1,200 do local y=logy(); if not seen[y] then seen[y]=true; n=n+1 end ys[#ys+1]=y; coroutine.yield() end
    local lo,hi=255,0 for _,y in ipairs(ys) do if y<lo then lo=y end if y>hi then hi=y end end
    report(lo==163 and hi==165 and n==3,string.format("log bobs 163..165 at waterheight 0 (min=%d max=%d distinct=%d)",lo,hi,n))
    local tl=SYM.tide_list
    report(mem:read_u8(tl+1)==168 and mem:read_u8(tl+3)==168 and mem:read_u8(tl+5)==168
      and mem:read_u8(tl)==80 and mem:read_u8(tl+2)==112 and mem:read_u8(tl+4)==144
      and r("room_water_count")==3 and (mem:read_u8(SYM.room_water_ptr)*256+mem:read_u8(SYM.room_water_ptr+1))==tl,
      "water = 3 tiles x=80,112,144 at y=168 (room_water_ptr->tide_list)")
    report(r("killed")==0,"standing on the right cliff at waterheight 0 is safe")
  end
  -- pixel dumps at waterheight 0
  D[0]=dump_fb()

  -- ---- attempt at 0 rocks (control) ----
  do
    local n,tries,landed=attempt_set()
    print(string.format("LOG48 INFO rocks=0: reached the left ledge in %d/%d jump-left tries from the log",n,tries))
    report(n==0,string.format("control: with waterheight 0 the left ledge is NOT reachable from the log (%d/%d tries)",n,tries))
    report(landed==164 or landed==163 or landed==165,string.format("Dizzy stands ON the log at waterheight 0 (feet=%s, log 163..165)",tostring(landed)))
  end

  -- ---- three real rock drops ----
  for k=1,3 do
    if not warp(48,184,112) then report(false,"warp back to right cliff for rock "..k); return end
    wait(20)
    local rk=rocks[k]
    local ok,why=drop_rock(rk.b,rk.i)
    if not ok then report(false,string.format("rock %d: %s",k,tostring(why))); return end
    report(r("msg_active")==1,string.format("rock %d: rockinwatermess is up (msg_active=%d)",k,r("msg_active")))
    -- the box's own text: first glyph row is drawn by prtmessage; check the
    -- message pointer by looking at the displayed screen for ink at the box
    dismiss_msg()
    local wh=r("waterheight")
    report(wh==6*k,string.format("rock %d: waterheight=%d (want %d)",k,wh,6*k))
    local rx,ry,rroom=mem:read_u8(rk.b+2),mem:read_u8(rk.b+3),mem:read_u8(rk.b)
    report(rroom==48 and rx==176-4*wh and ry==176,string.format("rock %d: now room %d at (%d,%d) want (48,%d,176)",k,rroom,rx,ry,176-4*wh))
    wait(60)
    local lo,hi=255,0
    for _=1,120 do local y=logy(); if y<lo then lo=y end if y>hi then hi=y end coroutine.yield() end
    report(lo==162-wh+1 and hi==162-wh+3,string.format("rock %d: log bobs %d..%d (want %d..%d)",k,lo,hi,163-wh,165-wh))
    local tl=SYM.tide_list
    report(mem:read_u8(tl+1)==168-wh and mem:read_u8(tl+3)==168-wh and mem:read_u8(tl+5)==168-wh,
      string.format("rock %d: water tiles at y=%d (%d,%d,%d)",k,168-wh,mem:read_u8(tl+1),mem:read_u8(tl+3),mem:read_u8(tl+5)))
    report(r("killed")==0,string.format("rock %d: Dizzy alive after the drop",k))
    if k==3 then D[18]=dump_fb() end
    do local bad,samples=trail_check(wh)
      report(bad==0,string.format("rock %d: no trail above the log (%d samples, %d bad)",k,samples,bad)) end
    -- ---- attempt after k rocks ----
    local n,tries,landed=attempt_set()
    print(string.format("LOG48 INFO rocks=%d: reached the left ledge in %d/%d jump-left tries from the log",k,n,tries))
    if k==3 then
      report(n>=1,string.format("OUTCOME: with 3 rocks (waterheight 18) Dizzy jumps from the log onto the left (key 4) ledge (%d/%d tries)",n,tries))
      report(landed==145 or landed==146 or landed==147,string.format("Dizzy stands ON the raised log (feet=%s, log 145..147)",tostring(landed)))
      -- ... and takes key 4 (frame 13, tape actor (48,32,96)) from it
      local kb,ks=find_tape(48,2,13)
      local got=false
      for _,sx in ipairs({100,108,116}) do
        for _,mode in ipairs({"tap","hold"}) do
          if not got then
            local reached=try_jump(sx,mode)
            if reached then
              local t0=f
              while r("dizzy_x")>40 and f-t0<200 do key("LEFT",true); coroutine.yield() end
              key("LEFT",false); wait(20)
              for s2=0,3 do mem:write_u8(SYM.inv+s2,0) end
              local t1=f
              while f-t1<60 do key("DOWN",f-t1>=10 and f-t1<50); coroutine.yield() end
              key("DOWN",false)
              local want=100+ks+1
              local inv=false
              for s2=0,3 do if mem:read_u8(SYM.inv+s2)==want then inv=true end end
              got=inv and mem:read_u8(kb)==255
            end
          end
        end
      end
      report(got,"OUTCOME: Dizzy picks key 4 up from the left ledge (inv has the tape-table key, record room=255)")
    end
  end

  if os.getenv("DUMPDIR") then
    for _,k in ipairs({0,18}) do
      local fh=io.open(os.getenv("DUMPDIR").."/r48_wh"..k..".raw","wb")
      for i=0,6143 do fh:write(string.char(D[k][i])) end fh:close()
    end
  end
  -- ---- pixels ----
  do
    local function col_ink_top(d,c0,c1,r0,r1)   -- topmost row with ink in byte cols c0..c1
      for row=r0,r1 do for c=c0,c1 do if d[row*32+c]~=0 then return row end end end
    end
    local t0=col_ink_top(D[0],10,12,100,183)
    local t18=col_ink_top(D[18],10,12,100,183)
    report(t0 and t18 and t0-t18==18,string.format("water band top row moved up by 18 (y %s -> %s)",tostring(t0),tostring(t18)))
    -- nothing outside the river columns (80..175 -> cols 10..21) changed
    local diff=0
    -- T0226: from the play window down (rows 48..191): room 48 now has a banner name, and the
    -- first dump can be taken before the banner pass has painted the second buffer
    -- ... and Dizzy himself (standing on the right cliff, rows 88..115, cols 22..26) is left out:
    -- his idle blink lands on a different frame in the two dumps depending on timing
    for row=48,191 do for c=0,31 do
      if (c<9 or c>22) and not (row>=88 and row<=115 and c>=22 and c<=26)
         and D[0][row*32+c]~=D[18][row*32+c] then diff=diff+1 end end end
    report(diff==0,string.format("no pixel change outside the river columns (%d bytes differ)",diff))
  end
  -- ---- game over resets waterheight ----
  mem:write_u8(SYM.lives,0); mem:write_u8(SYM.killed,1)
  local boxn=0
  local ok=waitfor(function()
    boxn=boxn+1
    key("SPACE",(boxn%26)<8)
    return r("cur_room")==36 and r("lives")==2 and r("dizzy_y")~=0 and boxn>200
  end,2400)
  key("SPACE",false)
  report(ok and r("waterheight")==0,string.format("game over -> new game: waterheight=%d (want 0), room=%d lives=%d",r("waterheight"),r("cur_room"),r("lives")))
  local ok2=true
  for _,rk in ipairs(rocks) do
    local rr=mem:read_u8(rk.b)
    if rr==48 or rr==255 then ok2=false end
  end
  report(ok2,"game over -> new game: the three rocks are back in their own rooms")

  print(string.format("LOG48 SUMMARY pass=%d fail=%d",pass,fail))
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
  if not ok then print("LOG48 FAIL harness error: "..tostring(err)); manager.machine:exit() end
  if coroutine.status(co)=="dead" and not os.getenv("NOEXIT") then manager.machine:exit() end
end)
