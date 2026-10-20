-- harness/tape_coin_pickup.lua -- T0236: end-to-end proof for the
-- tape-only region's own SECOND coin table (coin_init_tape,
-- COIN_COUNT_tape), the same real warp->stand->DOWN->check shape as
-- harness/tape_item_pickup.lua, plus the reset proof
-- harness/tape_actor_reset.lua uses for the actor table -- coins need
-- both: pickup_coins_tape sets bit 7 of the room byte and increments
-- the global `coins` counter, and reset_tape_actors (T0236: now also
-- restores coin_init_tape from coin_init_tape_template) must undo both
-- on a fresh game after a game over, in the SAME tape session.
--
--   1. warp beside coin_init_tape slot 0 (room 63, x=104,y=152 --
--      target/coin_data_tape.asm) and press DOWN
--   2. check: room byte now has bit 7 set (255-63=192, i.e. 63|0x80),
--      and `coins` incremented by exactly 1
--   3. dismiss the "found a coin" box (msg_foundcoin, pc_take's own
--      msg_box_done -- blocks the mainloop like any other message box)
--   4. force a death at 0 lives, ride the REAL death sequence to the
--      title, SPACE for a new game
--   5. check: coin_init_tape slot 0's room byte is back to 63 (bit 7
--      clear -- RESTORED, not still "collected") and `coins` is 0
--
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 120 \
--     -autoboot_script harness/tape_coin_pickup.lua
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
local COIN_SLOT=0   -- coin_init_tape's slot 0: room 63, x=104,y=152
local function coin_room() return mem:read_u8(SYM.coin_init_tape+COIN_SLOT*3) end
local function force_death()
  mem:write_u8(SYM.lives,0)
  mem:write_u8(SYM.killed,1)
end

local f,loaded,stage,t=0,false,"boot",0
local boot_live,stood1,busyn1=0,0,0
local coins_before=0
local boxseen,press_at=false,0
local boxseen2,press_at2=false,0
local log={}
local function fail(msg) print("TAPECOIN FAIL: "..msg); manager.machine:exit() end

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
    mem:write_u8(SYM.respawn_room,63); mem:write_u8(SYM.respawn_x,96)
    mem:write_u8(SYM.respawn_y,152); mem:write_u8(SYM.killed,1)
    stage="arrive1"; t=f
    return
  end

  if stage~="boot" and r("lives")<2 and stage~="dying" and stage~="title" and stage~="press" then
    mem:write_u8(SYM.lives,2)
  end

  if stage=="arrive1" then
    if in_msgwait() or in_audio() then busyn1=busyn1+1; key("SPACE",(busyn1//14)%2==0)
    else key("SPACE",false) end
    if r("cur_room")==63 and r("dizzy_x")==96 and r("killed")==0 and not in_msgwait() and not in_audio() then
      stood1 = r("dizzy_floor")==1 and stood1+1 or 0
      if stood1>=10 then
        coins_before=r("coins")
        stage="pickup"; t=f
      end
    end
    if f-t>1500 then fail(string.format("never stood beside the coin (room=%d x=%d y=%d floor=%d)",
      r("cur_room"),r("dizzy_x"),r("dizzy_y"),r("dizzy_floor"))) end

  elseif stage=="pickup" then
    key("DOWN", f-t>=10 and f-t<50)
    if f-t==90 then
      key("DOWN",false)
      local rm=coin_room()
      local got_bit7 = rm>=128
      local coins_now=r("coins")
      if not got_bit7 then fail(string.format("coin not collected (room byte=%d, want >=128)",rm)) end
      if coins_now~=coins_before+1 then
        fail(string.format("coins counter did not increment (before=%d now=%d)",coins_before,coins_now))
      end
      table.insert(log,string.format("picked up: room byte %d->%d, coins %d->%d",
        63,rm,coins_before,coins_now))
      stage="dismissbox"; t=f
    end

  elseif stage=="dismissbox" then
    -- pc_take's own msg_box_done (msg_foundcoin) blocks the mainloop --
    -- same shape as tape_actor_reset.lua's closeinv step.
    if not boxseen then
      key("SPACE",false)
      if in_msgwait() then boxseen=true; press_at=f end
      if f-t>300 then fail("no coin-found box after pickup") end
    elseif f-press_at<8 then
      key("SPACE",true)
    elseif f-press_at<24 then
      key("SPACE",false)
    elseif not in_msgwait() then
      force_death()
      stage="dying"; t=f
    elseif f-press_at>300 then
      fail("coin-found box never dismissed")
    end

  elseif stage=="dying" then
    if not boxseen2 then
      key("SPACE",false)
      if in_msgwait() then boxseen2=true; press_at2=f end
      if f-t>900 then fail("no death box after the last life") end
    elseif f-press_at2<8 then
      key("SPACE",true)
    elseif f-press_at2<24 then
      key("SPACE",false)
    else
      if in_title_wait() then
        table.insert(log,"death box dismissed, title reached")
        stage="title"; t=f
      elseif f-press_at2>240 then
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
      local rm=coin_room()
      local coins_now=r("coins")
      if rm==63 and coins_now==0 then
        table.insert(log,string.format("after new game: room byte=%d (RESTORED) coins=%d (RESET)",rm,coins_now))
        print("TAPECOIN PASS: "..table.concat(log," | "))
      else
        fail(string.format("not reset after new game (room byte=%d want 63, coins=%d want 0)",rm,coins_now))
      end
      stage="done"; manager.machine:exit()
    end
  end
end)
