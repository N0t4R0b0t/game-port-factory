-- harness/titleverify.lua -- T0126: does the TITLE SCREEN on the target match
-- the source image EXACTLY?
--
-- lzverify.lua proves the unpacked $8000 room image; nothing proved the title
-- (packed separately, gathered from load-time holes, unpacked into
-- TITLE_RAW_BUF, de-column-majored into framebuffer A). The T0085 LZSS build
-- was showing two wrong title bytes, invisible by eye, found only because a
-- codec change moved them. This compares framebuffer A, once the title is up
-- and before SPACE, with the linear 6144-byte image mktitle packed
-- (/tmp/title_raw.bin, left there by tools/stage_pack.sh).
--
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--   TITLE_IMAGE=/tmp/title_raw.bin \
--     mame coco2b -ext "" -nothrottle -video none -sound none \
--     -seconds_to_run 20 -autoboot_script harness/titleverify.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end
local fh=io.open(os.getenv("TITLE_IMAGE") or "/tmp/title_raw.bin","rb"); local want=fh:read("*all"); fh:close()
local f,loaded,done=0,false,false
local load_at,tries=150,0
emu.register_periodic(function()
  f=f+1
  -- Load at frame 150, NOT the frame 30 every other harness uses: at frame 30
  -- coco2b's BASIC is still in its cold-start RAM sweep, and the instruction
  -- it is part-way through when this script takes over lands one last write
  -- (seen: $00 into $3521, X=$3527, BASIC's S=$03D7) -- inside a title
  -- fragment. That cost exactly one title byte, in a different place per
  -- build, and looked like a codec bug for an afternoon. A real CLOADM only
  -- ever runs after BASIC has finished booting, so this is harness-only.
  -- ...and mask IRQ/FIRQ FIRST. By frame 150 BASIC's 60Hz IRQ is live, and
  -- the image loads rooms 35/36's art over BASIC's RAM interrupt vectors at
  -- $0100 (T0127): an IRQ between the load and start's own `orcc #$50` jumps
  -- into room data. One build crashed that way and the next one dodged it.
  if f==load_at and not loaded then
    cpu.state["CC"].value = cpu.state["CC"].value | 0x50
    cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true
    -- snapshot the fragments as loaded (title_frags: fdb addr,len pairs)
    fragbytes={}
    if SYM.title_frags then
      local tp=SYM.title_frags
      while true do
        local a=mem:read_u8(tp)*256+mem:read_u8(tp+1); local l=mem:read_u8(tp+2)*256+mem:read_u8(tp+3); tp=tp+4
        if l==0 then break end
        local b={} ; for i=0,l-1 do b[i]=mem:read_u8(a+i) end
        fragbytes[#fragbytes+1]={a=a,l=l,b=b}
      end
    end
  end
  -- T0124: ...and CHECK THE BOOT ACTUALLY STARTED. MAME suspends the 6809
  -- mid-instruction at frame boundaries (PC is never equal to CURPC here),
  -- so writing PC resumes BASIC's half-done instruction with operand bytes
  -- read from $0E00. Harmless for most images; for the T0124 image it jumped
  -- into data and hit an HCF opcode, and the CPU counted through memory
  -- forever -- with the mixer's address range passing under PC at frame 193,
  -- which made the wait test below fire and report a garbage title (6094/6144
  -- bytes "wrong") instead of a crash. One frame after a good start, start's
  -- `lds #$0100` has run; after a bad one S is still BASIC's (~$7F2A). On a
  -- bad one: force a COLD start ($0071=0: the warm-start vector below $0100
  -- is not trustworthy after our load) and retry at a different phase.
  -- ...and that the resumed instruction's stray WRITE (the other form of the
  -- same race: T0126's one wrong title byte) missed the title's load-time
  -- fragments. Boot does not touch them until show_title gathers them, far
  -- later than one frame; since T0125 they also carry block C.
  local frag_hit=false
  if loaded and not done and f==load_at+1 and SYM.title_frags and fragbytes then
    for _,fr in ipairs(fragbytes) do
      for i=0,fr.l-1 do if mem:read_u8(fr.a+i)~=fr.b[i] then frag_hit=true break end end
      if frag_hit then break end
    end
  end
  if loaded and not done and f==load_at+1 and (cpu.state["S"].value>0x0100 or frag_hit) then
    tries=tries+1
    if tries>5 then print("TITLEVERIFY FAIL: five loads in a row never started the image"); manager.machine:exit() return end
    print(string.format("TITLEVERIFY note: load at frame %d resumed a half-done BASIC instruction (S=$%04X after a frame%s) -- cold reset, retrying",
      load_at, cpu.state["S"].value, frag_hit and ", and it wrote into a title fragment" or ""))
    mem:write_u8(0x0071,0)
    loaded=false; load_at=f+150+tries*7
    manager.machine:soft_reset()
    return
  end
  if not loaded or done then return end
  -- the title is up once the CPU sits in the title's SPACE wait: the mixer
  -- blob (TITLE_MIX3 builds) or ti_press's tune loop (single-voice builds)
  local pc=cpu.state["PC"].value
  local waiting = (SYM.MIX3_BUF and pc>=SYM.MIX3_BUF and pc<SYM.MIX3_BUF+3072)
               or (SYM.play_tone and SYM.play_chirp and pc>=SYM.play_tone and pc<SYM.play_chirp)
  if waiting and f>load_at+30 then
    done=true
    local bad,first=0,nil
    for i=0,6143 do
      if mem:read_u8(0x4000+i)~=want:byte(i+1) then bad=bad+1; first=first or i end
    end
    if bad==0 then print("TITLEVERIFY OK: framebuffer A matches all 6144 bytes of the source title")
    else print(string.format("TITLEVERIFY FAIL: %d/6144 bytes differ, first at row %d col %d", bad, first//32, first%32)) end
    manager.machine:exit()
  end
  if f>2000 then print("TITLEVERIFY FAIL: the title's SPACE wait was never reached"); manager.machine:exit() end
end)
