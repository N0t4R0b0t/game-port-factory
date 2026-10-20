-- Headless playtest driver for the dizzy-coco2 port.
-- Loads a DECB binary directly (bypassing disk/cassette), then drives the
-- CoCo keyboard matrix's row3 (UP/DOWN/LEFT/RIGHT/SPACE) via ioport fields
-- -- more reliable for a raw-matrix-scanning game than natkeyboard, which
-- goes through MAME's natural-keyboard translation layer instead.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local row3 = manager.machine.ioport.ports[":row3"]
local fields = {}
for name, field in pairs(row3.fields) do fields[name] = field end

local function key(name, down)
  -- set_value(1) = pressed, set_value(0) = released -- this is the LOGICAL
  -- state MAME's digital ioport_field wants, regardless of the underlying
  -- port's active-low wiring; MAME applies that inversion itself. Confirmed
  -- empirically: the opposite polarity produced a mirror-world bug where
  -- holding RIGHT walked Dizzy left (dir=1) and eventually off the left
  -- edge into a death/respawn loop with lives silently wrapping 0->3 (no
  -- game-over screen -- a real, separate gap, see NOTES.md).
  fields[name]:set_value(down and 1 or 0)
end
local function release_all()
  for _, n in ipairs({"UP","DOWN","LEFT","RIGHT","SPACE"}) do fields[n]:set_value(0) end
end
release_all()

local function load_decb(path)
  local f = io.open(path, "rb"); local data = f:read("*all"); f:close()
  local pos, exec = 1, nil
  local allram=false
  while pos <= #data do
    local t = data:byte(pos)
    if t == 0x00 then
      local len = data:byte(pos+1)*256 + data:byte(pos+2)
      local addr = data:byte(pos+3)*256 + data:byte(pos+4)
      if addr>=0x8000 and not allram then mem:write_u8(0xffdf,0); allram=true end
      for i = 0, len-1 do mem:write_u8(addr+i, data:byte(pos+5+i)) end
      pos = pos + 5 + len
    elseif t == 0xFF then
      exec = data:byte(pos+3)*256 + data:byte(pos+4); break
    else break end
  end
  return exec
end

-- Symbol addresses come from THIS build's own lwasm --map (path passed by
-- coco_playtest.sh), never hardcoded -- a stale address from a previous
-- build has burned two earlier sessions on this project (see NOTES.md).
local function load_map(path)
  local sym = {}
  local f = io.open(path, "r")
  for line in f:lines() do
    local name, addr = line:match("^Symbol: (%S+) %(.-%) = (%x+)$")
    if name then sym[name] = tonumber(addr, 16) end
  end
  f:close()
  return sym
end
local ALLSYM = load_map(os.getenv("DIZZY_MAP"))
local WANT = {"lives","coins","cur_room","keyflags","dizzy_x","dizzy_y",
  "dizzy_dy","dizzy_floor","dizzy_dir","troll_launching","inv_cap","inv","fireout","troll_bribed"}
local SYM = {}
for _, n in ipairs(WANT) do
  SYM[n] = ALLSYM[n] or error("symbol not found in map: "..n)
end
SYM.inv0 = SYM.inv

local function u8(a) return mem:read_u8(a) end
local function s8(a) local v=u8(a); if v>=128 then v=v-256 end; return v end

-- Scripted input timeline: {frame, action}. action is a function. frame 0
-- is when the game actually STARTS (see the boot/started gate below), not
-- when the binary is loaded -- the title screen and any intro message
-- boxes take a variable amount of real time to get through.
local binpath = os.getenv("DIZZY_BIN")
local outdir  = os.getenv("DIZZY_OUT") or "/tmp/ptshots"
local script  = os.getenv("DIZZY_SCRIPT") or "/tmp/dizzy_script.lua"
local timeline = dofile(script)  -- returns a table of {frame=N, fn=function() ... end, label="..."}
local cpu = manager.machine.devices[":maincpu"]
local START_ROOM = tonumber(os.getenv("DIZZY_START_ROOM") or "36")

