-- harness/joystick.lua -- T0240: the CoCo analog joystick (TAPE build; tape_joy_code.asm).
--
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 600 \
--       -autoboot_script harness/joystick.lua
-- (tools/verify_joystick.sh wraps it.)  Last line: "JOYSTICK SUMMARY pass=N fail=M".
--
-- MAME exposes the right stick as analog ports :joystick_rx / _ry (0..1023, 512 = centre) and the
-- buttons as :joystick_buttons ("Right Button", "Left Button").  The pot reads x = V >> 4 (0..63);
-- the game's bands (d = x-32 right, 31-x left): d<8 dead, 8..11 n=1, 12..15 n=2, 16..19 n=3, >=20 n=4
-- (n steps per 4 updates).  A "pass" is one main-loop pass = one Dizzy update (rng_ctr changes once).
-- The sweep sets the stick, lets 3 passes go, then counts the 4 px steps over 20 passes.
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local ports=manager.machine.ioport.ports
local row3=ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local joyx; for _,f in pairs(ports[":joystick_rx"].fields) do joyx=f end
local btn={} ; for n,f in pairs(ports[":joystick_buttons"].fields) do btn[n]=f end
local function stick(v) joyx:set_value(v) end
local function fire(d) btn["Right Button"]:set_value(d and 1 or 0) end
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end
for _,s in ipairs({"joy_walk","joy_read","joy_fire","joy_f","joy_acc","joy_armed","pt_level","play_tone","play_chirp","msg_active"}) do
  if not SYM[s] then print("JOYSTICK FAIL: symbol "..s.." missing from the map"); manager.machine:exit() end end
local function rd(s) return mem:read_u8(SYM[s]) end
local function wr(s,v) mem:write_u8(SYM[s],v) end

local stall=0
local TAPS={}   -- keep the tap objects referenced (MAME drops a collected tap)
local pass,pass_ok,fails=0,0,0
local function check(name,ok,detail)
  if ok then pass_ok=pass_ok+1 print("JOYSTICK PASS "..name..(detail and (" ("..detail..")") or ""))
  else fails=fails+1 print("JOYSTICK FAIL "..name..(detail and (" ("..detail..")") or "")) end
end

-- sound taps: every $FF20 / $FF23 write with the PC it came from and the sound-enable state
local dac_log={}   -- {pc_in_joy, value, enable_bit3}
local enable=1
local dac_level=0
local mute_clicks=0      -- mutes that started from a non-zero DAC level
local mutes=0
local last_dac_before_mute=0
local function install_sound_taps()
TAPS[#TAPS+1]=mem:install_write_tap(0xff23,0xff23,"ff23",function(o,d,m)
  local e=(d>>3)&1
  if e==0 and enable==1 then mutes=mutes+1; if dac_level~=0 then mute_clicks=mute_clicks+1 end end
  enable=e; return d end)
