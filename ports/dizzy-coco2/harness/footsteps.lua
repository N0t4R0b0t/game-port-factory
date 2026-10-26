-- harness/footsteps.lua -- T0118: footstep sounds follow the walk
-- ANIMATION (X-ALL.TXT updatedizzy: grounded, walking, animation frames 3
-- and 7 for sndfx 1) and never play in the air.
-- T0260 (D3): and the thud, sndfx 0, on frames 1 and 5: every ODD frame plays, alternating thud (1,5) / tap (3,7).
--
-- Counts plays of the footstep tables by READ taps on the first byte of
-- fx1_notes (tap) and fx0_notes (thud) (play_tune reads it once per play), against dizzy_anim steps; and
-- counts the bursts of writes to the DAC ($FF20, gaps > 4 frames = a new sound) as the output-level check.
-- Walks RIGHT for 60 frames from where the troll's opening shove leaves
-- Dizzy (~x=84; left of there is the fire pit), then jumps in place.
--
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 40 \
--     -autoboot_script harness/footsteps.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end
local function r(s) return mem:read_u8(SYM[s]) end
local f,loaded,stage,t=0,false,"boot",0
local plays={walk=0,air=0,idle=0}
local thuds={walk=0,air=0,idle=0}
local anim_steps,lastanim,frames3or7,frames1or5=0,nil,0,0
local tap,thud,dac
local bursts,lastdac=0,-100
local x0,x1,passes,lastrng=nil,nil,0,nil   -- walking speed / CPU: pixels walked and mainloop passes (rng_ctr changes) in the walk window
local WALKF=tonumber(os.getenv("WALKF") or "60")        -- walk window in frames (the walk stops at the fire pit if too long)
local NOTHUD=(os.getenv("NOTHUD")=="1")            -- NOTHUD=1: silence the thud (fx0_notes := terminator) = the pre-T0260 behaviour, for a speed A/B
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  if not tap then
    tap=mem:install_read_tap(SYM.fx1_notes,SYM.fx1_notes,"steps",function(o,d,m)
      local k = stage=="walk" and "walk" or (stage=="jump" and (r("dizzy_floor")==0 and "air" or "idle")) or "idle"
      plays[k]=plays[k]+1 return d end)
    thud=mem:install_read_tap(SYM.fx0_notes,SYM.fx0_notes,"thuds",function(o,d,m)
      local k = stage=="walk" and "walk" or (stage=="jump" and (r("dizzy_floor")==0 and "air" or "idle")) or "idle"
      thuds[k]=thuds[k]+1 return d end)
    dac=mem:install_write_tap(0xff20,0xff20,"dac",function(o,d,m)
      if stage=="walk" then if f-lastdac>4 then bursts=bursts+1 end lastdac=f end return d end)
  end
  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if r("cur_room")==36 and r("dizzy_y")~=0 then key("SPACE",false); stage="wait"; t=f end
  elseif stage=="wait" then
    -- the troll's opening shove: let Dizzy land and settle first
    if f-t>120 and r("dizzy_floor")==1 then
      stage="walk"; t=f; lastanim=r("dizzy_anim"); x0=r("dizzy_x"); lastrng=r("rng_ctr")
      if NOTHUD then mem:write_u8(SYM.fx0_notes,0); mem:write_u8(SYM.fx0_notes+1,0) end
    end
  elseif stage=="walk" then
    key("RIGHT", true)
    local an=r("dizzy_anim")
    local rc=r("rng_ctr"); if rc~=lastrng then passes=passes+1; lastrng=rc end
    x1=r("dizzy_x")
    if an~=lastanim then anim_steps=anim_steps+1; if an==3 or an==7 then frames3or7=frames3or7+1 elseif an==1 or an==5 then frames1or5=frames1or5+1 end; lastanim=an end
    if r("killed")~=0 then print("FOOTSTEPS FAIL: killed while walking -- shorten the walk"); stage="done"; manager.machine:exit() end
    if f-t>=WALKF then key("RIGHT",false); stage="jump"; t=f end
  elseif stage=="jump" then
    key("UP", (f-t)%80<8)
    if f-t>=320 then
      key("UP",false)
      local ok = plays.air==0 and thuds.air==0 and plays.walk>0 and thuds.walk>0
        and math.abs(plays.walk-frames3or7)<=1 and math.abs(thuds.walk-frames1or5)<=1
        and math.abs(bursts-(plays.walk+thuds.walk))<=1
      print(string.format("FOOTSTEPS %s walk: %d taps (%d on frames 3/7), %d thuds (%d on frames 1/5) over %d animation steps; %d DAC bursts | walked %d px in the window, %d passes | jumping: %d taps %d thuds in the air",
        ok and "PASS" or "FAIL", plays.walk, frames3or7, thuds.walk, frames1or5, anim_steps, bursts, (x1 or 0)-(x0 or 0), passes, plays.air, thuds.air))
      stage="done"; manager.machine:exit()
    end
  end
end)
