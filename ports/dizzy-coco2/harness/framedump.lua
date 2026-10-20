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
  if rel % 14 == 0 then key("SPACE", (rel // 14) % 2 == 0) end
  if rel == 200 then
    mem:write_u8(SYM.respawn_room, tonumber(os.getenv("DUMP_ROOM") or "36"))
    mem:write_u8(SYM.respawn_x, tonumber(os.getenv("DUMP_X") or "190"))
    mem:write_u8(SYM.respawn_y, tonumber(os.getenv("DUMP_Y") or "176"))
    mem:write_u8(SYM.killed, 1)
  end
  -- PIN the world for the last stretch: two builds only produce
  -- comparable framebuffers if they are drawing the same scene, and
  -- Dizzy's position, his animation frame, the flame counter and the
  -- rat's RNG-driven walk all drift by a pass between builds otherwise.
  -- (Learned the hard way: the first comparison differed only because
  -- one build was 4px further along.)
  if rel >= AT - 40 then
    mem:write_u8(SYM.dizzy_x, tonumber(os.getenv("DUMP_PIN_X") or "180"))
    mem:write_u8(SYM.dizzy_y, tonumber(os.getenv("DUMP_PIN_Y") or "176"))
    mem:write_u8(SYM.dizzy_dy, 0)
    mem:write_u8(SYM.dizzy_floor, 1)
    -- pin the animation's INPUTS: dizzy_ff is recomputed from
    -- dizzy_seq/dizzy_anim every pass, so pinning ff alone just gets
    -- overwritten and the two builds land on frames one apart (which
    -- reads as a 1px vertical offset, since frame heights differ)
    mem:write_u8(SYM.dizzy_seq, 0)
    mem:write_u8(SYM.dizzy_anim, 0)
    mem:write_u8(SYM.dizzy_ff, 0)
    mem:write_u8(SYM.flame_ctr, 4)
    mem:write_u8(SYM.water_ctr, 0)   -- room 53's pool animates too
    -- Park the rat, whose walk is RNG-timed. Scan the WHOLE table: the
    -- slot order comes from the extracted movingdata and shifts every
    -- time a room is added to --actor-rooms, so a hardcoded index
    -- silently stops matching (it did, and 200 bytes of "difference"
    -- turned out to be one unparked rat).
    for i = 0, 31 do
      local room = mem:read_u8(SYM.actor_ram + i*8)
      if room ~= 255 and mem:read_u8(SYM.actor_ram + i*8 + 1) == 11 then
        mem:write_u8(SYM.actor_ram + i*8, 255)
      end
    end
  end
  -- A full repaint takes about two passes (~8 video frames), so the
  -- invalidation has to land well before the dump or it is caught
  -- half-drawn -- and which half depends on how fast the build is,
  -- which reads as a rendering difference between two builds.
  if rel == AT - 40 or rel == AT - 25 then
    mem:write_u8(SYM.bufA_last_x, 255) mem:write_u8(SYM.bufB_last_x, 255)
  end
  if rel == AT then
    local base = mem:read_u8(SYM.cur_buf) == 0 and 0x4000 or 0x6000
    local fh = io.open(os.getenv("DUMP_OUT"), "wb")
    for i = 0, 6143 do fh:write(string.char(mem:read_u8(base + i))) end
    fh:close()
    print(string.format("DUMPED room=%d x=%d y=%d flame_ctr=%d",
      mem:read_u8(SYM.cur_room), mem:read_u8(SYM.dizzy_x),
      mem:read_u8(SYM.dizzy_y), mem:read_u8(SYM.flame_ctr)))
  end
end)
