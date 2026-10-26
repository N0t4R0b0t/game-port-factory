-- harness/wellverify.lua -- T0125: the well traversal, logged state by state.
--
-- Warps Dizzy into START_ROOM at (X,Y) and lets him fall, logging a WELL
-- line whenever room, upsidedown, well_mode, sequence or floor changes (plus
-- dy and position), and a WELLSUM line at the end with the room sequence.
-- With START_ROOM=39 near the shaft's top the expected story is the source's:
--   fall through 39 (mode 0: a respawn is not a transition)
--   -> out of the bottom: upsidedown 0->1, back into 39 at y=180, mode 2,
--      seq 8, dy -6 every pass
--   -> out of the top: mode 3, dy -8, into 23 if the last entry came from 55
--      (else 55), drifting right, until he lands (mode 0)
-- With START_ROOM=55 above the well mouth (lid removed), the 55 -> 39 entry
-- is the fallenoutof23 tumble (mode 1, dy 4) and well_last=55.
--
--   START_ROOM=39 X=120 Y=70 [LIDOFF=1] DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 90 \
--     -autoboot_script harness/wellverify.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end
local ROOM=tonumber(os.getenv("START_ROOM") or "39")
local WX,WY=tonumber(os.getenv("X") or "120"),tonumber(os.getenv("Y") or "70")
local DUR=tonumber(os.getenv("DUR") or "1500")

local function r(s) return mem:read_u8(SYM[s]) end
local function sb(s) local v=r(s) return v>=128 and v-256 or v end
local f,loaded,stage,t=0,false,"boot",0
local last,rooms,lastroom="",{},nil
local dy6,mode2passes=0,0

emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  -- messages never block the log; NOSPACE=1 stops toggling once logging
  -- starts (SPACE is a game key too)
  if f%14==0 and not (os.getenv("NOSPACE") and stage=="log") then key("SPACE",(f//14)%2==0) end
  if os.getenv("NOSPACE") and stage=="log" then key("SPACE",false) end

  if stage=="boot" then
    -- wait for the mainloop to be RUNNING (see flipverify.lua): a respawn
    -- poked before new_game's set_checkpoint is silently overwritten
    boot_live=(r("cur_room")==36 and r("dizzy_y")~=0) and (boot_live or 0)+1 or 0
    if boot_live>=60 then
      -- T0125: block C (rooms 39, 23) is unpacked by new_game from the
      -- gathered title stream; IMAGE_C = /tmp/stage_c.bin checks every byte
      if os.getenv("IMAGE_C") and not checkedc then
        checkedc=true
        local fh=io.open(os.getenv("IMAGE_C"),"rb"); local want=fh:read("*all"); fh:close()
        local bad=0 ; for i=1,#want do if mem:read_u8(SYM.RC_DEST+i-1)~=want:byte(i) then bad=bad+1 end end
        print(string.format("WELL blockC %s: %d bytes at $%04X, %d wrong", bad==0 and "OK" or "FAIL", #want, SYM.RC_DEST, bad))
      end
      mem:write_u8(SYM.lives,2)
      mem:write_u8(SYM.respawn_room,ROOM); mem:write_u8(SYM.respawn_x,WX)
      mem:write_u8(SYM.respawn_y,WY); mem:write_u8(SYM.killed,1)
      stage="warp"; t=f
    end
  elseif stage=="warp" then
    if r("cur_room")==ROOM and r("dizzy_x")==WX and r("killed")==0 then
      if os.getenv("LIDOFF") then
        -- the well lid (crowbar actor frame 158 in room 55) out of the world
        for i=0,(SYM.ACTOR_COUNT or 33)-1 do local b=SYM.actor_ram+i*8
          if mem:read_u8(b)==55 and mem:read_u8(b+4)==158 then mem:write_u8(b,255) end end
      end
      stage="log"; t=f
    elseif f-t>900 then print("WELL FAIL never arrived"); stage="done" end
  elseif stage=="log" then
    local room,ud,mode,seq,floor=r("cur_room"),r("upsidedown"),r("well_mode"),r("dizzy_seq"),r("dizzy_floor")
    if room~=lastroom then rooms[#rooms+1]=room; lastroom=room end
    if mode==2 then mode2passes=mode2passes+1; if sb("dizzy_dy")==-6 then dy6=dy6+1 end end
    local key_=string.format("%d/%d/%d/%d/%d/%d",room,ud,mode,seq,floor,r("troll_launching"))
    if key_~=last then
      print(string.format("WELL a=%d room=%d upsidedown=%d fb_flip=%d well_mode=%d well_last=%d seq=%d floor=%d dy=%d x=%d y=%d killed=%d troll_launching=%d",
        f-t, room, ud, r("fb_flip"), mode, r("well_last"), seq, floor, sb("dizzy_dy"), r("dizzy_x"), r("dizzy_y"), r("killed"), r("troll_launching")))
      last=key_
    end
    -- SNAP=n: a MAME snapshot every n frames while logging (needs
    -- -snapshot_directory); the flipped rooms are best judged by eye
    local snap=tonumber(os.getenv("SNAP") or "0")
    if snap>0 and (f-t)%snap==0 then manager.machine.video:snapshot() end
    if f-t>=DUR then
      local rs={} ; for _,v in ipairs(rooms) do rs[#rs+1]=tostring(v) end
      print(string.format("WELLSUM rooms=%s final room=%d upsidedown=%d well_mode=%d floor=%d x=%d y=%d | frames in mode 2 with dy=-6: %d/%d",
        table.concat(rs,">"), r("cur_room"), r("upsidedown"), r("well_mode"), r("dizzy_floor"), r("dizzy_x"), r("dizzy_y"), dy6, mode2passes))
      stage="done"
    end
  end
end)
