-- Physics differential test: load room36.bin, let the priming redraw
-- finish, then poke Dizzy into a mid-jump state (dy=-8, floor=0) and let
-- mainloop run entirely naturally for a while -- no keys held, so this
-- exercises only gravity/landing, and along the way (sequence 3, "jump
-- no direction") the frame-height-varying draw path across several
-- different heights (14-20px). Dumps final dizzy_y/dizzy_dy/dizzy_floor
-- plus the final framebuffer, to confirm he lands cleanly back at
-- FLOOR_Y with dy=0/floor=1, not stuck or corrupted.
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

local DIZZY_Y = 0x12FF
local DIZZY_DY = 0x1300
local DIZZY_FLOOR = 0x1301
local CUR_BUF = 0x12E9

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
    if count == 200 and not poked then
        mem:write_u8(DIZZY_DY, 0xF8)  -- -8, mid-jump
        mem:write_u8(DIZZY_FLOOR, 0)
        poked = true
    end
    if count == 260 and not dumped then
        local y = mem:read_u8(DIZZY_Y)
        local dy = mem:read_u8(DIZZY_DY)
        local floor = mem:read_u8(DIZZY_FLOOR)
        local cur_buf = mem:read_u8(CUR_BUF)
        local fb_base = (cur_buf == 0) and 0x4000 or 0x6000
        print(string.format("RESULT dizzy_y=%d dizzy_dy=%d(0x%02X) dizzy_floor=%d cur_buf=%d fb_base=0x%04X", y, dy, dy, floor, cur_buf, fb_base))
        local f = io.open("/tmp/room36_physics_raw.bin", "wb")
        for addr = fb_base, fb_base + 6143 do
            f:write(string.char(mem:read_u8(addr)))
        end
        f:close()
        dumped = true
        manager.machine:exit()
    end
end)
