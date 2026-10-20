-- Real-input smoke test of read_input: press one host key through MAME's emulated CoCo
-- keyboard matrix (ioport fields, so no X11 needed), run ~30 frames, assert the effect in
-- gpf_state. Loads the DECB .bin itself (same approach as the gpfdiff coco2 backend:
-- wait out BASIC's cold start, mask IRQ/FIRQ, write the segments, set PC).
-- Env: SMOKE_BIN = path of brickfall.bin, SMOKE_STATE = gpf_state address (hex, from the map),
--      SMOKE_KEY = field-name prefix ("z", "x", "LEFT", "RIGHT", "SPACE"), SMOKE_EXPECT = left|right|fire.
-- Prints "SMOKE PASS ..." or "SMOKE FAIL ..." and exits.
local key, expect = os.getenv("SMOKE_KEY"), os.getenv("SMOKE_EXPECT")
local ST = tonumber(os.getenv("SMOKE_STATE"), 16)
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local fld
for n, fl in pairs(manager.machine.ioport.ports[":row3"].fields) do
  if n:sub(1, #key):lower() == key:lower() and n ~= "Keyboard" then fld = fl end
end
if not fld then print("SMOKE FAIL key field not found in :row3: " .. key); manager.machine:exit() end

local function load_decb(path)
  local fh = io.open(path, "rb"); local d = fh:read("*all"); fh:close()
  local pos = 1
  while pos <= #d do
    local t = d:byte(pos)
    local len, addr = d:byte(pos + 1) * 256 + d:byte(pos + 2), d:byte(pos + 3) * 256 + d:byte(pos + 4)
    if t == 0 then
      for i = 0, len - 1 do mem:write_u8(addr + i, d:byte(pos + 5 + i)) end
      pos = pos + 5 + len
    else return addr end
  end
end

local f, loaded_at = 0, nil
emu.register_periodic(function()
  f = f + 1
  if f == 150 then
    cpu.state["CC"].value = cpu.state["CC"].value | 0x50
    cpu.state["PC"].value = load_decb(os.getenv("SMOKE_BIN"))
    loaded_at = f
    return
  end
  if not loaded_at then return end
  local n = f - loaded_at
  fld:set_value((n >= 20 and n < 50) and 1 or 0)
  if n == 80 then
    local px, mode = mem:read_u8(ST + 6), mem:read_u8(ST + 2)
    local ok = (expect == "left" and px < 112) or (expect == "right" and px > 112 and px <= 224)
            or (expect == "fire" and mode == 1)
    print(string.format("SMOKE %s key=[%s] expect=%s px=%d mode=%d", ok and "PASS" or "FAIL", key, expect, px, mode))
    manager.machine:exit()
  end
end)
