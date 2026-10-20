-- harness/jumptrace.lua -- trace ONE jump, pass by pass, in the PORT.
--
-- The companion to the ZX side's ZXDBG=1 output (harness/exits_zx.lua):
-- print room/x/y/dy/floor for every change so the two can be diffed
-- step for step. That comparison is what found T0192 (a side room
-- transition ran a vertical step the original skips) after four rounds
-- of endpoint-only differentials had said "they match".
--
-- Lived in /tmp for most of a session and was wiped twice. It is a real
-- tool; it lives here now.
--
--   RM=68 SX=32 SY=148 DIR=LEFT HOLD=1 JUMP=1 \
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none \
--     -seconds_to_run 120 -autoboot_script harness/jumptrace.lua
--
--   RM    room to warp into        SX,SY  where to put Dizzy
--   DIR   LEFT|RIGHT to hold       HOLD   1 = hold DIR (0 = no direction)
--   JUMP  1 = press UP             AFTER  extra passes to keep tracing
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,fd in pairs(row3.fields) do fl[n]=fd end
local function key(n,d) if fl[n] then fl[n]:set_value(d and 1 or 0) end end
-- T0230: load_decb, generalised for images that carry a DECB block at
-- $8000+ (target/room36_tape.bin -- rooms 74/75, the tape-only region).
-- Real hardware confirmed (NOTES.md T0225 RESEARCH-2, "the platform
-- question ... settled NO"): $8000+ writes are DROPPED while the SAM
-- is in ROM mode, the state MAME/XRoar both boot into. A plain
-- mem:write_u8 loop -- what every other harness's own load_decb copy
-- still does -- silently no-ops for any block up there, exactly the
-- failure mode this task exists to avoid.
--
-- Fix: poke $FFDF (all-RAM) once, before writing the FIRST block whose
-- address is >=$8000, and simply leave it engaged -- this matches the
-- REAL tape path exactly (target/tape_stage1.asm's own header: "Leaves
-- all-RAM ENGAGED after the last block"), and room36.asm's `start:`
-- re-asserts `sta $ffdf` itself at its very first instruction anyway
-- (T0153's RELOC_BOOT_BYTES-guarded boot code, unmodified -- see its
-- own comment), so entering already-all-RAM is exactly the state a
-- real tape boot hands off in, not a harness-only shortcut.
--
-- Below-$8000 blocks are unaffected either way (ROM-mode writes there
-- always reached RAM -- every existing harness's load_decb already
-- relies on this, unchanged here).
--
-- Reusable pattern: any harness that needs to load an image with
-- $8000+ content (a tape build's own DECB image, not a .cas) can copy
-- this function verbatim; only jumptrace.lua uses it this round
-- (T0230's own verification), scoped to what this task needed.
local function load_decb(path)
  local fh=io.open(path,"rb"); local data=fh:read("*all"); fh:close(); local pos=1
  local allram=false
  while pos<=#data do local t=data:byte(pos)
    if t==0 then local len=data:byte(pos+1)*256+data:byte(pos+2)
      local addr=data:byte(pos+3)*256+data:byte(pos+4)
      if addr>=0x8000 and not allram then mem:write_u8(0xffdf,0); allram=true end
      for i=0,len-1 do mem:write_u8(addr+i,data:byte(pos+5+i)) end
      pos=pos+5+len
    elseif t==0xFF then return data:byte(pos+3)*256+data:byte(pos+4) else break end end
end
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end
local RM=tonumber(os.getenv("RM") or "36")
local SX=tonumber(os.getenv("SX") or "100")
local SY=tonumber(os.getenv("SY") or "168")
local DIR=os.getenv("DIR") or "LEFT"
local HOLD=(os.getenv("HOLD") or "1")=="1"
local JUMP=(os.getenv("JUMP") or "1")=="1"
local AFTER=tonumber(os.getenv("AFTER") or "260")
-- RELEASE=1: let go of DIR as soon as the jump has started, so the
-- trace shows how far Dizzy carries on AFTER landing with no key
-- held -- the playtest report ("he does a few steps after landing").
local RELEASE=(os.getenv("RELEASE") or "0")=="1"
local f,loaded,staged,live,boot,clear=0,false,false,nil,0,0
local jumped=false
local last
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded then return end
  if not live and f%14==0 then key("SPACE",(f//14)%2==0) end
  if not staged then
    if mem:read_u8(SYM.cur_room)~=0 and mem:read_u8(SYM.dizzy_floor)==1 then boot=boot+1 end
    if boot>=60 then
      mem:write_u8(SYM.respawn_room,RM); mem:write_u8(SYM.respawn_x,SX)
      mem:write_u8(SYM.respawn_y,SY);    mem:write_u8(SYM.killed,1)
      staged=true; boot=0
    end
    return
  end
  if not live then
    -- wait for arrival AND a settled floor, or the keys land mid-respawn
    -- NOFLOOR=1: do not wait for a floor. A shaft or a hazard pit has
    -- none, and the old gate simply never opened there (room 69's blade
    -- shaft produced no output at all).
    local ok = mem:read_u8(SYM.cur_room)==RM and
               (os.getenv("NOFLOOR")=="1" or mem:read_u8(SYM.dizzy_floor)==1)
    if ok then
      boot=boot+1
      if boot>=(os.getenv("NOFLOOR")=="1" and 30 or 120) then key("SPACE",false); live=f end
    end
    return
  end
  local a=f-live
  if mem:read_u8(SYM.jump_on)~=0 then jumped=true end
  if HOLD then key(DIR, a>=10 and not (RELEASE and jumped)) end
  if JUMP then key("UP", a>=10 and not jumped) end
  if a>=8 then
    local s=string.format("%d %3d %3d dy%-4d floor=%d jump_on=%d anim=%d kf=%02x ff=%-3d seq=%d killed=%d lives=%d",
      mem:read_u8(SYM.cur_room), mem:read_u8(SYM.dizzy_x), mem:read_u8(SYM.dizzy_y),
      (mem:read_u8(SYM.dizzy_dy)+128)%256-128, mem:read_u8(SYM.dizzy_floor),
      mem:read_u8(SYM.jump_on), mem:read_u8(SYM.jump_anim), mem:read_u8(SYM.keyflags),
      mem:read_u8(SYM.dizzy_ff), SYM.dizzy_seq and mem:read_u8(SYM.dizzy_seq) or 0,
      mem:read_u8(SYM.killed), mem:read_u8(SYM.lives))
    if s~=last then print("JT "..s); last=s end
  end
  if a>AFTER then manager.machine:exit() end
end)
