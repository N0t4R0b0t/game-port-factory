-- harness/cmaskverify.lua -- T0163/T0166 (Change 1): does the collision
-- mask DERIVED at room load from placements (derive_room_cmask, straight
-- into CUR_ROOM_CMASK, patched by dc_patch for rooms 51/84) agree
-- byte-for-byte with the EXPECTED mask computed offline?
--
-- T0166 REWRITE: the stored per-room mask (room_cmask_lz) this script
-- used to diff CUR_ROOM_CMASK against in RAM is GONE -- removing it was
-- the whole point of Change 1's delivery half (NOTES.md "Decision:
-- remove the stored masks NOW"). The comparison now reads its
-- expectation from target/cmask_expected.bin (tools/derive_cmask.py
-- --dump-expected), 27 rooms x 384 bytes concatenated in BUILT_ROOMS
-- order -- that script's own "full" derivation, proved against the
-- REAL shipped masks while they still existed ("Change 1 PROVED
-- OFFLINE": 0 bytes/0 cells different, all 27 rooms) and unaffected by
-- their removal, since it re-derives from rooms.json + FRAMES.DAT, not
-- from the target's own asm. Regenerate the dump if rooms.json or
-- FRAMES.DAT ever changes:
--   python3 tools/derive_cmask.py --dump-expected target/cmask_expected.bin
--
-- Every room must match, INCLUDING 51 and 84 -- that's what proves
-- dc_patch's hardcoded 6 bytes are right, not just present.
--
-- Warps into every BUILT room in turn (the `killed=1`/respawn mechanism
-- roomsweep.lua and rate.lua already use -- a real death->respawn->
-- load_room round trip, not a raw memory poke), waits for
-- room_load_seq to bump (load_room, including derive_room_cmask, has
-- run), then diffs the 384 bytes at CUR_ROOM_CMASK against this room's
-- 384-byte slice of the expected-mask dump. One PASS/FAIL line per
-- room, plus a summary.
--
-- The wait after room_load_seq bumps is generous (up to 600 frames/10s)
-- because derive_room_cmask's own cost is NOT a fraction of a frame --
-- see harness/cmasktime.lua's own numbers. This script does not measure
-- that; it only needs to wait it out so the comparison isn't read
-- mid-derivation.
--
--   python3 tools/derive_cmask.py --dump-expected target/cmask_expected.bin
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none \
--     -seconds_to_run 600 -autoboot_script harness/cmaskverify.lua
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local row3 = manager.machine.ioport.ports[":row3"]
local fl = {} ; for n, f in pairs(row3.fields) do fl[n] = f end
local function key(n, d) fl[n]:set_value(d and 1 or 0) end

-- T0233: all-RAM-aware, same as harness/jumptrace.lua's own load_decb --
-- needed for the tape build (CMASK_TAPE=1), which carries a real DECB
-- block at $8000+ (the tape-only region); a plain write loop silently
-- drops it under ROM mode. Harmless for the -run build: it never has a
-- block >= $8000, so `allram` never flips there.
local function load_decb(path)
  local fh = io.open(path, "rb"); local data = fh:read("*all"); fh:close()
  local pos = 1
  local allram = false
  while pos <= #data do
    local t = data:byte(pos)
    if t == 0 then
      local len = data:byte(pos+1)*256 + data:byte(pos+2)
      local addr = data:byte(pos+3)*256 + data:byte(pos+4)
      if addr >= 0x8000 and not allram then mem:write_u8(0xffdf, 0); allram = true end
      for i = 0, len-1 do mem:write_u8(addr+i, data:byte(pos+5+i)) end
      pos = pos + 5 + len
    elseif t == 0xFF then return data:byte(pos+3)*256 + data:byte(pos+4)
    else break end
  end
end

-- the frame-30 load's one stray write ($00 at $3521, NOTES.md T0125)
local function stray_fix(path)
  local fh = io.open(path, "rb"); local d = fh:read("*all"); fh:close()
  local pos = 1
  while pos <= #d and d:byte(pos) == 0 do
    local len = d:byte(pos+1)*256 + d:byte(pos+2)
    local addr = d:byte(pos+3)*256 + d:byte(pos+4)
    for i = 0, len-1 do
      local a = addr + i
      if a >= 0x0E00 and a < 0x8000 and mem:read_u8(a) ~= d:byte(pos+5+i) then
        mem:write_u8(a, d:byte(pos+5+i))
      end
    end
    pos = pos + 5 + len
  end
end

local SYM = {}
for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n, a = line:match("^Symbol: (%S+) %(.-%) = (%x+)$")
  if n then SYM[n] = tonumber(a, 16) end
end

-- Every room tools/derive_cmask.py's BUILT_ROOMS checks EXCEPT room 2
-- (found chasing a T0166 FAIL, not a T0166 regression): room 2 is not a
-- walkable room at all -- it is 4 flame placements used ONLY as data for
-- room 36's fire-pit overlay (draw_fire_overlay, NOTES.md "the real fire
-- mechanic"), and it has no entry in room36.asm's room_desc_table, so
-- load_room can never actually load it (lr_unknown, leaving whatever the
-- PREVIOUS room's load left behind untouched). Forcing cur_room=2 via
-- this script's own warp() sets cur_room directly (bypassing load_room's
-- dispatch), so this file's OLD design -- diffing two buffers load_room
-- both filled -- passed here by COINCIDENCE (both stale-equal, from
-- whatever the previous load left), not because room 2's mask was ever
-- actually derived. Comparing against an independent ground truth
-- (this file's whole T0166 rewrite) correctly turns that into a FAIL,
-- which is why room 2 is excluded here rather than "fixed": there is
-- nothing to derive for a room load_room never loads.
-- T0233: CMASK_TAPE=1 selects the tape-only region's own rooms (does
-- not exist in the -run build at all) instead of the -run build's
-- BUILT_ROOMS -- matches tools/derive_cmask.py's own CMASK_TAPE switch.
-- Room 77 (THE ACTIVE VOLCANO) is now built too (T0233-fix: roompack's
-- water-phase panic fixed, see tools/regen_art.sh's own note).
local TAPE = os.getenv("CMASK_TAPE") == "1"

local ROOMS = {22,23,24,35,36,39,50,51,52,53,54,55,56,57,
               58,59,60,
               67,68,69,70,71,72,83,84,85,86,87,100,76}
local TAPE_ROOMS_LIST = {74,75,63,91,92,45,48,49,94,89,41,73,88,93,40,46,31,47,77}
if TAPE then ROOMS = TAPE_ROOMS_LIST end

-- Per-room WALKABLE spots (harness/roomsweep.lua's own "spots that work",
-- NOTES.md "Room sweep", plus tools/roomview.py --surfaces for the four
-- rooms added since that list was written: 22/24/57/72). This is what
-- this script warps Dizzy INTO -- unlike a single-shot check, this one
-- waits out room_load_seq bumps and restarts its settle clock on every
-- further one (see the "settle" stage below), so an UNSAFE spot doesn't
-- just read stale data, it respawns Dizzy into a hazard forever and the
-- room never finishes. Room 2 has no placements at all (0 solid, T0163's
-- derive is instant either way) so any spot is fine there.
local POS = {
  [36]={80,176}, [35]={112,152}, [51]={76,136}, [52]={80,168}, [53]={20,104},
  [54]={200,176}, [68]={100,176}, [69]={128,176}, [55]={164,176}, [67]={112,176},
  [84]={184,72}, [85]={56,150}, [83]={200,176}, [86]={200,176}, [100]={100,176},
  [70]={120,100}, [87]={200,96}, [50]={24,168}, [56]={72,136}, [71]={136,96},
  [39]={20,176}, [23]={216,120}, [22]={64,176}, [24]={80,120}, [57]={128,176},
  [72]={120,160}, [2]={128,176},
  -- T0??? -- 58/59/60, derived from target/cmask_expected.bin's widest
  -- ground-level solid run (roomview.py --surfaces is stale post-Change-1,
  -- still reading the shipped room_cmask_lz Change 1 removed -- see its
  -- own header; the "full" derivation this file already loads is the
  -- same ground truth, so a one-off script over it stands in).
  [58]={80,176}, [59]={40,176}, [60]={60,160},
}
-- T0233: tape-only rooms' own safe spawns -- tools/start_pos.py's own
-- output for each room (the same tool play.sh/tape_pack.sh use).
local TAPE_POS = {
  [74]={132,168}, [75]={52,152}, [63]={108,168}, [91]={172,160},
  [92]={124,96}, [45]={196,136}, [48]={16,104}, [49]={204,160},
  [94]={92,160}, [89]={52,104}, [41]={180,104}, [73]={52,88},
  [88]={180,168}, [93]={180,168}, [40]={144,120}, [46]={104,136},
  [31]={28,168}, [47]={188,136}, [77]={88,135},
}
if TAPE then POS = TAPE_POS end

local CM_LEN = 1536          -- T0187: 192 rows of 1px, not 48 of 4px

-- T0188: bytes where the TARGET is deliberately not equal to
-- tools/derive_cmask.py's "full" derivation, because the DERIVATION is
-- the one that is wrong. These are the negative-pixel_x slivers in rooms
-- 51/60/84 that dc_patch paints back. Patching them per-row to match the
-- offline mask exactly made ALL FIFTEEN room-51 cases NEVER-ARRIVE --
-- Dizzy could not stand where the ORIGINAL stands him (checked against
-- the ZX log, which completes every one). The coarse 4-row patch
-- over-paints relative to the offline mask and matches the REAL GAME
-- better. Counted as deviations, not failures, so this harness stays
-- meaningful; see NOTES.md T0188 for the evidence and the open question.
local KNOWN_DEV = {
  [51] = {[1088]=true,[1120]=true,[1128]=true},
  [60] = {[1280]=true,[1320]=true},
  [84] = {[1080]=true,[1096]=true,[1112]=true,[1120]=true,[1128]=true,[1144]=true},
}
-- T0233: the SAME negative-pixel_x-sliver class as T0188 above, found in
-- three of the tape-only rooms (48/94/40) once the frame_table bug was
-- fixed and cmaskverify actually started reading real per-room masks.
-- All three hit tools/regen_art.sh's "pixel_x N is off the left edge,
-- skipped, not clamped" warning during generation; every byte differs
-- only at col-byte 0 (x=0..7, the screen's own left edge) with the
-- SAME shape T0188 documents (derived has fewer solid bits than the
-- naive offline derivation, never more) -- not accepted from the
-- pattern alone: `harness/jumptrace.lua` walking LEFT into the wall in
-- each room (RM=94 SX=92 SY=160 DIR=LEFT; RM=48 SX=16 SY=104 DIR=LEFT;
-- RM=40 SX=144 SY=120 DIR=LEFT) shows Dizzy walks smoothly across every
-- one of these rows with floor=1 throughout, transitioning cleanly to
-- the neighbouring room at the edge -- never stranded, never falling
-- through. No dc_patch equivalent added (T0188's own lesson: patching
-- to match the offline mask exactly risks a NEVER-ARRIVE regression);
-- accepted as-is, same as 51/60/84.
local TAPE_KNOWN_DEV = {
  [48] = {[896]=true,[904]=true,[912]=true,[928]=true,[936]=true,[944]=true},
  [94] = {[384]=true,[392]=true,[400]=true,[408]=true,[416]=true,[424]=true,[432]=true,
          [960]=true,[968]=true,[976]=true,[992]=true,[1000]=true,[1008]=true},
  [40] = {[704]=true,[712]=true,[720]=true,[728]=true,[736]=true,[744]=true,[752]=true,
          [760]=true,[768]=true,[776]=true,[784]=true,[792]=true,[800]=true,[808]=true,
          [816]=true},
  -- T0233-fix: room 77's own single-bit deviation (4 bytes, one pixel-
  -- column each) -- NOT the negative-pixel_x class above. tools/
  -- roomview.py 77 shows these 4 rows (172-175) at col-byte 3 (x=24-31)
  -- buried deep inside a solid rock mass, not a walkable surface or its
  -- edge -- Dizzy cannot physically stand there regardless of which
  -- side is "correct", so unlike the other entries this one wasn't
  -- walk-tested (there is nowhere to walk to). Left as a genuine open
  -- question for whether it's a per-cell-attribute edge case (the
  -- offline deriver's own "5/19 rooms where the per-cell test changes
  -- the outcome" note) rather than assumed caused by the water-phase
  -- fix (derive_cmask.py's own solidity check does not model dither
  -- phase at all).
  [77] = {[1379]=true,[1387]=true,[1395]=true,[1403]=true},
}
if TAPE then KNOWN_DEV = TAPE_KNOWN_DEV end
local function r(s) return mem:read_u8(SYM[s]) end

-- T0166: the expected mask per room, loaded from tools/derive_cmask.py
-- --dump-expected's own output -- see this file's header comment. The
-- dump is written in tools/derive_cmask.py's own BUILT_ROOMS order (27
-- rooms, INCLUDING room 2 -- that script has no reason to exclude it,
-- it never warps anywhere) -- kept here as DUMP_ROOMS, deliberately
-- separate from this file's own (26-room) ROOMS list, so the two lists
-- can differ (as they now do) without silently mis-indexing the slice.
local DUMP_ROOMS = {2,22,23,24,35,36,39,50,51,52,53,54,55,56,57,
                     58,59,60,
                     67,68,69,70,71,72,83,84,85,86,87,100,76}
-- T0233: tools/derive_cmask.py's own TAPE_BUILT_ROOMS order (CMASK_TAPE=1
-- there too) -- must match exactly, it's a flat concatenation this
-- script slices by position, same as DUMP_ROOMS above.
if TAPE then DUMP_ROOMS = TAPE_ROOMS_LIST end
local EXPECT = {}
do
  local path = os.getenv("CMASK_EXPECTED") or "target/cmask_expected.bin"
  local fh = io.open(path, "rb")
  if not fh then
    error("cmaskverify: can't open " .. path ..
          " -- run: python3 tools/derive_cmask.py --dump-expected " .. path)
  end
  local data = fh:read("*all"); fh:close()
  if #data ~= #DUMP_ROOMS * CM_LEN then
    error(string.format("cmaskverify: %s is %d bytes, expected %d (%d rooms x %d) -- "
      .. "DUMP_ROOMS here and BUILT_ROOMS in tools/derive_cmask.py have drifted apart",
      path, #data, #DUMP_ROOMS * CM_LEN, #DUMP_ROOMS, CM_LEN))
  end
  for i, room in ipairs(DUMP_ROOMS) do
    EXPECT[room] = data:sub((i - 1) * CM_LEN + 1, i * CM_LEN)
  end
end

local f, loaded = 0, false
local boot_live, stage, t, idx = 0, "boot", 0, 1
local prev_seq
local rebumps = 0
local pass_n, fail_n, skip_n, results = 0, 0, 0, {}

local function warp(room)
  mem:write_u8(SYM.lives, 2)
  prev_seq = r("room_load_seq")
  local p = POS[room] or {100, 176}
  mem:write_u8(SYM.respawn_room, room)
  mem:write_u8(SYM.respawn_x, p[1])
  mem:write_u8(SYM.respawn_y, p[2])
  mem:write_u8(SYM.killed, 1)
end

local function compare_masks(room)
  local dev_n = nil
  local actual_room = r("cur_room")
  if actual_room ~= room then
    -- Even a walkable spot (POS above) can be an edge some rooms transition
    -- straight out of (room 39's ledge, room 70's empty sky -- NOTES.md
    -- "Room sweep" says the ORIGINAL does the same at both) -- if Dizzy
    -- left before the settle window elapsed, cur_room has moved on and
    -- CUR_ROOM_CMASK is for that other room, not the one this call
    -- thinks it's checking. Report it as its own thing, not a silent
    -- wrong-room compare.
    print(string.format("CMASK room %3d: SKIP -- drifted to room %d before settle finished", room, actual_room))
    -- T0172: counted as a SKIP, NOT a FAIL. It used to bump fail_n, so the
    -- summary read "27 PASS, 2 FAIL" for a run whose per-room lines had no
    -- FAIL in them at all -- which cost a false alarm and a bisect that
    -- found nothing. A drift means the room was NOT VERIFIED; that is not
    -- the same claim as "its mask is wrong", and the summary must not make
    -- it. Still not green, just named correctly.
    skip_n = skip_n + 1
    results[#results+1] = { room = room, diff = -2, drift = actual_room }
    return
  end
  local expected = EXPECT[room]
  local bytes_diff, first = 0, nil
  local diffbytes = {}
  for i = 0, CM_LEN - 1 do
    local a = mem:read_u8(SYM.CUR_ROOM_CMASK + i)
    local b = expected:byte(i + 1)
    if a ~= b then
      if KNOWN_DEV[room] and KNOWN_DEV[room][i] then
        dev_n = (dev_n or 0) + 1
        goto continue_byte
      end
      bytes_diff = bytes_diff + 1
      if not first then first = i end
      if #diffbytes < 8 then
        diffbytes[#diffbytes+1] = string.format("[%d] derived=$%02x expected=$%02x", i, a, b)
      end
    end
    ::continue_byte::
  end
  if bytes_diff == 0 then
    print(string.format("CMASK room %3d: PASS (%d bytes match%s)", room, CM_LEN,
      dev_n and string.format(", %d known deviation(s)", dev_n) or ""))
    pass_n = pass_n + 1
  else
    print(string.format("CMASK room %3d: FAIL %d/384 bytes differ, first at offset %d (row %d col-byte %d)",
      room, bytes_diff, first, first // 8, first % 8))
    for _, d in ipairs(diffbytes) do print("    " .. d) end
    fail_n = fail_n + 1
  end
  results[#results+1] = { room = room, diff = bytes_diff }
end

emu.register_periodic(function()
  f = f + 1
  if f == 30 and not loaded then
    cpu.state["PC"].value = load_decb(os.getenv("DIZZY_BIN")); loaded = true
  end
  if not loaded then return end
  if f == 31 then stray_fix(os.getenv("DIZZY_BIN")) end
  if stage ~= "boot" and r("lives") < 2 then mem:write_u8(SYM.lives, 2) end

  if stage == "boot" then
    if f % 14 == 0 then key("SPACE", (f // 14) % 2 == 0) end
    boot_live = (r("cur_room") == 36 and r("dizzy_y") ~= 0) and boot_live + 1 or 0
    if boot_live >= 60 then
      key("SPACE", false)
      warp(ROOMS[idx])
      stage, t = "wait_seq", f
    end

  elseif stage == "wait_seq" then
    -- SPACE clears the death/respawn message box and any new-life tune
    if f % 14 == 0 then key("SPACE", (f // 14) % 2 == 0) end
    if r("room_load_seq") ~= prev_seq then
      prev_seq = r("room_load_seq")
      stage, t = "settle", f
    elseif f - t > 600 then
      print(string.format("CMASK room %3d: FAIL room_load_seq never advanced (timed out)", ROOMS[idx]))
      fail_n = fail_n + 1
      results[#results+1] = { room = ROOMS[idx], diff = -1 }
      idx = idx + 1
      if idx > #ROOMS then stage = "done" else warp(ROOMS[idx]); stage, t = "wait_seq", f end
    end

  elseif stage == "settle" then
    -- generous margin past the seq bump -- derive_room_cmask's own cost
    -- is multiple SECONDS for a placement-heavy room (cmasktime.lua), not
    -- a fraction of a frame, so give it real headroom before reading.
    --
    -- Even a WALKABLE spot (POS above) doesn't rule out a hazard nearby
    -- respawning Dizzy AGAIN before he's fully settled, which bumps
    -- room_load_seq a second time WITHOUT this script asking for it. An
    -- elapsed-frames-since-the-FIRST-bump check can then fire while THAT
    -- second derive is still mid-flight (same multi-second cost as the
    -- first), reading a half-built buffer and reporting a phantom
    -- mismatch that has nothing to do with T0163's own correctness --
    -- this is exactly what produced wildly different byte-diff counts
    -- across otherwise-identical runs while this bug was being chased.
    -- Restart the clock on every further bump, capped so a genuinely
    -- unsafe spot can't hang the run forever.
    if f % 14 == 0 then key("SPACE", (f // 14) % 2 == 0) end
    if r("room_load_seq") ~= prev_seq then
      prev_seq = r("room_load_seq")
      t = f
      rebumps = rebumps + 1
    end
    if rebumps > 5 then
      print(string.format("CMASK room %3d: FAIL respawned %d times without settling (bad warp spot?)", ROOMS[idx], rebumps))
      fail_n = fail_n + 1
      results[#results+1] = { room = ROOMS[idx], diff = -3 }
      idx = idx + 1
      rebumps = 0
      if idx > #ROOMS then stage = "done" else warp(ROOMS[idx]); stage, t = "wait_seq", f end
    elseif f - t > 600 then
      key("SPACE", false)
      compare_masks(ROOMS[idx])
      idx = idx + 1
      rebumps = 0
      if idx > #ROOMS then
        stage = "done"
      else
        warp(ROOMS[idx])
        stage, t = "wait_seq", f
      end
    end

  elseif stage == "done" then
    print(string.format("CMASKSUM %d rooms, %d PASS, %d FAIL, %d SKIP (not verified)",
                        #ROOMS, pass_n, fail_n, skip_n))
    stage = "finished"
    manager.machine:exit()
  end
end)
