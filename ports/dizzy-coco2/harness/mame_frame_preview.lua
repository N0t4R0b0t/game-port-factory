-- Draws ONE specific Dizzy frame via the real, verified blitdizzy routine
-- (not a separate preview decoder that might use a different pixel
-- convention) onto a cleared buffer A, and dumps the result. Used to
-- visually sanity-check specific frame ids / the seq0-seq5 tables against
-- what the game actually draws -- this is how the sequence-selection bug
-- (grounded states off-by-one into the wrong seqN table) was diagnosed.
--
-- The exact symbol addresses below are only valid for the room36.bin
-- they were captured against -- re-derive from a fresh `lwasm --map`
-- if room36.asm changes and this stops looking right.
--
-- Usage: DIZZY_BIN=... DIZZY_TEST_FF=<n> DIZZY_OUT=/tmp/foo.bin mame ...
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

-- Re-derive these with: lwasm --decb -o /tmp/x.bin --map=/tmp/x.map
-- target/room36.asm ; grep "^Symbol: (dizzy_ff|dizzy_x|dizzy_y|
-- draw_base|blitdizzy) " /tmp/x.map
local DIZZY_FF = 0x1306
local DIZZY_X = 0x12FE
local DIZZY_Y = 0x12FF
local DRAW_BASE = 0x12E7
local BLITDIZZY = 0x1173
local MAINLOOP_ADDR = 0x1077  -- test_spin, not mainloop -- see room36.asm

local binpath = os.getenv("DIZZY_BIN") or "room36.bin"
local test_ff = tonumber(os.getenv("DIZZY_TEST_FF") or "0")
local outpath = os.getenv("DIZZY_OUT") or "/tmp/frame_preview_raw.bin"
local count = 0
local loaded = false
local done = false

emu.register_periodic(function()
    count = count + 1
    if count == 20 and not loaded then
        local exec_addr = load_decb(binpath)
        cpu.state["PC"].value = exec_addr
        loaded = true
    end
    if count == 200 and not done then
        -- clear buffer A ($4000) directly, draw ONLY the requested frame
        -- there via a synthetic call to blitdizzy, at a safe fixed
        -- position clear of the room art
        for addr = 0x4000, 0x4000 + 6143 do
            mem:write_u8(addr, 0)
        end
        mem:write_u8(DIZZY_FF, test_ff)
        mem:write_u8(DIZZY_X, 100)
        mem:write_u8(DIZZY_Y, 100)
        mem:write_u8(DRAW_BASE, 0x40)
        mem:write_u8(DRAW_BASE + 1, 0x00)

        local s = cpu.state["S"].value
        s = s - 2
        mem:write_u8(s, (MAINLOOP_ADDR >> 8) & 0xFF)
        mem:write_u8(s + 1, MAINLOOP_ADDR & 0xFF)
        cpu.state["S"].value = s
        cpu.state["PC"].value = BLITDIZZY
        done = true
    end
    if count == 205 and done then
        local f = io.open(outpath, "wb")
        for addr = 0x4000, 0x4000 + 6143 do
            f:write(string.char(mem:read_u8(addr)))
        end
        f:close()
        manager.machine:exit()
    end
end)