local f = 0
local loaded, started = false, false
local load_at, tries = 150, 0
local start_at = nil
local shotnum = 0
emu.register_periodic(function()
  f = f + 1

  -- T0124/T0129: MAME suspends the 6809 mid-instruction at frame
  -- boundaries (PC is never equal to CURPC), so writing PC at an
  -- arbitrary frame can resume a half-done BASIC instruction instead of
  -- actually starting the game -- see harness/titleverify.lua and
  -- factory/recipes/never-write-pc-from-an-emulator-script-without-checking-the-jump-actually-took.md.
  -- Load at frame 150, not 30: at 30 coco2b's BASIC is still in its
  -- cold-start RAM sweep. Mask IRQ/FIRQ before the jump (the image loads
  -- room art over BASIC's RAM interrupt vectors at $0100), then confirm
  -- one frame later that start's own `lds #$0100` actually ran (S<=$0100);
  -- if not, cold-reset and retry at a later frame.
  if f == load_at and not loaded then
    cpu.state["CC"].value = cpu.state["CC"].value | 0x50
    local exec = load_decb(binpath)
    cpu.state["PC"].value = exec
    loaded = true
    print(string.format("F%06d LOADED exec=%04X", f, exec))
    return
  end
  if loaded and not started and f == load_at + 1 and cpu.state["S"].value > 0x0100 then
    tries = tries + 1
    if tries > 5 then
      print("BOOT FAIL: five loads in a row never started the image")
      manager.machine:exit()
      return
    end
    print(string.format(
      "F%06d note: load at frame %d resumed a half-done BASIC instruction (S=$%04X) -- cold reset, retrying",
      f, load_at, cpu.state["S"].value))
    mem:write_u8(0x0071, 0)
    loaded = false
    load_at = f + 150 + tries * 7
    manager.machine:soft_reset()
    return
  end
  if not loaded then return end

  -- The title screen (3-voice mixer looping) and any intro message boxes
  -- (msg_wait_dismiss) block the WHOLE game loop until SPACE is pressed --
  -- dizzy_x/dizzy_y read 0 the entire time, which used to look exactly
  -- like "movement is broken" (T0129). Toggle rather than hold (a held
  -- key doesn't dismiss twice -- see tiecroc.lua's boot stage), and gate
  -- on the game's own state actually confirming new_game ran, since the
  -- title/message wait lasts as long as it takes, not a fixed frame count.
  if not started then
    if f % 14 == 0 then key("SPACE", (f // 14) % 2 == 0) end
    if u8(SYM.cur_room) == START_ROOM and u8(SYM.dizzy_y) ~= 0 then
      key("SPACE", false)
      started = true
      start_at = f
      print(string.format("F%06d STARTED room=%d y=%d", f, u8(SYM.cur_room), u8(SYM.dizzy_y)))
    end
    return
  end

  for _, ev in ipairs(timeline) do
    if ev.frame == (f - start_at) then
      print(string.format("F%06d ACTION %s", f, ev.label or "?"))
      ev.fn(key, release_all)
    end
  end

  if f % 15 == 0 then
    print(string.format(
      "F%06d room=%d x=%d y=%d dir=%d dy=%d floor=%d lives=%d coins=%d launch=%d inv0=%d fireout=%d bribed=%d kf=%d",
      f, u8(SYM.cur_room), u8(SYM.dizzy_x), u8(SYM.dizzy_y), u8(SYM.dizzy_dir),
      s8(SYM.dizzy_dy), u8(SYM.dizzy_floor), u8(SYM.lives), u8(SYM.coins),
      u8(SYM.troll_launching), u8(SYM.inv0), u8(SYM.fireout), u8(SYM.troll_bribed), u8(SYM.keyflags)))
    manager.machine.video:snapshot()
  end
end)
