-- harness/tape_actor_reset.lua -- T0234: the tape-only region's own
-- actor table (actor_init_tape) has no separate ROM master to restore
-- from (T0230's "delivered raw, no relocation" design) -- a picked-up
-- item used to stay gone for the rest of the tape session, including
-- across a game over. Reported as a real bug (non-resetting tape rooms
-- after game over). Fixed by reset_tape_actors (actors.asm), called
-- from new_game, restoring FROM actor_init_tape_template (roompack's
-- --actor-template). This is the end-to-end proof:
--   1. warp into room 88, stand by crowbarhere, DOWN -- picked up
--      (same proof as harness/tape_item_pickup.lua)
--   2. force a death at 0 lives (gameover_tape.lua's own force_death),
--      ride the death box -> title -> SPACE -> new game
--   3. warp BACK into room 88 -- crowbarhere's record must read room=88
--      again (NOT 255 -- restored, not still "carried"/removed)
--
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 120 \
--     -autoboot_script harness/tape_actor_reset.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
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
local function stray_fix(path)
  local fh=io.open(path,"rb"); local d=fh:read("*all"); fh:close(); local pos=1
  while pos<=#d and d:byte(pos)==0 do
    local len=d:byte(pos+1)*256+d:byte(pos+2); local addr=d:byte(pos+3)*256+d:byte(pos+4)
    for i=0,len-1 do local a=addr+i
      if a>=0x0E00 and a<0x8000 and mem:read_u8(a)~=d:byte(pos+5+i) then mem:write_u8(a,d:byte(pos+5+i)) end end
    pos=pos+5+len
  end
end
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end
local function r(s) return mem:read_u8(SYM[s]) end
local function pc() return cpu.state["PC"].value end
local function stack_has(lo,hi)
  local sp=cpu.state["S"].value
  for i=0,63 do if sp+i+1>=0x100 then break end local a=mem:read_u8(sp+i)*256+mem:read_u8(sp+i+1)
    if a>=lo and a<hi then return true end end
  return false
end
local function in_msgwait()
  local p=pc()
  return (p>=SYM.msg_wait_dismiss and p<SYM.fb_stablekeys) or stack_has(SYM.msg_wait_dismiss,SYM.fb_stablekeys)
end
local function in_audio() local p=pc() return p>=SYM.play_tone and p<SYM.play_chirp end
local function in_title_wait()
  local p=pc()
  return (SYM.MIX3_BUF and p>=SYM.MIX3_BUF and p<SYM.MIX3_BUF+3072)
      or (SYM.play_tone and SYM.play_chirp and p>=SYM.play_tone and p<SYM.play_chirp)
end
-- T0238/T0239: slot keeps shifting as more tape-only actors are
-- inserted earlier in actor_init_tape's own source order -- 8 (T0234)
-- -> 10 (T0238, lifts+switch1) -> 12 (T0239, room 48's log+key 4).
-- Re-verify against target/actor_data_tape.asm directly, don't
-- increment by habit.
local function slot_of(room,frame)
  -- parse the assembled-from source: slot = fcb line order after the label
  local i=-1; local inside=false
  for line in io.lines("target/actor_data_tape.asm") do
    if line:match("^actor_init_tape%s*$") then inside=true
    elseif inside then
      local rm,_,_,_,fr=line:match("^%sfcb (%d+),(%d+),(%d+),(%d+),(%d+)")
      if rm then i=i+1; if tonumber(rm)==room and tonumber(fr)==frame then return i end
      elseif line:match("^%S") and not line:match("^;") then break end
    end
  end
  error("no tape actor room "..room.." frame "..frame)
end
-- T0229: the crowbar starts hidden (room 255, Doug's talk materialises it); this is an isolated
-- pickup/reset unit test, so warp1 puts it into room 88 by hand and the reset must send it back to 255.
local CROWBAR_SLOT=slot_of(255,4)
local function crowbar_room() return mem:read_u8(SYM.actor_init_tape+CROWBAR_SLOT*8) end
local function force_death()
  mem:write_u8(SYM.lives,0)
  mem:write_u8(SYM.killed,1)
end

local f,loaded,stage,t=0,false,"boot",0
local boot_live=0
local boxseen,press_at,stood1,busyn1=false,0,0,0
local log={}
local function fail(msg) print("TAPERESET FAIL: "..msg); manager.machine:exit() end

emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  if f==31 then stray_fix(os.getenv("DIZZY_BIN")) end

  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    boot_live=(r("cur_room")==36 and r("dizzy_y")~=0) and boot_live+1 or 0
    if boot_live>=60 then
      key("SPACE",false)
      stage="warp1"; t=f
    end
    return
  end

  if stage=="warp1" then
    mem:write_u8(SYM.actor_init_tape+CROWBAR_SLOT*8,88)   -- T0229: stand-in for Doug's talk
    mem:write_u8(SYM.respawn_room,88); mem:write_u8(SYM.respawn_x,64)
    mem:write_u8(SYM.respawn_y,96); mem:write_u8(SYM.killed,1)
    if os.getenv("RSTDBG") then
      print(string.format("RSTDBG warp1: wrote respawn_room=%d x=%d y=%d killed=%d (readback: rr=%d rx=%d ry=%d k=%d lives=%d)",
        88,64,96,1, r("respawn_room"), r("respawn_x"), r("respawn_y"), r("killed"), r("lives")))
    end
    stage="arrive1"; t=f
    return
  end

  if stage~="boot" and r("lives")<2 and stage~="dying" and stage~="title" and stage~="press" then
    -- keep lives topped up EXCEPT while we're deliberately forcing a death
    mem:write_u8(SYM.lives,2)
  end

  if stage=="arrive1" then
    -- T0234: killed=1 goes through the REAL update_death countdown (see
    -- gameplay.asm) -- decrements to 0 on this very poke, which shows
    -- msg_deadwindow and blocks on msg_wait_dismiss same as any other
    -- death, THEN runs gp_ud_respawn (lives=2, not 0) and moves cur_room/
    -- dizzy_x/y from respawn_room/x/y. Costs a life, same as items.lua's
    -- own identical warp trick -- topped back up to 2 above.
    if in_msgwait() or in_audio() then busyn1=(busyn1 or 0)+1; key("SPACE",(busyn1//14)%2==0)
    else key("SPACE",false) end
    if os.getenv("RSTDBG") and (f-t)%20==0 then
      print(string.format("RSTDBG a=%d room=%d x=%d y=%d floor=%d killed=%d lives=%d msgwait=%s audio=%s pc=%04X",
        f-t, r("cur_room"), r("dizzy_x"), r("dizzy_y"), r("dizzy_floor"), r("killed"), r("lives"),
        tostring(in_msgwait()), tostring(in_audio()), pc()))
    end
    if r("cur_room")==88 and r("dizzy_x")==64 and r("killed")==0 and not in_msgwait() and not in_audio() then
      stood1 = r("dizzy_floor")==1 and (stood1 or 0)+1 or 0
      if stood1>=10 then stage="pickup"; t=f end
    end
    if f-t>1500 then fail(string.format("never stood beside crowbarhere (room=%d x=%d y=%d floor=%d)",
      r("cur_room"),r("dizzy_x"),r("dizzy_y"),r("dizzy_floor"))) end

  elseif stage=="pickup" then
    key("DOWN", f-t>=10 and f-t<50)
    if f-t==90 then
      key("DOWN",false)
      if crowbar_room()~=255 then fail("crowbarhere not picked up (room="..crowbar_room()..")") end
      table.insert(log,"picked up: crowbarhere room byte -> 255, ok")
      stage="closeinv"; t=f
    end

  elseif stage=="closeinv" then
    -- T0234: try_pickup's own tp_take opens show_inventory on EVERY
    -- successful pickup (actors.asm's own comment) -- its input loop
    -- blocks the mainloop (update_death never runs) until dismissed.
    -- Cursor defaults to EXIT, so one clean SPACE press+release closes
    -- it without dropping anything back down.
    if f-t<8 then key("SPACE",true)
    elseif f-t<24 then key("SPACE",false)
    elseif f-t==40 then
      force_death()
      stage="dying"; t=f
    end

  elseif stage=="dying" then
    if not boxseen then
      key("SPACE",false)
      if in_msgwait() then boxseen=true; press_at=f end
      if f-t>900 then fail("no death box after the last life") end
    elseif f-press_at<8 then
      key("SPACE",true)
    elseif f-press_at<24 then
      key("SPACE",false)
    else
      if in_title_wait() then
        table.insert(log,"death box dismissed, title reached")
        stage="title"; t=f
      elseif f-press_at>240 then
        fail("title never reached after the death box")
      end
    end

  elseif stage=="title" then
    key("SPACE",false)
    if f-t==90 then key("SPACE",true); stage="press"; t=f end

  elseif stage=="press" then
    key("SPACE", f-t<10)
    if f-t>=10 and not in_title_wait() and r("cur_room")==36 and r("dizzy_y")~=0 then
      table.insert(log,"SPACE on the title started a new game")
      stage="newgame"; t=f
    end
    if f-t>900 then fail("SPACE on the title never started a game") end

  elseif stage=="newgame" then
    key("SPACE",false)
    mem:write_u8(SYM.lives,2)
    if f-t==60 then
      -- new_game's own reset_tape_actors already ran (before load_room);
      -- read the record directly, no need to warp back into the room --
      -- actor_init_tape is global state, not room-load-time derived.
      local rm=crowbar_room()
      if rm==255 then
        table.insert(log,"crowbarhere room byte after new game: 255 (RESTORED to hidden, T0229)")
        print("TAPERESET PASS: "..table.concat(log," | "))
      else
        fail("crowbarhere NOT restored after new game (room="..rm..", want 255)")
      end
      stage="done"; manager.machine:exit()
    end
  end
end)
