-- harness/floppy_overlays.lua -- T0241: the resident disk driver + overlay loader, tested IN THE
-- RUNNING FLOPPY BUILD against MAME's real WD1793/CoCo FDC (tools/mame_floppy.sh):
--
--   tools/mame_floppy.sh -video none -sound none -nothrottle -seconds_to_run 200 \
--       -autoboot_script harness/floppy_overlays.lua
--   (env DIZZY_BIN / DIZZY_MAP default to the floppy build, OVL_FILE to target/floppy/DIZZY.OVL)
--
-- The game is poke-loaded (the same idiom as every harness; the REAL Disk BASIC boot is
-- harness/floppy_boot_regions.py's job), runs to the title wait -- which already proves the boot-time
-- title overlay read (show_title unpacks it and the mixer plays) -- and then, for EVERY overlay id in
-- ovl_tab, the CPU is pointed at `ovl_load` as a subroutine (A = id, X = a scratch destination) and
-- the destination bytes are compared with that slot of DIZZY.OVL.  Also:
--   * emulated seconds per load (reported),
--   * the ERROR path: a read of sector 19 (does not exist) must come back A != 0 through the NMI hook
--     (RNF -> INTRQ -> NMI -> fd_nmi) and must not wedge the machine: the next good load still works,
--   * the WRITE path: write a known pattern to the DIZZY.SAV area of the (copy of the) disk, read it
--     back through the driver (must match), and verify the image file on the host side has it (MAME
--     writes the disk back on exit).
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local ROOT = os.getenv("PT_ROOT") or "."
local BIN = os.getenv("DIZZY_BIN") or "target/room36_floppy.bin"
local MAP = os.getenv("DIZZY_MAP") or "target/room36_floppy.map"
local OVLF = os.getenv("OVL_FILE") or "target/floppy/DIZZY.OVL"
local SYM = {}
for line in io.lines(MAP) do local n, a = line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n] = tonumber(a, 16) end end
for _, s in ipairs({ "ovl_load", "ovl_tab", "fd_read", "fd_write", "fd_trk", "fd_sec", "fd_cnt", "MIX3_BUF", "TITLE_RAW_LEN", "TITLE_RESIDENT_LEN" }) do
  if not SYM[s] then print("FLOPPY_OVL FAIL symbol " .. s .. " missing from " .. MAP); manager.machine:exit() end
end
local function load_decb(path)
  local fh = io.open(path, "rb"); local data = fh:read("*all"); fh:close(); local pos = 1
  local allram = false
  while pos <= #data do
    local t = data:byte(pos)
    if t == 0 then
      local len = data:byte(pos + 1) * 256 + data:byte(pos + 2)
      local addr = data:byte(pos + 3) * 256 + data:byte(pos + 4)
      if addr >= 0x8000 and not allram then mem:write_u8(0xffdf, 0); allram = true end
      for i = 0, len - 1 do mem:write_u8(addr + i, data:byte(pos + 5 + i)) end
      pos = pos + 5 + len
    elseif t == 0xFF then return data:byte(pos + 3) * 256 + data:byte(pos + 4) else break end
  end
end
local fh = io.open(OVLF, "rb"); local OVL = fh:read("*all"); fh:close()

local pass, fail = 0, 0
local function check(name, ok, extra)
  if ok then pass = pass + 1; print(string.format("FLOPPY_OVL PASS %s%s", name, extra and (" -- " .. extra) or ""))
  else fail = fail + 1; print(string.format("FLOPPY_OVL FAIL %s%s", name, extra and (" -- " .. extra) or "")) end
end
local function now() return manager.machine.time:as_double() end
local function pc() return cpu.state["PC"].value end

