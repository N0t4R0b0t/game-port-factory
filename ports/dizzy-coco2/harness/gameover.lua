-- harness/gameover.lua -- T0114: losing the last life goes back to the
-- TITLE SCREEN, and SPACE there starts a genuinely NEW game.
--
-- X-ALL.TXT: after the death box, `ld a,(lives) / and a / jp nz,nextlife`,
-- otherwise `quitted` ... `jp titlescreen`; the title loop then runs
-- resetmoving/resetcoins/resetcarrying/resetlives and nextlife, so a game
-- starts with 2 spare lives (3 set, one used).
--
-- Plays a game long enough to fake some progress (coins, a carried item,
-- dragon asleep, troll bribed, portcullis thrown), sets lives to 0 and
-- kills Dizzy. Checks:
--   start_lives   a new game shows 2 spare lives
--   title         the CPU reaches the title code and the screen's top rows
--                 are the title art again (= BANNER_BUF)
--   title_waits   it stays on the title for 90 frames with no key
--   reset         after SPACE: room 36, lives 2, coins 0, hands empty,
--                 dragon/troll/gate state cleared
--   machine       DP is 0 and the stack is back near $0100 (new_game resets
--                 it; update_death's frame was abandoned by the jump)
--
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 120 \
--     -autoboot_script harness/gameover.lua
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
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end
-- T0146: the game no longer returns to the TITLE when the last life goes; it
-- shows a GAME OVER message box and waits for a key (the user's deliberate
-- memory trade -- the packed title stream is boot-transient now). So this
-- harness asserts the BOX, not the title art. show_title_again is gone.
for _,s in ipairs({"msg_wait_dismiss","fb_stablekeys","msg_gameover","lz_unpack","new_game","lives","coins","inv",
                   "dragon_asleep","troll_bribed","actor_ram","BANNER_BUF","cur_room","dizzy_y","killed"}) do
  if not SYM[s] then print("GAMEOVER FAIL: symbol "..s.." missing from the map") end
end
local function r(s) return mem:read_u8(SYM[s]) end
-- T0146: "is the GAME OVER box up and blocking for a key?" A once-per-frame PC
-- sample almost never lands inside msg_wait_dismiss itself -- the loop spends
-- its time in fb_stablekeys/wait_vsync -- so look for the loop's own return
-- address on the 6809 stack too, exactly as tiecroc.lua does for the
-- inventory. (in_title() used to serve this role for the title screen.)
local function stack_has(lo,hi)
  local sp=cpu.state["S"].value
  for i=0,63,1 do if sp+i+1>=0x100 then break end
    local a=mem:read_u8(sp+i)*256+mem:read_u8(sp+i+1)
    if a>=lo and a<hi then return true end
  end
  return false
end
local function in_gameover_box()
  local p=cpu.state["PC"].value
  if p>=SYM.msg_wait_dismiss and p<SYM.fb_stablekeys then return true end
  return stack_has(SYM.msg_wait_dismiss,SYM.fb_stablekeys)
end
-- (T0146: title_on_screen() deleted with the title-return behaviour it checked.)
local function gate()
  for i=0,19 do local b=SYM.actor_ram+i*8
    if mem:read_u8(b+1)==0 and mem:read_u8(b+4)==120 then return b end end
end
local f,loaded,stage,t=0,false,"boot",0
local R={}
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    -- T0146: in_title() is gone. "The game is actually running" is a stable
    -- room 36 with Dizzy placed, held for 30 frames -- the title's own code
    -- never satisfies that, so no PC heuristic is needed here.
    R.boot_n = (r("cur_room")==36 and r("dizzy_y")~=0) and (R.boot_n or 0)+1 or 0
    if R.boot_n>=30 then key("SPACE",false); stage="play"; t=f end
  elseif stage=="play" then
    if f-t==150 then
      R.start_lives = r("lives")
      -- fake progress, then lose the last life
      mem:write_u8(SYM.coins,5)
      mem:write_u8(SYM.inv,1)
      mem:write_u8(SYM.dragon_asleep,1)
      mem:write_u8(SYM.troll_bribed,1)
      local g=gate(); if g then mem:write_u8(g+5,254); mem:write_u8(g+6,2) end
      mem:write_u8(SYM.lives,0)
      mem:write_u8(SYM.killed,1)
      stage="dying"; t=f
    end
  elseif stage=="dying" then
    -- T0146: losing the last life shows TWO boxes back to back -- the death
    -- window, then GAME OVER -- and both block in the same msg_wait_dismiss
    -- loop, so they cannot be told apart by PC or by lives. Tapping SPACE
    -- blindly (what this stage used to do) dismisses both and the game-over
    -- box is never observed. So: wait for the FIRST box, dismiss it with
    -- exactly one press+release, and whatever is still blocking after that
    -- is the GAME OVER box.
    if not R.box1 then
      key("SPACE",false)
      if in_gameover_box() then R.box1=true; R.press_at=f end
      if f-t>900 then print("GAMEOVER FAIL: no death box after the last life"); stage="done" end
    elseif f-R.press_at<8 then
      key("SPACE",true)                      -- one clean press...
    elseif f-R.press_at<24 then
      key("SPACE",false)                     -- ...and release, then settle
    else
      if in_gameover_box() then
        stage="title"; t=f; R.title_pc=true; R.title_frames=0
      elseif f-R.press_at>200 then
        print("GAMEOVER FAIL: nothing blocked for a key after the death box")
        stage="done"
      end
    end
  elseif stage=="title" then
    key("SPACE",false)
    local a=f-t
    if in_gameover_box() then R.title_frames=R.title_frames+1 end
    if a==40 then R.title_screen = in_gameover_box() end
    if a==90 then R.title_waits = (R.title_frames>=85); key("SPACE",true); stage="press"; t=f end
  elseif stage=="press" then
    key("SPACE", f-t<10)
    if f-t>=10 and not in_gameover_box() and r("cur_room")==36 and r("dizzy_y")~=0 then stage="newgame"; t=f end
    if f-t>900 then print("GAMEOVER FAIL: SPACE on the GAME OVER box never started a game"); stage="done" end
  elseif stage=="newgame" then
    key("SPACE",false)
    if f-t==60 then
      local g=gate()
      R.lives=r("lives"); R.coins=r("coins"); R.inv0=r("inv")
      R.dragon=r("dragon_asleep"); R.troll=r("troll_bribed"); R.gate_v1=g and mem:read_u8(g+5) or -1
      R.dp=cpu.state["DP"].value; R.s=cpu.state["S"].value
      local reset = R.lives==2 and R.coins==0 and R.inv0==0 and R.dragon==0 and R.troll==0 and R.gate_v1==0
      local machine = R.dp==0 and R.s>=0x00B0 and R.s<=0x0100
      local ok = R.start_lives==2 and R.title_pc and R.title_screen and R.title_waits and reset and machine
      print(string.format("GAMEOVER %s start_lives=%s box_reached=%s box_on_screen=%s box_waits=%s | new game: room=%d lives=%d coins=%d inv0=%d dragon_asleep=%d troll_bribed=%d gate_v1=%d | DP=$%02X S=$%04X",
        ok and "PASS" or "FAIL", tostring(R.start_lives), tostring(R.title_pc), tostring(R.title_screen), tostring(R.title_waits),
        r("cur_room"), R.lives, R.coins, R.inv0, R.dragon, R.troll, R.gate_v1, R.dp, R.s))
      stage="done"; manager.machine:exit()
    end
  end
end)
