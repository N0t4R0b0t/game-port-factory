-- harness/tape_dozyfloat.lua -- T0218: room 45's Dozy in the TAPE build
-- (X-ALL.TXT dozyhere 1661 / dozytalking 613 / dozyrou 2411 / dozyfloathere
-- 1665 / dozyfloatrou 3230). End to end, with real talks (DOWN, try_pickup):
--   * boot: potion not in the world, Dozy standing, float idle (room 255)
--   * talk 1 shows dozytalking's 9 boxes in turn (T0220; box identified from
--     msg_chatter's saved pointer on the stack) and materialises the potion;
--     talks 2..4 show kickdozyagainmess
--     (DOZY_DUMP=dir also dumps the framebuffers of each box as boxN.raw)
--   * talk 5 shows pushdozymess, Dozy's slot -> room 255, float var1 != 0
--   * the float: x drops by 4 only on the var1==4 tick, y = 139+{1,2,1,0}
--     by var1, ends at x=0 (var1=0, out of the world)
--   * pixels: nothing changes outside the sprite's box (no trail) and the
--     sprite really is drawn
--   * talk 6 does nothing; game over resets all of it
--
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 400 \
--     -autoboot_script harness/tape_dozyfloat.lua
-- Prints "DOZYFLOAT PASS|FAIL ..." lines and "DOZYFLOAT SUMMARY pass=N fail=N".
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
for _,s in ipairs({"actor_init_tape","msg_active","msg_kickdozy","msg_pushdozy","msg_dozy_end","msg_dozytalking","msg_dozylow_end","dz_talks",
                   "DZ_FLOAT","DZ_POTION","cur_buf","dizzy_x","dizzy_y","lives","killed","cur_room"}) do
  if not SYM[s] then print("DOZYFLOAT FAIL symbol "..s.." missing from the map"); manager.machine:exit() end
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
  print(string.format("DOZYFLOAT %s %s", ok and "PASS" or "FAIL", what))
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

local function tape_rec(rou,frame)
  for i=0,NACT_T-1 do local b=SYM.actor_init_tape+i*8
    if mem:read_u8(b+1)==rou and mem:read_u8(b+4)==frame then return b,i end end
end
local function rec(b) return mem:read_u8(b),mem:read_u8(b+2),mem:read_u8(b+3),mem:read_u8(b+5) end -- room,x,y,var1
local function dump_fb()
  local base = mem:read_u8(SYM.cur_buf)==0 and 0x4000 or 0x6000
  local t={} for i=0,6143 do t[i]=mem:read_u8(base+i) end
  return t
end
-- which message box is up: the stack holds msg_chatter's saved X (the
-- pointer just past the box that is showing).  T0220: dozytalking
-- (low region, 9 boxes: the original has NINE `mend`-terminated boxes, not 8) = "talkN" (N = box 1..9: the number of 0
-- terminators below the pointer), (dozytalking_end..dozylow_end] = kick,
-- (push, dozy_end] = push.
local function box_index(w)
  local n=0
  for a=SYM.msg_dozytalking,w-1 do if mem:read_u8(a)==0 then n=n+1 end end
  return n
end
local function which_msg()
  local s=cpu.state["S"].value
  for i=0,40,2 do   -- T0237: aligned words only (an unaligned pair of data bytes can look like a message pointer: it made "kick" win over talk1)
    local w=mem:read_u8(s+i)*256+mem:read_u8(s+i+1)
    if w>SYM.msg_dozytalking and w<=SYM.msg_dozylow_end then
      -- kick is the stream right after dozytalking's own two 0 terminator bytes
      if w>SYM.msg_kickdozy then return "kick" end
      return "talk"..box_index(w)
    end
    if w>SYM.msg_pushdozy and w<=SYM.msg_dozy_end then return "push" end
  end
  return nil
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
-- T0237: dismiss ONE box of a chatter stream: press SPACE until the box id changes (the next box is up) or the
-- stream is over.  dismiss_msg() waits for a gap with msg_active==0 between boxes; that gap is shorter than a frame
-- now and the old version pulsed SPACE through the whole conversation.
local function dismiss_box(prev)
  local n=0
  local ok=waitfor(function()
    n=n+1
    key("SPACE",(n%26)<8)
    if not in_msgwait() then return not in_audio() and r("msg_active")==0 end
    local w=which_msg()
    return w~=nil and w:match("^talk%d$")~=nil and w~=prev
  end,600)
  key("SPACE",false)
  return ok
