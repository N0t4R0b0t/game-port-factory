-- harness/flipverify.lua -- T0125: is the upside-down world an EXACT mirror?
--
-- X-ALL.TXT's flipscreenrou swaps screentable entries 48..183, so with
-- `upsidedown` set every draw in that window lands on row 231-r and nothing
-- outside it moves. This warps Dizzy into a room, captures the on-screen
-- buffer normally, sets upsidedown=1 with both buffers invalidated, and
-- captures again. PASS needs:
--   rows 48..183   flipped[r] == normal[231-r], byte for byte
--   rows 0..47 and 184..191  unchanged (banner, status)
--   and after upsidedown=0 again, the normal picture back exactly.
-- Dizzy's own box is excluded from the byte test (his idle blink changes
-- frame between captures), and checked separately for ink in the mirrored
-- place.
--
--   ROOM=84 X=184 Y=72 DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 90 \
--     -autoboot_script harness/flipverify.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end
local ROOM=tonumber(os.getenv("ROOM") or "84")
local WX,WY=tonumber(os.getenv("X") or "184"),tonumber(os.getenv("Y") or "72")

local function r(s) return mem:read_u8(SYM[s]) end
local function pc() return cpu.state["PC"].value end
local function in_audio() local p=pc() return p>=SYM.play_tone and p<SYM.play_chirp end
local function busy()
  local p=pc()
  if p>=SYM.play_tone and p<SYM.play_chirp then return true end
  local sp=cpu.state["S"].value
  for i=0,24 do local w=mem:read_u8(sp+i)*256+mem:read_u8(sp+i+1)
    if (w>=SYM.msg_begin and w<SYM.fb_stablekeys) or (w>=SYM.play_tone and w<SYM.play_chirp) then return true end end
  return false