local DEST = 0x9000          -- scratch destination (live game data; this test ends the game)
local t0 = nil
local tab = {}
-- THE SERVER.  Setting the CPU's PC from Lua while it is mid-instruction corrupts the run (found the hard way:
-- a `bra *` caught at its operand byte), so nothing here ever writes PC.  Instead a tiny server loop is written
-- into the dead loader window and the RETURN ADDRESS of show_title (new_game, on the stack under the title
-- mixer) is replaced with it; SPACE ends the title and the game returns into the server, which then executes
-- requests the harness leaves in a mailbox.  Requests: cmd 1 = ovl_load(A=id, X=dest); 2 = fd_read; 3 = fd_write
-- (track, sector, count in the mailbox).  The reply (A) is stored in the mailbox, cmd cleared when done.
local SERVER, MB = 0x7700, 0x77E0
local function build_server()
  local asm = string.format([[
fd_trk equ $%04x
fd_sec equ $%04x
fd_cnt equ $%04x
ovl_load equ $%04x
fd_read equ $%04x
fd_write equ $%04x
MBOX equ $%04x
        org $%04x
server  orcc #$50
        lds #$76F0
        clr MBOX
sv_loop lda MBOX
        beq sv_loop
        tfr a,b
        cmpb #1
        bne sv_fd
        lda MBOX+1
        ldx MBOX+4
        jsr ovl_load
        bra sv_done
sv_fd   lda MBOX+1
        sta fd_trk
        lda MBOX+2
        sta fd_sec
        lda MBOX+3
        sta fd_cnt
        ldx MBOX+4
        cmpb #2
        bne sv_w
        jsr fd_read
        bra sv_done
sv_w    jsr fd_write
sv_done sta MBOX+6
        clr MBOX
        bra sv_loop
]], SYM.fd_trk, SYM.fd_sec, SYM.fd_cnt, SYM.ovl_load, SYM.fd_read, SYM.fd_write, MB, SERVER)
  local fh = io.open("/tmp/fd_server.asm", "w"); fh:write(asm); fh:close()
  assert(os.execute("lwasm --format=raw -o /tmp/fd_server.bin /tmp/fd_server.asm") , "lwasm failed")
  local fb = io.open("/tmp/fd_server.bin", "rb"); local code = fb:read("*all"); fb:close()
  assert(#code < MB - SERVER, "server too big")
  return code
end
local function request(cmd, a, trk_or_id, sec, cnt, dest)
  mem:write_u8(MB + 1, trk_or_id or 0); mem:write_u8(MB + 2, sec or 0); mem:write_u8(MB + 3, cnt or 0)
  mem:write_u8(MB + 4, dest >> 8); mem:write_u8(MB + 5, dest & 255)
  mem:write_u8(MB + 6, 0xEE)
  mem:write_u8(MB, cmd)
  t0 = now()
end
local function server_done() return mem:read_u8(MB) == 0 and mem:read_u8(MB + 6) ~= 0xEE end
local function reply() return mem:read_u8(MB + 6) end
local function slot_bytes(idx, nsec) return OVL:sub(idx * 256 + 1, (idx + nsec) * 256) end
local function mem_matches(addr, s)
  for i = 1, #s do if mem:read_u8(addr + i - 1) ~= s:byte(i) then return false, i - 1 end end
  return true
end

-- the slots as laid out by floppy_layout.asm: idx 0 (title), 14 (heart A), 16 (heart B), 18, 27 (spares)
local SLOT_IDX = { [0] = 0, [1] = 14, [2] = 16, [3] = 18, [4] = 21, [5] = 24 }
local PAT = {}
for i = 1, 256 do PAT[i] = (i * 37 + 11) & 255 end
local patstr = {}
for i = 1, 256 do patstr[i] = string.char(PAT[i]) end
patstr = table.concat(patstr)
local key_space = manager.machine.ioport.ports[":row3"].fields["SPACE"]

local function fill(addr, n, v) for i = 0, n - 1 do mem:write_u8(addr + i, v) end end
local steps = {}
local function step(name, start, finish) steps[#steps + 1] = { name = name, start = start, finish = finish } end

-- the sequence of requests
for id = 0, 5 do
  step("overlay " .. id, function() fill(DEST, 5120, 0xA5); request(1, nil, id, 0, 0, DEST) end,
    function()
      local trk, sec, cnt = tab[id][1], tab[id][2], tab[id][3]
      local idx = SLOT_IDX[id]
      local want = slot_bytes(idx, cnt)
      local ok, first = mem_matches(DEST, want)
      check(string.format("overlay %d (track %d sec %d, %d sectors = %d bytes) loaded byte-identical to DIZZY.OVL", id, trk, sec, cnt, #want),
        reply() == 0 and ok, string.format("A=%02x %s load took %.2f s emulated", reply(), ok and "" or ("first diff at +" .. tostring(first)), now() - t0))
      if trk * 18 + sec - 1 ~= idx then check(string.format("overlay %d: ovl_tab (%d,%d) matches slot index %d", id, trk, sec, idx), false) end
    end)
end
step("error", function() fill(DEST, 512, 0xA5); request(2, nil, 0, 19, 1, DEST) end,   -- sector 19 does not exist: RNF
  function() check("error path: read of a non-existent sector returns an error through the NMI hook", reply() ~= 0, string.format("A=%02x after %.2f s emulated", reply(), now() - t0)) end)
step("recover", function() fill(DEST, 5120, 0xA5); request(1, nil, 0, 0, 0, DEST) end,
  function()
    check("after the error: the next overlay load still works (restore forced) and is byte-identical",
      reply() == 0 and mem_matches(DEST, slot_bytes(0, tab[0][3])), string.format("A=%02x load %.2f s", reply(), now() - t0))
  end)
step("write", function() for i = 1, 256 do mem:write_u8(DEST + i - 1, PAT[i]) end; request(3, nil, 2, 1, 1, DEST) end,   -- DIZZY.SAV first sector
  function() check("write path: fd_write of one sector to DIZZY.SAV (track 2 sector 1) returns OK", reply() == 0, string.format("A=%02x in %.2f s emulated", reply(), now() - t0)) end)
step("readback", function() fill(DEST + 0x400, 256, 0); request(2, nil, 2, 1, 1, DEST + 0x400) end,
  function()
    local ok, first = mem_matches(DEST + 0x400, patstr)
    check("write path: the sector reads back through the driver identical to what was written", reply() == 0 and ok, string.format("A=%02x %s", reply(), ok and "" or tostring(first)))
  end)
step("neighbour", function() fill(DEST + 0x500, 256, 0xEE); request(2, nil, 2, 2, 1, DEST + 0x500) end,
  function()
    local z = true
    for i = 0, 255 do if mem:read_u8(DEST + 0x500 + i) ~= 0 then z = false end end
    check("write path: the neighbouring sector of DIZZY.SAV was not touched (still zero)", z)
  end)

local f, stage, cur = 0, "boot", 0
local mix_lo, mix_hi = SYM.MIX3_BUF, SYM.MIX3_BUF + 3072
local title_frames, press_f = 0, 0
emu.register_frame_done(function()
  f = f + 1
  if f == 30 and stage == "boot" then cpu.state["PC"].value = load_decb(BIN) end
  if stage == "boot" then
    local p = pc()
    if p >= mix_lo and p < mix_hi then title_frames = title_frames + 1 else title_frames = 0 end
    if title_frames >= 60 then
      check("boot: title overlay read at boot, unpacked and playing", true, string.format("t=%.2f s emulated since power-on", now()))
      for i = 0, 5 do tab[i] = { mem:read_u8(SYM.ovl_tab + i * 3), mem:read_u8(SYM.ovl_tab + i * 3 + 1), mem:read_u8(SYM.ovl_tab + i * 3 + 2) } end
      local code = build_server()
      for i = 1, #code do mem:write_u8(SERVER + i - 1, code:byte(i)) end
      mem:write_u8(MB, 0xFF)                              -- server not yet running
      -- find new_game's return address (show_title returns into it) under the mixer and aim it at the server
      local sp, hit = cpu.state["S"].value, nil
      for a = sp, 0x00FE do
        if mem:read_u8(a) == (SYM.new_game >> 8) and mem:read_u8(a + 1) == (SYM.new_game & 255) then hit = a; break end
      end
      if not hit then check("found show_title's return address (new_game) on the stack", false); stage = "end"
      else
        mem:write_u8(hit, SERVER >> 8); mem:write_u8(hit + 1, SERVER & 255)
        stage = "press"; press_f = f; key_space:set_value(1)
      end
    elseif f > 60 * 90 then check("boot: title playing", false, string.format("never reached the title wait (pc=%04x)", p)); stage = "end" end
  elseif stage == "press" then
    if f - press_f > 12 then key_space:set_value(0) end
    if mem:read_u8(MB) == 0 then stage = "run"; cur = 1; steps[1].start() end
    if f - press_f > 600 then check("the title returned into the server", false, string.format("pc=%04x", pc())); stage = "end" end
  elseif stage == "run" then
    if server_done() then
      steps[cur].finish()
      cur = cur + 1
      if cur > #steps then stage = "end" else steps[cur].start() end
    elseif now() - t0 > 30 then check(steps[cur].name .. " finished within 30 s", false, string.format("pc=%04x", pc())); stage = "end" end
  elseif stage == "end" then
    print(string.format("FLOPPY_OVL SUMMARY pass=%d fail=%d", pass, fail))
    stage = "done"
    manager.machine:exit()
  end
end)
