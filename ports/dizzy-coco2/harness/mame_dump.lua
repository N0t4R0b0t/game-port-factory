-- MAME autoboot script: load+PC-set our program at a tunable early tick
-- (REDIRECT_AT, via env var), then dump the PMODE4 framebuffer after a
-- fixed longer delay and exit. Used to headlessly binary-search the
-- earliest tick where redirecting execution still "sticks" (doesn't get
-- overwritten by the machine's own reset sequence still in progress),
-- without needing a human to look at each attempt.
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
local redirect_at = tonumber(os.getenv("REDIRECT_AT") or "120")
local count = 0
local loaded = false

emu.register_periodic(function()
    count = count + 1
    if count == redirect_at and not loaded then
        local exec_addr = load_decb(binpath)
        cpu.state["PC"].value = exec_addr
        loaded = true
    end
    if count > redirect_at + 240 then
        local f = io.open("/tmp/mame_fb.bin", "wb")
        for addr = 0x4000, 0x4000 + 6143 do
            f:write(string.char(mem:read_u8(addr)))
        end
        f:close()
        manager.machine:exit()
    end
end)
