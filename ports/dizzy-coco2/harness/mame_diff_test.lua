-- Differential test for the damage-rect redraw: load room36.bin, let the
-- initial (priming) redraw finish, then simulate exactly one movement step
-- by poking dizzy_x directly and calling redraw() a second time via a
-- synthetic JSR (push a return address, set PC), without going through
-- scankeys/mainloop's real keyboard-matrix reads (headless MAME has no key
-- held down, so a natural flow would immediately reset keyflags to 0).
-- Dumps the resulting buffer A ($4000) for comparison against an
-- independently-generated reference (Dizzy spawned directly at the same
-- final position via the ordinary priming/full-redraw path).
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

local DIZZY_X = 0x125E
local REDRAW_ADDR = 0x0E94
local MAINLOOP_ADDR = 0x0E37

local binpath = os.getenv("DIZZY_BIN") or "room36.bin"
local count = 0
local loaded = false
local poked = false
local dumped = false

emu.register_periodic(function()
    count = count + 1
    if count == 20 and not loaded then
        local exec_addr = load_decb(binpath)
        cpu.state["PC"].value = exec_addr
        loaded = true
    end
    -- give the priming redraw (full-screen, ~6144 clear + 63 blits) plenty
    -- of real ticks to finish before we touch anything
    if count == 200 and not poked then
        mem:write_u8(DIZZY_X, 50)  -- move right by one 4px step (46 -> 50)
        local s = cpu.state["S"].value
        s = s - 2
        mem:write_u8(s, (MAINLOOP_ADDR >> 8) & 0xFF)
        mem:write_u8(s + 1, MAINLOOP_ADDR & 0xFF)
        cpu.state["S"].value = s
        cpu.state["PC"].value = REDRAW_ADDR
        poked = true
    end
    if count == 260 and not dumped then
        local f = io.open("/tmp/room36_diff_raw.bin", "wb")
        for addr = 0x4000, 0x4000 + 6143 do
            f:write(string.char(mem:read_u8(addr)))
        end
        f:close()
        dumped = true
        manager.machine:exit()
    end
end)
