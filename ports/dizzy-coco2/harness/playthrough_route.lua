-- harness/playthrough_route.lua -- the route as DATA.  Read next to docs/PLAYTEST-GUIDE.md.
-- Verbs (engine: harness/pt_engine.lua):
--   {"walk_to", x=N | x={lo,hi}, y=feet_y}   stand there (the planner walks/jumps; avoids hazards)
--   {"exit", "up"|"down"|"left"|"right", to=ROOM}
--   {"pickup", item}  {"drop", item, at={x,y}, boxes=N, expect=fn}  {"talk", who, boxes=N}  {"coin"}
--   {"dismiss"} {"wait_for", fn, sec=, what=} {"wait", passes} {"press", keys={..}, passes=N} {"assert", fn, what=}
-- All coordinates are Dizzy's x and FEET y.
local E = PT_E
E.win = { set = false, coins = nil, title = false }
local rd = E.rd
local R = {}
R.items = {
  jug = { frame = 19 }, loaf = { frame = 20 }, apple = { frame = 17 }, railing = { frame = 192 }, bag = { frame = 1, consumed = true }, leaves = { frame = 206 },
  -- (the bag is not carried: taking it raises the inventory cap to 4)
  rope = { frame = 14 }, denzil = { frame = 33 }, dozy = { frame = 32 }, potion = { frame = 15 },
  cow = { frame = 7 }, dylan = { frame = 34 }, doug = { frame = 36 }, key3 = { frame = 13, slot = 22 }, crowbar = { frame = 4 }, bucket = { frame = 5 }, fullbucket = { frame = 5 }, egg = { frame = 10 }, rug = { frame = 12 }, daisy = { frame = 35, rou = 17 }, daisy1 = { frame = 35, rou = 19 }, bean = { frame = 2 }, windowframe = { frame = 204 }, knocker = { frame = 21 }, pickaxe = { frame = 9 }, bone = { frame = 6 }, rock53 = { frame = 136 }, key4 = { frame = 13, slot = 110 }, key1 = { frame = 13, slot = 18 }, key2 = { frame = 13, slot = 20 }, rock50 = { frame = 138 }, rock35 = { frame = 139 },
}
-- PER-MACHINE OVERRIDES (T0233).  The same route is played by the CoCo bot (tools/playthrough.sh) and by the ZX bot on the ORIGINAL
-- (tools/zx_playthrough.sh, PT_MACHINE=zx).  Where the original genuinely differs from the port, the difference is declared HERE, not by
-- forking the route:
--   R.override.zx.items[name] = spec    replaces an item spec (on the ZX `slot` means the item's ORIGIN room: the four keys share frame 13)
--   R.override.zx.steps["SEG.STEP"] = false | step | { seq = {step, ...} }   skips / replaces / expands step STEP of segment SEG ([SEG.STEP] in the log)
--   R.override.zx.checks[SEG] = fn | false   replaces / drops the end-of-segment check
-- Every entry carries the reason; the ZX findings are collected in NOTES.md `## T0233`.
R.override = { zx = { items = {}, steps = {}, checks = {} }, coco = { items = {}, steps = {}, checks = {} } }
local ZXO = R.override.zx
-- CoCo-only retimings (T0237): the port's actors now tick 4 per 3 Dizzy updates (like the ZX), so waits tuned to the old
-- phase relation are re-derived here, keyed like the ZX ones ("SEG.STEP").  Each synchronises on an actor phase, then waits a tuned number of passes.
local CO = R.override.coco
ZXO.items.key1 = { frame = 13, slot = 85 }
ZXO.items.key2 = { frame = 13, slot = 24 }
ZXO.items.key3 = { frame = 13, slot = 60 }
ZXO.items.key4 = { frame = 13, slot = 48 }
-- positions the planner must not stand on or fly through (Dizzy x, feet y), by room; may depend on game state
R.hazards = function(room)
  if room == 94 and not os.getenv("PT_NOHAZ94") then return { { 21, 87, 153, 190 } } end   -- the two daggers (40,152) (72,152): lethal below their top row (the carpets make 152 the floor)
  if room == 36 then
    local b = {}
    if rd("fireout") == 0 then b[#b + 1] = { 0, 31, 140, 191 } end        -- the fire pit (flames x 4..32, y 144..168)
    if rd("troll_bribed") == 0 then b[#b + 1] = { 176, 255, 140, 191 } end -- the troll's launch zone on the floor
    return b
  end
end
-- named actor accessors: the CoCo reads its 8-byte actor records, the ZX its movingdata (harness/pt_mach_zx.lua Z.act, same names)
local ZA = E.ZX and E.Zm.act or nil
local function rat_x() if ZA then return ZA.rat_x() end return E.rd8(E.SYM.actor_ram + 32 * 8 + 2) end
local function rat_room() if ZA then return ZA.rat_room() end return E.rd8(E.SYM.actor_ram + 32 * 8) end
local function gate_y() if ZA then return ZA.gate_y() end return E.rd8(E.SYM.actor_ram + 8 * 1 + 3) end
local function gate_v1() if ZA then return ZA.gate_v1() end local v = E.rd8(E.SYM.actor_ram + 8 * 1 + 5); return v end
local function switch_v1() if ZA then return ZA.switch_v1() end return E.rd8(E.SYM.actor_ram + 8 * 2 + 5) end
R.dyn_hazards = function(room)
  if ZA then return E.Zm.dyn_hazards(room) end
  if room == 51 then   -- the portcullis sprite (kills while moving); T0237: while it RISES (1.33 px per Dizzy pass) plan against where it will be ~3 passes ahead
    local gy = gate_y()
    if gate_v1() >= 128 then gy = gy - 4 end
    return { { 176, gy, 8, 8, "actor" } }
  end
  if room == 50 then                                                    -- Armorog's whole sprite box (also after he is fed)
    for i = 0, E.NACT - 1 do
      local a = E.SYM.actor_ram + i * 8
      if E.rd8(a) == 50 and E.rd8(a + 1) == 3 then
        local w, h = E.sprite_dims(E.rd8(a + 4))
        return { { E.rd8(a + 2), E.rd8(a + 3), w, h, "actor" } }
      end
    end
  end
end
local function inv_has(frame, slot)
  if ZA then return E.Zm.inv_has_frame(frame, slot) ~= nil end
  for s = 0, 3 do
    local v = E.rd8(E.SYM.inv + s)
    if v ~= 0 then
      local a = v > 100 and E.SYM.actor_init_tape + (v - 101) * 8 or E.SYM.actor_ram + (v - 1) * 8
      if E.rd8(a + 4) == frame then return true end
    end
  end
  return false
end
-- "portcullis high and rising".  The port's gate rises 1 px/pass and slams at 2 px/pass; the ZX's rises 2 px per actor update (an update every 2 main passes =
-- 6 frames = 1.5 Dizzy updates) and slams at 2 px per main pass (3 frames).  The crossing of the moat's bridge (feet y 136, head 115) is only possible with the
-- gate's bottom (y+8) above the head, i.e. gate y <= 106: a window of ~11 Dizzy updates on the ZX (7.5 rising + 3.75 falling) for the 7 updates Dizzy needs
-- inside the gate's columns, so on the ZX he is staged right at the edge of the columns (184,144) and leaves the moment the window opens.
-- T0237: the port's actors now tick 4 per 3 Dizzy updates like the ZX's (gate: 1.33 px/update up, 2.67 down on both).
local GATE_Y = ZA and 106 or tonumber(os.getenv("PT_GATEY") or "102")      -- (CoCo: actor_hit's head margin REACH_MARGIN makes the safe height 103 (bottom y+8 <= head 111); the planner's hazard below looks 4 px ahead while the gate rises)
local GATE_STAGE = ZA and { x = 184, y = 148 } or { x = 184, y = 144 }   -- ZX: the block's top at x=184 is 148 (a stage at y=144 needs the LOW gate as a wall to step up against: it killed Dizzy when the gate rose)
-- west-side staging for the crossing: the CoCo's safe window is shorter than the ZX's (see GATE_Y), so wait right at the edge of the gate's columns (x+20 > 176)
local LEFT_STAGE_X = 152
local function gate_ok() return gate_y() <= GATE_Y and gate_v1() >= 128 end
local function gate_bottom() return gate_y() >= 130 and gate_v1() >= 128 end     -- the gate has just turned round at the bottom and starts rising
-- 6.3: the planned jump onto the block (184,144) lands there only while the closed gate is still a wall at x=176; sync on the gate's cycle
CO.steps["6.3"] = { seq = { { "wait_for", gate_bottom, sec = 60, what = "gate starting to rise" }, { "wait", tonumber(os.getenv("PT_W6") or "42") }, { "walk_to", x = 184, y = 144 } } }
local function croc_v1() if ZA then return ZA.croc_v1() end return E.rd8(E.SYM.actor_ram + 10 * 8 + 5) end
local function armorog_state()
  if ZA then return ZA.armorog_state() end
  for i = 0, E.NACT - 1 do
    local a = E.SYM.actor_ram + i * 8
    if E.rd8(a) == 50 and E.rd8(a + 1) == 3 then return E.rd8(a + 5) end
  end
  return -1
end
local function hawk_n() if ZA then return ZA.hawk_n() end return E.rd8(E.SYM.actor_init_tape + 0 * 8 + 6) end
local function hutlift_y() if ZA then return ZA.hutlift_y() end return E.rd8(E.SYM.actor_ram + 22 * 8 + 3) end
local function dozylift_y() if ZA then return ZA.dozylift_y() end return E.rd8(E.SYM.actor_ram + 15 * 8 + 3) end
local function elders_lift_y() if ZA then return ZA.elders_lift_y() end return E.rd8(E.SYM.actor_init_tape + 8 * 8 + 3) end
local function welllid_room() if ZA then return ZA.welllid_room() end return E.rd8(E.SYM.actor_ram + 36 * 8) end
local function shopkeeper_room() if ZA then return ZA.shopkeeper_room() end return E.rd8(E.SYM.actor_init_tape + 1 * 8) end
local function lair_lift_y() if ZA then return ZA.lair_lift_y() end return E.rd8(E.SYM.actor_init_tape + 7 * 8 + 3) end
local function troll_room() if ZA then return ZA.troll_room() end return E.rd8(E.SYM.actor_ram + 33 * 8) end
local function prison_lift_y() if ZA then return ZA.prison_lift_y() end return E.rd8(E.SYM.actor_init_tape + 24 * 8 + 3) end
local function daisy_room() if ZA then return ZA.daisy_room() end return E.rd8(E.SYM.actor_init_tape + 25 * 8) end
local function daisy1_room() if ZA then return ZA.daisy1_room() end return E.rd8(E.SYM.actor_init_tape + 27 * 8) end
local function loaf_room() if ZA then return ZA.loaf_room() end return E.rd8(E.SYM.actor_ram + 31 * 8) end
-- T0237: lifts that must be BOARDED from afar (the walk takes ~30 passes = 40 ticks of the 50-tick pause): start the walk right at the start of the bottom pause
-- (update_lifts' pause counter, record byte 6, counts down from 50).  The ZX keeps its own accessor-based timing.
local function elders_bottom_fresh()
  if ZA then return elders_lift_y() >= 132 end
  return elders_lift_y() >= 132 and E.rd8(E.SYM.actor_init_tape + 8 * 8 + 6) >= 46
end
-- ---- the ZX step overrides (they need the accessors above)
ZXO.steps["1.3"] = false   -- ZX: the apple starts in Dizzy's pocket (resetcarrying: objectscarried[0]=8, the apple's record is in room 255); the port leaves it on the floor
-- ZX rat (X-ALL ratrou/ratnewdir): it patrols x 49..79 (px 68..188) in random legs of 16..31 steps and eats the loaf when it reaches loaf.movex+2.  A loaf
-- dropped at the port's x 40..44 (movex 44, target 46) is practically unreachable (it needs a 31-step leg from the right end), so on the ZX the loaf is
-- dropped at Dizzy x 60..68 (movex 48..50, target 50..52: the rat's left turns are uniform over 48..63) while the rat is far right, then Dizzy walks away.
ZXO.steps["3.1"] = { "wait_for", function() return rat_x() >= 150 end, sec = 60, what = "rat far to the right (ZX px)" }
ZXO.steps["3.2"] = { "drop", "loaf", at = { { 60, 68 }, 80 },
  expect = function() return rd("rat_target_active") == 1 or rd("rat_fled") == 1, "rat not sent to the loaf" end }
-- ZX actors tick every 3 frames (the main loop, 50/3 Hz) but Dizzy every 4 (the ISR's eggcount): the croc's phases are 24 frames = 6 Dizzy updates (the
-- port: 8), so its 3-phase shut stretch is 18 updates, not 24.  The 16-update jump from x=88 plus the ~3 updates the drop needs to open the inventory
-- do not fit, so on the ZX the jump starts ~5 updates BEFORE the shut stretch: Dizzy enters the bite box (x > 128) only after var1 has turned to 0.
ZXO.steps["12.2"] = { "wait_for", function() return croc_v1() == 7 and E.Zm.act.croc_dc() <= 2 end, sec = 30, what = "gator at the end of its last open phase (ZX timing)" }
-- Room 84 (Castle Staircase): the up-exit of 68's curtain ledge arrives at the same x.  The port's planner arrives at x=64; the ZX planner's cheapest edge is
-- the leftmost (x 16), which lands on the bottom-left island (x 8..31, a 3-node pocket: the first step is 32 px above the floor).  Hint the stairs side.
for _, k in ipairs({ "15.6", "45.6", "76.6" }) do ZXO.steps[k] = { "exit", "up", to = 84, arrive = { x = { 56, 255 } } }; CO.steps[k] = ZXO.steps[k] end   -- T0237: the CoCo planner now also picks the leftmost edge (same slide)
-- THE ZX CARRIES 2 ITEMS BEFORE THE BAG (4 after), the port 3 (4 after): X-ALL resetcarrying leaves objectscarried = [apple,0,END,...] and the bag raises the list's end;
-- the port's `inv_cap` is 3 without the bag.  The port's route carries bone + 2 rocks (segments 16..19), impossible on the ZX: the third rock is parked in the
-- Entrance Hall (52) and fetched on a second trip from the river (48) after the other two rocks are in the water.
ZXO.steps["14.5"] = { seq = { { "exit", "up", to = 52 }, { "drop", "rock53" } } }
ZXO.checks[14] = function() return rd("cur_room") == 52 and inv_has(139), "room=" .. rd("cur_room") end
ZXO.checks[18] = function() return rd("cur_room") == 49 and inv_has(138) and inv_has(139), "room=" .. rd("cur_room") end
ZXO.steps["20.3"] = { seq = {
  { "exit", "right", to = 49 },
  { "wait_for", function() local n = hawk_n(); return n >= 48 and n <= 52 end, sec = 60, what = "hawk at the right end of its patrol" },
  { "exit", "right", to = 50 },
  { "exit", "right", to = 51 },
  { "walk_to", x = LEFT_STAGE_X, y = 136 },
  { "wait_for", gate_ok, sec = 60, what = "portcullis high and rising" },
  { "walk_to", x = 184, y = 144 },
  { "exit", "right", to = 52 },
  { "pickup", "rock53" },
  { "exit", "left", to = 51, from = { y = 168 } },
  { "walk_to", x = GATE_STAGE.x, y = GATE_STAGE.y },
  { "wait_for", gate_ok, sec = 60, what = "portcullis high and rising" },
  { "exit", "left", to = 50 },
  { "exit", "left", to = 49 },
  { "wait_for", function() local n = hawk_n(); return n >= 46 and n <= 50 end, sec = 60, what = "hawk at the right end of its patrol" },
  { "exit", "left", to = 48 },
  { "drop", "rock53", at = { { 144, 190 }, 112 }, boxes = 1 },
} }
-- Dozy (45): on the ZX every ENTER next to him is a "talk" (X-ALL talkingtopeople: the counter talkbefore[0] counts them, the 5th floats him away), and the
-- potion's pickup stands next to him: its DOWN presses already count 1-2.  The first talk is all that is needed for the potion; the port's 3 extra
-- "kick" talks would push the counter to 5 and float him off.
for _, k in ipairs({ "24.3", "24.4", "24.5" }) do ZXO.steps[k] = false end
-- Hut lift (56): the bar is only at floor level for a moment; the port's route happens to arrive when it is there, the ZX's lift runs on a different
-- phase relative to the walk, so wait for it.
ZXO.steps["49.1"] = { seq = {
  { "wait_for", function() return hutlift_y() >= 138 end, sec = 60, what = "the lift bar at the bottom" },
  { "walk_to", x = { 112, 120 }, label = "onto the lift bar" } } }
-- T0237: the CoCo lift now runs on the ZX's phase relation too (50-tick pauses = 37.5 passes; the walk from the door to the bar takes ~28): start the walk right at
-- the START of the bottom pause (update_lifts' pause counter, record byte 6, counts down from 50), not anywhere inside it.
local function hutlift_pause() return E.rd8(E.SYM.actor_ram + 22 * 8 + 6) end
CO.steps["49.1"] = { seq = {
  { "wait_for", function() return hutlift_y() >= 138 and hutlift_pause() >= 46 end, sec = 90, what = "the lift bar just arrived at the bottom" },
  { "walk_to", x = { 112, 120 }, label = "onto the lift bar" } } }
-- The well (55): the port carries whoever stands at the well mouth down into 39 and 23 the moment the lid is off (well_route), so its segment 61 ends in room 23.  In
-- the original the open mouth is just a hole in the floor (x 56..87): Dizzy stands on the stone rim (or hangs on its edge) until he walks into it.  The fall then
-- runs the same 55 > 39 > 23 chain.
ZXO.steps["62.1"] = { seq = { { "exit", "down", to = 23, blind = true }, { "exit", "left", to = 22 } } }
-- Window frame over the coin (73): the main loop runs the items (domoving) BEFORE pickupcoins, and a DOWN is consumed by the first that takes it, so on the ZX the first
-- DOWN takes the FRAME (the port's coin_covered quirk makes it take the coin first); the coin underneath is taken by the second.
ZXO.steps["73.8"] = { seq = { { "coin" }, { "drop", "windowframe" } } }
-- The miner's box (X-ALL proxminer: x 90..92 units, y 120..152) covers Dizzy x 208..239 on the ZX, so the port's staging walk to x 212..224 already triggers the shove
-- (and the planner then keeps trying to walk back there): stage on the y=152 ledge's east end (x 196..200) and let the press walk him off it into the box.
ZXO.steps["70.1"] = { "walk_to", x = { 196, 200 }, y = 152 }
ZXO.steps["70.2"] = { "press", keys = { "right" }, passes = 8 }
-- 18.1: the planner's cheapest way down to Armorog's floor is the jump-left fall through his wake box, which starts his countdown ~60 passes before the race the
-- segment is built for.  With the actors at the original's pace (T0237) that race is 4/3 shorter, so drop straight down from the ledge on the east side first.
local function S(name, steps, check) return { name = name, steps = steps, check = check } end
R.segments = {
  S("The dungeon", {
    -- PLAYTEST-GUIDE steps 1-4.  Route difference: the loaf/rat is skipped here (the rat sits on the shelf at y=80,
    -- which only room 52 reaches from above) and the way out is the left exit into 35 (the ceiling slab of 36 is
    -- solid for the whole width; the floor cannot reach the shelf).
    { "pickup", "jug" },
    { "drop", "jug", at = { { 36, 60 }, 176 }, boxes = 1,
      expect = function() return rd("fireout") == 1, "fireout=" .. rd("fireout") end },
    { "pickup", "apple" },
    { "pickup", "loaf" },   -- unavoidable: Dizzy overlaps the loaf wherever the troll's apple box is; it is dropped for the rat later
    { "drop", "apple", at = { { 164, 172 }, 176 }, boxes = 1,
      expect = function() return rd("troll_bribed") == 1, "troll_bribed=" .. rd("troll_bribed") end },
    { "exit", "left", to = 35 },
  }, function() return rd("fireout") == 1 and rd("troll_bribed") == 1 and rd("cur_room") == 35,
    string.format("fireout=%d bribed=%d room=%d", rd("fireout"), rd("troll_bribed"), rd("cur_room")) end),
  S("Smuggler's Hideout: over the pillar to the shelf of the dungeon", {
    -- room 35's right pillar top (y=80) lines up with 36's shelf (y=80): horizontal transitions keep y.
    { "exit", "right", to = 36, from = { y = 80 } },
  }),
  S("The shelf: the rat, then out through the ceiling gap", {
    -- The rat patrols x 48..192 (4 px/pass, kills on contact) and, once fed, runs right to x=224 and vanishes.
    -- Arrival is at x=8, where it cannot reach (it never goes below 48).  Wait for it to be far right, step in,
    -- drop the loaf (the inventory is modal: the rat does not move), step back out of its way.
    { "wait_for", function() return rat_x() >= 104 end, sec = 60, what = "rat far to the right" },
    { "drop", "loaf", at = { { 40, 44 }, 80 },   -- the loaf lands at (x&0xF8)+8 = 48: the rat only patrols x>=48, so 40 px left of it would be unreachable
      expect = function() return rd("rat_target_active") == 1 or rd("rat_fled") == 1, "rat not sent to the loaf" end },
    { "walk_to", x = 8, y = 80 },
    { "wait_for", function() return rd("rat_fled") == 1 and rat_room() == 255 end, sec = 60, what = "rat eats the loaf and leaves",
      onfail = function() return string.format("[rat room=%d x=%d fled=%d target=%d tx=%d loaf_room=%d]", rat_room(), rat_x(), rd("rat_fled"), rd("rat_target_active"), rd("rat_target_x"), loaf_room()) end },
    { "exit", "up", to = 52 },
  }, function() return rd("cur_room") == 52 and rd("rat_fled") == 1, "room=" .. rd("cur_room") end),
  S("The Entrance Hall: railing, coin", {
    { "pickup", "railing" },       -- the railing sits on the coin (PLAYTEST-GUIDE: the coins under items)
    { "coin" },
    { "drop", "railing" },
    -- 51 has two levels reached from 52's two levels: the lower one (y=168) holds the coin and the gate's stairs,
    -- the upper one (y=104) the lever.
    { "exit", "left", to = 51, from = { y = 168 } },
  }, function() return rd("coins") == 1 and rd("cur_room") == 51, "coins=" .. rd("coins") .. " room=" .. rd("cur_room") end),
  S("The moat: coin below, lever above", {
    { "coin" },
    { "exit", "right", to = 52 },
    { "exit", "left", to = 51, from = { y = 104 } },
    { "walk_to", x = { 136, 148 }, y = 88 },
    { "press", keys = { "down" }, passes = 1 },
    { "dismiss" },
  }, function() return rd("coins") == 2 and rd("cur_room") == 51 and gate_v1() ~= 0 and switch_v1() == 1,
    string.format("coins=%d room=%d gate_v1=%d switch_v1=%d", rd("coins"), rd("cur_room"), gate_v1(), switch_v1()) end),
  S("The moat: under the portcullis", {
    { "exit", "right", to = 52 },
    { "exit", "left", to = 51, from = { y = 168 } },
    { "walk_to", x = 184, y = 144 },
    -- the gate rises 1 px/pass from 136 to 98, then slams back 2 px/pass.  Its sprite (8x8 at x=176) kills while Dizzy's
    -- head is below its bottom edge: start crossing when it is high and still rising.
    { "wait_for", gate_ok, sec = 60, what = "portcullis high and rising" },
    { "exit", "left", to = 50 },
  }),
  S("Armorog's den seen; back east through the portcullis, up to the West Wing", {
    -- (the bone for Armorog and the rock come later: the bone is in the attic, reached through the castle)
    { "exit", "right", to = 51 },
    { "walk_to", x = LEFT_STAGE_X, y = 136 },
    { "wait_for", gate_ok, sec = 60, what = "portcullis high and rising" },
    { "walk_to", x = 184, y = 144 },
    { "exit", "right", to = 52 },
    { "exit", "left", to = 51, from = { y = 104 } },
    { "exit", "up", to = 67 },   -- (the planner looks ahead: 67 has floor only at x=72..143 and 200..247, arriving above its hole falls back into 51)
  }),
  S("The West Wing: coin; on into the Banquet Hall", {
    { "coin" },
    { "exit", "right", to = 68 },
  }, function() return rd("coins") == 3 and rd("cur_room") == 68, "coins=" .. rd("coins") .. " room=" .. rd("cur_room") end),
  S("The Banquet Hall: Denzil, the rope, the coin", {
    { "talk", "denzil" },          -- his boxes play, then the rope appears (PLAYTEST-GUIDE step 7)
    { "pickup", "rope" },
    { "coin" },
  }, function() return rd("coins") == 4 and inv_has(14), "coins=" .. rd("coins") end),
  S("Back out of the castle, east to the gator", {
    -- 68's right exit is through the fireplace (flames at x>=204): the east wing is reached from 53 (53+16) instead.
    { "exit", "left", to = 67 },
    { "exit", "down", to = 51 },
    { "exit", "right", to = 52 },
    { "exit", "right", to = 53 },
  }),
  S("The gator: down to the lower level of 53", {
    { "exit", "left", to = 52 },
    { "exit", "right", to = 53, from = { y = 168 } },
  }),
  S("The gator: tie it up with the rope", {
    -- the gator's mouth (frame 124) bites at x 152..176 while var1 is 3, 5 or 7 (each lasts 8 passes). Launch at the
    -- start of the shut stretch (var1 == 0, three phases = 24 passes) so the jump onto its back and the drop (the
    -- inventory is modal: no game time passes) both fall inside it.
    { "walk_to", x = 88 },
    { "wait_for", function() return croc_v1() == 0 end, sec = 30, what = "gator mouth shut for a long stretch" },
    { "walk_to", x = { 144, 164 } },   -- onto the gator (its ink top sits at y 154..156)
    { "drop", "rope", boxes = 1, expect = function() return croc_v1() == 255, "croc var1=" .. croc_v1() end },
  }, function() return croc_v1() == 255 and not inv_has(14), "croc var1=" .. croc_v1() end),
  S("Rock from the gator's far bank, then up the 52 hole to the dungeon shelf and room 35", {
    -- three rocks (rooms 53, 35, 50) go into the river in 48; carrying cap is 3, so they are collected on the way
    -- (the bone for Armorog is the 4th carried thing, dropped before the 3rd rock is picked up).
    { "pickup", "rock53" },
    { "exit", "left", to = 52 },       -- down the left steps; the last one is a fall that carries him out of the room
  }),
  S("Back to the dungeon for the rock of room 35", {
    { "exit", "down", to = 36 },
    { "exit", "left", to = 35 },
    { "pickup", "rock35" },
    { "exit", "right", to = 36, from = { y = 80 } },
    { "exit", "up", to = 52 },
  }, function() return rd("cur_room") == 52 and inv_has(136) and inv_has(139), "room=" .. rd("cur_room") end),
  S("Up into the castle: the loop 67 - 68 - 67 - 68 to the Castle Staircase", {
    -- (found with harness/pt_global.lua: the castle's upper floors are reached by feet alone, no dagger death needed)
    { "exit", "left", to = 51, from = { y = 104 } },
    { "exit", "up", to = 67 },
    { "exit", "right", to = 68, arrive = { y = 148 } },        -- jump from the West Wing floor onto the banquet table
    { "exit", "left", to = 67, arrive = { y = 117 } },         -- from the table onto the ledge of the West Wing (T0180)
    { "exit", "right", to = 68, arrive = { y = 88 } },         -- from that ledge onto the curtain ledge top-left of 68
    { "exit", "up", to = 84 },
  }),
  S("The Castle Staircase: coin; the attic: the bone", {
    { "coin" },
    { "exit", "up", to = 100 },
    { "pickup", "bone" },
  }, function() return rd("coins") == 5 and inv_has(6), "coins=" .. rd("coins") end),
  S("Down from the castle to Armorog's den", {
    { "exit", "down", to = 84 },
    { "exit", "down", to = 68 },       -- through the hole in the staircase floor
    { "exit", "left", to = 67 },       -- lands on a 2-cell ledge at (224,88)
    { "exit", "right", to = 68, arrive = { y = { 140, 160 } } },   -- ... and a jump right from the ledge below it lands on the banquet table
    { "exit", "left", to = 67, arrive = { y = { 160, 176 } } },   -- walk off the table's left edge: a drop onto the floor of the West Wing
    { "exit", "down", to = 51 },       -- 67's floor has a hole at x 144..199: down into 51
    { "exit", "right", to = 52 },
    { "exit", "left", to = 51, from = { y = 168 } },
    -- staging point right of the gate's lethal columns (x 157..183): an overshoot to 180 killed him with the gate low
    { "walk_to", x = GATE_STAGE.x, y = GATE_STAGE.y },
    { "wait_for", gate_ok, sec = 60, what = "portcullis high and rising" },
    { "exit", "left", to = 50 },
  }),
  S("Armorog's den: bone, third rock, wake him, feed him", {
    -- Armorog (asleep at x=88) wakes when Dizzy stands in x 104..176 on the floor, counts down 40 passes, runs right
    -- 2 px/pass to his den at x=184 and eats a bone lying there (record x>=192, y>=140: dropped from the FLOOR).
    -- Anything in his way dies, and once he sits in the den his 48x20 box (x 184..232) covers the rock: so the rock is
    -- picked first (cap 3: the bone goes down before it), then he is woken and Dizzy waits on the ledge.
    { "walk_to", x = { 184, 188 }, y = 176 },      -- the bone lands at (x&0xF8)+8 = 192: as far left as the rule allows, clear of the rock
    { "drop", "bone", boxes = 0, msgwait = 3 },   -- (no message follows: do not wait the default 90 frames, Armorog is already counting down)
    { "pickup", "rock50", x = 208 },               -- standing at 208 only (x 204 would also overlap the bone and pick it up again)
    -- Armorog wakes by himself on the way down (the cliff is a fall to the left through his wake box x 128..176, y 125..165): he
    -- counts 40 passes, then runs 2 px/pass to the den at x=184 and kills what is in his path.  The only way back up is the step
    -- at x~176 (feet 144, above his head), so everything from here to there is a race of ~60 passes: no idle waits.
    { "do", function(E, PT, V) if armorog_state() == 0 then V.walk_to({ x = 172, y = 176, label = "wake Armorog" }) end end },
    { "walk_to", x = { 196, 224 }, y = 136 },
    { "wait_for", function() return armorog_state() == 4 end, sec = 60, what = "Armorog fed", onfail = function() return "armorog state " .. armorog_state() end },
    { "exit", "left", to = 49 },       -- jump from the stairs over his den box to the floor left of it
  }, function() return rd("cur_room") == 49 and inv_has(138) and inv_has(139) and inv_has(136), "room=" .. rd("cur_room") end),
  S("The Guard House: the hawk, the coin, west over the boulders", {
    -- The hawk patrols x = 32..160 (counter n 0..127, one act per 2 passes) and dives, tracking Dizzy's x for good, if
    -- Dizzy is within (hx-16, hx+24) while its x is 72..127.  It is at x>=128 for n = 48..79 (64 passes): cross, take the
    -- coin and be left of x=64 inside that window.
    { "wait_for", function() local n = hawk_n(); return n >= 48 and n <= 56 end, sec = 60, what = "hawk at the right end of its patrol" },
    { "coin" },
    { "walk_to", x = { 48, 60 } },
    { "exit", "left", to = 48 },
  }, function() return rd("cur_room") == 48 and rd("coins") == 6, "room=" .. rd("cur_room") .. " coins=" .. rd("coins") end),
  S("The Broken Bridge: three rocks into the river", {
    -- proxrock box (160,80,40,30): stand on the right cliff top at x 144..190; each rock raises the water and the log by 6
    { "drop", "rock50", at = { { 144, 190 }, 112 }, boxes = 1 },
    { "drop", "rock35", boxes = 1 },
    { "drop", "rock53", boxes = 1 },
  }, function() return rd("waterheight") == 18 and rd("cur_room") == 48, "waterheight=" .. rd("waterheight") end),
  S("The Broken Bridge: across the log to the left cliff, key 4", {
    { "pickup", "key4" },
  }, function() return inv_has(13) and rd("cur_room") == 48, "no key" end),
  S("West: Fourway Warehouse and the Amazing Illusion (coin)", {
    { "exit", "left", to = 47 },
    -- T0232: the coin is in a pocket under invisible slabs; the way back up is a chain of pixel-tight jumps the planner finds
    -- (pocket -> floor -> right block -> pillar top -> small block -> hang at x=96 and jump left onto the slab -> top step -> up).
    { "exit", "down", to = 31 },
    { "coin" },
  }),
  S("West: the Docks (coin), Looking Out to Sea", {
    { "exit", "up", to = 47 },
    { "exit", "left", to = 46 },
    { "coin" },
    { "exit", "left", to = 45 },
  }),
  S("Looking Out to Sea: Dozy, the sleeping potion", {
    { "talk", "dozy", boxes = 9 },      -- 1st talk: the 9-box conversation; the sleeping potion appears
    { "pickup", "potion" },
    { "talk", "dozy" },                 -- talks 2-4: "kick him"; (the 5th, which floats him away, is not needed:
    { "talk", "dozy" },                 -- harness/tape_dozyfloat.lua covers it)
    { "talk", "dozy" },
  }, function() return inv_has(15) and inv_has(13), "inv" end),
  S("Back east: 46, 47, the log in 48", {
    { "exit", "right", to = 46 },
    { "exit", "right", to = 47 },
    { "exit", "right", to = 48 },
    { "exit", "right", to = 49 },        -- (across the log; the planner times its jumps on the bobbing log)
  }, function() return rd("cur_room") == 49 and inv_has(15) and inv_has(13), "room=" .. rd("cur_room") end),
  S("The Guard House eastward (hawk window), into Armorog's den, up to the moat", {
    { "wait_for", function() local n = hawk_n(); return n >= 48 and n <= 52 end, sec = 60, what = "hawk at the right end of its patrol" },
    { "exit", "right", to = 50 },
    { "exit", "right", to = 51 },
  }),
  S("East through the portcullis, the Entrance Hall, across the tied gator to the dragon", {
    { "walk_to", x = LEFT_STAGE_X, y = 136 },
    { "wait_for", gate_ok, sec = 60, what = "portcullis high and rising" },
    { "walk_to", x = 184, y = 144 },
    { "exit", "right", to = 52 },
    { "exit", "right", to = 53, from = { y = 168 } },
    { "exit", "right", to = 54 },
  }),
  S("The dragon: the sleeping potion", {
    -- potion box (112,150,40,30); the head (x 144..160) bites at x > 124 and the fire (random, 5/256 per tick, then 48
    -- ticks) sweeps left from the mouth: drop from x 96..120 while no fire is running (the inventory is modal).
    { "walk_to", x = { 96, 120 }, y = 176 },
    { "wait_for", function() return rd("dragon_fire") == 0 end, sec = 30, what = "no fire" },
    { "drop", "potion", boxes = 1, expect = function() return rd("dragon_asleep") == 1, "dragon_asleep=" .. rd("dragon_asleep") end },
    { "exit", "right", to = 55 },
  }, function() return rd("dragon_asleep") == 1 and rd("cur_room") == 55, "asleep=" .. rd("dragon_asleep") .. " room=" .. rd("cur_room") end),
  S("The Bottomless Well: the bag, the two coins under the leaves and the railing", {
    { "pickup", "bag" },
    { "pickup", "leaves" },
    { "coin", x = 104, y = 136 },
    { "drop", "leaves" },
    { "pickup", "railing" },
    { "coin", x = 176, y = 128 },
    { "drop", "railing" },
  }, function() return rd("coins") == 10 and rd("inv_cap") == 4, "coins=" .. rd("coins") .. " cap=" .. rd("inv_cap") end),
  S("Over the roof of the Lift Control Hut to the tree house", {
    -- the hut's left wall is closed up to its roof; the way past is OVER the roof (y=96, the whole width of 56): jump right
    -- from the upper ledge of the well room (found with harness/pt_global.lua)
    { "exit", "right", to = 56, arrive = { y = 96 } },
    { "exit", "right", to = 57 },
  }),
  S("Base of the tree house: on to the Smelly Allotment, back for the ground coin", {
    { "exit", "right", to = 58 },
  }),
  S("The Smelly Allotment: the cow; the Large Oak Tree: Dylan and the leaves coin", {
    { "pickup", "cow" },
    { "exit", "right", to = 59 },
    { "talk", "dylan", boxes = 3 },
  }),
  S("The Large Oak Tree: the leaves and the coin up in the branches (collected mid-jump)", {
    { "pickup", "leaves", air = true },
    { "coin", air = true },
    { "drop", "leaves" },
  }, function() return rd("coins") == 11, "coins=" .. rd("coins") end),
  S("The Base of the Volcano", {
    { "exit", "right", to = 60 },
  }),
  S("The Base of the Volcano: key 3, then up the slope", {
    { "pickup", "key3" },
    { "exit", "up", to = 77 },       -- the jump up the slope carries on through 76 (a sky) into the volcano 77
  }),
  S("The Active Volcano: the coin on the rocks, then back down", {
    { "coin" },
    { "exit", "left", to = 76 },
    { "exit", "down", to = 60 },
  }, function() return rd("coins") == 12 and rd("cur_room") == 60, "coins=" .. rd("coins") .. " room=" .. rd("cur_room") end),
  S("Back west to the tree house: the ground coin, then into the Lift Control Hut", {
    { "exit", "left", to = 59 },
    { "exit", "left", to = 58 },
    { "exit", "left", to = 57 },
    { "coin" },
    { "exit", "left", to = 56 },
  }),
  S("The Lift Control Hut: keys 3 and 4 into their machines", {
    -- cdt_key_tab boxes (16x16): slot 3 (84,160) -> lift 88 (Doug), slot 4 (156,160) -> the hut's own lift
    { "drop", "key4", at = { { 140, 168 }, 176 }, boxes = 1 },
    { "drop", "key3", at = { { 68, 96 }, 176 }, boxes = 1 },
  }),
  S("Up the tree: Daisy's empty hut (73)", {
    { "exit", "right", to = 57 },
    { "exit", "right", to = 58, arrive = { y = 145 } },     -- a jump from the ground of 57 onto the tree platform of 58
    { "exit", "left", to = 57, arrive = { y = 120 } },      -- ... and back left onto the upper level of 57
    { "exit", "up", to = 73 },
  }),
  S("Denzil's Pad (72)", {
    { "exit", "left", to = 72 },
  }),
  S("Denzil's Pad: the coin under the railing (not the hole!), up to the Lift to the Elders", {
    { "pickup", "railing" },
    { "coin" },
    { "drop", "railing" },
  }, function() return rd("coins") == 14, "coins=" .. rd("coins") end),
  S("Denzil's Pad: left to Dozy's hut", {
    { "exit", "left", to = 71 },
  }),
  S("Dozy's hut is a dead end without key 1 (88 is only reachable past a lethal torch flame from the right): fall down to the well room and go back west for key 1", {
    { "exit", "down", to = 54 },       -- a drop from the walkway carries on through the well room (55) into the dragon's (54)
    { "exit", "left", to = 53 },
    { "exit", "left", to = 52 },
  }),
  S("The East Wing coin (69, from 53 up; the blade row is far above the floor)", {
    { "exit", "right", to = 53, from = { y = 104 } },
    { "exit", "up", to = 69 },
    { "coin" },
    { "exit", "down", to = 53 },
    { "exit", "left", to = 52 },
  }, function() return rd("coins") == 15 and rd("cur_room") == 52, "coins=" .. rd("coins") .. " room=" .. rd("cur_room") end),
  S("Up into the castle again, for key 1 in the East Tower (85)", {
    { "exit", "left", to = 51, from = { y = 104 } },
    { "exit", "up", to = 67 },
    { "exit", "right", to = 68, arrive = { y = 148 } },
    { "exit", "left", to = 67, arrive = { y = 117 } },
    { "exit", "right", to = 68, arrive = { y = 88 } },
    { "exit", "up", to = 84 },
    { "exit", "right", to = 85 },
    { "pickup", "key1" },
  }, function() return inv_has(13) and rd("cur_room") == 85, "room=" .. rd("cur_room") end),
  S("Back down out of the castle and east to the well room", {
    { "exit", "left", to = 84 },
    { "exit", "down", to = 68 },
    { "exit", "left", to = 67 },
    { "exit", "right", to = 68, arrive = { y = { 140, 160 } } },
    { "exit", "left", to = 67, arrive = { y = { 160, 176 } } },
    { "exit", "down", to = 51 },
    { "exit", "right", to = 52 },
    { "exit", "right", to = 53, from = { y = 168 } },
    { "exit", "right", to = 54 },
    { "exit", "right", to = 55 },
  }),
  S("Over the hut roof, into the corridor on the hut's right side: the railing coin", {
    { "exit", "right", to = 56, arrive = { y = 96 } },
    { "exit", "right", to = 57 },
    { "exit", "left", to = 56, arrive = { y = { 140, 150 } } },   -- from the low step of 57's left staircase into the hut's right corridor
    { "pickup", "railing" },
    { "coin" },
    { "drop", "railing" },
    { "exit", "right", to = 57 },
  }, function() return rd("coins") == 16 and rd("cur_room") == 57, "coins=" .. rd("coins") .. " room=" .. rd("cur_room") end),
  S("Into the hut again (through the ground of 57)", {
    { "exit", "right", to = 58 },
    { "exit", "left", to = 57, arrive = { y = 176 } },
    { "exit", "left", to = 56 },
  }),
  S("The hut: ride its lift (key 4) up to the shelves and put key 1 in the top-left machine", {
    -- lift 56: head y 104..140 (+40 = the bar Dizzy rides), 1 px/pass, 50-pass pause at each end
    { "walk_to", x = { 112, 120 }, label = "onto the lift bar" },
    { "wait_for", function() return hutlift_y() <= 108 end, sec = 60, what = "the lift bar at the top" },
    { "walk_to", x = { 56, 88 }, y = 136, label = "off the bar onto the left shelf" },
    { "drop", "key1", boxes = 1 },
  }),
  S("Back up the tree to Dozy's hut (71) with its lift now running", {
    { "walk_to", x = { 112, 120 }, label = "back onto the lift bar (at its top)" },
    { "wait_for", function() return hutlift_y() >= 138 end, sec = 60, what = "the lift bar at the bottom" },
    { "exit", "right", to = 57 },
    { "exit", "right", to = 58, arrive = { y = 145 } },
    { "exit", "left", to = 57, arrive = { y = 120 } },
    { "exit", "up", to = 73 },
    { "exit", "left", to = 72 },
    { "exit", "left", to = 71 },
  }),
  S("Dozy's hut: ride its lift up and out to the top-left platform of Denzil's Pad", {
    -- lift 71: head y 56..112 (+40 = the bar), 1 px/pass; arriving in 72 from the LEFT lands on its x<=64 part of the
    -- platform that the torch flame (92,58) makes lethal from the right
    { "wait_for", function() return dozylift_y() >= 112 end, sec = 90, what = "the lift bar at the bottom" },   -- T0237: was >= 108 (a 4 px lip the planner cannot step onto while the bar still moves)
    { "walk_to", x = { 80, 88 }, label = "onto the left edge of the lift bar (it only moves with Dizzy standing within 12 px of it)" },
    { "wait_for", function() return dozylift_y() <= 60 end, sec = 90, what = "the lift bar at the top" },
    { "exit", "right", to = 72 },
  }),
  S("Denzil's Pad (top-left platform, x <= 64 only) up to the Lift to the Elders", {
    { "exit", "up", to = 88 },
  }),
  S("The Lift to the Elders: ride up, Doug, the crowbar", {
    -- lift 88: head y 56..136 (+40 = the bar); it moves only with Dizzy standing within 12 px of the bar's left edge
    { "wait_for", elders_bottom_fresh, sec = 90, what = "the lift bar at the bottom" },
    { "walk_to", x = { 104, 112 }, label = "onto the left edge of the lift bar" },
    { "wait_for", function() return elders_lift_y() <= 60 end, sec = 90, what = "the lift bar at the top" },
    { "talk", "doug", boxes = 6 },       -- his 6 boxes, then (and only then) the crowbar appears
    { "pickup", "crowbar" },
  }, function() return inv_has(4), "no crowbar" end),
  S("Down the lift, east to Dizzy's Parents' Hut (89)", {
    { "wait_for", function() return elders_lift_y() <= 62 end, sec = 90, what = "the lift bar at the top (it runs by itself while Dizzy is outside its shaft)" },
    { "walk_to", x = { 104, 112 }, label = "back onto the lift bar (at its top)" },
    { "wait_for", function() return elders_lift_y() >= 132 end, sec = 90, what = "the lift bar at the bottom" },
    { "exit", "right", to = 89 },
  }),
  S("Parents' Hut: the door knocker; back up the lift for the coin on the hut's floor slab", {
    -- the slab (y=112, x 8..135) is reached from 88's upper right balcony: leave 88 to the right at its height
    { "pickup", "knocker" },
    { "exit", "left", to = 88 },
    { "wait_for", elders_bottom_fresh, sec = 90, what = "the lift bar at the bottom" },
    { "walk_to", x = { 104, 112 }, label = "onto the left edge of the lift bar" },
    { "wait_for", function() return elders_lift_y() <= 60 end, sec = 90, what = "the lift bar at the top" },
    { "exit", "right", to = 89, arrive = { y = { 96, 112 } } },
    { "coin" },
  }, function() return rd("coins") == 17 and inv_has(21), "coins=" .. rd("coins") end),
  S("To the Meeting Hall (87) over the top of the lift", {
    { "exit", "left", to = 88 },
    { "wait_for", function() return elders_lift_y() <= 62 end, sec = 90, what = "the lift bar at the top" },
    { "exit", "left", to = 87 },
  }),
  S("The Meeting Hall: the pickaxe and the coin", {
    { "pickup", "pickaxe" },
  }, function() return inv_has(9), "no pickaxe" end),
  S("The lower part of the Meeting Hall (the coin): out right, down the lift, then left from 88's floor", {
    -- 87's lower balcony is entered from 88's FLOOR (the hall itself is the upper level, entered from Doug's platform)
    { "exit", "right", to = 88 },
    { "wait_for", function() return elders_lift_y() <= 62 end, sec = 90, what = "the lift bar at the top" },
    { "walk_to", x = { 104, 112 }, label = "onto the lift bar" },
    { "wait_for", function() return elders_lift_y() >= 132 end, sec = 90, what = "the lift bar at the bottom" },
    { "exit", "left", to = 87, arrive = { y = 176 } },
    { "coin" },
  }, function() return rd("coins") == 18 and rd("cur_room") == 87, "coins=" .. rd("coins") .. " room=" .. rd("cur_room") end),
  S("The Longjump Cloud: the coin", {
    { "exit", "left", to = 86 },
    { "coin" },
  }, function() return rd("coins") == 19, "coins=" .. rd("coins") end),
  S("Off the Longjump Cloud: a plain walk off its right edge falls through 87 and 71 into the well room", {
    -- (a JUMP off the cloud lands in 71 right across the torch flame at (112,106): lethal; walking off drifts less)
    { "exit", "right", to = 55 },
  }),
  S("The well: the crowbar takes the lid off", {
    { "drop", "crowbar", at = ZA and { { 36, 84 }, 160 } or { { 52, 68 }, 160 }, boxes = 1,   -- T0237: x 52..68 keeps his whole foot span (x+4 .. x+19) over the open mouth (56..87); at 72 the right foot stood on the rim and he never fell
    expect = function() return welllid_room() == 255, "lid room=" .. welllid_room() end },
  }),
  S("The Market Square: the coin, the shopkeeper, the cow for the bean", {
    { "exit", "left", to = 22 },
    { "coin" },
    { "wait_for", function() return shopkeeper_room() == 22 end, sec = 120, what = "the shopkeeper appears (about 15 s in the room)" },
    { "drop", "cow", at = { { 120, 164 }, 176 }, boxes = 8 },    -- shoptalk: an 8-box bargaining conversation; the bean appears
    { "pickup", "bean" },
  }, function() return rd("coins") == 20 and inv_has(2) and not inv_has(7), "coins=" .. rd("coins") end),
  S("Inside the Church: key 2 and the coin", {
    { "exit", "right", to = 23 },
    { "exit", "right", to = 24 },
    { "pickup", "key2" },
    { "coin" },
  }, function() return rd("coins") == 21 and inv_has(13), "coins=" .. rd("coins") end),
  S("Back up out of the well: falling out of the bottom of 23 runs the well loop (39 tumbles, flips, and throws him out at the top)", {
    { "exit", "left", to = 23 },
    { "exit", "down", to = 55, blind = true },     -- well_route (logic_low.asm T0125): 23 -> 39 -> flipped 39 -> out the top, back to 55
  }),
  S("Into the hut again: key 2 into the top-right machine (lift 40)", {
    { "exit", "right", to = 56, arrive = { y = 96 } },
    { "exit", "right", to = 57 },
    { "exit", "right", to = 58 },
    { "exit", "left", to = 57, arrive = { y = 176 } },
    { "exit", "left", to = 56 },
    { "wait_for", function() return hutlift_y() >= 138 end, sec = 60, what = "the lift bar at the bottom" },
    { "walk_to", x = { 112, 120 }, label = "onto the lift bar" },
    { "wait_for", function() return hutlift_y() <= 108 end, sec = 60, what = "the lift bar at the top" },
    { "walk_to", x = { 140, 172 }, y = 136, label = "off the bar onto the right shelf" },
    { "drop", "key2", boxes = 1 },
  }),
  S("Down the hut's lift shaft into the Dragon's Lair", {
    -- ride the bar down from the shelf, step off on the floor, then drop into the shaft while the bar is up
    { "wait_for", function() return hutlift_y() <= 108 end, sec = 60, what = "the lift bar at the top" },
    { "walk_to", x = { 112, 120 }, label = "onto the lift bar" },
    { "wait_for", function() return hutlift_y() >= 138 end, sec = 60, what = "the lift bar at the bottom" },
    { "walk_to", x = { 152, 170 }, y = 176, label = "off the bar onto the floor (clear of the shaft box, or the lift stops)" },
    { "wait_for", function() return hutlift_y() <= 112 end, sec = 60, what = "the lift bar up again (the shaft is open below it)" },
    { "exit", "down", to = 40 },
  }),
  S("The Dragon's Lair: the coin on the upper walkway, down the lift to the lower floor (the egg stays: the dragon breathes only while it is taken)", {
    { "coin" },
    -- lift 40 (key 2 is in): head y 56..134, bar = y+40; it only moves with Dizzy standing within 12 px of its left edge (x 32..44).
    -- The cogs head blocks the walkway (wall probes at y-14/y-18) unless the lift is at its very top.
    { "wait_for", function() return lair_lift_y() <= 57 end, sec = 90, what = "the lift at its very top" },
    { "walk_to", x = { 32, 38 }, label = "onto the left edge of the lift bar" },
    { "wait_for", function() return lair_lift_y() >= 130 end, sec = 90, what = "the lift bar at the bottom" },
  }),
  S("The Dragon's Lair: the egg out of the nest and straight back: the dragon goes to sleep and the floor is safe", {
    -- (the head hangs over x 144..160 and the floor is the only way east; it is lethal while awake)
    { "walk_to", x = { 92, 116 }, y = 168, label = "to the nest" },
    -- lift the egg and drop it back inside the modal inventory screen the pickup opens: no game pass runs in between
    { "pickup_and_drop", "egg", boxes = 1, expect = function() return rd("dragon_asleep") == 1, "dragon_asleep=" .. rd("dragon_asleep") end },
    { "exit", "right", to = 41 },
  }, function() return rd("coins") == 22 and rd("cur_room") == 41, "coins=" .. rd("coins") .. " room=" .. rd("cur_room") end),
  S("The Deserted Mines: the pickaxe at the rock, the coin above it", {
    -- proxpickaxe box (16,101,48,20): stand on the middle-left ledge (y=128, x 36..60)
    { "drop", "pickaxe", at = { { 36, 60 }, 128 }, boxes = 1 },
    { "coin" },
  }, function() return rd("coins") == 23, "coins=" .. rd("coins") end),
  S("The Deserted Mines: the miner (touch his box at x 232): \"go away\", a shove, and the troll in the dungeon vanishes", {
    { "walk_to", x = { 212, 224 }, y = 160 },
    { "press", keys = { "right" }, passes = 3 },
    { "dismiss" },
  }, function() return troll_room() == 255, "troll room=" .. troll_room() end),
  S("Back into the Dragon's Lair along its middle slab: the rug (for Daisy's prison)", {
    { "exit", "left", to = 40, arrive = { y = 128 } },
    { "pickup", "rug" },
  }, function() return inv_has(12), "no rug" end),
  S("Out of the Dragon's Lair: round through 41 to the lower floor, up the lift, up the shaft into the hut", {
    { "exit", "right", to = 41 },
    { "exit", "left", to = 40, from = { y = 176 }, arrive = { y = 176 } },
    { "wait_for", function() return lair_lift_y() >= 130 end, sec = 90, what = "the lift bar at the bottom" },
    { "walk_to", x = { 32, 38 }, label = "onto the left edge of the lift bar" },
    { "wait_for", function() return lair_lift_y() <= 57 end, sec = 90, what = "the lift at its very top" },
    { "exit", "up", to = 56 },
  }),
  S("Up the tree to Daisy's hut by the upper platform of Denzil's Pad: the coin under the window frame", {
    { "exit", "right", to = 57 },
    { "exit", "right", to = 58, arrive = { y = 145 } },
    { "exit", "left", to = 57, arrive = { y = 120 } },
    { "exit", "up", to = 73 },
    { "exit", "left", to = 72 },
    { "exit", "right", to = 73, from = { y = 96 } },
    -- (known fidelity gap, NOTES T0236: coin_covered ignores tape-table actors, so the first DOWN here takes the coin
    -- through the window frame; the second takes the frame)
    { "pickup", "windowframe" },
    { "drop", "windowframe" },
  }, function() return rd("coins") == 24, "coins=" .. rd("coins") end),
  S("The long way west again: Dozy's hut, down through the well room, the dragon, the gator, to the Entrance Hall", {
    { "exit", "left", to = 72 },
    { "exit", "left", to = 71 },
    { "exit", "down", to = 54 },
    { "exit", "left", to = 53 },
    { "exit", "left", to = 52 },
  }),
  S("Down to the dungeon for its coin (the troll is gone) and back up", {
    { "exit", "down", to = 36 },
    { "exit", "left", to = 35 },
    { "exit", "right", to = 36, arrive = { y = { 160, 176 } } },
    { "coin" },
    { "exit", "left", to = 35 },
    { "exit", "right", to = 36, from = { y = 80 } },
    { "exit", "up", to = 52 },
  }, function() return rd("coins") == 25 and rd("cur_room") == 52, "coins=" .. rd("coins") .. " room=" .. rd("cur_room") end),
  S("Up into the castle (the third time): the knocker opens the door of the West Tower, the empty bucket", {
    { "exit", "left", to = 51, from = { y = 104 } },
    { "exit", "up", to = 67 },
    { "exit", "right", to = 68, arrive = { y = 148 } },
    { "exit", "left", to = 67, arrive = { y = 117 } },
    { "exit", "right", to = 68, arrive = { y = 88 } },
    { "exit", "up", to = 84 },
    { "drop", "knocker", at = { { 12, 20 }, 176 }, boxes = 1 },       -- proxdoor box (8,160,16,16)
    { "exit", "left", to = 83 },
    { "pickup", "bucket" },
  }, function() return inv_has(5) and rd("cur_room") == 83, "room=" .. rd("cur_room") end),
  S("Down out of the castle and east to the well room (the third time)", {
    { "exit", "right", to = 84 },
    { "exit", "down", to = 68 },
    { "exit", "left", to = 67 },
    { "exit", "right", to = 68, arrive = { y = { 140, 160 } } },
    { "exit", "left", to = 67, arrive = { y = { 160, 176 } } },
    { "exit", "down", to = 51 },
    { "exit", "right", to = 52 },
    { "exit", "right", to = 53, from = { y = 168 } },
    { "exit", "right", to = 54 },
    { "exit", "right", to = 55 },
  }),
  S("To the base of the volcano and fill the bucket", {
    { "exit", "right", to = 56, arrive = { y = 96 } },
    { "exit", "right", to = 57 },
    { "exit", "right", to = 58 },
    { "exit", "right", to = 59 },
    { "exit", "right", to = 60 },
    -- proxmtbucket box (56,144,16,16): the water at the foot of the slope
    { "drop", "bucket", at = { { 40, 56 }, 160 }, boxes = 1 },
    { "pickup", "fullbucket" },
  }, function() return inv_has(5), "no full bucket" end),
  S("The Smelly Allotment: the bean, then the bucket of water, and the beanstalk grows", {
    { "exit", "left", to = 59 },
    { "exit", "left", to = 58 },
    -- the plant box (156,160,32,16) is entered from x 136..140: clear of the manure (x 160..175), where DOWN would only show its message
    { "walk_to", x = { 136, 140 }, y = 176 },
    { "drop", "bean", boxes = 1 },
    { "drop", "fullbucket", boxes = 1, expect = function() return rd("stalk_grown") == 1, "stalk_grown=" .. rd("stalk_grown") end },
  }, function() return rd("stalk_grown") == 1, "stalk_grown=" .. rd("stalk_grown") end),
  S("Up the beanstalk", {
    { "exit", "up", to = 74 },
  }),
  S("The clouds: Complex Cloud Route", {
    { "exit", "right", to = 75 },
    { "coin" },
  }, function() return rd("coins") == 26, "coins=" .. rd("coins") end),
  S("The clouds: Yet More Clouds, More 'Orrible Clouds (coin)", {
    { "exit", "up", to = 91 },
    { "exit", "right", to = 92 },
    { "coin" },
  }, function() return rd("coins") == 27, "coins=" .. rd("coins") end),
  S("Near the Volcano Top: the coin on the cloud, reached by walking RIGHT off 92's left platform (the only way that lands on it), then back up", {
    -- ZX (T0232): every other fall from 92 chains 92 > 76 > 60 > 59, and 92's right platform (where 93 drops Dizzy) has no way back.
    { "exit", "down", to = 76, from = { y = 136 } },
    { "coin" },
    { "exit", "down", to = 59 },   -- 76 has no way back up (a jump bounces 76 > 92 > 76); the fall chains 60 > 59
  }, function() return rd("coins") == 28, "coins=" .. rd("coins") end),
  S("Back up the beanstalk and across the clouds to 92 again (no coins left on the way)", {
    { "exit", "left", to = 58 },
    { "exit", "up", to = 74 },
    { "exit", "right", to = 75 },
    { "exit", "up", to = 91 },
    { "exit", "right", to = 92 },
  }),
  S("The Cloud Castle (93) and on to Daisy's Prison (94)", {
    { "exit", "right", to = 93 },
    { "exit", "right", to = 94 },
  }),
  S("Daisy's Prison: the rug over the daggers", {
    { "drop", "rug", at = { { 8, 20 }, 168 }, boxes = 1 },
  }),
  S("Daisy's Prison: the coin under the table FIRST (the lowered lift covers it afterwards)", {
    { "coin" },
  }, function() return rd("coins") == 29, "coins=" .. rd("coins") end),
  S("Back to the Cloud Castle (93) by the carpets: a jump left from them lands on 93's right-hand shelf (y=120)", {
    -- ZX (T0232, with the rug's carpets poked in, ZXPOKE=ABC4=94,ABD4=94): from the carpets at x 24..32 JUMPLEFT leaves 94 and lands on 93's shelf
    { "exit", "left", to = 93, from = { y = 152 }, arrive = { y = { 112, 124 } } },
  }),
  S("93's stairs: a running jump right lands on the switch platform of 94 (y=80); walk to the switch: the lift lowers Daisy", {
    -- ZX (exits_zx, T0232): from 93's steps at (204,97)/(204,104)/(208,112) JUMPRIGHT lands in 94 on the y=80 platform (x 20..32), safe from the torches
    { "exit", "right", to = 94, arrive = { x = { 8, 44 }, y = { 76, 86 } } },
    { "walk_to", x = { 104, 136 }, y = 80, label = "the switch (120,70) on the y=80 platform" },
    { "wait_for", function() return prison_lift_y() >= 100 end, sec = 40, what = "the lift lowered" },
  }),
  S("Off the platform to the left, round via 93's shelf back into 94's left block (the lowered lift put Daisy at table height)", {
    { "exit", "left", to = 93 },
    { "exit", "right", to = 94 },
  }),
  S("Daisy's Prison: meet Daisy where the lowered lift puts her (box, tune, heart demo, box; she runs to her hut)", {
    { "touch", "daisy", boxes = 2,
      what = "Daisy gone from 94 and daisy1 in 73",
      ["until"] = function() return daisy_room() == 255 and daisy1_room() == 73 end },
  }, function() return daisy_room() == 255 and daisy1_room() == 73, "Daisy still in 94" end),
  S("Back out of the prison and down the cloud castle: 92's right platform drops Dizzy through 76 and 60 into 59 (the ZX does the same)", {
    { "exit", "left", to = 93 },
    { "exit", "left", to = 92 },
    { "exit", "down", to = 59 },
  }, function() return rd("coins") == 29, "coins=" .. rd("coins") end),
  S("Down off the volcano top and west along the tree-house village to Daisy's hut", {
    { "exit", "left", to = 58 },
    { "exit", "left", to = 57, arrive = { y = 176 } },
    { "exit", "right", to = 58, arrive = { y = 144 } },
    { "exit", "left", to = 57, arrive = { y = 120 } },
    { "exit", "up", to = 73 },
  }),
  S("The long way west: Dozy's hut, the well room, the gator, to the Entrance Hall", {
    { "exit", "left", to = 72 },
    { "exit", "left", to = 71 },
    { "exit", "down", to = 54 },
    { "exit", "left", to = 53 },
    { "exit", "left", to = 52 },
  }),
  S("West again through the castle moat and Armorog's den (fed) to the Guard House", {
    { "exit", "left", to = 51, from = { y = 168 } },
    -- staging point right of the gate's lethal columns (x 157..183): an overshoot to 180 killed him with the gate low
    { "walk_to", x = GATE_STAGE.x, y = GATE_STAGE.y },
    { "wait_for", gate_ok, sec = 60, what = "portcullis high and rising" },
    { "exit", "left", to = 50 },
    { "exit", "left", to = 49 },
  }),
  S("The Guard House westward (the hawk is at its far end for 64 passes), over the log to the Warehouse (47)", {
    { "wait_for", function() local n = hawk_n(); return n >= 46 and n <= 50 end, sec = 60, what = "hawk at the right end of its patrol" },
    { "exit", "left", to = 48 },
    { "exit", "left", to = 47 },
  }, function() return rd("cur_room") == 47, "room=" .. rd("cur_room") end),
  S("The Warehouse: the roof-top spot (x 136..152, feet 72), jump up to the Crafty Cloud (63) for the 30th coin, and back down", {
    { "walk_to", x = { 136, 148 }, y = 72, label = "the thatch-cap stand (the Warehouse roof, 72)" },
    { "exit", "up", to = 63 },
    { "coin" },
    { "exit", "down", to = 47 },
  }, function() return rd("cur_room") == 47 and rd("coins") == 30, "room=" .. rd("cur_room") .. " coins=" .. rd("coins") end),
  S("Back east: the log, the Guard House (hawk window), Armorog's den, up to the moat", {
    { "exit", "right", to = 48 },
    { "exit", "right", to = 49 },
    { "wait_for", function() local n = hawk_n(); return n >= 48 and n <= 52 end, sec = 60, what = "hawk at the right end of its patrol" },
    { "exit", "right", to = 50 },
    { "exit", "right", to = 51 },
  }),
  S("East through the portcullis, the Entrance Hall, the gator, the sleeping dragon, the well room", {
    { "walk_to", x = LEFT_STAGE_X, y = 136 },
    { "wait_for", gate_ok, sec = 60, what = "portcullis high and rising" },
    { "walk_to", x = 184, y = 144 },
    { "exit", "right", to = 52 },
    { "exit", "right", to = 53, from = { y = 168 } },
    { "exit", "right", to = 54 },
    { "exit", "right", to = 55 },
  }),
  S("Over the roof of the Lift Control Hut to the tree house, and up to Daisy's Empty Hut", {
    { "exit", "right", to = 56, arrive = { y = 96 } },
    { "exit", "right", to = 57 },
    { "exit", "right", to = 58 },
    { "exit", "left", to = 57, arrive = { y = 120 } },
    { "exit", "up", to = 73 },
  }),
  S("THE WIN: walk into Daisy with 30 coins: the completion tune under the boxes, the heart demo, then the title", {
    -- (the hut's lower floor has no way up: Daisy stands on the upper level, entered from Denzil's Pad, as for the window frame)
    { "exit", "left", to = 72 },
    { "exit", "right", to = 73, from = { y = 96 } },
    { "touch", "daisy1", sec = 180, what = "the win and the title",
      ["until"] = function()
        local w = E.win
        if w.set and E.in_title_wait() then w.tn = (w.tn or 0) + 1 else w.tn = 0 end
        if w.tn >= 30 and not w.title then w.title = true; w.title_t = E.mtime(); E.say("TITLE t=%.3f (title screen back)", w.title_t) end
        return w.title
      end },
  }, function() local w = PT_E.win; return w.set and w.coins == 30 and w.title, "win=" .. tostring(w.set) .. " coins_at_win=" .. tostring(w.coins) .. " title=" .. tostring(w.title) end),
}

-- ======================================================================================================================================================
-- THE ZX PLAN (R.override.zx.plan): the order in which the ORIGINAL can be played.  Only the lair leg moves.
--   THE LAIR DRAGON (room 40).  In the original its head (frame 109, x 144..160, y 136..152 +16) kills on every pass unless the dragon is asleep, and the only
--   thing that puts it to sleep is dropping the GOLDEN EGG OF ROOM 93 (X-ALL goldenegghere: the prox routine proxegg is attached to THAT record; the nest egg
--   goldenegghere1 has no prox pointer).  The port made the nest egg do it (harness pickup_and_drop), which is how its route crosses the lair floor early.
--   On the ZX the floor under the head is lethal at every swing phase (Dizzy's top is below the head's bottom even at its highest, and the 9 updates he needs
--   inside the head's columns outlast its 8-update high phase; measured: KILLED at x=124 with the head at its highest), the upper walkway ends at a
--   cave block (x 208..), and the middle slab is closed at its west end by a pillar (it is entered from room 41 only).  So the mines (41) cannot be entered
--   before the golden egg has been carried from the Cloud Castle (93) to the nest.  The ZX therefore does the bucket / beanstalk / clouds leg (segments 76..84)
--   FIRST, takes the egg in 93, brings it down and across the village to the hut, down its shaft into the lair, puts the dragon to sleep with it, and then plays the
--   port's lair/mines segments (69..72) unchanged; the dungeon coin (75, needs the miner's swap) follows, and the clouds are climbed a second time for the
--   prison (85..).  ZX-only segments have pair = nil; reused ones keep their port numbers (`pair`) for the side-by-side video.
-- ======================================================================================================================================================
local function steps_of(i, a, b) local t = {}; for j = a or 1, b or #R.segments[i].steps do t[#t + 1] = R.segments[i].steps[j] end; return t end
local function cat(...) local t = {}; for _, l in ipairs({ ... }) do for _, st in ipairs(l) do t[#t + 1] = st end end; return t end
local function lair_top() return lair_lift_y() <= 57 end
ZXO.plan = {}
local plan = ZXO.plan
for i = 1, 66 do plan[#plan + 1] = i end
plan[#plan + 1] = { name = "ZX: the lair's coin on the upper walkway, then straight back up the lift into the hut (the mines are not open yet: see the dragon note)", pair = 67,
  steps = { steps_of(67, 1, 1)[1],
    { "wait_for", lair_top, sec = 90, what = "the lift at its very top" },
    { "walk_to", x = { 32, 38 }, label = "onto the left edge of the lift bar" },
    { "wait_for", lair_top, sec = 90, what = "the lift at its very top" },
    { "exit", "up", to = 56 } },
  check = function() return rd("cur_room") == 56 and rd("coins") == 22, "room=" .. rd("cur_room") .. " coins=" .. rd("coins") end }
for _, i in ipairs({ 73, 74, 76, 77, 78, 79, 80, 81, 82, 83, 84 }) do plan[#plan + 1] = i end
plan[#plan + 1] = { name = "ZX: the Cloud Castle (93): the golden egg", pair = nil,
  steps = { steps_of(85, 1, 1)[1], { "pickup", "egg" } },
  check = function() return inv_has(10) and rd("cur_room") == 93, "egg=" .. tostring(inv_has(10)) .. " room=" .. rd("cur_room") end }
plan[#plan + 1] = { name = "ZX: back down the clouds with the egg (92's right platform drops Dizzy to 59)", pair = nil,
  steps = steps_of(92, 2, 3), check = function() return rd("cur_room") == 59 and inv_has(10), "room=" .. rd("cur_room") end }
plan[#plan + 1] = { name = "ZX: across the village into the hut, up its lift and down the shaft into the Dragon's Lair", pair = nil,
  steps = cat({ { "exit", "left", to = 58 }, { "exit", "left", to = 57, arrive = { y = 176 } }, { "exit", "left", to = 56 } }, steps_of(66, 5, 6)),   -- (from the hut floor: wait for the bar to be up, then step into the open shaft)
  check = function() return rd("cur_room") == 40 and inv_has(10), "room=" .. rd("cur_room") end }
plan[#plan + 1] = { name = "ZX: the lair: down the lift, the egg into the nest (the dragon sleeps), out east along the floor", pair = 68,
  steps = { steps_of(67, 2, 2)[1], steps_of(67, 3, 3)[1], steps_of(67, 4, 4)[1],
    { "walk_to", x = { 68, 84 }, y = 168, label = "left of the nest egg (standing on it, DOWN would pick the nest egg up) but inside the nest's box" },
    { "drop", "egg", boxes = 1, expect = function() return rd("dragon_asleep") == 1, "dragon_asleep=" .. rd("dragon_asleep") end },
    { "exit", "right", to = 41 } },
  check = function() return rd("cur_room") == 41 and rd("dragon_asleep") == 1, "room=" .. rd("cur_room") end }
for _, i in ipairs({ 69, 70, 71, 72 }) do plan[#plan + 1] = i end
plan[#plan + 1] = { name = "ZX: from the hut back up the tree to Daisy's hut and the long way west to the Entrance Hall", pair = nil,
  steps = cat(steps_of(73, 1, 4), steps_of(74)), check = function() return rd("cur_room") == 52, "room=" .. rd("cur_room") end }
plan[#plan + 1] = 75
plan[#plan + 1] = { name = "ZX: east again to the foot of the beanstalk and up the clouds to 92 (the stalk stays grown)", pair = nil,
  steps = cat(steps_of(77, 8, 10), steps_of(78, 1, 3), steps_of(84, 2, 5)), check = function() return rd("cur_room") == 92, "room=" .. rd("cur_room") end }
for i = 85, #R.segments do plan[#plan + 1] = i end
for _, i in ipairs({ 69, 73, 75, 81, 82, 83 }) do ZXO.checks[i] = false; CO.checks[i] = false end   -- coin counts of the port's order (the CoCo plays the original's order now too)
-- Daisy's meeting: the ZX shows THREE boxes (the meeting, one in the heart-demo room 3, "daisy runs"); the port's scene has two.
do local c = {}; for k, v in pairs(steps_of(91, 1, 1)[1]) do c[k] = v end; c.boxes = 3; ZXO.steps["91.1"] = c end
-- CoCo (T0237): the left-to-right crossing under the portcullis.  The port's kill box is taller than the original's (REACH_MARGIN: head = feet-25 instead of -18),
-- so the safe window (gate bottom above the head, y <= 103) is only ~6.7 Dizzy passes at the original's gate speed, against the 6 passes inside the gate's columns the
-- walk needs: the planner's wait_for + navigate latency (a pass or two, and it differs between a continuous run and a checkpoint resume) is too much.  Replace
-- "wait_for gate_ok; walk_to 184,144" by a fixed 7-pass walk right that starts the moment the gate has risen to 104, then the planner takes over at x=180.
local function gate_cross_ok() return gate_y() == 104 and gate_v1() >= 128 end     -- exactly the START of the window (the gate stays at each even y for 1-2 passes)
for si, seg in ipairs(R.segments) do
  for j = 1, #seg.steps - 2 do
    local a, b, c = seg.steps[j], seg.steps[j + 1], seg.steps[j + 2]
    if a[1] == "walk_to" and a.x == LEFT_STAGE_X and a.y == 136 and b[1] == "wait_for" and b[2] == gate_ok and c[1] == "walk_to" and c.x == 184 and c.y == 144 then
      CO.steps[si .. "." .. (j + 1)] = { seq = { { "wait_for", gate_cross_ok, sec = 60, what = "portcullis rising through y=104" }, { "press", keys = { "right" }, passes = 7 } } }
    end
  end
end

-- CoCo (T0235 + T0237): the lair dragon needs the golden egg of room 93 now (T0235), so the CoCo plays the SAME order as the original (the plan above): the
-- port-specific per-step overrides stay in CO.steps, the ZX ones (ZXO.steps) are not applied to it.
CO.plan = ZXO.plan
return R
