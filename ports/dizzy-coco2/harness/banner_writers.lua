-- harness/banner_writers.lua -- T0237 STEP 1: MAME write-taps on
-- framebuffer rows 0-47 of BOTH buffers ($4000-$45FF, $6000-$65FF),
-- mapping every writer PC to its enclosing symbol (target/room36_tape.map),
-- driven through a real scenario: boot/title, gameplay redraws, several
-- room transitions (warp, which is what force_redraw's own 255-sentinel
-- full-buffer-invalidate path also sees on a real room change), a
-- death, game over -> title -> new game.
--
-- Also dumps rows 0-47 of both buffers to CKPT_DIR/<name>.raw at each
-- named checkpoint (T0237 STEP 3 reuses this for the before/after diff).
--
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--   CKPT_DIR=/tmp/ckpt_before \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 180 \
--     -autoboot_script harness/banner_writers.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
local SYM={} ; local SYMLIST={}
for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$")
  if n then local v=tonumber(a,16); SYM[n]=v; SYMLIST[#SYMLIST+1]={n,v} end
end
table.sort(SYMLIST, function(a,b) return a[2]<b[2] end)
local function sym_for(pc)
  local lo,hi=1,#SYMLIST
  if pc<SYMLIST[1][2] then return "<before-map>" end
  while lo<hi do
    local mid=(lo+hi+1)//2
    if SYMLIST[mid][2]<=pc then lo=mid else hi=mid-1 end
  end
  return string.format("%s+%d", SYMLIST[lo][1], pc-SYMLIST[lo][2])
end
local function r(s) return mem:read_u8(SYM[s]) end
local function pc() return cpu.state["PC"].value end
local function stack_has(lo,hi)
  local sp=cpu.state["S"].value
  for i=0,63,1 do if sp+i+1>=0x100 then break end
    local a=mem:read_u8(sp+i)*256+mem:read_u8(sp+i+1)
    if a>=lo and a<hi then return true end
  end
  return false
end
local function in_msgwait()
  local p=pc()
  return (p>=SYM.msg_wait_dismiss and p<SYM.fb_stablekeys) or stack_has(SYM.msg_wait_dismiss,SYM.fb_stablekeys)
end
local function in_title_wait()
  local p=pc()
  return (SYM.MIX3_BUF and p>=SYM.MIX3_BUF and p<SYM.MIX3_BUF+3072)
      or (SYM.play_tone and SYM.play_chirp and p>=SYM.play_tone and p<SYM.play_chirp)
end

-- writers: keyed by "sym|buf" -> {count, rowlo, rowhi}
local writers={}
local tapcount=0
local function note_write(bufname,base,addr)
  tapcount=tapcount+1
  local ok,s=pcall(sym_for,pc())
  if not ok then s="<error:"..tostring(s)..">" end
  local row=(addr-base)//32
  local key2=s.."|"..bufname
  local w=writers[key2]
  if not w then w={count=0,rowlo=999,rowhi=-1}; writers[key2]=w end
  w.count=w.count+1
  if row<w.rowlo then w.rowlo=row end
  if row>w.rowhi then w.rowhi=row end
end
-- T0237: taps must be installed AFTER load_decb's own $FFDF all-RAM
-- switch, not before -- SAM remapping $4000-$7FFF to a different
-- underlying view detaches a tap installed on the pre-switch view.
-- Confirmed empirically: installed early, only the load's OWN direct
-- pokes into the fb A/B staging blocks (3072 writes, one PC) were ever
-- seen; nothing from real CPU execution afterward.
local tapA,tapB
local function install_taps()
  if tapA then tapA:remove() end
  if tapB then tapB:remove() end
  tapA=mem:install_write_tap(0x4000,0x45FF,"bannerA",function(offset,data,mask) note_write("A",0x4000,offset) end)
  tapB=mem:install_write_tap(0x6000,0x65FF,"bannerB",function(offset,data,mask) note_write("B",0x6000,offset) end)
end

local CKPT_DIR=os.getenv("CKPT_DIR")
local function checkpoint(name)
  if not CKPT_DIR then return end
  local fh=io.open(CKPT_DIR.."/"..name..".raw","wb")
  local buf={}
  for i=0,1535 do buf[#buf+1]=string.char(mem:read_u8(0x4000+i)) end
  for i=0,1535 do buf[#buf+1]=string.char(mem:read_u8(0x6000+i)) end
  fh:write(table.concat(buf)); fh:close()
  print("BANNER_WRITERS checkpoint "..name.." saved")
end

local function gate()
  for i=0,19 do local b=SYM.actor_ram+i*8
    if mem:read_u8(b+1)==0 and mem:read_u8(b+4)==120 then return b end end
end
local function force_death()
  mem:write_u8(SYM.coins,5)
  mem:write_u8(SYM.inv,1)
  mem:write_u8(SYM.dragon_asleep,1)
  mem:write_u8(SYM.troll_bribed,1)
  local g=gate(); if g then mem:write_u8(g+5,254); mem:write_u8(g+6,2) end
  mem:write_u8(SYM.lives,0)
  mem:write_u8(SYM.killed,1)
end
local function warp(room,x,y)
  mem:write_u8(SYM.respawn_room,room)
  mem:write_u8(SYM.respawn_x,x)
  mem:write_u8(SYM.respawn_y,y)
  mem:write_u8(SYM.killed,1)
end

local f,loaded,stage,t=0,false,"boot",0
local stage_n,stage_n2
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded then return end
  install_taps()

  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    local live=(r("cur_room")==36 and r("dizzy_y")~=0)
    stage_n = live and (stage_n or 0)+1 or 0
    if stage_n and stage_n>=30 then
      key("SPACE",false)
      checkpoint("post_title_new_game")
      stage="gameplay"; t=f
    end
  elseif stage=="gameplay" then
    if f-t==300 then
      checkpoint("gameplay_room36")
      stage="warp1"; t=f
      warp(63,104,150)
    end
  elseif stage=="warp1" then
    if f-t==300 then
      checkpoint("after_warp_room63")
      stage="warp2"; t=f
      warp(88,64,96)
    end
  elseif stage=="warp2" then
    if f-t==300 then
      checkpoint("after_warp_room88")
      stage="warp3"; t=f
      warp(73,64,96)
    end
  elseif stage=="warp3" then
    if f-t==300 then
      checkpoint("after_warp_room73")
      stage="dying"; t=f
      force_death()
    end
  elseif stage=="dying" then
    if not box1 then
      key("SPACE",false)
      if in_msgwait() then box1=true; press_at=f; checkpoint("death_box") end
      if f-t>600 then print("BANNER_WRITERS FAIL: no death box"); manager.machine:exit() end
    elseif f-press_at<8 then key("SPACE",true)
    elseif f-press_at<24 then key("SPACE",false)
    else
      if in_title_wait() then
        checkpoint("gameover_title")
        stage="title"; t=f
      elseif f-press_at>400 then
        print("BANNER_WRITERS FAIL: title never reached after death box")
        manager.machine:exit()
      end
    end
  elseif stage=="title" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    local live=(r("cur_room")==36 and r("dizzy_y")~=0)
    stage_n2=live and (stage_n2 or 0)+1 or 0
    if stage_n2 and stage_n2>=30 then
      key("SPACE",false)
      checkpoint("post_gameover_new_game")
      stage="done"
    end
    if f-t>500 then print("BANNER_WRITERS FAIL: new game never reached after title"); manager.machine:exit() end
  elseif stage=="done" then
    print("BANNER_WRITERS WRITERS_BEGIN")
    local keys={} for k in pairs(writers) do keys[#keys+1]=k end
    table.sort(keys)
    for _,k in ipairs(keys) do
      local w=writers[k]
      print(string.format("  %-40s count=%-8d rows=%d..%d", k, w.count, w.rowlo, w.rowhi))
    end
    print("BANNER_WRITERS WRITERS_END")
    print("BANNER_WRITERS tapcount="..tapcount)
    print("BANNER_WRITERS DONE")
    manager.machine:exit()
  end
end)
