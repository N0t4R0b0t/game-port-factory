-- Loads a DECB .bin file directly into MAME's CoCo2 RAM via Lua memory
-- pokes and sets the PC to its exec address, bypassing cassette/disk
-- emulation entirely. Delays the load+PC-set until after the machine's
-- own reset/boot sequence has had time to run (setting PC immediately on
-- script load was tried first and silently didn't stick -- the machine's
-- own reset sequence was still running and overwrote it).
--
-- SNAPSHOT variant: loads, runs for a fixed number of ticks, writes ONE
-- MAME snapshot PNG of the REAL RENDERED DISPLAY, then exits.
--
-- This is the only harness path that can see a VIDEO MODE error.
-- capture_pmode4.sh reads $4000 over GDB and decodes it as 1bpp 256x192
-- -- it shows what we MEANT to draw, and is blind to what the VDG is
-- actually doing with those bytes. A wrong PIA1 mode nibble made the
-- machine display CG6 (128x192, 4 colour) for days while every headless
-- check stayed green (NOTES.md T0028). Use this to confirm the display.
--
-- Usage: DIZZY_BIN=/path/to/room36.bin mame coco2b -ext gmc \
--          -autoboot_script mame_load_run.lua

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]

local function load_decb(path)
    local f = io.open(path, "rb")
    local data = f:read("*all")
    f:close()

    local pos = 1
    local exec_addr = nil
    while pos <= #data do
        local blocktype = data:byte(pos)
        if blocktype == 0x00 then
            local len_hi, len_lo = data:byte(pos+1), data:byte(pos+2)
            local length = len_hi * 256 + len_lo
            local addr_hi, addr_lo = data:byte(pos+3), data:byte(pos+4)
            local addr = addr_hi * 256 + addr_lo
            for i = 0, length - 1 do
                mem:write_u8(addr + i, data:byte(pos + 5 + i))
            end
            pos = pos + 5 + length
        elseif blocktype == 0xFF then
            local exec_hi, exec_lo = data:byte(pos+3), data:byte(pos+4)
            exec_addr = exec_hi * 256 + exec_lo
            break
        else
            break
        end
    end
    return exec_addr
end


local binpath = os.getenv("DIZZY_BIN")
local ticks = tonumber(os.getenv("DIZZY_TICKS") or "400")
local count = 0
local loaded = false
emu.register_periodic(function()
    count = count + 1
    if count == 20 and not loaded then
        local exec_addr = load_decb(binpath)
        cpu.state["PC"].value = exec_addr
        loaded = true
    end
    if count == ticks then
        manager.machine.video:snapshot()
    end
    if count == ticks + 20 then
        manager.machine:exit()
    end
end)
