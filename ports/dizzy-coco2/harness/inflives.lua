-- harness/inflives.lua -- ./play.sh --inf-lives check (INF_LIVES=1 build).
-- Boots, then forces 5 deaths in a row with lives already at 0 (the
-- worst case: a normal build would go to game over on the first one).
-- Each death must show its box, and after SPACE the game must carry on
-- (NOT the title), with lives unchanged and progress (coins) intact.
-- Control: run it on a normal build and it must FAIL (title reached).
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 200 \
--     -autoboot_script harness/inflives.lua
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
      -- (gameover_tape.lua also counts play_tone..play_chirp; NOT here --
      -- a respawn/sfx tone would read as "title")
end
local f,loaded,stage,t,deaths,log=0,false,"boot",0,0,{}
local function finish(ok)
  print(string.format("INFLIVES %s deaths=%d %s", ok and "PASS" or "FAIL", deaths, table.concat(log,"; ")))
  stage="done"; manager.machine:exit()
end
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    boot_n=(r("cur_room")==36 and r("dizzy_y")~=0) and (boot_n or 0)+1 or 0
    if boot_n>=30 then key("SPACE",false); stage="play"; t=f end
  elseif stage=="play" then
    key("SPACE",false)
    if f-t==120 then
      mem:write_u8(SYM.lives,0); mem:write_u8(SYM.coins,7); mem:write_u8(SYM.killed,1)
      stage="dying"; t=f; box=false
    end
  elseif stage=="dying" then
    if not box then
      key("SPACE",false)
      if in_death_box() then box=true; pa=f end
      if f-t>900 then table.insert(log,"no death box"); finish(false) end
    elseif f-pa<8 then key("SPACE",true)
    elseif f-pa<24 then key("SPACE",false)
    elseif f-pa<200 and in_death_box() then
      -- not dismissed yet: press again (counted -- a box needing >1 press is logged)
      presses=(presses or 1)+1; pa=f
      if presses>6 then table.insert(log,"box never dismissed after 6 presses"); finish(false) end
    elseif in_title_wait() then table.insert(log,"death "..(deaths+1).." went to the TITLE (game over)"); finish(false)
    elseif f-pa>200 then
      local lives,coins,killed=r("lives"),r("coins"),r("killed")
      if in_death_box() then table.insert(log,"still in a box after dismiss"); finish(false); return end
      if lives~=0 or coins~=7 or killed~=0 then
        table.insert(log,string.format("after death %d: lives=%d coins=%d killed=%d",deaths+1,lives,coins,killed)); finish(false); return end
      deaths=deaths+1
      table.insert(log,string.format("death %d: %d press(es)",deaths,presses or 1)); presses=nil
      if deaths>=5 then table.insert(log,"lives stayed 0, coins kept, play resumed each time"); finish(true)
      else stage="play"; t=f end
    end
  end
end)
