-- Reproducible screenshots through MAME's snapshot. Drives the real keyboard matrix
-- (ioport fields, like keys_smoke.lua), so the picture is what a player sees.
-- Env: SHOT_MODE = play | over | title ; the PNG lands in -snapshot_directory.
--   play : a tracking bot (Z/X follow the ball, SPACE relaunches) until a few bricks
--          are gone and the ball is mid-field, then one snapshot.
--   over : no steering, SPACE only to relaunch; snapshot 15 frames after GAME OVER.
--   title: snapshot at frame 10 (WAIT screen).
-- gpf_state is at $F000 (asserted by the Makefile).
local mode = os.getenv("SHOT_MODE")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local function field(prefix)
  for _, pn in ipairs({":LINE0",":LINE1",":LINE2",":LINE3",":LINE4",":LINE5",":LINE6",":LINE7"}) do
    for n, fl in pairs(manager.machine.ioport.ports[pn].fields) do
      if n:sub(1, #prefix) == prefix then return fl end
    end
  end
  print("SHOT FAIL key field not found: " .. prefix); manager.machine:exit()
end
local kz, kx, ksp = field("z "), field("x "), field("SPACE")
local n, over_at = 0, nil
local function done(tag)
  manager.machine.video:snapshot()
  print("SHOT DONE " .. mode .. " frame=" .. n .. " " .. tag)
  manager.machine:exit()
end
emu.register_periodic(function()
  n = n + 1
  local md, score, clr = mem:read_u8(0xF002), mem:read_u16(0xF004), mem:read_u8(0xF007)
  local px, bx, by = mem:read_u8(0xF006), mem:read_u8(0xF008 + 1), mem:read_u8(0xF00A + 1)
  if mode == "title" then
    if n == 10 then done("") end
    return
  end
  local left, right, fire = 0, 0, 0
  if md == 0 and n % 10 < 3 then fire = 1 end
  if mode == "play" and md == 1 then
    local c = bx + 2 - (px + 16)
    if c < -6 then left = 1 elseif c > 6 then right = 1 end
  end
  kz:set_value(left); kx:set_value(right); ksp:set_value(fire)
  if mode == "play" and md == 1 and clr >= 8 and by > 90 and by < 140 then
    done(string.format("score=%d clr=%d", score, clr))
  end
  if mode == "over" then
    if md == 2 and not over_at then over_at = n end
    if over_at and n >= over_at + 15 then done(string.format("score=%d", score)) end
  end
  if n > 60000 then print("SHOT FAIL timeout mode=" .. mode); manager.machine:exit() end
end)