end
local quiet=0
-- true once the game has run 40 frames with no sound or message box; while
-- anything is busy SPACE is toggled so a box that popped up gets dismissed
local function settled()
  -- (own counter: `f` is declared below this function)
  if busy() then quiet=0; busyn=(busyn or 0)+1; key("SPACE",(busyn//14)%2==0) else quiet=quiet+1; key("SPACE",false) end
  return quiet>=40
end
local function capture()
  local base = r("cur_buf")==0 and 0x4000 or 0x6000
  local t={} ; for i=0,6143 do t[i]=mem:read_u8(base+i) end
  return t
end
-- Dizzy's box in logical rows/columns, one byte of margin each side
local function dizzy_box()
  local x,y,h=r("dizzy_x"),r("dizzy_y"),r("dizzy_h")
  return {c0=math.max(0,x//8-1), c1=math.min(31,x//8+4), r0=math.max(0,y-h-1), r1=math.min(191,y+1)}
end
local function in_box(b,row,col) return col>=b.c0 and col<=b.c1 and row>=b.r0 and row<=b.r1 end

local f,loaded,stage,t,clear,count=0,false,"boot",0,0,0
local normal,box
local function to(s) stage=s; t=f; clear=0; count=0; quiet=0 end
local function fail(why)
  print(string.format("FLIPVERIFY FAIL at %s: %s (room=%d x=%d y=%d killed=%d)", stage, why, r("cur_room"), r("dizzy_x"), r("dizzy_y"), r("killed")))
  stage="done"
end

emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  -- flames/water change bitmap every few passes; hold their counters so
  -- the two captures show the same animation phase
  if stage=="settle" or stage=="flipped" or stage=="back" then
    for _,n in ipairs({"flame_ctr","water_ctr"}) do if SYM[n] then mem:write_u8(SYM[n],0) end end
  end

  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    -- the mainloop must be RUNNING, not merely past `sta dizzy_y`: new_game
    -- calls set_checkpoint a few instructions later and would overwrite a
    -- respawn poked in between (T0125: unpack_c moved that window onto the
    -- frame boundary and every warp silently stayed in room 36)
    boot_live=(r("cur_room")==36 and r("dizzy_y")~=0) and (boot_live or 0)+1 or 0
    if boot_live>=60 then
      mem:write_u8(SYM.lives,2)
      mem:write_u8(SYM.respawn_room,ROOM); mem:write_u8(SYM.respawn_x,WX)
      mem:write_u8(SYM.respawn_y,WY); mem:write_u8(SYM.killed,1)
      to("warp")
    end
  elseif stage=="warp" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if count==0 then
      if r("cur_room")==ROOM and r("dizzy_x")==WX then count=1 end
    elseif not in_audio() then
      clear=clear+1; if clear>=3 then key("SPACE",false); to("settle") end
    else clear=0 end
    if f-t>900 then fail("never arrived") end
  elseif (stage=="settle" or stage=="flipped" or stage=="back") and f-t>1800 then
    fail("never went quiet (a message or sound keeps firing here -- pick another spot)")
  elseif stage=="settle" then
    grounded = r("dizzy_floor")==1 and (grounded or 0)+1 or 0
    if f-t>=90 and settled() and grounded>=30 then
      normal=capture(); box=dizzy_box()
      mem:write_u8(SYM.upsidedown,1)
      mem:write_u8(SYM.bufA_last_x,255); mem:write_u8(SYM.bufB_last_x,255)
      to("flipped")
    end
  elseif stage=="flipped" or stage=="back" then
    if f-t==10 or f-t==20 then mem:write_u8(SYM.bufA_last_x,255); mem:write_u8(SYM.bufB_last_x,255) end
  end
  if stage=="flipped" then
    if f-t>=60 and settled() and r("fb_flip")==1 then
      local fl=capture()
      local same=0 ; for i=48*32,184*32-1 do if fl[i]==normal[i] then same=same+1 end end
      local sp=cpu.state["S"].value ; local msg=false
      for i=0,20 do local w=mem:read_u8(sp+i)*256+mem:read_u8(sp+i+1) if w>=SYM.msg_wait_dismiss and w<SYM.fb_stablekeys then msg=true end end
      print(string.format("FLIPVERIFY diag: upsidedown=%d fb_flip=%d cur_buf=%d msgwait=%s pc=%04X  window bytes equal to the UNmirrored normal=%d/4352",
        r("upsidedown"), r("fb_flip"), r("cur_buf"), tostring(msg), pc(), same))
      local bad,first,outside,firsto=0,nil,0,nil
      local mbox={c0=box.c0,c1=box.c1,r0=231-box.r1,r1=231-box.r0}
      local ink=0
      for row=0,191 do for col=0,31 do
        local got=fl[row*32+col]
        if row>=48 and row<=183 and (col==0 or col==31) then
          -- the port's own bead border (ui.asm draw_border): its side
          -- columns run an 8-row pattern down from row 40 every pass, outside
          -- the room renderer, so a mirrored row sits at a different bead
          -- phase. Not room art; nothing in the source to be faithful to.
        elseif row>=48 and row<=183 then
          if in_box(mbox,row,col) then
            if got~=0 then ink=ink+1 end
          elseif not in_box(box,231-row,col) and got~=normal[(231-row)*32+col] then
            bad=bad+1; first=first or string.format("row %d col %d got %02X want %02X",row,col,got,normal[(231-row)*32+col])
            badrows=badrows or {} ; badrows[row]=(badrows[row] or 0)+1
          end
        elseif got~=normal[row*32+col] then
          outside=outside+1; firsto=firsto or string.format("row %d col %d got %02X want %02X",row,col,got,normal[row*32+col])
        end
      end end
      local rl={} ; for row=48,183 do if badrows and badrows[row] then rl[#rl+1]=row..":"..badrows[row] end end
      print(string.format("FLIPVERIFY flipped: window mismatches=%d%s | banner/status changed=%d%s | ink in Dizzy's mirrored box=%d | rows %s",
        bad, first and (" (first "..first..")") or "", outside, firsto and (" (first "..firsto..")") or "", ink, table.concat(rl," ")))
      flipped_ok = bad==0 and outside==0 and ink>0
      mem:write_u8(SYM.upsidedown,0)
      mem:write_u8(SYM.bufA_last_x,255); mem:write_u8(SYM.bufB_last_x,255)
      to("back")
    end
  elseif stage=="back" then
    if f-t>=60 and settled() then
      local nb=capture()
      local bad,first=0,nil
      for row=0,191 do for col=0,31 do
        if not in_box(box,row,col) and nb[row*32+col]~=normal[row*32+col] then
          bad=bad+1; first=first or string.format("row %d col %d",row,col)
        end
      end end
      print(string.format("FLIPVERIFY %s room %d: mirrored window %s; unflipped again: %d mismatches%s",
        (flipped_ok and bad==0) and "PASS" or "FAIL", ROOM, flipped_ok and "exact" or "WRONG", bad, first and (" (first "..first..")") or ""))
      stage="done"
    end
  end
end)