end
-- one real talk: stand overlapping Dozy and press DOWN (try_pickup's key)
local function talk()
  local seen=nil
  local ok=waitfor(function()
    key("DOWN",true)
    -- T0237: a frame-boundary sample can land where the box id is not readable yet (in a blit): keep sampling until it is
    if in_msgwait() and r("msg_active")==1 then seen=which_msg() return seen~=nil end
    return false
  end,300)
  key("DOWN",false)
  return ok,seen
end
local function gone_msg(n) -- a talk that should do nothing: no box within n frames
  local up=false
  for _=1,n do key("DOWN",true); coroutine.yield(); if r("msg_active")==1 then up=true break end end
  key("DOWN",false)
  return up
end

local function script()
  local live=0
  waitfor(function()
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    live=(r("cur_room")==36 and r("dizzy_y")~=0) and live+1 or 0
    return live>=60
  end,3000)
  key("SPACE",false)
  local potb=tape_rec(2,15); local dozb=tape_rec(2,32); local flb=tape_rec(10,32)
  report(potb==SYM.DZ_POTION and flb==SYM.DZ_FLOAT and flb==dozb+8,
    string.format("slots: potion=%04X (DZ_POTION %04X) dozy=%04X float=%04X (DZ_FLOAT %04X, dozy+8)",potb or 0,SYM.DZ_POTION,dozb or 0,flb or 0,SYM.DZ_FLOAT))
  if not (potb and dozb and flb) then return end
  local function rep_state(tag)
    local pr=mem:read_u8(potb); local dr=mem:read_u8(dozb); local fr,fx,fy,fv=rec(flb)
    print(string.format("DOZYFLOAT INFO %s: potion room=%d dozy room=%d float room=%d x=%d y=%d var1=%d talks=%d",
      tag,pr,dr,fr,fx,fy,fv,r("dz_talks")))
  end
  rep_state("boot")
  report(mem:read_u8(potb)==255,"boot: sleeping potion NOT in the world (room 255; dozytalking materialises it)")
  report(mem:read_u8(dozb)==45,"boot: Dozy stands in room 45")
  do local fr,fx,fy,fv=rec(flb)
    report(fr==255 and fv==0 and fx==144 and fy==139,string.format("boot: float not in the world (room %d x=%d y=%d var1=%d)",fr,fx,fy,fv)) end
  report(r("dz_talks")==0,"boot: talk count 0")

  -- ---- get to Dozy ----
  local DX=tonumber(os.getenv("DOZY_X") or "168")
  if not warp(45,DX,100) then report(false,"warp to room 45"); return end
  wait(20)
  print(string.format("DOZYFLOAT INFO room 45: dizzy x=%d y=%d floor=%d",r("dizzy_x"),r("dizzy_y"),r("dizzy_floor")))

  -- ---- talk 1: dozytalking (8 boxes, each shown and dismissed in turn);
  -- the potion appears; talks 2..4: kickdozyagainmess ----
  do
    local ok,seen=talk()
    local order={}
    local dumpdir=os.getenv("DOZY_DUMP")
    local k=0
    while ok and seen and seen:match("^talk%d$") and k<10 do
      k=k+1
      order[#order+1]=seen
      if os.getenv("DOZYDBG") then local S=cpu.state["S"].value; local ws={} for i=0,12 do ws[#ws+1]=string.format("%04X",mem:read_u8(S+i)*256+mem:read_u8(S+i+1)) end
        print(string.format("DOZYFLOAT DBG box %s pc=%04X S=%04X f=%d words %s",seen,pc(),S,f,table.concat(ws," "))) end
      if k==1 then report(mem:read_u8(potb)==45,string.format("talk 1, box 1 up: potion already materialised in room 45 (room=%d)",mem:read_u8(potb))) end
      if dumpdir then
        wait(20)
        local fh=io.open(string.format("%s/box%d.raw",dumpdir,k),"wb")
        for i=0,12287 do fh:write(string.char(mem:read_u8(0x4000+i))) end
        fh:close()
      end
      report(r("msg_active")==1,string.format("talk 1: box %d is up (msg_active=1)",k))
      dismiss_box(seen)
      -- the next box of the SAME conversation is up as soon as msg_active goes back to 1
      ok=waitfor(function() return in_msgwait() and r("msg_active")==1 end,60)
      seen=ok and which_msg() or nil
    end
    local want="talk1,talk2,talk3,talk4,talk5,talk6,talk7,talk8,talk9"
    report(table.concat(order,",")==want,string.format("talk 1: boxes shown in turn = %s (want %s)",table.concat(order,","),want))
    report(not ok or seen==nil,"talk 1: no 10th box (the conversation ends after box 9)")
    report(r("dz_talks")==1,string.format("talk 1: count=%d",r("dz_talks")))
    report(mem:read_u8(potb)==45,string.format("talk 1: sleeping potion appears in room 45 (room=%d)",mem:read_u8(potb)))
    report(mem:read_u8(dozb)==45 and select(4,rec(flb))==0 and mem:read_u8(flb)==255,"talk 1: Dozy still in place, float still idle")
    waitfor(function() return r("msg_active")==0 and not in_msgwait() end,200)
    wait(40)
  end
  for n=2,4 do
    local ok,seen=talk()
    report(ok and seen=="kick",string.format("talk %d: box up = %s (want kick, kickdozyagainmess)",n,tostring(seen)))
    if not ok then rep_state("talk "..n.." failed"); return end
    report(r("dz_talks")==n,string.format("talk %d: count=%d",n,r("dz_talks")))
    report(mem:read_u8(dozb)==45 and select(4,rec(flb))==0 and mem:read_u8(flb)==255,
      string.format("talk %d: Dozy still in place, float still idle",n))
    dismiss_msg(); wait(40)
  end
  -- ---- talk 5: pushdozymess, Dozy leaves, the float starts ----
  local ok,seen=talk()
  report(ok and seen=="push",string.format("talk 5: box up = %s (want push, pushdozymess)",tostring(seen)))
  report(r("dz_talks")==5,"talk 5: count=5")
  report(mem:read_u8(dozb)==255,string.format("talk 5: dozyhere.room=255 (%d)",mem:read_u8(dozb)))
  do local fr,fx,fy,fv=rec(flb)
    report(fv~=0 and fr==45,string.format("talk 5: float started (room=%d var1=%d x=%d)",fr,fv,fx)) end
  -- dismiss, then sample the float every video frame
  local trace={}
  do
    local n=0
    waitfor(function() n=n+1; key("SPACE",(n%26)<8); return not in_msgwait() and r("msg_active")==0 end,600)
    key("SPACE",false)
  end
  local fb_samples={}
  local t0=f
  local last_v=-1
  local maxn=tonumber(os.getenv("DOZY_FRAMES") or "6000")
  while f-t0<maxn do
    local fr,fx,fy,fv=rec(flb)
    trace[#trace+1]={fr,fx,fy,fv}
    if fv==0 then break end
    if (#trace%3)==0 and fx>=8 and #trace>=20 then -- (first frames: the push box is still being repainted away)
      fb_samples[#fb_samples+1]={dump_fb(),fx,fy,r("dizzy_x"),r("dizzy_y")} end
    coroutine.yield()
  end
  local last=trace[#trace]
  report(last[4]==0,string.format("float ends: var1=0 after %d frames (x=%d room=%d)",#trace,last[2],last[1]))
  report(last[2]==0 and last[1]==255,string.format("float end state: x=0 (left edge) and out of the world (x=%d room=%d)",last[2],last[1]))
  -- (var1,y) relation and x stepping
  local badrel,badx,seenv,xs=0,0,{},0
  local px,pv
  for i,t in ipairs(trace) do
    local fr,x,y,v=t[1],t[2],t[3],t[4]
    if v~=0 then
      local want={[4]=140,[3]=141,[2]=140,[1]=139,[255]=nil}
      -- T0228: the periodic callback can land BETWEEN update_dozyfloat's var1 step and its y step
      -- (one pass later the pair is consistent): tolerate exactly that one-sample lag, never two in a row
      local nx=trace[i+1]
      local lag_ok = nx and nx[4]==v and want[v]==nx[3]
      if v~=255 and want[v]~=y and not lag_ok then badrel=badrel+1 end
      seenv[v]=(seenv[v] or 0)+1
    end
    if px then
      local d=px-x
      if d~=0 and d~=4 then badx=badx+1 end
      if d==4 then xs=xs+1; if v~=4 and v~=0 then badx=badx+1 end end
    end
    px,pv=x,v
  end
  report(badrel==0,string.format("y follows var1 (4->140 3->141 2->140 1->139): %d bad samples",badrel))
  report(badx==0 and xs>=30,string.format("x only ever drops by 4 and only on the var1==4 tick: %d bad, %d steps seen (36 expected, some can fall between frames)",badx,xs))
  report(seenv[1] and seenv[2] and seenv[3] and seenv[4],"all four bob phases seen (var1 1,2,3,4)")
  print(string.format("DOZYFLOAT INFO frames=%d start x=%d y=%d",#trace,trace[1][2],trace[1][3]))

  -- ---- pixels: no trail ----
  wait(30)
  local clean=dump_fb()
  local bad,shown=0,0
  local worst=0
  for _,s in ipairs(fb_samples) do
    local d,fx,fy,dx,dy=s[1],s[2],s[3],s[4],s[5]
    -- allowed: the sprite's box (24x28 + 4px shift spill) one step either side
    local c0=math.max(0,(fx-8)//8); local c1=math.min(31,(fx+4+24+8)//8)
    local y0=fy-4; local y1=fy+28+4
    local dc0=math.max(0,(dx-8)//8); local dc1=math.min(31,(dx+32)//8)
    local dy0=dy-48; local dy1=dy+16
    -- the float moves LEFT, so a missing erase leaves ink to the RIGHT of
    -- its box: compare that zone (rows above the animated water ripple at
    -- y160, which differs between any two captures) with the clean
    -- scene.  Dizzy's own box is masked.
    local outside,inside=0,0
    local zr1=math.min(fy+19,157)   -- row 160 is animated water ripple
    for row=0,191 do for c=0,31 do
      local i=row*32+c
      if d[i]~=clean[i] then
        local inbox = c>=c0 and c<=c1 and row>=y0 and row<=y1
        local indiz = c>=dc0 and c<=dc1 and row>=dy0 and row<=dy1
        if inbox then inside=inside+1
        elseif c>c1 and row>=y0 and row<=zr1 and not indiz then outside=outside+1 end
      end
    end end
    if outside>0 then bad=bad+1; if outside>worst then worst=outside end end
    if os.getenv("DOZYDBG") and outside>0 then
      local r0,r1,k0,k1=999,-1,99,-1
      for row=y0,zr1 do for c=c1+1,31 do local i=row*32+c
        if d[i]~=clean[i] then r0=math.min(r0,row); r1=math.max(r1,row); k0=math.min(k0,c); k1=math.max(k1,c) end end end
      local cells={}
      for row=y0,zr1 do for c=c1+1,31 do local i=row*32+c
        if d[i]~=clean[i] then cells[#cells+1]=string.format("(%d,%d:%02x/%02x)",row,c,d[i],clean[i]) end end end
      print("DOZYFLOAT DBG cells "..table.concat(cells," "))
      print(string.format("DOZYFLOAT DBG sample fx=%d fy=%d diz=(%d,%d) out=%d rows %d..%d cols %d..%d (c1=%d)",fx,fy,dx,dy,outside,r0,r1,k0,k1,c1))
    end
    if false then
      local r0,r1,k0,k1=999,-1,99,-1
      for row=0,191 do for c=0,31 do local i=row*32+c
        if d[i]~=clean[i] then
          local inbox = c>=c0 and c<=c1 and row>=y0 and row<=y1
          local indiz = c>=dc0 and c<=dc1 and row>=dy0 and row<=dy1
          if not inbox and not indiz then r0=math.min(r0,row); r1=math.max(r1,row); k0=math.min(k0,c); k1=math.max(k1,c) end
        end end end
      print(string.format("DOZYFLOAT DBG fx=%d fy=%d diz=(%d,%d) outside=%d rows %d..%d cols %d..%d",fx,fy,dx,dy,outside,r0,r1,k0,k1))
    end
    if inside>0 then shown=shown+1 end
  end
  report(#fb_samples>=20 and bad==0,string.format("no trail: %d framebuffer samples, %d with changed bytes outside the sprite box (worst %d bytes)",#fb_samples,bad,worst))
  report(shown>=0.9*#fb_samples,string.format("the float is actually drawn: %d/%d samples differ from the clean scene inside its box",shown,#fb_samples))

  -- ---- 6th talk: nothing (he is gone) ----
  report(not gone_msg(60),"talk 6: nothing happens (no box)")
  report(r("dz_talks")==5,"talk 6: count stays 5")

  -- ---- game over resets everything ----
  mem:write_u8(SYM.lives,0); mem:write_u8(SYM.killed,1)
  local boxn=0
  local ok=waitfor(function()
    boxn=boxn+1
    key("SPACE",(boxn%26)<8)
    return r("cur_room")==36 and r("lives")==2 and r("dizzy_y")~=0 and boxn>200
  end,2400)
  key("SPACE",false)
  rep_state("after game over")
  local fr,fx,fy,fv=rec(flb)
  report(ok and mem:read_u8(dozb)==45 and mem:read_u8(potb)==255 and fr==255 and fv==0 and fx==144 and fy==139 and r("dz_talks")==0,
    "game over -> new game: Dozy back in place, potion gone, float idle (room 255, var1 0, x 144, y 139), talk count 0")

  print(string.format("DOZYFLOAT SUMMARY pass=%d fail=%d",pass,fail))
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
  if not ok then print("DOZYFLOAT FAIL harness error: "..tostring(err)); manager.machine:exit() end
  if coroutine.status(co)=="dead" and not os.getenv("NOEXIT") then manager.machine:exit() end
end)
