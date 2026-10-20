-- Real-input smoke test of read_input: press one host key through MAME's emulated
-- keyboard matrix (ioport fields, so no X11 needed), run 30 frames, assert the effect.
-- Env: SMOKE_KEY = field-name prefix ("z ", "SPACE", "0 " ...), SMOKE_EXPECT = left|right|fire.
-- Prints "SMOKE PASS ..." or "SMOKE FAIL ..." and exits. gpf_state is at $F000 (asserted by make).
local key, expect = os.getenv("SMOKE_KEY"), os.getenv("SMOKE_EXPECT")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local fld
for _, pn in ipairs({":LINE0",":LINE1",":LINE2",":LINE3",":LINE4",":LINE5",":LINE6",":LINE7"}) do
  for n, fl in pairs(manager.machine.ioport.ports[pn].fields) do
    if n:sub(1, #key) == key then fld = fl end
  end
end
if not fld then print("SMOKE FAIL key field not found: " .. key); manager.machine:exit() end
local n = 0
emu.register_periodic(function()
  n = n + 1
  fld:set_value((n >= 20 and n < 50) and 1 or 0)
  if n == 60 then
    local px, mode = mem:read_u8(0xF006), mem:read_u8(0xF002)
    local ok = (expect == "left" and px < 112) or (expect == "right" and px > 112 and px <= 224)
            or (expect == "fire" and mode == 1)
    print(string.format("SMOKE %s key=[%s] expect=%s px=%d mode=%d", ok and "PASS" or "FAIL", key, expect, px, mode))
    manager.machine:exit()
  end
end)
