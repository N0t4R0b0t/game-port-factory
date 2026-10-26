-- harness/lzverify.lua -- T0085: does the 6809 unpacker reproduce the
-- staged $8000 image EXACTLY?
--
-- The Rust packer round-trips against its own decoder, and that proves
-- nothing about the 6809 half: a codec wrong in the same direction on
-- both sides round-trips happily and still corrupts the target. This is
-- the check that matters, because the failure it catches is silent --
-- a mis-decoded room assembles, loads, and draws garbage tiles or
-- collides against a mask that is one byte out.
--
--   cat /tmp/stage_a.bin /tmp/stage_b.bin > /tmp/stage_image.bin
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--   DIZZY_IMAGE=/tmp/stage_image.bin \
--     mame coco2b -ext "" -nothrottle -video none -sound none \
--     -seconds_to_run 8 -autoboot_script harness/lzverify.lua
--
-- DIZZY_MAP IS NOT OPTIONAL (T0172). Without it this falls back to
-- "check at frame 120", which the T0123 comment below already records as
-- too early -- block B's tail is still being written, so it reports a few
-- hundred differing bytes at the END of the image and looks like a codec
-- bug. Run without the map and you get "992/16252 bytes differ, first at
-- $bb27"; run with it and the same binary is byte-exact.
--
-- The two .bin halves are left in /tmp by tools/stage_pack.sh's raw pass.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
local f,loaded,checked=0,false,false
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  -- T0123: not a fixed f<120. The staged image is unpacked at boot, and with
  -- a bit-level decoder and a bigger block B that took longer than 90 frames:
  -- the check read the image while block B's tail was still being written
  -- (916 "wrong" bytes, all at the end). With DIZZY_MAP, wait for the CPU to
  -- reach show_title, which runs only after both blocks are unpacked.
  if not loaded or checked then return end
  if SYMS == nil then
    SYMS = {}
    local m = os.getenv("DIZZY_MAP")
    if m then for line in io.lines(m) do
      local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYMS[n]=tonumber(a,16) end end end
  end
  if SYMS.show_title then
    local pc = cpu.state["PC"].value
    reached = reached or (pc >= SYMS.show_title and pc < SYMS.show_title + 64)
    if not reached and f < 3000 then return end
  elseif f < 120 then return end
  checked=true
  local fh=io.open(os.getenv("DIZZY_IMAGE"),"rb"); local want=fh:read("*all"); fh:close()
  local bad,first=0,nil
  for i=1,#want do
    local got=mem:read_u8(0x8000+i-1)
    if got ~= want:byte(i) then bad=bad+1; if not first then first=i-1 end end
  end
  if bad==0 then print(string.format("LZVERIFY OK: %d bytes at $8000 match the raw image exactly",#want))
  else print(string.format("LZVERIFY FAIL: %d/%d bytes differ, first at $%04x",bad,#want,0x8000+first)) end
end)
