-- Precise differential test of the exact scenario the user confirmed
-- shows "duplicated top": standing still, idle blink only (frame 0 <->
-- 1), position never changing. Never actually tested this specific
-- case byte-precisely before (only checked individual frames in
-- isolation, or position-changing walk steps) -- this is the real gap.
--
-- Simulates 3 consecutive idle-blink redraws (position constant,
-- dizzy_ff alternating 0,1,0,1) via direct poke + synthetic JSR into
-- redraw, then diffs the final displayed buffer against an
-- independently-built reference that spawns Dizzy directly with
-- frame 1 at the same position via the normal full-redraw priming
-- path.
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

local DIZZY_FF = 0x1306
local REDRAW_ADDR = 0x0F06
local TEST_SPIN = 0x1077  -- see room36.asm

local binpath = os.getenv("DIZZY_BIN") or "room36.bin"
local ff_steps = {1, 0, 1}  -- alternating blink, final = 1
local count = 0
local loaded = false
local step = 0
local done = false

local function synth_call(target_pc)
    local s = cpu.state["S"].value
    s = s - 2
    mem:write_u8(s, (TEST_SPIN >> 8) & 0xFF)
    mem:write_u8(s + 1, TEST_SPIN & 0xFF)
    cpu.state["S"].value = s
    cpu.state["PC"].value = target_pc
end

emu.register_periodic(function()
    count = count + 1
    if count == 20 and not loaded then
        local exec_addr = load_decb(binpath)
        cpu.state["PC"].value = exec_addr
        loaded = true
    end
    local step_ticks = {200, 220, 240}
    if step < #ff_steps and count == step_ticks[step + 1] and not done then
        step = step + 1
        mem:write_u8(DIZZY_FF, ff_steps[step])
        synth_call(REDRAW_ADDR)
    end
    if count == 260 and not done then
        local cur_buf = mem:read_u8(0x12E9)  -- see room36.asm map for cur_buf addr
        print("cur_buf=" .. cur_buf)
        local fb_base = (cur_buf == 0) and 0x4000 or 0x6000
        local f = io.open("/tmp/room36_idle_raw.bin", "wb")
        for addr = fb_base, fb_base + 6143 do
            f:write(string.char(mem:read_u8(addr)))
        end
        f:close()
        done = true
        manager.machine:exit()
    end
end)
