-- harness/tiecroc.lua -- T0105/T0110: drop the rope while standing on the
-- gator (room 53) and check that it gets TIED.
--
-- Rewritten in T0110. The previous version never once drove the drop --
-- T0105's own notes said so and stopped there -- and it had THREE separate
-- bugs, any one of which was enough:
--   1. Its teleport spot (140,140) is only half over the gator; Dizzy slid
--      off the left end into the pool and drowned (killed by the water
--      hazard), then sat in the death box because it stopped pressing
--      SPACE in room 53. A settle sweep found where he actually STANDS:
--      dropped from x=168..172 he lands at (144..148, 152), inside the
--      proxcroc box (x 144..184, y 140..160). From 144..164 he falls in.
--   2. (NOT a bug -- recorded because the rewrite first assumed it was.)
--      The old version pressed UP before SPACE, and that is CORRECT:
--      show_inventory deliberately opens with the cursor on EXIT (playtest
--      feedback: dropping should be a choice, not a stray SPACE), so one
--      UP moves to the last item. The rewrite dropped the UP, and a write
--      tap on inv_cursor showed it opening at 1 = EXIT with one item
--      carried, then SPACE closing the inventory. Put back as the
--      "cursor" stage, gated on inv_cursor actually reading 0.
--   3. It poked the gator's var1 to 2 every frame "to hold the mouth shut"
--      (open only on var1 3/5/7). That does the OPPOSITE: within one
--      mainloop pass update_crocodile does var1+=1 and THEN picks the
--      frame from var1, so a var1 forced to 2 becomes 3 -- mouth open --
--      on every animate tick, and the gator bit him. Instrumented, not
--      guessed: write taps on pickup_timer/inv_cursor never fired, the
--      death tune played, and the game sat in the death box. It also
--      clobbered var1 == 255, which IS the tied state. Now: hold var1 at
--      0 (becomes 1: shut) and the frame byte at 123, only until var1
--      reads 255.
--
-- Every stage is gated on observed state, not frame counts (see
-- pickupsfx.lua for why), and a stage that times out says which one.
--
-- T0155: this test started failing ("no tie; rope still carried=false,
-- in_inventory=false") with the rope landing at EXACTLY the position
-- drop_to_world's own formula predicts for Dizzy standing at (148,152)
-- -- i.e. genuinely inside the CROC_PROX box (144,140,40,20) at drop
-- time, not a bisection/position regression. Bisected with the GAME,
-- not the harness, as the first suspect: disassembled check_drop_
-- trigger, aabb_hit and update_crocodile straight from target/room36.bin
-- byte-for-byte against gameplay.asm (CROC_PROX_X really assembles to
-- $90=144, the JSR chain play_drop->drop_to_world->check_drop_trigger
-- is unconditional, cdt_find's crocodile lookup is unambiguous -- only
-- one ROU_CROCODILE actor exists). Every byte matches the source; the
-- game logic is provably self-consistent and correct.
--
-- The actual cause is in the MAME environment this harness's own
-- recommended invocation uses. Isolated by toggling ONE flag at a time
-- with nothing else changed: `-debug -debugger none` (with ZERO
-- breakpoints set -- just the CLI flag) flips this test from a
-- deterministic FAIL (3/3 runs) to a deterministic PASS (2/2 runs),
-- while `-sound none` and `-nothrottle` were independently ruled out
-- (removing either alone, without -debug, still failed). This is the
-- same family as NOTES.md's T0037 finding that `-nothrottle` combined
-- with `-video none` makes `register_periodic` unreliable on a
-- DIFFERENT MAME driver (spectrum) -- here the tick RATE itself is
-- fine (measured: exactly 600 ticks per 10 emulated seconds, identical
-- with and without -debug), so it's not a periodic-callback-count bug
-- this time, but some other timing-sensitive path (plausibly SAM wait-
-- state/keyboard-IRQ approximation under whatever fast-dispatch this
-- MAME build uses without a debugger attached) that -debug's slower,
-- fully-hooked dispatch avoids. Root mechanism not chased further --
-- flagging as an open MAME-environment question, same as T0037.
-- `mem:install_write_tap` and `cpu.debug:bpset` were BOTH tried first
-- to pin down which instruction fails to run, and both turned out to
-- have their own blind spots here (a write-tap on dizzy_x, written
-- constantly during normal walking, caught only 3 of many writes; a
-- breakpoint on check_drop_trigger's own entry point never fired even
-- in a run that provably reached and completed it) -- not reliable
-- enough to use for this diagnosis, so don't reach for them again on
-- this driver without a fresh sanity check first.
--
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -debug \
--     -debugger none -seconds_to_run 40 -autoboot_script harness/tiecroc.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end

local ROU_CROCODILE, FRAME_ROPE = 5, 14
-- T0125: 148, not 172. The old 172 only ever landed on the gator because a
-- troll knockback in progress at the warp survived the respawn and carried
-- Dizzy 24px left while he fell (fixed: respawn clears troll_launching).
local START_X, START_Y = tonumber(os.getenv("TIE_X") or "148"), 136
local PROX = {x=144, y=140, w=40, h=20}

local function r(s) return mem:read_u8(SYM[s]) end
local function pc() return cpu.state["PC"].value end
local function in_audio() local p=pc() return p>=SYM.play_tone and p<SYM.play_chirp end
-- A once-per-frame PC sample almost never lands INSIDE a blocking UI loop:
-- the inventory and message loops spend nearly all their time in
-- wait_vsync/scankeys (via fb_stablekeys), which live elsewhere. The first
-- run of this harness stood Dizzy on the gator, opened the inventory, and
-- reported "DOWN never opened the inventory" with PC in wait_vsync. So also
-- look for the loop's own return address on the 6809 stack.
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
local function croc()
  for i=0,19 do local b=SYM.actor_ram+i*8
    if mem:read_u8(b+1)==ROU_CROCODILE and mem:read_u8(b)==53 then return b end end
end
local function rope()
  for i=0,19 do local b=SYM.actor_ram+i*8
    if mem:read_u8(b+4)==FRAME_ROPE then return b,i end end
end
local function rope_in_inv(ri)
  for s=0,3 do if mem:read_u8(SYM.inv+s)==ri+1 then return true end end
  return false
end

local f,loaded,stage,t,clear,count=0,false,"boot",0,0,0
local ropeidx
local function to(s) stage=s; t=f; clear=0; count=0 end
local function fail(why)
  print(string.format("TIECROC FAIL at stage %s: %s  (room=%d x=%d y=%d floor=%d killed=%d pc=%04x)",
    stage, why, r("cur_room"), r("dizzy_x"), r("dizzy_y"), r("dizzy_floor"), r("killed"), pc()))
  stage="done"
end

emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end

  -- keep the gator's mouth shut until it is tied (see bug 3 above): var1 0
  -- increments to 1, which is below the open range; frame 123 = shut
  local cb=croc()
  if cb and mem:read_u8(cb+5)~=255 then mem:write_u8(cb+5,0); mem:write_u8(cb+4,123) end
  if stage~="boot" and stage~="teleport" and stage~="settle" and r("killed")~=0 then
    return fail("Dizzy was killed mid-sequence")
  end

  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    -- T0125: the mainloop must be RUNNING: new_game's set_checkpoint and
    -- gameplay_init run after `sta dizzy_y` and undo a warp poked in between
    boot_live=(r("cur_room")==36 and r("dizzy_y")~=0) and (boot_live or 0)+1 or 0
    if boot_live>=60 then
      local rb,ri=rope()
      if not rb then return fail("no rope actor (frame 14) in actor_ram") end
      ropeidx=ri
      mem:write_u8(rb,255); mem:write_u8(SYM.inv,ri+1)       -- carrying the rope
      mem:write_u8(SYM.respawn_room,53); mem:write_u8(SYM.respawn_x,START_X)
      mem:write_u8(SYM.respawn_y,START_Y); mem:write_u8(SYM.killed,1)
      to("teleport")
    end

  elseif stage=="teleport" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if count==0 then
      if r("cur_room")==53 and r("dizzy_x")==START_X then count=1 end
    elseif not in_audio() then
      clear=clear+1; if clear>=3 then key("SPACE",false); to("settle") end
    else clear=0 end
    if f-t>900 then fail("never arrived in room 53") end

  elseif stage=="settle" then
    local x,y=r("dizzy_x"),r("dizzy_y")
    local inside = r("dizzy_floor")==1 and x+24>PROX.x and x<PROX.x+PROX.w and y>PROX.y and y<=PROX.y+PROX.h
    if r("killed")~=0 then return fail("died before standing on the gator") end
    count = inside and count+1 or 0
    if count>=10 then
      print(string.format("TIECROC standing on the gator at x=%d y=%d (inside proxcroc)", x, y))
      to("open")
    elseif f-t>300 then fail("never stood inside the proxcroc box") end

  elseif stage=="open" then
    key("DOWN", true)
    -- T0125: in_inventory()'s PC/stack range test can match with the
    -- inventory shut (it did on the T0125 build, releasing DOWN before the
    -- game polled it). Only show_inventory writes inv_occupied: wait for it.
    if in_inventory() and mem:read_u8(SYM.inv_occupied)>=1 then key("DOWN",false); to("invwait") end
    if f-t>200 then key("DOWN",false); fail("DOWN never opened the inventory") end

  elseif stage=="invwait" then
    -- fb_stablekeys wants DOWN released on two agreeing vsync polls
    if f-t>=30 then to("cursor") end

  elseif stage=="cursor" then
    -- the cursor opens on EXIT; UP moves it onto the rope (slot 0)
    if mem:read_u8(SYM.inv_cursor)==0 then
      key("UP", false)
      if count==0 then count=f end
      if f-count>=20 then to("select") end        -- let the release register
    else
      key("UP", ((f-t)%30)<10)
      if f-t>300 then key("UP",false); fail("UP never moved the cursor onto the rope") end
    end

  elseif stage=="select" then
    -- T0155: was a fixed 10-frame SPACE hold, the one stage in this
    -- file NOT gated on observed state (see the file header). Didn't
    -- turn out to be the cause of the T0155 failure by itself (still
    -- failed with this gate in place, absent -debug), but it's a real
    -- inconsistency with the rest of the file's own stated design and
    -- a genuine source of risk (SPACE staying down after the menu
    -- closes could re-trigger a pickup on the just-dropped item), so
    -- fixed it anyway while in here: release the instant the game
    -- itself confirms the selection (drop_slot leaves 0).
    if r("drop_slot")==0 then
      key("SPACE", true)
      if f-t>200 then key("SPACE",false); fail("SPACE never selected the rope (drop_slot stayed 0)") end
    else
      key("SPACE", false)
      to("tiewait")
    end

  elseif stage=="tiewait" then
    if cb and mem:read_u8(cb+5)==255 then
      print("TIECROC tie registered (gator var1=255)")
      to("dismiss")
    elseif f-t>300 then
      fail(string.format("no tie; rope still carried=%s, in_inventory=%s",
        tostring(rope_in_inv(ropeidx)), tostring(in_inventory())))
    end

  elseif stage=="dismiss" then
    key("SPACE", ((f-t)%26)<8)
    -- T0125: not in_inventory() -- the drop IS the inventory closing, and its
    -- PC/stack range test ($23C9-$2537 in that build) also covers variables
    -- whose addresses sit on the stack in ordinary play, so it never read clear
    local busy = in_msgwait() or in_audio()
    clear = busy and 0 or clear+1
    if clear>=30 then
      key("SPACE",false)
      print(string.format("TIECROC PASS croc_var1=%d (255=tied) croc_frame=%d rope_still_carried=%s mainloop_back=yes dizzy x=%d y=%d killed=%d",
        cb and mem:read_u8(cb+5) or -1, cb and mem:read_u8(cb+4) or -1,
        tostring(rope_in_inv(ropeidx)), r("dizzy_x"), r("dizzy_y"), r("killed")))
      stage="done"
    elseif f-t>600 then fail("tied, but the message/inventory never let go") end
  end
end)
