-- harness/tape_daisy_ending.lua -- T0236: daisyrou1 (room 73, frame 35,
-- ROU_DAISY1) -- the game's win trigger. X-ALL.TXT's doendmessages:
-- coins<30 nags (notgotallcoins, 4 boxes, game carries on unchanged);
-- coins==30 sets completedgame and shows gotallcoins (5 boxes), and
-- mainloop's own completedgame check (X-ALL.TXT line 1357, `jr nz,
-- quitted`) ends the game the same way a game-over does.
--
-- Real touch, one continuous stand on daisy1here: update_daisy1 (like
-- the original's own doendmessages) retriggers every mainloop pass
-- while Dizzy stays in contact -- there is no "already shown, stop
-- asking" latch in X-ALL.TXT either (chatter's own `jp windowrou1` just
-- returns to ordinary play, still standing on her). So this harness
-- does NOT wait for the message to go away and stay away (it won't,
-- while coins<30 and Dizzy hasn't moved) -- it dismisses continuously,
-- confirms the FIRST few dismissals are the nag (completedgame stays 0,
-- title not reached), pokes coins=30, and confirms a LATER retrigger
-- wins (completedgame=1, title reached).
--
-- T0221: also asserts the completion tune (tune3 through the 3-voice mixer,
-- blob unpacked into the HIDDEN framebuffer) runs under the win boxes:
--   * PC sits inside the blob (tw_base .. +WIN_MIX3_RAW) for >= TUNE_HOLD_S
--     seconds of emulated time while the first gotallcoins box is up (SPACE is
--     held off until then; default 3 s, WIN_HOLD_S=28 also proves the loop
--     wrap, sptr back to the stream start);
--   * the blob is in the buffer that is NOT displayed (cur_buf), and that
--     buffer differs from the visible page; WIN_DUMP=dir saves both pages;
--   * after the last box SPACE returns, the title replay is reached and
--     completedgame=1 (as before).
--
-- T0228: daisy1 now starts HIDDEN (room 255; X-ALL.TXT daisy1here orig_room 255, she appears
-- when Daisy's meeting in room 94 moves her -- harness/tape_daisy94.lua walks that meeting).
-- This harness is about the ENDING, so it places her in 73 by a poke at boot (documented set-up).
-- Also asserts the win sequence's tail (X-ALL.TXT doendmessages `jr theheartdemo`, 3565): after
-- the last gotallcoins box the heart demo runs (silent: the mixer does not run during it, 255
-- updates, every update's pixel change equal to harness/heartref.lua's independent render,
-- ages/paths as the original's), and only then the title.  WIN_DUMP also gets heart_{start,mid,end}.
-- The blob now sits 1536 B into the hidden buffer (below the banner rows).
-- WIN_TIMES=file records the emu-time window of the first-box mixer run so a
-- -wavwrite capture can be cropped to the tune.
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 150 \
--     -autoboot_script harness/tape_daisy_ending.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local H=dofile("harness/heartref.lua")
if os.getenv("FLOPPY_OVL_DIR") then H.load_overlay_ranges(os.getenv("FLOPPY_OVL_DIR"),mem) end   -- T0241: the demo is a disk overlay in the floppy build
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
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
local mon=H.monitor({mem=mem,cpu=cpu,SYM=SYM,dumpdir=os.getenv("WIN_DUMP"),dump_at={[0]="heart_start",[127]="heart_mid",[255]="heart_end"}})
local demo_mix_viol=0
local function pc() return cpu.state["PC"].value end
local function stack_has(lo,hi)
  local sp=cpu.state["S"].value
  for i=0,63 do if sp+i+1>=0x100 then break end local a=mem:read_u8(sp+i)*256+mem:read_u8(sp+i+1)
    if a>=lo and a<hi then return true end end
  return false
end
local fail
local log={}
local function in_msgwait()
  local p=pc()
  -- T0221: the win boxes are driven by tape_win_chatter..tw_base (their own
  -- wait IS the mixer), not msg_wait_dismiss
  return (p>=SYM.msg_wait_dismiss and p<SYM.fb_stablekeys) or stack_has(SYM.msg_wait_dismiss,SYM.fb_stablekeys)
    or (p>=SYM.tape_win_chatter and p<SYM.tw_base) or stack_has(SYM.tape_win_chatter,SYM.tw_base)
end
local function u16(a) return mem:read_u8(a)*256+mem:read_u8(a+1) end
local HOLD_S=tonumber(os.getenv("WIN_HOLD_S") or "3")
local mix_n,mix_t0,mix_t1,mix_wraps,last_sptr,pages_checked=0,nil,nil,0,nil,false
local function now() return manager.machine.time:as_double() end
local function track_mixer()
  -- returns true while the win mixer is the thing running
  local base=u16(SYM.tw_base)
  local p=pc()
  if base==0 or not (p>=base and p<base+SYM.WIN_MIX3_RAW) then return false end
  if H.overlay_loaded() then return false end    -- T0241: the floppy build's demo overlay REPLACES the blob at the same addresses
  mix_n=mix_n+1
  if not mix_t0 then mix_t0=now() end
  mix_t1=now()
  local dpp=mem:read_u8(SYM.tw_dp)
  local sp_=u16(dpp*256+0x0F)             -- mixer's stream pointer (sptr)
  if last_sptr and sp_<last_sptr-100 then mix_wraps=mix_wraps+1 end
  last_sptr=sp_
  if not pages_checked and mix_n>=40 then
    pages_checked=true
    local live=(r("cur_buf")==0) and 0x4000 or 0x6000
    local hid=(live==0x4000) and 0x6000 or 0x4000
    if base~=hid+1536 then fail(string.format("blob unpacked at $%04x but the hidden buffer + 1536 is $%04x (cur_buf=%d)",base,hid+1536,r("cur_buf"))) end
    local same=0
    for i=0,255 do if mem:read_u8(live+i+1536)==mem:read_u8(hid+i+1536) then same=same+1 end end
    if same==256 then fail("visible page identical to the blob buffer") end
    local d=os.getenv("WIN_DUMP")
    if d then
      for _,pg in ipairs({{"live",live},{"hidden",hid}}) do
        local fh=io.open(d.."/win_"..pg[1]..".raw","wb")
        for i=0,6143 do fh:write(string.char(mem:read_u8(pg[2]+i))) end
        fh:close()
      end
    end
    table.insert(log,string.format("mixer running in $%04x (hidden buffer; live=$%04x), DP page $%02x",base,live,dpp))
  end
  return true
end
local function in_audio() local p=pc() return p>=SYM.play_tone and p<SYM.play_chirp end
local function in_title_wait()
  -- T0236: MIX3_BUF ONLY -- unlike tape_actor_reset.lua/gameover_tape.lua
  -- (which only ever check this AFTER a death box has already fully
  -- resolved, so play_tone..play_chirp is a safe title-music proxy
  -- there), THIS harness polls in_title_wait() continuously while
  -- message boxes (and their own play_boxopen sfx, same PC range) are
  -- still coming and going -- the play_tone..play_chirp fallback gave a
  -- false positive on the very first box's own sound effect. MIX3_BUF
  -- is the title tune's self-modifying mix buffer (T0089) -- PC only
  -- ever lands there while the title tune is actually playing.
  local p=pc()
  return SYM.MIX3_BUF and p>=SYM.MIX3_BUF and p<SYM.MIX3_BUF+3072
end

local f,loaded,stage,t=0,false,"boot",0
local boot_live,busyn1=0,0
local dismissals,was_msgwait,poked=0,false,false
local mix_done=false
local ng_live=0
local nag_checked=false
fail=function(msg) print("TAPEDAISY FAIL: "..msg); stage="done"; manager.machine:exit() end

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
      mem:write_u8(SYM.coins,5)
      -- T0228: daisy1 starts hidden (room 255); place her in room 73 for this ending-only harness
      local hid_n=0
      for i=0,SYM.ACTOR_COUNT_tape-1 do local b=SYM.actor_init_tape+i*8
        if mem:read_u8(b+1)==19 then
          if mem:read_u8(b)~=255 then fail("daisy1 does not start hidden (room "..mem:read_u8(b)..")") return end
          mem:write_u8(b,73); hid_n=hid_n+1 end end
      if hid_n~=1 then fail("expected exactly one daisy1 record, found "..hid_n) return end
      table.insert(log,"daisy1 starts hidden (room 255); placed in 73 by poke")
      stage="warp1"; t=f
    end
    return
  end

  if stage=="warp1" then
    mem:write_u8(SYM.respawn_room,73); mem:write_u8(SYM.respawn_x,64)
    mem:write_u8(SYM.respawn_y,96); mem:write_u8(SYM.killed,1)
    stage="arrive1"; t=f
    return
  end

  if stage~="boot" and r("lives")<2 and stage~="title" and stage~="press" then
    mem:write_u8(SYM.lives,2)
  end

  if stage=="arrive1" then
    -- T0236: daisy1here's box overlaps the respawn point immediately
    -- (by design -- see this harness's own header), so the busy/dismiss
    -- loop that rides out the respawn-death box below is the SAME loop
    -- that starts riding out the (possibly already-firing) nag -- no
    -- separate "stand and wait to settle" step, since the message never
    -- fully clears while still in contact.
    if in_msgwait() or in_audio() then busyn1=busyn1+1; key("SPACE",(busyn1//14)%2==0)
    else key("SPACE",false) end
    if r("cur_room")==73 and r("dizzy_x")==64 and r("killed")==0 then
      stage="dismiss_loop"; t=f
    end
    if f-t>1500 then fail(string.format("never arrived beside daisy1here (room=%d x=%d y=%d killed=%d)",
      r("cur_room"),r("dizzy_x"),r("dizzy_y"),r("killed"))) end

  elseif stage=="dismiss_loop" then
    local mw=in_msgwait()
    local inmix=track_mixer()
    if inmix and mon.cur and not mon.cur.finished then demo_mix_viol=demo_mix_viol+1 end
    local t_in=mix_t0 and (mix_t1-mix_t0) or 0
    if r("completedgame")==1 and mix_t0 and t_in<HOLD_S and not mix_done then
      key("SPACE",false)       -- let the first win box's tune play undisturbed
    elseif mw or in_audio() then
      busyn1=busyn1+1; key("SPACE",(busyn1//14)%2==0)
    else
      key("SPACE",false)
    end
    if was_msgwait and not mw then
      dismissals=dismissals+1
    end
    was_msgwait=mw

    if not nag_checked and dismissals>=4 then
      -- one full notgotallcoins run (4 boxes) has gone by -- coins is
      -- still 5, this must be the nag, not the win.
      if r("completedgame")~=0 then fail("completedgame set during the <30-coin nag") end
      if in_title_wait() then fail("title reached during the <30-coin nag (should just nag)") end
      table.insert(log,string.format("after %d box dismissal(s): completedgame=0, no title -- nag confirmed",dismissals))
      nag_checked=true
    end

    if nag_checked and not poked and dismissals>=6 then
      -- let at least one more retrigger's worth of nag boxes clear
      -- before switching the condition, so we're not poking mid-run.
      mem:write_u8(SYM.coins,30)
      poked=true
      table.insert(log,"coins poked to 30")
    end

    if poked and in_title_wait() then
      table.insert(log,string.format("title reached after coins=30 (total dismissals=%d)",dismissals))
      stage="verify_win"; t=f
    end

    if f-t>5000 then fail(string.format("never reached the title after coins=30 (dismissals=%d nag_checked=%s poked=%s)",
      dismissals, tostring(nag_checked), tostring(poked))) end

  elseif stage=="verify_win" then
    if f-t==20 then
      local cg=r("completedgame")
      if cg~=1 then
        fail("completedgame not 1 after the win ("..cg..") at f="..f)
        return
      end
      table.insert(log,"completedgame=1 at the title -- correct")
      local d=os.getenv("WIN_DUMP")
      if d then   -- the title replay's visible page (both buffers hold it)
        local fh=io.open(d.."/win_title.raw","wb")
        for i=0,6143 do fh:write(string.char(mem:read_u8(0x4000+i))) end
        fh:close()
      end
      if (mix_t1 or 0)-(mix_t0 or 0)<HOLD_S then
        fail(string.format("win mixer ran %.2fs of emu time under the first box, wanted >= %.1fs",(mix_t1 or 0)-(mix_t0 or 0),HOLD_S)) return
      end
      if mix_n<40 then fail("win mixer PC samples: "..mix_n) return end
      if HOLD_S>=27 and mix_wraps<1 then fail("tune did not loop (sptr never wrapped) in "..HOLD_S.."s") return end
      table.insert(log,string.format("win mixer: %d PC samples inside the blob, first run %.2fs emu, sptr wraps=%d",mix_n,mix_t1-mix_t0,mix_wraps))
      local tf=os.getenv("WIN_TIMES")
      if tf then local fh=io.open(tf,"w"); fh:write(string.format("%.4f %.4f\n",mix_t0,mix_t0+HOLD_S)); fh:close() end
      -- T0228: the heart demo of the win sequence
      local d=mon.demos[1]
      if not d then fail("the win sequence ran no heart demo") return end
      if not d.finished or d.n~=255 then fail("heart demo did not run 255 updates (n="..d.n..")") return end
      if not (d.age_ok and d.path_ok) then fail("heart ages/paths differ from the original's: "..(mon.errors[1] or "?")) return end
      if d.bad~=0 then fail(string.format("heart pixels differ from the reference render in %d bytes (worst update %d): %s",d.bad,d.badmax,mon.errors[1] or "?")) return end
      if d.drawn_max<10 then fail("hardly any hearts drawn (max "..d.drawn_max..")") return end
      if demo_mix_viol~=0 then fail("the mixer ran during the (silent) heart demo: "..demo_mix_viol.." samples") return end
      if #mon.demos~=1 then fail("expected one heart demo, saw "..#mon.demos) return end
      table.insert(log,string.format("heart demo after the last box: 255 updates, pixel diff 0, max %d hearts drawn, silent, %.1f s emu, hd_dir=$%02x",d.drawn_max,d.t1-d.t0,d.dir))
      stage="newgame"; t=f; ng_live=0
    end

  elseif stage=="newgame" then
    -- T0221: SPACE leaves the title replay (the mixer returns on it) and a
    -- new game starts cleanly: completedgame reset, room 36, Dizzy placed,
    -- DP back to 0, coins reset, stack sane (gameover_tape's idiom).
    key("SPACE",(f-t)<30)
    if not in_title_wait() and r("completedgame")==0 and r("cur_room")==36 and r("dizzy_y")~=0 then
      ng_live=ng_live+1 else ng_live=0 end
    if ng_live>=60 then
      local dp=cpu.state["DP"].value
      if dp~=0 then fail("DP="..dp.." after the new game started") return end
      if r("coins")~=0 then fail("coins="..r("coins").." after the new game started") return end
      local sp=cpu.state["S"].value
      if sp<0x80 or sp>0x100 then fail(string.format("S=$%04x implausible",sp)) return end
      table.insert(log,string.format("new game after the win: completedgame=0 room=36 coins=0 DP=0 S=$%04x",sp))
      print("TAPEDAISY PASS (f="..f.."): "..table.concat(log," | "))
      stage="done"; manager.machine:exit()
    end
    if f-t>1500 then fail("new game did not start after the win title (completedgame="..r("completedgame").." room="..r("cur_room")..")") end
  end
end)
