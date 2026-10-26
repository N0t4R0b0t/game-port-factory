-- harness/gameover_floppy.lua -- T0241: gameover_tape.lua for the FLOPPY build: the title replay after game over
-- is no longer a resident copy but OVERLAY 0 read from DIZZY.OVL through the real MAME FDC (~2 s emulated). Run
-- through tools/mame_floppy.sh with DIZZY_BIN/DIZZY_MAP=the _floppy files and TITLE_IMAGE=/tmp/stage_floppy_title_raw.bin.
-- (original header follows)
-- harness/gameover_tape.lua -- T0231: TAPE_ROOMS builds restore X-ALL.TXT
-- fidelity at game over (`quitted` -> `jp titlescreen`) via the resident
-- title-image+music copy in the tape-only region (boot_code.asm's
-- show_title_resident), instead of the -run build's T0146 msg_gameover
-- text box. This is gameover.lua's own scenario (fake progress, force a
-- death at 0 lives), aimed at target/room36_tape.bin, and extended to:
--   1. assert the death box is followed STRAIGHT by the title (no second
--      "GAME OVER" text box in this build -- gp_ud_gameover's TAPE_ROOMS
--      branch skips msg_gameover entirely)
--   2. assert framebuffer A matches the real title image once the title's
--      SPACE-wait is reached (titleverify.lua's own check, reused)
--   3. assert SPACE on the title starts a genuinely new game (room 36,
--      lives reset, progress cleared, DP/stack sane -- gameover.lua's own
--      "reset"/"machine" checks, reused)
--   4. force a SECOND game over and repeat all of the above, to catch the
--      state leak a real playtest previously reported (flicker/crashes on
--      a second title entry) -- TITLE_RAW_BUF/MIX3_BUF/CUR_ROOM_CMASK
--      aliasing must survive being re-used a second time.
--
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--   TITLE_IMAGE=/tmp/title_raw.bin \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 180 \
--     -autoboot_script harness/gameover_tape.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
-- T0230's all-RAM-aware load_decb (jumptrace.lua) -- room36_tape.bin
-- carries a real block at $8000+ (the tape-only region), which a plain
-- write loop would silently drop under ROM mode.
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end
for _,s in ipairs({"msg_wait_dismiss","fb_stablekeys","new_game","lives","coins","inv",
                   "dragon_asleep","troll_bribed","actor_ram","BANNER_BUF","cur_room","dizzy_y","killed",
                   "show_title_resident","ovl_load","TITLE_RESIDENT_LEN"}) do
  if not SYM[s] then print("GAMEOVER_FLOPPY FAIL: symbol "..s.." missing from the map") end
end
local fh=io.open(os.getenv("TITLE_IMAGE") or "/tmp/title_raw.bin","rb"); local want=fh:read("*all"); fh:close()
local function r(s) return mem:read_u8(SYM[s]) end
local function stack_has(lo,hi)
  local sp=cpu.state["S"].value
  for i=0,63,1 do if sp+i+1>=0x100 then break end
    local a=mem:read_u8(sp+i)*256+mem:read_u8(sp+i+1)
    if a>=lo and a<hi then return true end
  end
  return false
end
local function in_death_box()
  local p=cpu.state["PC"].value
  if p>=SYM.msg_wait_dismiss and p<SYM.fb_stablekeys then return true end
  return stack_has(SYM.msg_wait_dismiss,SYM.fb_stablekeys)
end
-- titleverify.lua's own "is the title up, waiting on SPACE" check.
local function in_title_wait()
  local pc=cpu.state["PC"].value
  return (SYM.MIX3_BUF and pc>=SYM.MIX3_BUF and pc<SYM.MIX3_BUF+3072)
      or (SYM.play_tone and SYM.play_chirp and pc>=SYM.play_tone and pc<SYM.play_chirp)
end
local function gate()
  for i=0,19 do local b=SYM.actor_ram+i*8
    if mem:read_u8(b+1)==0 and mem:read_u8(b+4)==120 then return b end end
end
local function title_matches()
  local bad=0
  for i=0,6143 do if mem:read_u8(0x4000+i)~=want:byte(i+1) then bad=bad+1 end end
  return bad==0, bad
end

local f,loaded,stage,t=0,false,"boot",0
local R={round=1}
local function force_death()
  mem:write_u8(SYM.coins,5)
  mem:write_u8(SYM.inv,1)
  mem:write_u8(SYM.dragon_asleep,1)
  mem:write_u8(SYM.troll_bribed,1)
  local g=gate(); if g then mem:write_u8(g+5,254); mem:write_u8(g+6,2) end
  mem:write_u8(SYM.lives,0)
  mem:write_u8(SYM.killed,1)
end
local function finish(ok)
  print(string.format("GAMEOVER_FLOPPY %s (rounds=%d) %s", ok and "PASS" or "FAIL", R.round-1,
    table.concat(R.log or {}, " | ")))
  manager.machine:exit()
end
R.log={}
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    R.boot_n = (r("cur_room")==36 and r("dizzy_y")~=0) and (R.boot_n or 0)+1 or 0
    if R.boot_n>=30 then key("SPACE",false); stage="play"; t=f end
  elseif stage=="play" then
    if f-t==150 then
      R.start_lives = r("lives")
      force_death()
      stage="dying"; t=f
    end
  elseif stage=="dying" then
    -- Wait for the (only) death box, dismiss it with one clean press+
    -- release, then it must go STRAIGHT to the title -- no second box.
    if not R.box1 then
      key("SPACE",false)
      if in_death_box() then R.box1=true; R.press_at=f end
      if f-t>900 then table.insert(R.log,"no death box after the last life"); finish(false) end
    elseif f-R.press_at<8 then
      key("SPACE",true)
    elseif f-R.press_at<24 then
      key("SPACE",false)
    else
      if in_title_wait() then
        stage="title"; t=f; R.title_frames=0
      elseif in_death_box() then
        table.insert(R.log,string.format("round %d: a SECOND box blocked after the death box (msg_gameover not skipped?)",R.round))
        finish(false)
      elseif f-R.press_at>1800 then
        table.insert(R.log,string.format("round %d: title never reached after the death box",R.round))
        finish(false)
      end
    end
  elseif stage=="title" then
    key("SPACE",false)
    local a=f-t
    if in_title_wait() then R.title_frames=R.title_frames+1 end
    if a==40 then
      local ok,bad=title_matches()
      table.insert(R.log,string.format("round %d: title_frame_match=%s(bad=%d)",R.round,tostring(ok),bad))
      R["match"..R.round]=ok
    end
    if a==90 then
      R["waits"..R.round]=(R.title_frames>=85)
      key("SPACE",true); stage="press"; t=f
    end
  elseif stage=="press" then
    key("SPACE", f-t<10)
    if f-t>=10 and not in_title_wait() and r("cur_room")==36 and r("dizzy_y")~=0 then stage="newgame"; t=f end
    if f-t>900 then table.insert(R.log,string.format("round %d: SPACE on the title never started a game",R.round)); finish(false) end
  elseif stage=="newgame" then
    key("SPACE",false)
    if f-t==60 then
      local g=gate()
      local lives,coins,inv0=r("lives"),r("coins"),r("inv")
      local dragon,troll=r("dragon_asleep"),r("troll_bribed")
      local gate_v1=g and mem:read_u8(g+5) or -1
      local dp,s=cpu.state["DP"].value,cpu.state["S"].value
      local reset = lives==2 and coins==0 and inv0==0 and dragon==0 and troll==0 and gate_v1==0
      local machine = dp==0 and s>=0x00B0 and s<=0x0100
      table.insert(R.log,string.format("round %d: reset=%s machine=%s (lives=%d coins=%d inv0=%d DP=$%02X S=$%04X)",
        R.round,tostring(reset),tostring(machine),lives,coins,inv0,dp,s))
      R["reset"..R.round]=reset; R["machine"..R.round]=machine
      if R.round==1 then
        -- Round 2: force ANOTHER game over from this fresh game, to catch
        -- state left over from the first title replay (the user's own
        -- "flicker/crashes after restarting" report, T0230-era).
        R.round=2
        force_death()
        stage="dying"; t=f; R.box1=nil
      else
        local ok = R.start_lives==2 and R.match1 and R.waits1 and R.reset1 and R.machine1
                and R.match2 and R.waits2 and R.reset2 and R.machine2
        finish(ok)
      end
    end
  end
end)