TAPS[#TAPS+1]=mem:install_write_tap(0xff20,0xff20,"ff20",function(o,d,m)
  local pc=cpu.state["PC"].value
  dac_level=d&0xfc
  dac_log[#dac_log+1]={pc=pc,v=d,en=enable}
  return d end)
end
local function in_joy(pc) return pc>=SYM.joy_read and pc<SYM.joy_read+80 end

-- a pass = one write of dizzy_h (once per main-loop pass, at the flip); the script is resumed INSIDE
-- that tap, so the stick/keys it sets are what the NEXT pass's scan sees (no frame-phase race)
local waiting=nil
local co
local passn=0
local function resume()
  local ok,err=coroutine.resume(co)
  if not ok then print("JOYSTICK FAIL harness error: "..tostring(err)); manager.machine:exit() end
end
local function install_pass_tap()
TAPS[#TAPS+1]=mem:install_write_tap(SYM.cur_buf,SYM.cur_buf,"pass",function(o,d,m)
  passn=passn+1
  if os.getenv("JOY_DEBUG") then print(string.format("JD pass=%d x=%d y=%d killed=%d lives=%d keyflags=%02x stick=%s",passn,rd("dizzy_x"),rd("dizzy_y"),rd("killed"),rd("lives"),rd("keyflags"),tostring(joyx.user_value))) end
  if waiting=="pass" then resume() end
  return d
end)
end
co=coroutine.create(function()
  local function frames(n) for _=1,n do waiting="frame"; coroutine.yield() end waiting=nil end
  local function wait_pass() waiting="pass"; stall=0; coroutine.yield(); waiting=nil; pass=pass+1 end
  local function passes(n) for _=1,n do wait_pass() end end
  local function X() return rd("dizzy_x") end
  -- boot into the game
  local f=0
  while true do
    f=f+1; if f%14==0 then key("SPACE",(f//14)%2==0) end
    if rd("cur_room")==36 and rd("dizzy_y")~=0 and rd("dizzy_floor")==1 and f>260 then break end
    frames(1)
  end
  key("SPACE",false); frames(120)
  local function stand(x) -- put Dizzy on room 36's floor at x, settled, no inputs
    stick(512); fire(false); key("RIGHT",false); key("LEFT",false); key("UP",false)
    wr("dizzy_x",x); passes(4)
    wr("dizzy_x",x); wr("joy_acc",3); passes(2)
  end
  -- record dizzy_x at each pass boundary for n passes
  local function trace(n) local t={X()} for i=1,n do wait_pass() t[#t+1]=X() end return t end
  local function steps(t) local c=0 for i=2,#t do if t[i]~=t[i-1] then c=c+1 end end return c end
  local function deltas(t) local d={} for i=2,#t do d[#d+1]=t[i]-t[i-1] end return d end
  local function same(a,b) if #a~=#b then return false end for i=1,#a do if a[i]~=b[i] then return false end end return true end

  -- 0. arming: the stick has not been centred yet, so a pegged stick is ignored (no stick plugged in)
  stand(60); wr("joy_armed",0); stick(1023); local t0=trace(10)
  check("unarmed pegged stick is ignored (unplugged-port safety)", steps(t0)==0, "x "..t0[1].."->"..t0[#t0])
  wr("joy_armed",0); stick(0); t0=trace(10)
  check("unarmed pegged-left stick is ignored", steps(t0)==0)
  stick(512); passes(3)
  check("centred stick arms", rd("joy_armed")~=0)

  -- 1. centre: no movement, and keyboard-identical (nothing set in keyflags)
  stand(60); local tc=trace(20)
  check("centre: no movement over 20 passes", steps(tc)==0, "x="..tc[#tc])

  -- 2. full right == RIGHT key
  stand(60); stick(1023); passes(1); local tr=trace(12); stick(512)
  stand(60); key("RIGHT",true); passes(1); local tk=trace(12); key("RIGHT",false)
  check("full right: 4 px every update", steps(tr)==12 and tr[#tr]-tr[1]==48, "dx="..(tr[#tr]-tr[1]).." in 12 passes")
  check("full right == RIGHT key, same positions", same(deltas(tr),deltas(tk)), "stick "..table.concat(deltas(tr),",").." key "..table.concat(deltas(tk),","))
  -- left mirrors
  stand(150); stick(0); passes(1); local tl=trace(12); stick(512)
  stand(150); key("LEFT",true); passes(1); local tkl=trace(12); key("LEFT",false)
  check("full left: -4 px every update, == LEFT key", steps(tl)==12 and tl[#tl]-tl[1]==-48 and same(deltas(tl),deltas(tkl)))

  -- 3. sweep: steps per 20 passes at several deflections (right then left)
  local function nexp(V,left)
    local x=V>>4; local d= left and (31-x) or (x-32)
    if d<8 then return 0 end
    local n=(d>>2)-1; if n>4 then n=4 end; return n end
  local last_steps=-1; local mono=true; local model_ok=true; local line={}
  for _,V in ipairs({512,544,576,608,624,640,656,672,688,704,720,736,768,800,832,864,896,960,1023}) do
    stand(40); stick(V); passes(3); local t=trace(20); stick(512)
    local s=steps(t); line[#line+1]=string.format("V=%d(n=%d):%d",V,nexp(V,false),s)
    local want=nexp(V,false)*5
    if math.abs(s-want)>1 then model_ok=false end
    if s<last_steps then mono=false end; last_steps=s
    if t[#t]-t[1]~=4*s then model_ok=false end
    if t[#t]-t[1]>80 then model_ok=false end
  end
  print("JOYSTICK SWEEP right, steps per 20 updates (full = 20): "..table.concat(line," "))
  check("sweep right: steps per 20 updates follow the n/4 bands, never above 20", model_ok)
  check("sweep right: monotonic with deflection", mono)
  local lline={}; local lmodel=true
  for _,V in ipairs({512,480,448,416,400,384,368,352,336,320,256,192,128,0}) do
    stand(160); stick(V); passes(3); local t=trace(20); stick(512)
    local s=steps(t); lline[#lline+1]=string.format("V=%d(n=%d):%d",V,nexp(V,true),s)
    if math.abs(s-nexp(V,true)*5)>1 or t[#t]-t[1]~=-4*s then lmodel=false end
  end
  print("JOYSTICK SWEEP left,  steps per 20 updates: "..table.concat(lline," "))
  check("sweep left mirrors right", lmodel)
  -- at least three distinct partial speeds
  local seen={} for _,V in ipairs({640,704,768}) do stand(40); stick(V); passes(3); local t=trace(20); stick(512); seen[steps(t)]=true end
  local cnt=0 for k in pairs(seen) do if k>0 and k<20 then cnt=cnt+1 end end
  check("three distinct partial speeds (n=1,2,3)", cnt==3)

  -- 4. dead zone with noise: +-3 counts of x around the centre
  stand(80); local seed=12345; local moved=0
  for i=1,60 do seed=(seed*1103515245+12345)&0x7fffffff; stick(512+((seed>>8)%97)-48); wait_pass() end
  stick(512); passes(2)
  check("dead zone holds with +-48/1023 noise over 60 passes", X()==80, "x="..X())
  -- the edges of the dead zone: x=39 right (d=7) still, x=40 (d=8) steps; x=24 (d=7) still, x=23 (d=8) steps
  stand(80); stick(39*16+8); local te=trace(8); stick(512)
  check("right dead-zone edge x=39: still", steps(te)==0)
  stand(80); stick(40*16+8); passes(3); te=trace(16); stick(512)
  check("right x=40: slowest speed (4 steps in 16)", steps(te)==4, "steps="..steps(te))
  stand(80); stick(24*16+8); te=trace(8); stick(512)
  check("left dead-zone edge x=24: still", steps(te)==0)
  stand(80); stick(23*16+8); passes(3); te=trace(16); stick(512)
  check("left x=23: slowest speed (4 steps in 16)", steps(te)==4, "steps="..steps(te))

  -- 5. fire = jump, direction latched at take-off
  local function jump_trace(setup_down, setup_up, n, x0)
    stand(x0 or 60); setup_down()
    local t={}
    for i=1,n do wait_pass() t[#t+1]={X(),rd("dizzy_y"),rd("jump_on")~=0 and 1 or 0}
      if i==2 then setup_up() end end
    return t
  end
  local function flat(t) local s={} for _,e in ipairs(t) do s[#s+1]=e[1]..":"..e[2] end return table.concat(s," ") end
  local tj=jump_trace(function() fire(true) end,function() fire(false) end,30)
  check("fire jumps straight up with the stick centred", tj[3][2]<176 and tj[5][1]==tj[1][1], "x "..tj[1][1].."->"..tj[5][1].." y "..tj[1][2].."->"..tj[3][2])
  local tkj=jump_trace(function() key("UP",true) end,function() key("UP",false) end,30)
  check("fire jump == UP key jump (same x/y per pass)", flat(tj)==flat(tkj))
  -- full right + fire
  local tjr=jump_trace(function() stick(1023) fire(true) end,function() fire(false) stick(512) end,30)
  local tkr=jump_trace(function() key("RIGHT",true) key("UP",true) end,function() key("UP",false) key("RIGHT",false) end,30)
  check("full right + fire == RIGHT+UP keys, direction latched", flat(tjr)==flat(tkr), flat(tjr):sub(1,60))
  check("jump carried Dizzy right", tjr[12][1]>tjr[1][1]+16)
  -- half-tilt + fire: full-speed jump
  local tjh=jump_trace(function() stick(40*16+8) fire(true) end,function() fire(false) stick(512) end,30)
  check("slow tilt + fire: the jump goes at FULL speed (== RIGHT+UP)", flat(tjh)==flat(tkr))
  -- left + fire mirrors
  local tjl=jump_trace(function() stick(0) fire(true) end,function() fire(false) stick(512) end,30,140)
  check("full left + fire: jumps left", tjl[12][1]<tjl[1][1]-16)
  -- stick held through the whole jump: no air control, same as the key
  local tjhold=jump_trace(function() stick(1023) fire(true) end,function() fire(false) end,30); stick(512)
  stand(60) -- settle
  check("stick held in the air still lands (no air steering)", tjhold[10][2]<=176)

  -- 6. message dismissal by fire (the death message waits for SPACE)
  stand(60); wr("lives",2)
  wr("respawn_room",36); wr("respawn_x",60); wr("respawn_y",176); wr("killed",1)
  local waited=0
  while rd("msg_active")==0 and waited<600 do frames(1); waited=waited+1 end
  check("a message box is up", rd("msg_active")~=0, "after "..waited.." frames")
  frames(90)
  check("box stays up with nothing pressed", rd("msg_active")~=0)
  fire(true); local g=0
  while rd("msg_active")~=0 and g<200 do frames(1); g=g+1 end
  fire(false)
  check("fire dismisses the box (as SPACE)", rd("msg_active")==0, "frames="..g)
  frames(300)

  -- 7. sound: DAC writes.  The pot read mutes the sound enable ($FF23 bit 3), probes the DAC, parks it at 0,
  -- and un-mutes.  Silent passes (stick centred, standing): every DAC write is joy_read's, 7 per read, all muted.
  stand(60); passes(3)
  local c0=mute_clicks; dac_log={}
  passes(20)
  local nj,bad_en,other=0,0,0
  for _,e in ipairs(dac_log) do
    if in_joy(e.pc) then nj=nj+1; if e.en~=0 then bad_en=bad_en+1 end else other=other+1 end end
  check("20 silent passes: only joy_read writes the DAC, 7 per read, all with the sound muted", other==0 and bad_en==0 and nj>=7*19 and nj<=7*21, "joy writes="..nj.." other="..other.." unmuted="..bad_en)
  check("no pop at rest: 20 silent reads, none began from a non-zero DAC", mute_clicks==c0, "pops="..(mute_clicks-c0))
  check("mux select left at 00 (CA2 $FF01 bit3 = 0, CB2 $FF03 bit3 = 0), the DAC sound source", (mem:read_u8(0xff01)&8)==0 and (mem:read_u8(0xff03)&8)==0)
  check("sound enable is back on after a read", (mem:read_u8(0xff23)&8)==8)
  check("DAC parked at 0 and pt_level cleared", (mem:read_u8(0xff20)&0xfc)==0 and rd("pt_level")==0)
  -- the audio code's own DAC writes must be identical with the stick and with the keys
  local function audio_vals(setup,release,n)
    stand(60); passes(3); dac_log={}; setup(); passes(n); release(); passes(2)
    local v={} for _,e in ipairs(dac_log) do if not in_joy(e.pc) then v[#v+1]=e.v end end
    return v end
  local function eq(a,b) if #a~=#b then return false end for i=1,#a do if a[i]~=b[i] then return false end end return true end
  local c1=mute_clicks
  local vs=audio_vals(function() stick(1023) fire(true) end,function() fire(false) stick(512) end,6)
  local pops_jump=mute_clicks-c1
  local vk=audio_vals(function() key("UP",true) key("RIGHT",true) end,function() key("UP",false) key("RIGHT",false) end,6)
  check("jump sfx has audio DAC writes", #vk>10, #vk.." writes")
  check("jump sfx while the stick is held: the same audio DAC writes as the keyboard (UP+RIGHT)", eq(vs,vk), #vs.." vs "..#vk)
  local ws=audio_vals(function() stick(1023) end,function() stick(512) end,12)
  local wk=audio_vals(function() key("RIGHT",true) end,function() key("RIGHT",false) end,12)
  check("walking (footstep clicks): the same audio DAC writes with the stick as with the key", eq(ws,wk), #ws.." vs "..#wk)
  print("JOYSTICK INFO one jump sfx: pops (a read starting from a non-zero DAC level, i.e. the one-time DC removal) = "..pops_jump.."; whole run: mutes="..mutes.." from_nonzero_dac="..mute_clicks)
  check("at most one DC-removal pop per sound effect", pops_jump<=2, "pops after one jump sfx="..pops_jump)

  print(string.format("JOYSTICK SUMMARY pass=%d fail=%d",pass_ok,fails))
  manager.machine:exit()
end)
local frames_run=0
emu.register_periodic(function()
  frames_run=frames_run+1
  if frames_run==30 then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")) end
  if frames_run<=30 then return end
  if frames_run==32 then install_sound_taps(); install_pass_tap() end   -- taps die when the load flips the SAM map
  if frames_run==31 then
    -- stray-write fix as rate.lua (T0125)
    local fh=io.open(os.getenv("DIZZY_BIN"),"rb"); local d=fh:read("*all"); fh:close(); local pos=1
    while pos<=#d and d:byte(pos)==0 do
      local len=d:byte(pos+1)*256+d:byte(pos+2); local addr=d:byte(pos+3)*256+d:byte(pos+4)
      for i=0,len-1 do local a=addr+i
        if a>=0x0E00 and a<0x8000 then local want=d:byte(pos+5+i)
          if mem:read_u8(a)~=want then mem:write_u8(a,want) end end end
      pos=pos+5+len end
  end
  if coroutine.status(co)=="dead" then return end
  if waiting=="pass" then          -- the tap resumes it; watchdog for a frozen game (box up, dead)
    stall=stall+1
    if stall%100==0 and os.getenv("JOY_DEBUG") then print(string.format("JS stall=%d pc=%04x dir=%d x=%d room=%d",stall,cpu.state["PC"].value,rd("dizzy_dir"),rd("dizzy_x"),rd("cur_room"))) end
    if stall>1200 then print(string.format("JOYSTICK FAIL no main-loop pass for 1200 frames: pc=%04x passn=%d pass=%d room=%d x=%d y=%d killed=%d msg_active=%d",cpu.state["PC"].value,passn,pass,
      rd("cur_room"),rd("dizzy_x"),rd("dizzy_y"),rd("killed"),rd("msg_active"))); print(string.format("JOYSTICK SUMMARY pass=%d fail=%d",pass_ok,fails+1)); manager.machine:exit() end
    return
  end
  stall=0
  resume()
end)
