-- gpf_mame.lua: MAME side of the gpfdiff zx48 backend (factory/tools/gpfdiff/src/mame.rs).
--
-- Env (set by gpfdiff): GPF_STATE, GPF_BRICKS, GPF_RET = decimal addresses of the
-- gpf_state / gpf_bricks / gpf_input_ret labels.
-- Optional (coco2 backend; absent for zx48, where MAME's -snapshot loads the program):
--   GPF_REG   name of the CPU register that carries the buttons (default "A")
--   GPF_LOAD  path of a load list written by gpfdiff (coco.rs), lines
--               "S <addr> <hex bytes>"  a segment, written into RAM
--               "X <addr>"              the entry point
--             (decimal addresses). The script waits for the machine's BASIC to
--             finish its cold start, masks IRQ/FIRQ (CC |= $50), writes the segments, sets
--             PC, reads PC back, and if the program has not reached gpf_input_ret
--             within 30 frames (the jump did not take: MAME suspends the 6809
--             mid-instruction at frame boundaries) soft-resets and tries again,
--             at most 5 times, then reports "GPF ERR ...".
--
-- Protocol, line based, every line this script emits starts with "GPF " (MAME prints
-- plenty of other stuff on stdout; the Rust side ignores everything without the prefix):
--   script -> gpfdiff   "GPF S <42 hex digits>"   state (16 B) + bricks (5 B) at an input point
--   gpfdiff -> script   "P <addr> <len>"          (any number of times, before B) read RAM, decimal args
--   script -> gpfdiff   "GPF M <2*len hex digits>" the bytes read
--   gpfdiff -> script   "B <n>"                   set A = n (decimal), resume
--   script -> gpfdiff   "GPF ACK <A> <PC>"        A and PC read back AFTER the write (decimal)
--   gpfdiff -> script   "Q"                       quit MAME
-- The script blocks on stdin inside the debugger-stop callback, so MAME is parked
-- (not running) while gpfdiff thinks; there is no timing dependence at all.
--
-- A breakpoint at gpf_input_ret (the RET of read_input) stops the CPU BEFORE the RET
-- executes, so the A we write is the value read_input returns.

local ST  = tonumber(os.getenv("GPF_STATE"))
local BR  = tonumber(os.getenv("GPF_BRICKS"))
local RET = tonumber(os.getenv("GPF_RET"))
local REG = os.getenv("GPF_REG") or "A"
local LOAD = os.getenv("GPF_LOAD")
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local dbg = manager.machine.debugger

local function out(s) io.stdout:write("GPF " .. s .. "\n"); io.stdout:flush() end

cpu.debug:bpset(RET, "", "")
out("READY")

local function read_load_list(path)
  local f = io.open(path, "r")
  if not f then return nil, "cannot open " .. path end
  local segs, exec = {}, nil
  for line in f:lines() do
    local a, hex = line:match("^S (%d+) (%x*)$")
    if a then
      local bytes = {}
      for i = 1, #hex, 2 do bytes[#bytes + 1] = tonumber(hex:sub(i, i + 1), 16) end
      segs[#segs + 1] = { addr = tonumber(a), bytes = bytes }
    else
      local x = line:match("^X (%d+)$")
      if x then exec = tonumber(x) end
    end
  end
  f:close()
  if not exec then return nil, "load list has no X (entry) line" end
  return { segs = segs, exec = exec }
end

local img, load_at, loaded_at, tries, frame, hit_seen = nil, 150, nil, 0, 0, false
if LOAD then
  local e
  img, e = read_load_list(LOAD)
  if not img then out("ERR " .. e); manager.machine:exit() end
end

local function try_load()
  -- Mask IRQ/FIRQ first: the image may cover BASIC's RAM interrupt vectors.
  cpu.state["CC"].value = cpu.state["CC"].value | 0x50
  for _, s in ipairs(img.segs) do
    for i, b in ipairs(s.bytes) do mem:write_u8(s.addr + i - 1, b) end
  end
  cpu.state["PC"].value = img.exec
  local pc = cpu.state["PC"].value
  if pc ~= img.exec then
    out(string.format("ERR PC write did not take: wrote %d, read back %d", img.exec, pc))
    manager.machine:exit()
    return
  end
  loaded_at = frame
end

emu.register_periodic(function()
  frame = frame + 1
  if img and not hit_seen then
    if loaded_at == nil then
      -- Load at frame 150, not earlier: before that BASIC's cold start is still sweeping RAM.
      if frame >= load_at then try_load() end
      return
    elseif frame - loaded_at > 30 and dbg.execution_state ~= "stop" then
      tries = tries + 1
      if tries >= 5 then
        out("ERR image never reached gpf_input_ret after 5 loads (PC write did not start the program)")
        manager.machine:exit()
        return
      end
      loaded_at = nil
      load_at = frame + 150 + tries * 7
      manager.machine:soft_reset()
      return
    end
  end
  if dbg.execution_state ~= "stop" then return end
  local pc = cpu.state["PC"].value
  if pc ~= RET then return end          -- the initial -debug stop, or anything else: not ours
  hit_seen = true
  local t = {}
  for i = 0, 15 do t[#t + 1] = string.format("%02x", mem:read_u8(ST + i)) end
  for i = 0, 4 do t[#t + 1] = string.format("%02x", mem:read_u8(BR + i)) end
  out("S " .. table.concat(t))
  local line
  while true do
    line = io.stdin:read("l")
    if line == nil or line:sub(1, 1) == "Q" then manager.machine:exit(); return end
    -- "P <addr> <len>": read RAM while parked (field maps); answer and keep waiting
    local pa, pl = line:match("^P (%d+) (%d+)$")
    if not pa then break end
    local m = {}
    for i = 0, tonumber(pl) - 1 do m[#m + 1] = string.format("%02x", mem:read_u8(tonumber(pa) + i)) end
    out("M " .. table.concat(m))
  end
  local b = tonumber(line:match("^B (%d+)$"))
  if b == nil then out("ERR bad command " .. tostring(line)); manager.machine:exit(); return end
  cpu.state[REG].value = b
  out(string.format("ACK %d %d", cpu.state[REG].value, cpu.state["PC"].value))
  dbg.execution_state = "run"
end)
