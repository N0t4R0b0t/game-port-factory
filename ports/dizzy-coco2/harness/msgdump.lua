-- harness/msgdump.lua -- T0215: render one message (death-box path) and dump the
-- framebuffers, for a before/after byte compare when message TEXT ENCODING changes
-- (pixels must be identical). Usage, per build under comparison:
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map MSG=msg_goaway \
--   DUMP_OUT=out.raw LOAD_AT=150 mame coco2b -ext "" -nothrottle -video none -sound none \
--     -seconds_to_run 12 -autoboot_script harness/msgdump.lua
-- then `cmp before.raw after.raw`. MSG is any message symbol in the map. The map
-- must belong to the binary (symbol addresses move between builds).
-- Dump the DISPLAYED framebuffer at a deterministic point, for
-- byte-exact before/after comparison of a change that must not alter a
-- single pixel (an optimization, a refactor, a data-layout move).
--
-- Two builds fed the same inputs reach the same pass with the same
-- state, so `cmp` on the two dumps is the whole verification. This is
-- the check that made T0064's clear-loop rewrites safe to keep.
--
-- Usage:
--   DIZZY_BIN=... DIZZY_MAP=... DUMP_OUT=out.raw [DUMP_ROOM=36]
--   [DUMP_X=190] [DUMP_Y=176] [DUMP_AT=310]
--   mame coco2b -ext "" -autoboot_script harness/framedump.lua \
--     -video none -sound none -nothrottle -seconds_to_run 10
-- then: cmp before.raw after.raw   (and harness/pmode4_to_png.py to look)
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
local SYM = {}
for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n, a = line:match("^Symbol: (%S+) %(.-%) = (%x+)$")
  if n then SYM[n] = tonumber(a, 16) end
end
local AT = tonumber(os.getenv("DUMP_AT") or "310")
local f, loaded = 0, false
emu.register_periodic(function()
  f = f + 1
  -- LOAD_AT (default 30): at frame 30 BASIC's cold-start RAM sweep is still
  -- running, and its in-flight write can land one byte inside the loaded
  -- image ($3521, a title fragment, T0126). Use ~150 when comparing screens.
  if f == tonumber(os.getenv("LOAD_AT") or "30") and not loaded then
    cpu.state["PC"].value = load_decb(os.getenv("DIZZY_BIN")) ; loaded = true
  end
  if not loaded then return end
  local rel = f - tonumber(os.getenv("LOAD_AT") or "30")
  -- T0220: MSG_WAITSTART=1 (needed for the TAPE build, whose de-duplicated
  -- title (T0219) is not through by rel 200): pulse SPACE until the game is
  -- live (dizzy_y ~= 0), and count `rel` from the frame that happened.
  if os.getenv("MSG_WAITSTART") then
    if not STARTF then
      if f % 14 == 0 then key("SPACE", (f // 14) % 2 == 0) end
      if mem:read_u8(SYM.dizzy_y) ~= 0 then STARTF = f; key("SPACE", false) end
      return
    end
    rel = f - STARTF + 0
  elseif rel <= 300 and rel % 14 == 0 then key("SPACE", (rel // 14) % 2 == 0) end
  if rel == 310 then key("SPACE", false) end
  if rel == 200 then
    mem:write_u8(SYM.respawn_room, 36) mem:write_u8(SYM.respawn_x, 190) mem:write_u8(SYM.respawn_y, 176)
    mem:write_u8(SYM.killed, 1)
  end
  if rel == 330 then
    local m = SYM[os.getenv("MSG")]
    mem:write_u8(SYM.death_msg, m // 256) mem:write_u8(SYM.death_msg+1, m % 256)
    mem:write_u8(SYM.killed, 2)
  end
  if rel >= 330 and mem:read_u8(SYM.msg_active) == 1 then
    ACT = (ACT or 0) + 1
    if ACT == 20 then
      local fh = io.open(os.getenv("DUMP_OUT"), "wb")
      for i = 0, 12287 do fh:write(string.char(mem:read_u8(0x4000 + i))) end
      fh:close()
      print("DUMPED msg=" .. os.getenv("MSG") .. " rel=" .. rel)
    end
  end
end)
