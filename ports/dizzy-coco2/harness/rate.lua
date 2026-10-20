-- Measure the mainloop PASS RATE, per room, straight out of RAM.
--
-- WHY THIS EXISTS: "does this change cost anything?" has come up in
-- T0073, T0079, T0080, T0081 and T0082, and every time the answer had
-- to be a number rather than a feeling. This lived in a scratch
-- directory for three of those and got deleted between sessions twice,
-- so it is committed now.
--
-- HOW: rng_ctr is STEPPED once per mainloop pass (room36.asm), so
-- counting how often it CHANGES over a known number of emulated 60Hz
-- frames gives passes/sec directly.
--
-- Count CHANGES, never deltas. rng_ctr stopped being a plain counter
-- and is now an 8-bit Galois LFSR (gameplay.asm's own note), so
-- consecutive values differ by a pseudo-random amount averaging ~128.
-- Summing deltas reports about 128x the true rate -- 2082 passes/sec
-- for a build actually running at ~15. An LFSR step never repeats the
-- previous value, so one change == one pass, exactly.
--
-- emu.register_periodic fires once per emulated 60Hz frame here
-- (measured: 200 calls = 3.336s of machine time), so the frame counts
-- below really are emulated seconds regardless of -nothrottle.
--
-- The pacing quantises each pass to a whole number of 60Hz fields
-- (FRAME_FIELDS), so healthy numbers are 15.0 (4 fields) and 12.0 (5).
-- A room sitting at something in between is losing some passes to a
-- spike -- see NOTES.md T0064/T0073 for that failure mode.
--
--   DIZZY_BIN=... DIZZY_MAP=... [RATE_ROOMS=36,35,51] \
--     mame coco2b -ext "" -autoboot_script harness/rate.lua \
--       -video none -sound none -nothrottle -seconds_to_run 45
--
-- NOTE (NOTES.md T0061, learned twice): SPACE is toggled for the WHOLE
-- run, not just the boot messages. Any mechanic that fires and shows a
-- message leaves msg_wait_dismiss blocking the main loop, and a frozen
-- game reads as a very slow one.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local row3 = manager.machine.ioport.ports[":row3"]
local fl = {} ; for n, f in pairs(row3.fields) do fl[n] = f end
local function key(n, d) fl[n]:set_value(d and 1 or 0) end

local function load_decb(path)
  local fh = io.open(path, "rb"); local data = fh:read("*all"); fh:close()
  local pos = 1
  local allram=false
  while pos <= #data do
    local t = data:byte(pos)
    if t == 0 then
      local len = data:byte(pos+1)*256 + data:byte(pos+2)
      local addr = data:byte(pos+3)*256 + data:byte(pos+4)
      if addr>=0x8000 and not allram then mem:write_u8(0xffdf,0); allram=true end
      for i = 0, len-1 do mem:write_u8(addr+i, data:byte(pos+5+i)) end
      pos = pos + 5 + len
    elseif t == 0xFF then return data:byte(pos+3)*256 + data:byte(pos+4)
    else break end
  end
end

-- T0125 (NOTES.md "harness traps"): the frame-30 load resumes BASIC's
-- cold-start RAM sweep mid-instruction, and its last write lands at $3521
-- ($00, X=$3527) inside whatever that build assembled there -- in T0125,
-- cdt_key's `lda #255`, which silently broke key 1 in every harness run.
-- start: writes nothing in $0E00-$7FFF during its first frame (lz_unpack's
-- variables are in the low region, its output at $8000+), so a byte there
-- that differs from the file one frame after the load is that stray
-- write: put it back, and say so.
local function stray_fix(path, memspace)
  local fh=io.open(path,"rb"); local d=fh:read("*all"); fh:close(); local pos=1
  while pos<=#d and d:byte(pos)==0 do
    local len=d:byte(pos+1)*256+d:byte(pos+2); local addr=d:byte(pos+3)*256+d:byte(pos+4)
    for i=0,len-1 do local a=addr+i
      if a>=0x0E00 and a<0x8000 then local want=d:byte(pos+5+i)
        if memspace:read_u8(a)~=want then memspace:write_u8(a,want)
          print(string.format("STRAYFIX $%04X restored %02X", a, want)) end end end
    pos=pos+5+len
  end
end
local SYM = {}
for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n, a = line:match("^Symbol: (%S+) %(.-%) = (%x+)$")
  if n then SYM[n] = tonumber(a, 16) end
end

local rooms = {}
for r in (os.getenv("RATE_ROOMS") or "36,35,51,52,53,54,55,67,68,69"):gmatch("[^,]+") do
  rooms[#rooms+1] = tonumber(r)
end

-- Where to stand in each room. One fixed position for all of them does
-- NOT work: (100,176) is room 51's moat, so the warp drops him through
-- the floor into room 35 and the "room 51" number is really room 35's.
-- These are the middle of each room's widest walkable surface, taken
-- from `tools/roomview.py <room> --surfaces` -- regenerate them the
-- same way if a room's art changes.
--
-- Widest is a starting point, not the rule: it must also be clear of
-- HAZARDS. Room 36's widest surface is the y=80 slab, which is the
-- rat's own patrol line (rathere at 40,73), so parking there gets Dizzy
-- killed on a loop and reads as 8.2 passes/sec of "performance". Check
-- the room's actor list before trusting a spot.
local POS = {
  [36] = { 80, 176}, [35] = {112, 152}, [51] = { 76, 136},
  [52] = { 80, 168}, [53] = { 20, 104}, [54] = {128, 176},
  [55] = {164, 176}, [67] = {112, 176}, [68] = {100, 176},
  [69] = {128, 176},
  -- T0237 (tape build): hawk room, Daisy's room, the lift room
  [49] = {40, 176}, [94] = {12, 168}, [56] = {24, 176},
}

-- RATE_POS="94:12:168,49:40:176" overrides POS entries.
for r,x,y in (os.getenv("RATE_POS") or ""):gmatch("(%d+):(%d+):(%d+)") do POS[tonumber(r)]={tonumber(x),tonumber(y)} end

-- Per room: warp in, let it settle, then count over the sample window.
-- T0169: SETTLE must clear the post-respawn TRANSIENT, not just "settle".
-- Every death/respawn runs the message box, the tune, load_room and a FULL
-- redraw inside ONE mainloop pass -- ~143 frames before Change 1, ~197 after.
-- The old default of 150 sampled INSIDE that pass, so it reported 11.0 for a
-- build whose steady state is 15.0, and a 25%% "regression" was filed off it.
-- Sweeping settle shows: 150 -> 11.0, 200 -> 14.0, 250 -> 15.2, 300+ -> 15.0
-- flat out to 1900. 400 is comfortably past it.
-- Both are env-overridable BECAUSE they were not, and an attempt to override
-- SETTLE from the environment silently did nothing, which is what produced the
-- false regression.
local SETTLE = tonumber(os.getenv("RATE_SETTLE") or "400")
local SAMPLE = tonumber(os.getenv("RATE_SAMPLE") or "240")
local idx, phase, t0 = 1, "warp", 0
local last, passes = nil, 0
local f, loaded = 0, false

emu.register_periodic(function()
  f = f + 1
  if f == 30 and not loaded then
    cpu.state["PC"].value = load_decb(os.getenv("DIZZY_BIN")); loaded = true
    print(string.format("%-6s %-12s %s", "room", "passes/sec", "(15.0 = 4 fields, 12.0 = 5)"))
  end
  if not loaded then return end
  if f == 31 then stray_fix(os.getenv("DIZZY_BIN"), mem) end
  local rel = f - 30
  if rel % 14 == 0 then key("SPACE", (rel // 14) % 2 == 0) end
  if rel < 60 then return end
  -- T0126: not a fixed 60 frames -- wait until the GAME is running. The
  -- first warp used to land 1s after load, i.e. during boot (unpacking,
  -- title, new-life jingle), so room 36's sample window depended on how
  -- long boot takes: a slower decoder "dropped" room 36 from 15.0 to 12.0
  -- while every later room read the same.
  if not game_running then
    if mem:read_u8(SYM.cur_room) == 36 and mem:read_u8(SYM.dizzy_y) ~= 0
       and mem:read_u8(SYM.dizzy_floor) == 1 and rel > 200 then
      game_running = true
      key("SPACE", false)
    end
    return
  end
  if idx > #rooms then return end

  if phase == "warp" then
    local p = POS[rooms[idx]] or {100, 176}
    mem:write_u8(SYM.respawn_room, rooms[idx])
    mem:write_u8(SYM.respawn_x, p[1])
    mem:write_u8(SYM.respawn_y, p[2])
    mem:write_u8(SYM.lives,2)  -- T0114: the warp is a death; 2 spare lives run out by room 52

    mem:write_u8(SYM.killed, 1)
    phase, t0 = "settle", rel
  elseif phase == "settle" then
    if rel - t0 >= SETTLE then
      phase, t0 = "sample", rel
      last, passes = mem:read_u8(SYM.rng_ctr), 0
    end
  elseif phase == "sample" then
    local cur = mem:read_u8(SYM.rng_ctr)
    if cur ~= last then passes = passes + 1 end  -- CHANGES, not deltas
    last = cur
    if rel - t0 >= SAMPLE then
      local got = mem:read_u8(SYM.cur_room)
      local rate = passes / (SAMPLE / 60.0)
      print(string.format("%-6d %-12.1f %s", rooms[idx], rate,
        got == rooms[idx] and "" or ("  !! warp landed in room " .. got)))
      idx = idx + 1
      phase = "warp"
    end
  end
end)
