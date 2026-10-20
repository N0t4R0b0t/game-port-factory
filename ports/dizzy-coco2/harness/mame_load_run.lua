-- Loads a DECB .bin file directly into MAME's CoCo2 RAM via Lua memory
-- pokes and sets the PC to its exec address, bypassing cassette/disk
-- emulation entirely. Delays the load+PC-set until after the machine's
-- own reset/boot sequence has had time to run (setting PC immediately on
-- script load was tried first and silently didn't stick -- the machine's
-- own reset sequence was still running and overwrote it).
--
-- Interactive version: loads and runs, then gets out of the way (no
-- auto-dump/auto-exit) so the emulator keeps running for real play/
-- keyboard input. See mame_dump.lua for the headless verification
-- variant this was split from.
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

local binpath = os.getenv("DIZZY_BIN") or "room36.bin"
local count = 0
local loaded = false

emu.register_periodic(function()
    count = count + 1
    if count == 20 and not loaded then  -- earliest possible tick -- headlessly
        -- confirmed this still loads/runs correctly (doesn't get overwritten
        -- by the machine's own reset still in progress), and is early enough
        -- BASIC likely hasn't printed its boot banner to screen yet, unlike
        -- the original ~2s-delayed version -- see NOTES.md "boot path" theory.
        local exec_addr = load_decb(binpath)
        print("loaded " .. binpath .. ", exec address: " .. string.format("$%04X", exec_addr))
        cpu.state["PC"].value = exec_addr
        loaded = true
    end
end)
