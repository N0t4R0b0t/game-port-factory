-- Render/sound verifier, run under MAME on the shipped .sna with real (emulated) keys.
-- A tracking bot plays until GAME OVER (RC_MODE=over, stops tracking at frame 600)
-- or until the last brick falls (RC_MODE=win, tracks throughout). Asserts:
--  1. cadence: the published step advances by exactly 1 every frame (the beeper
--     slices and redraws never cost a 50 Hz frame; one sim step per frame);
--  2. sound: effects fired for a brick hit, a paddle bounce, a miss and game over
--     (SND_ID $F092 sampled while SND_PTR $F090 is non-zero);
--  3. screen integrity at GAME OVER (ball hidden, nothing moving): popcount of the
--     brick rows == 217 px per live brick (+12 px for the frozen ball on a win), the paddle row == 244 px, and the
--     field rows between/below them (excluding the message row) are all zero =
--     no XOR erase debris.
-- Prints "RCHECK PASS ..." or "RCHECK FAIL <why>".
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local function field(prefix)
  for _, pn in ipairs({":LINE0",":LINE1",":LINE2",":LINE3",":LINE4",":LINE5",":LINE6",":LINE7"}) do
    for n, fl in pairs(manager.machine.ioport.ports[pn].fields) do
      if n:sub(1, #prefix) == prefix then return fl end
    end
  end
end
local kz, kx, ksp = field("z "), field("x "), field("SPACE")
local rmode = os.getenv("RC_MODE") or "over"
local finished = false
local function fail(why) if finished == "failed" then return end; print("RCHECK FAIL " .. why); finished = "failed"; manager.machine:exit() end
local function pop(v) local c = 0; while v > 0 do c = c + (v & 1); v = v >> 1 end; return c end
local function cellrow_addr(r) return 0x4000 + (r >> 3) * 0x800 + (r & 7) * 32 end -- line 0 of char row r
local function rowpop(r, c0, c1)  -- popcount over the 8 pixel lines of cells c0..c1 of char row r
  local t = 0
  for ln = 0, 7 do for c = c0, c1 do t = t + pop(mem:read_u8(cellrow_addr(r) + ln * 256 + c)) end end
  return t
end
local n, prev, seen, over_at, bad = 0, nil, {}, nil, 0
local first_bad
emu.register_periodic(function()
  if finished then return end
  n = n + 1
  local step = mem:read_u16(0xF000)
  local md, px = mem:read_u8(0xF002), mem:read_u8(0xF006)
  local bx = mem:read_u8(0xF009)
  if n > 10 and prev and md ~= 2 and step - prev ~= 1 then
    bad = bad + 1; first_bad = first_bad or string.format("frame %d step %d->%d", n, prev, step)
  end
  prev = step
  if mem:read_u16(0xF090) ~= 0 then seen[mem:read_u8(0xF092)] = true end
  local left, right, fire = 0, 0, 0
  if md == 0 and n % 10 < 3 then fire = 1 end
  if md == 1 then
    local c = bx + 2 - (px + 16)
    if c < -6 then left = 1 elseif c > 6 then right = 1 end
    if rmode == "over" and n > 600 then left, right = 0, 0 end   -- stop tracking: lose all lives
  end
  kz:set_value(left); kx:set_value(right); ksp:set_value(fire)
  local want = (rmode == "win") and 3 or 2
  if md == want and not over_at then over_at = n end
  if (over_at and n >= over_at + 12) or n > 20000 then
    finished = true  -- (fail() below still reports; it overrides this)
    if bad > 0 then fail("cadence broken " .. bad .. " times, first " .. first_bad) end
    if md ~= want then fail("never reached mode " .. want) end
    local brick = 0
    for r = 0, 4 do brick = brick + pop(mem:read_u8(0xF010 + r)) end
    local bp = 0
    for r = 3, 7 do bp = bp + rowpop(r, 0, 31) end
    local ball = (rmode == "win") and 12 or 0
    if bp ~= brick * 217 + ball then fail(string.format("brick pixels %d != %d bricks * 217 + %d", bp, brick, ball)) end
    local pp = rowpop(22, 0, 31)
    if pp ~= 244 then fail("paddle row pixels " .. pp .. " != 244") end
    local junk = rowpop(23, 0, 31)
    for r = 8, 21 do
      if r == 14 then junk = junk + rowpop(r, 0, 7) + rowpop(r, 24, 31) else junk = junk + rowpop(r, 0, 31) end
    end
    if junk ~= 0 then fail("debris pixels in empty field: " .. junk) end
    local need = {{"brick", 4, 8}, {"paddle", 3, 3}, {"miss", 9, 9}, {"over", 10, 10}}
    if rmode == "win" then need = {{"brick", 4, 8}, {"paddle", 3, 3}, {"win", 11, 11}} end
    local names = {}
    for _, nd in ipairs(need) do
      local ok = false
      for id = nd[2], nd[3] do ok = ok or seen[id] end
      if not ok then fail("sound effect never fired: " .. nd[1]) end
    end
    for id in pairs(seen) do names[#names + 1] = id end
    table.sort(names)
    if finished == "failed" then return end
    print(string.format("RCHECK PASS %s frames=%d cadence=1 step/frame, sfx ids seen=%s, bricks=%d", rmode, n, table.concat(names, ","), brick))
    manager.machine:exit()
  end
end)
