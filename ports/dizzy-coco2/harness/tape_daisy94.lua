-- harness/tape_daisy94.lua -- T0228: Daisy in her prison (room 94) and the heart demo.
-- X-ALL.TXT daisyrou 3492 (meeting), justinlift 3530 (she rides the lift), theheartdemo
-- 3517 + heartdemo/updatehearts/printheart/getvalue 3590-3715, `random` 5128.
--
-- Real input throughout (the switch is walked into, the table is walked along, SPACE pulses
-- dismiss the boxes); memory is POKED only to set up (lives, warps, coins, the win's daisy1)
-- and READ to judge.  What it proves, in order:
--   1  records: Daisy starts in room 94 (frame 35, colour 95), daisy1 starts HIDDEN (room 255)
--   2  CONTROL: standing on daisy1's old spot in room 73 does nothing (no box, no win, no Daisy drawn)
--   3  justinlift: walking into the switch lowers the lift and Daisy rides it (y = lift y + 21)
--   4  CONTROL: walking (RIGHT held) into Daisy does NOT start the meeting (sequence != 0);
--      releasing the key while overlapping does
--   5  box 1 (gottodaisymess): shown, the text is token-for-token, tune 3 is running under it,
--      Daisy is still in 94 and daisy1 still hidden
--   6  the heart demo: runs after box 1 and BEFORE box 2, SILENT (the mixer is not running), 255
--      updates, every update's pixel change equals the independent reference (heartref.lua:
--      the original's arithmetic, window clip and XOR plot), ages/paths/direction as the original
--   7  box 2 (daisyrunsmess): daisy moved out of 94 and daisy1 into 73 only now, text verbatim,
--      the tune RESUMES (stream pointer continues, not restarted)
--   8  afterwards: room 94 is redrawn without Daisy; room 73 shows daisy1; no win/nag from a
--      distance
--   9  game over -> new game restores Daisy to 94 (and her y) and hides daisy1
--  10  the win path again: coins=30 + daisy1 poked to 73, the SECOND demo of the session:
--      add/sub direction flipped, `random` continues, same pixel check; then the title
--  11  win -> new game restores them too
--
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map [DUMPDIR=/tmp/x] \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 700 \
--     -autoboot_script harness/tape_daisy94.lua
-- Prints "DAISY94 PASS|FAIL <what>" and "DAISY94 SUMMARY pass=N fail=N".
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
for _,s in ipairs({"tape_heart_demo","hd_sin","hd_dir","hd_seed","ud94_daisy","tape_win_one","tape_win_chatter","tw_base","tw_dp",
                   "WIN_MIX3_RAW","msg_active","completedgame","actor_init_tape","actor_init_tape_template","ACTOR_COUNT_tape",
                   "dizzy_dir","jump_on","respawn_room","MIX3_BUF","msg_wait_dismiss","fb_stablekeys","play_tone","play_chirp",
                   "cur_buf","lives","coins","killed","hd_print","hd_room3"}) do
  if not SYM[s] and not (os.getenv("FLOPPY_OVL_DIR") and (s=="hd_sin" or s=="hd_print" or s=="hd_room3")) then print("DAISY94 FAIL symbol "..s.." missing from the map"); manager.machine:exit() end
end
local H=dofile("harness/heartref.lua")
-- T0241: FLOPPY_OVL_DIR=target/floppy -> the heart demo is an overlay in the hidden framebuffer (see heartref.lua)
if os.getenv("FLOPPY_OVL_DIR") then
  local rg=H.load_overlay_ranges(os.getenv("FLOPPY_OVL_DIR"),mem)
  for _,n in ipairs({"hd_sin","hd_print","hd_room3"}) do SYM[n]=rg[1][4][n] end   -- only the presence checks above need them
end
local GLYPH=H.load_glyphs("target/font_data.asm")
local NACT_T=SYM.ACTOR_COUNT_tape
local ROU_LIFT,ROU_DAISY,ROU_SWITCH1,ROU_DAISY1=9,17,18,19
local function r(s) return mem:read_u8(SYM[s]) end
local function pc() return cpu.state["PC"].value end
local function u16(a) return mem:read_u8(a)*256+mem:read_u8(a+1) end
local function now() return manager.machine.time:as_double() end
local function stack_has(lo,hi)
  local sp=cpu.state["S"].value
  for i=0,63 do if sp+i+1>=0x100 then break end local a=mem:read_u8(sp+i)*256+mem:read_u8(sp+i+1)
    if a>=lo and a<hi then return true end end
  return false
end
local function in_msgwait()
  local p=pc()
  return (p>=SYM.msg_wait_dismiss and p<SYM.fb_stablekeys) or stack_has(SYM.msg_wait_dismiss,SYM.fb_stablekeys)
    or (p>=SYM.tape_win_chatter and p<SYM.tw_base) or stack_has(SYM.tape_win_chatter,SYM.tw_base)
end
local function in_audio() local p=pc() return p>=SYM.play_tone and p<SYM.play_chirp end
local function in_title_wait() local p=pc() return SYM.MIX3_BUF and p>=SYM.MIX3_BUF and p<SYM.MIX3_BUF+3072 end
local function in_hearts() return H.in_hearts(pc(),SYM) end
local function in_mixer()
  local base=u16(SYM.tw_base); local p=pc()
  if H.overlay_loaded() then return false end     -- T0241: the floppy build's demo overlay REPLACES the blob (same addresses): no mixer while it is there
  return base~=0 and p>=base and p<base+SYM.WIN_MIX3_RAW
end
local function mixer_sptr() return u16(mem:read_u8(SYM.tw_dp)*256+0x0F) end
local function rec(rou,room)
  for i=0,NACT_T-1 do local b=SYM.actor_init_tape+i*8
    if mem:read_u8(b+1)==rou and (room==nil or mem:read_u8(b)==room) then return b end end
end
local function daisy94() return rec(ROU_DAISY) end
local function daisy73() return rec(ROU_DAISY1) end
local function lift94() return rec(ROU_LIFT,94) end

local f=0
local pass,fail=0,0
local function report(ok,what)
  if ok then pass=pass+1 else fail=fail+1 end
  print(string.format("DAISY94 %s %s", ok and "PASS" or "FAIL", what))
end
local function wait(n) for _=1,n do coroutine.yield() end end
local function waitfor(pred,timeout)
  for _=1,timeout do if pred() then return true end coroutine.yield() end
  return pred()
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
local function warp(room,x,y,expect_box)
  mem:write_u8(SYM.lives,2)
  mem:write_u8(SYM.respawn_room,room); mem:write_u8(SYM.respawn_x,x)
  mem:write_u8(SYM.respawn_y,y); mem:write_u8(SYM.killed,1)
  local n=0
  local seen_box=false
  local ok=waitfor(function()
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
-- rows 0..47 (the banner art, never repainted by redraw in the tape build) of BOTH framebuffers
local function banners()
  local t={}
  for _,base in ipairs({0x4000,0x6000}) do
    local b={} for i=0,1535 do b[i]=mem:read_u8(base+i) end t[base]=b
  end
  return t
end
local function banner_diff(a,b)
  local n=0
  for _,base in ipairs({0x4000,0x6000}) do for i=0,1535 do if a[base][i]~=b[base][i] then n=n+1 end end end
  return n
end
local function tex(fb,lines)
  local worst=0
  for _,l in ipairs(lines) do
    local bad=H.text_at(GLYPH,fb,l[3],l[1],l[2]); if bad>worst then worst=bad end
  end
  return worst
end
-- message lines (x unit, y, text); the text is looked up from the user's own X-ALL.TXT (harness/orig.lua), lines 733-744
local OT=dofile("harness/orig.lua")
local LINES_GOTTO={{8,72,OT("X-ALL:733")},{8,80,OT("X-ALL:734")},{9,88,OT("X-ALL:735")}}
local LINES_RUNS={{13,88,OT("X-ALL:738")},{10,96,OT("X-ALL:739")},{11,104,OT("X-ALL:740")},
  {9,112,OT("X-ALL:741")},{11,120,OT("X-ALL:742")},{10,128,OT("X-ALL:743")},{14,136,OT("X-ALL:744")}}
local function fix(l) return {l[1],l[2],l[3]} end
-- tex() wants {y,?}: reorder to (xu,y,text) -> text_at(G,fb,str,xu,y)
local function tex2(fb,lines)
  local worst=0
  for _,l in ipairs(lines) do local bad=H.text_at(GLYPH,fb,l[3],l[1],l[2]); if bad>worst then worst=bad end end
  return worst
end

local mon=H.monitor({mem=mem,cpu=cpu,SYM=SYM,dumpdir=os.getenv("DUMPDIR"),dump_at={[0]="heart_start",[127]="heart_mid",[255]="heart_end"}})

local function check_records(tag)
  local d,d1,lb=daisy94(),daisy73(),lift94()
  report(d~=nil and mem:read_u8(d)==94 and mem:read_u8(d+2)==172 and mem:read_u8(d+3)==80 and mem:read_u8(d+4)==35 and mem:read_u8(d+7)==95,
    string.format("%s: Daisy is in room 94 at (172,80), frame 35, colour 95",tag))
  report(d1~=nil and mem:read_u8(d1)==255 and mem:read_u8(d1+2)==64 and mem:read_u8(d1+3)==77 and mem:read_u8(d1+4)==35,
    string.format("%s: daisy1 is hidden (room 255) at (64,77), frame 35",tag))
  report(lb~=nil and mem:read_u8(lb+3)==56,string.format("%s: the lift is up (y=%d)",tag,lb and mem:read_u8(lb+3) or -1))
end

-- run a whole heart demo to the end while asserting it is silent; returns when the monitor says finished
local function watch_demo(tag,n0,pred_extra)
  local silent_viol,frames=0,0
  local ok=waitfor(function()
    frames=frames+1
    if in_mixer() then silent_viol=silent_viol+1 end
    local c=mon.cur
    -- (the frame in which the last update finishes also sees what comes right after the demo)
    if pred_extra and not (c and #mon.demos>n0 and c.n>=250) then pred_extra() end
    return #mon.demos>n0 and c.finished
  end,4000)
  return ok,silent_viol
end

local function demo_report(tag,idx)
  local d=mon.demos[idx]
  if not d then report(false,tag..": no heart demo was monitored"); return end
  report(d.finished and d.n==255,string.format("%s: the demo ran 255 updates (n=%d)",tag,d.n))
  report(d.age_ok and d.path_ok,string.format("%s: ages = 8*i+4*n for every heart and every update, paths = `random` replayed from the seed",tag))
  report(d.bad==0,string.format("%s: every update's pixel change == the reference render XOR (diff bytes %d over %d updates, worst %d)",tag,d.bad,d.n,d.badmax))
  report(d.drawn_max>=10 and d.drawn_total>=255*8,string.format("%s: hearts are really drawn (max %d per update, %d heart-draws in total)",tag,d.drawn_max,d.drawn_total))
  report(d.dir_flipped,string.format("%s: add/sub direction flipped vs the previous demo (hd_dir=$%02x)",tag,d.dir))
  print(string.format("DAISY94 INFO %s: demo took %.1f s of emulated time",tag,(d.t1 or 0)-d.t0))
  if #mon.errors>0 then for _,e in ipairs(mon.errors) do print("DAISY94 INFO monitor: "..e) end mon.errors={} end
end

local function script()
  -- ============ boot ============
  local n,live=0,0
  waitfor(function() n=n+1
    if n%14==0 then key("SPACE",(n//14)%2==0) end
    live=(r("cur_room")==36 and r("dizzy_y")~=0) and live+1 or 0
    return live>=60 end,1500)
  key("SPACE",false)
  mem:write_u8(SYM.coins,5)

  -- ============ 1 records ============
  check_records("boot")
  local d0=daisy94(); local t0=SYM.actor_init_tape_template
  report(mem:read_u8(t0+(d0-SYM.actor_init_tape)+0)==94,"the pristine template holds Daisy in 94 too")

  -- ============ 2 CONTROL: room 73, daisy1's old spot ============
  if not warp(73,64,96) then report(false,"warp to room 73"); return end
  wait(150)
  local d1=daisy73()
  report(r("cur_room")==73 and r("msg_active")==0 and r("completedgame")==0 and mem:read_u8(d1)==255,
    "control: standing where daisy1 used to be (room 73, x=64) starts nothing -- no box, no win, daisy1 still hidden")
  local fb73a=dump_fb(); save_dump("ctl_room73_before",fb73a)

  -- ============ 3 justinlift: the real switch ============
  if not warp(94,60,80) then report(false,"warp to room 94 (60,80)"); return end
  local lb=lift94(); local d=daisy94()
  report(mem:read_u8(d+3)==77 or mem:read_u8(d+3)==80,string.format("in room 94 Daisy sits at y=%d (80 at reset, lift y+21=77 once justinlift has run)",mem:read_u8(d+3)))
  local moved,maxdev,samples,stopped=false,0,0,false
  local t=f
  while f-t<2500 do
    key("RIGHT",true)
    local ly,dy=mem:read_u8(lb+3),mem:read_u8(d+3)
    if ly>56 then moved=true end
    if moved and ly<100 then samples=samples+1; local dev=math.abs(dy-(ly+21)); if dev>maxdev then maxdev=dev end end
    if moved and ly>=100 and mem:read_u8(lb+5)==0 then stopped=true; break end
    coroutine.yield()
  end
  key("RIGHT",false); wait(30)
  local ly,dy=mem:read_u8(lb+3),mem:read_u8(d+3)
  report(moved and stopped,string.format("walking into the switch lowered the lift to y=%d",ly))
  report(dy==ly+21,string.format("at rest Daisy is at lift y + 21 (%d == %d+21)",dy,ly))
  report(samples>=5 and maxdev<=3,string.format("while the lift moved Daisy rode it (%d samples, worst deviation %d px)",samples,maxdev))
  local fbl=dump_fb(); save_dump("lift_lowered",fbl)

  -- ============ 4 CONTROL + the meeting ============
  if not warp(94,140,132) then report(false,"warp onto the table in room 94"); return end
  report(r("dizzy_floor")==1 and r("cur_room")==94 and r("msg_active")==0,string.format("standing on the table at x=%d y=%d, nothing running",r("dizzy_x"),r("dizzy_y")))
  local banner_pre=banners()
  local walked_overlap,viol=0,0
  local got_box=false
  t=f
  while f-t<400 do
    local dx=r("dizzy_x")
    if dx<170 then key("RIGHT",true) else key("RIGHT",false) end
    if dx>=156 and dx<170 and r("dizzy_dir")==2 then
      walked_overlap=walked_overlap+1
      if r("msg_active")==1 or mem:read_u8(d)~=94 then viol=viol+1 end
    end
    if r("msg_active")==1 then got_box=true; break end
    coroutine.yield()
  end
  key("RIGHT",false)
  report(walked_overlap>=3 and viol==0,string.format("control: walking into Daisy (RIGHT held, dizzy_dir=2) for %d frames inside her box started nothing",walked_overlap))
  report(got_box and r("dizzy_dir")==0 and r("jump_on")==0,string.format("releasing the key while overlapping her starts the meeting (dizzy_x=%d)",r("dizzy_x")))
  if not got_box then return end

  -- ============ 5 box 1 + tune ============
  local mix1,sptr1=0,0
  local tb=f
  while f-tb<200 do      -- 200 frames ~ 3.3 s emu with SPACE up: the tune must be playing
    if in_mixer() then mix1=mix1+1; sptr1=mixer_sptr() end
    coroutine.yield()
  end
  report(r("msg_active")==1 and mix1>=100,string.format("box 1: the tune runs under it (%d mixer PC samples in 200 frames, stream pointer $%04x)",mix1,sptr1))
  local fb1=dump_fb(); save_dump("meet_box1",fb1)
  local bad1=tex2(fb1,LINES_GOTTO)
  report(bad1==0,string.format("box 1 shows gottodaisymess verbatim (worst line: %d bad pixels)",bad1))
  report(mem:read_u8(d)==94 and mem:read_u8(daisy73())==255,"box 1: Daisy still in 94, daisy1 still hidden")
  local blob=u16(SYM.tw_base)
  local hid=(r("cur_buf")==0) and 0x6000 or 0x4000
  report(blob==hid+1536,string.format("the tune's blob sits in the HIDDEN framebuffer, below the banner rows ($%04x = $%04x + 1536)",blob,hid))

  -- dismiss box 1, then the demo must run (silent) before box 2
  local sp1_last=sptr1
  local nn=0
  local demo_started=false
  waitfor(function() nn=nn+1; key("SPACE",(nn%26)<8)
    if in_mixer() then sp1_last=mixer_sptr() end
    if in_hearts() then demo_started=true end
    return demo_started end,600)
  key("SPACE",false)
  report(demo_started and r("msg_active")==0,"after SPACE the heart demo starts (no box up)")
  local d1rec=daisy73()
  local order_viol=0
  local ok,silent=watch_demo("meeting",0,function()
    if mem:read_u8(d)~=94 or mem:read_u8(d1rec)~=255 then order_viol=order_viol+1 end
    if r("msg_active")==1 then order_viol=order_viol+1 end
  end)
  report(ok,"the heart demo finished")
  report(silent==0,"the demo is SILENT (the mixer never ran during it)")
  report(order_viol==0,"during the demo Daisy is still in 94 and daisy1 still hidden, no box up (they move after it, as the original)")
  demo_report("meeting",1)

  -- ============ 7 box 2 ============
  local got2=waitfor(function() return r("msg_active")==1 end,600)
  report(got2,"box 2 (daisyrunsmess) comes up after the demo")
  report(mem:read_u8(d)==255 and mem:read_u8(daisy73())==73,string.format("at box 2 Daisy has left 94 (room %d) and daisy1 is in 73 (room %d)",mem:read_u8(d),mem:read_u8(daisy73())))
  local mix2,sptr2=0,nil
  tb=f
  while f-tb<200 do
    if in_mixer() then mix2=mix2+1; if not sptr2 then sptr2=mixer_sptr() end end
    coroutine.yield()
  end
  report(mix2>=100,string.format("box 2: the tune resumes under it (%d mixer samples)",mix2))
  report(sptr2~=nil and sptr2>=sp1_last-8 and sptr2<sp1_last+400,string.format("the tune CONTINUES where box 1 stopped (stream pointer $%04x -> $%04x), not restarted",sp1_last,sptr2 or 0))
  local fb2=dump_fb(); save_dump("meet_box2",fb2)
  local bad2=tex2(fb2,LINES_RUNS)
  report(bad2==0,string.format("box 2 shows daisyrunsmess verbatim (worst line: %d bad pixels)",bad2))
  nn=0
  waitfor(function() nn=nn+1; key("SPACE",(nn%26)<8); return r("msg_active")==0 and not in_msgwait() and not in_audio() end,900)
  key("SPACE",false); wait(60)

  -- ============ 8 afterwards ============
  report(r("cur_room")==94 and r("killed")==0 and r("msg_active")==0,"play resumes in room 94")
  local fb94=dump_fb(); save_dump("after_meeting_94",fb94)
  wait(40)
  local bd=banner_diff(banner_pre,banners())
  report(bd==0,string.format("both framebuffers still hold the banner art of room 94 after the meeting (%d differing bytes in rows 0..47; the tune's blob must not leave garbage there)",bd))
  -- Daisy's old pixels (172..196, lift y+21 ..+19) must be blank of her now: compare against the lowered-lift dump
  local x0,x1,yy0,yy1=21,24,mem:read_u8(lb+3)+21,mem:read_u8(lb+3)+21+18
  local diff=0
  for row=yy0,yy1 do for col=x0,x1 do if fb94[row*32+col]~=fbl[row*32+col] then diff=diff+1 end end end
  report(diff>=20,string.format("room 94 no longer draws Daisy (%d bytes differ from the picture with her, over her 4x19 byte box)",diff))
  if not warp(73,92,96) then report(false,"warp to room 73 afterwards"); return end
  wait(30)
  report(r("cur_room")==73,"still in room 73 beside daisy1 (not fallen through)")
  local fb73b=dump_fb(); save_dump("daisy1_in_73",fb73b)
  local dd=0
  for row=77,95 do for col=8,10 do if fb73b[row*32+col]~=fb73a[row*32+col] then dd=dd+1 end end end
  report(dd>=15,string.format("room 73 now draws daisy1 at (64,77) (%d bytes differ from the dump taken before the meeting)",dd))
  report(r("msg_active")==0 and r("completedgame")==0,"standing right beside daisy1 (not overlapping) starts nothing")

  -- ============ 9 game over resets ============
  do
    mem:write_u8(SYM.lives,0); mem:write_u8(SYM.killed,1)
    local boxn=0
    local ok2=waitfor(function()
      boxn=boxn+1
      key("SPACE",(boxn%26)<8)
      return r("cur_room")==36 and r("lives")==2 and r("dizzy_y")~=0 and boxn>200
    end,3000)
    key("SPACE",false)
    report(ok2,string.format("game over -> new game (room %d, lives %d)",r("cur_room"),r("lives")))
    wait(40)
    check_records("after game over")
    report(mem:read_u8(daisy94()+3)==80,"Daisy's y is back at 80")
  end

  -- ============ 10 the win: the SECOND demo of the session ============
  mem:write_u8(SYM.coins,30)
  mem:write_u8(daisy73(),73)       -- (the meeting above was reset by the game over)
  mem:write_u8(SYM.lives,2)
  mem:write_u8(SYM.respawn_room,73); mem:write_u8(SYM.respawn_x,64)
  mem:write_u8(SYM.respawn_y,96); mem:write_u8(SYM.killed,1)
  local nd=#mon.demos
  local pulse=0
  waitfor(function() pulse=pulse+1
    if (in_msgwait() or in_audio()) and not in_hearts() then key("SPACE",(pulse//14)%2==0) else key("SPACE",false) end
    return #mon.demos>nd end,3000)
  report(#mon.demos>nd and r("completedgame")==1,"win: the heart demo runs after the gotallcoins boxes (completedgame=1)")
  local ok3,silent3=watch_demo("win",nd)
  key("SPACE",false)
  report(ok3,"win: the heart demo finished")
  report(silent3==0,"win: the demo is silent too")
  demo_report("win",2)
  -- then the title
  local tt=waitfor(function() key("SPACE",false); return in_title_wait() end,2000)
  report(tt,"win: the title replay follows the demo")

  -- ============ 11 win -> new game restores ============
  nn=0
  waitfor(function() nn=nn+1; key("SPACE",nn<30)
    return nn>40 and not in_title_wait() and r("completedgame")==0 and r("cur_room")==36 and r("dizzy_y")~=0 end,2400)
  key("SPACE",false); wait(40)
  check_records("after the win")
  print(string.format("DAISY94 SUMMARY pass=%d fail=%d",pass,fail))
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
  if not ok then print("DAISY94 FAIL harness error: "..tostring(err)); manager.machine:exit() end
  if coroutine.status(co)=="dead" and not os.getenv("NOEXIT") then manager.machine:exit() end
end)
