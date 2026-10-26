-- harness/lift94.lua -- T0238: room 94's daisylifthere (ROU_LIFT) +
-- switch1 (ROU_SWITCH1). X-ALL.TXT switchrou1: standing on the switch
-- sets the lift's var1=1 (descending, 56..120 travel, X-ALL's own
-- cointable/movingdata bounds); stepping off holds it; once movey>=100
-- it is off for good (one-way, no rising back -- switchrou1's own
-- `cp 100/ret nc` before it ever re-grants var1).
--
-- Warping DIRECTLY onto/under the switch's own box (a formula guess)
-- reproducibly gave a FALSE negative here: right after a warp, Dizzy
-- drifts upward out of the switch's y-range over ~40 frames (residual
-- warp state, not gameplay) and never re-enters it standing still.
-- Walking a REAL floor into the switch from the side does not have
-- this problem and is the real player action anyway, so this harness
-- warps to a floor away from the switch (94,60,80 -- an ordinary
-- corridor tile, confirmed by floor settle, not by formula) and holds
-- RIGHT to walk into it for real.
--
-- Verifies: (1) lift var1 is 0 before contact, (2) walking through the
-- switch's box sets it to 1 and the lift's own y (byte 3 of its
-- actor_init_tape record) advances from 56 toward 120, (3) once it
-- passes 100 var1 drops back to 0 for good and movement stops there
-- (X-ALL.TXT's own one-way design -- it does not need to reach 120).
--
-- NOT verified by this harness (left as an open item, NOTES.md T0238):
-- physically riding the lift's bar down to the room's coin (X-ALL.TXT
-- cointable: room 94, pixel x=112,y=152). Walking right from the
-- switch's own floor hits an obstruction around x=112 that this round
-- did not have time to identify (ruled out: it is not a solid-actor
-- entry -- solid_list was dumped live and only ever held the lift's
-- own two parts near x=168 and one unrelated static box near x=180;
-- most likely level geometry/approach-from-above, not a bug in the
-- lift/switch code itself, but not confirmed either way).
--
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 90 \
--     -autoboot_script harness/lift94.lua
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
local NACT_T = SYM.ACTOR_COUNT_tape
local STRIDE = 8
local ROU_LIFT = 9
local function r(s) return mem:read_u8(SYM[s]) end
local function pc() return cpu.state["PC"].value end

local function find_tape(pred)
  for i=0,NACT_T-1 do local b=SYM.actor_init_tape+i*STRIDE
    if pred(b) then return b end end
end
local function lift94() return find_tape(function(b) return mem:read_u8(b)==94 and mem:read_u8(b+1)==ROU_LIFT end) end

local f,loaded,stage,t=0,false,"boot",0
local boot_live,settle_count=0,0
local saw_v1_1=false
local lift_y_min,lift_y_max=255,0
local act_passes,last_rng=0,nil   -- T0262: mainloop passes (rng_ctr changes, one per pass) with the lift ACTIVE (var1 == 1) between its top (56) and the stop
local function fail(msg) print("LIFT94 FAIL at "..stage..": "..msg); stage="done"; manager.machine:exit() end

emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  if f==31 then stray_fix(os.getenv("DIZZY_BIN")) end

  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    boot_live=(r("cur_room")==36 and r("dizzy_y")~=0) and boot_live+1 or 0
    if boot_live>=60 then
      key("SPACE",false)
      local lb=lift94()
      if not lb then return fail("no room-94 lift record in actor_init_tape") end
      if mem:read_u8(lb+5)~=0 then return fail("lift var1 nonzero before any contact -- should start off") end
      mem:write_u8(SYM.respawn_room,94); mem:write_u8(SYM.respawn_x,60)
      mem:write_u8(SYM.respawn_y,80); mem:write_u8(SYM.killed,1)
      stage="arrive"; t=f
    end
    return
  end

  if stage~="boot" and stage~="done" and r("lives")<2 then mem:write_u8(SYM.lives,2) end

  if stage=="arrive" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if r("cur_room")==94 and r("killed")==0 then key("SPACE",false); stage="settle"; t=f end
    if f-t>1000 then fail("never arrived in room 94") end

  elseif stage=="settle" then
    if r("killed")~=0 then return fail("died settling onto a floor") end
    local floor=r("dizzy_floor")
    settle_count = (floor==1) and settle_count+1 or 0
    if settle_count>=10 then
      print(string.format("LIFT94 settled at x=%d y=%d floor=%d", r("dizzy_x"), r("dizzy_y"), floor))
      t=f; stage="walk"
    end
    if f-t>1200 then fail(string.format("never landed (x=%d y=%d floor=%d)", r("dizzy_x"), r("dizzy_y"), floor)) end

  elseif stage=="walk" then
    -- walk RIGHT, through the switch's own box, for real (not a warp).
    key("RIGHT", true)
    local lb=lift94()
    local v1,ly = mem:read_u8(lb+5), mem:read_u8(lb+3)
    if ly<lift_y_min then lift_y_min=ly end
    if ly>lift_y_max then lift_y_max=ly end
    local rc=r("rng_ctr")
    if v1~=0 and ly<100 and last_rng and rc~=last_rng then act_passes=act_passes+1 end
    last_rng=rc
    if v1~=0 then saw_v1_1=true end
    if f%20==0 then print(string.format("LIFT94 f=%d x=%d y=%d lift_var1=%d lift_y=%d",
      f, r("dizzy_x"), r("dizzy_y"), v1, ly)) end
    if r("killed")~=0 then return fail(string.format("killed while walking (ly=%d)", ly)) end
    if saw_v1_1 and ly>=100 and v1==0 then
      key("RIGHT",false)
      -- T0262: SPEED, in the game's own time base (the port's frame rate in this room is not the original's, the
      -- ACTOR TICK is). X-ALL liftrou moves the lift by var1 (=1) px per RUN while the switch is stood on, and the lift's
      -- record has delay 2 (movingdata z62): it runs every 2nd actor tick = 1 px per 2 ticks. The port runs 4 actor
      -- ticks per 3 mainloop passes (actors_pass, T0237), so 1 px per 1.5 passes. Before T0255 F9 (the delay) it was
      -- 1 px per 0.75 pass. Passes are counted by rng_ctr (stepped once per pass, harness/rate.lua), only while the lift
      -- is active (Dizzy walks off the switch box part-way).
      local px = ly - 56
      local per = act_passes / px
      if per < 1.3 or per > 1.7 then
        return fail(string.format("lift pace %.2f active passes per px over %d px, want 1.5 (X-ALL delay 2 at 4 ticks per 3 passes); 0.75 = the old every-tick pace", per, px))
      end
      print(string.format("LIFT94 pace: %.2f active passes per px over %d px (ideal 1.5 = delay 2)", per, px))
      print(string.format(
        "LIFT94 PASS: switch actuated the lift (var1 went 0->1->0), travel seen %d..%d (want top 56, stop >=100)",
        lift_y_min, lift_y_max))
      print("LIFT94 NOTE: coin94 (pixel x=112,y=152) walk-to-coin NOT traced this round -- see this file's own header")
      stage="done"; manager.machine:exit()
    end
    if f-t>2500 then
      key("RIGHT",false)
      fail(string.format("never completed a full switch/lift cycle (saw_v1_1=%s, lift_y seen %d..%d, currently var1=%d ly=%d)",
        tostring(saw_v1_1), lift_y_min, lift_y_max, v1, ly))
    end
  end
end)
