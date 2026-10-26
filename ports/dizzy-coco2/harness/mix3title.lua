-- TITLE_MIX3=1 builds: prove the in-game 3-voice title (target/title_mix3.asm)
-- runs, loops at the measured tempo, exits on SPACE and hands a sane machine
-- back to the game.
--
-- Checks, in order:
--   1. the CPU reaches the mixer blob (PC inside MIX3_BUF..+BLOB) and
--      stays there with no key held;
--   2. the stream pointer (sptr, DP page MIX3_DP offset $0F) wraps back to
--      the stream start at least once -- the loop time is printed, and should
--      be ~20.4s (harness/mixer3.asm header: 20.41s measured standalone);
--   3. SPACE leaves the blob, DP is 0 again, and the game reaches room 36
--      with Dizzy placed.
-- Run with -wavwrite to keep the audio for listening.
--
-- Usage:
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -seconds_to_run 60 \
--     -wavwrite /tmp/mix3_ingame.wav -autoboot_script harness/mix3title.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end
-- T0114: the blob runs from MIX3_BUF (it used to run from TITLE_RAW_BUF,
-- which now has to keep the title image for game over)
local RAW=SYM.MIX3_BUF or SYM.TITLE_RAW_BUF or (SYM.IMAGE_END+4096)
local DPPAGE=SYM.MIX3_DP or ((RAW+0x1000)//256)
local BLOB=tonumber(os.getenv("MIX3_BLOB_LEN") or "4096")
local VARS=DPPAGE*256
local function now() return manager.machine.time:as_double() end
local function in_blob(pc) return pc>=RAW and pc<RAW+BLOB end

local f,loaded,state=0,false,"to_blob"
local blob_t, sstart, last_ptr, wraps, wrap_t = nil, nil, nil, 0, {}
local fails={}
local function fail(m) table.insert(fails,m) end
local deadline

emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true; deadline=now()+15 end
  if not loaded or state=="done" then return end
  local pc=cpu.state["PC"].value

  if state=="to_blob" then
    if in_blob(pc) then
      blob_t=now(); state="listen"
      print(string.format("mix3: in the blob at %.2fs (PC $%04x, vars page $%02x)", blob_t, pc, DPPAGE))
    elseif now()>deadline then fail("never reached the mixer blob"); state="finish" end

  elseif state=="listen" then
    if not in_blob(pc) then fail(string.format("left the blob with no key held (PC $%04x)", pc)); state="finish"; return end
    local p=mem:read_u16(VARS+0x0f)
    if not sstart then sstart=mem:read_u16(VARS+0x15) end
    if last_ptr and p<last_ptr then
      wraps=wraps+1; table.insert(wrap_t, now())
      print(string.format("mix3: stream wrapped at %.2fs", now()))
    end
    last_ptr=p
    if wraps>=2 or now()-blob_t>45 then
      key("SPACE",true); state="press"; deadline=now()+2
    end

  elseif state=="press" then
    if not in_blob(pc) then
      key("SPACE",false); state="to_game"; deadline=now()+15
      print(string.format("mix3: SPACE left the blob, PC $%04x DP $%02x", pc, cpu.state["DP"].value))
    elseif now()>deadline then fail("SPACE did not exit the mixer within 2s"); state="finish" end

  elseif state=="to_game" then
    if cpu.state["DP"].value~=0 and not in_blob(pc) then fail("DP not restored to 0 after the title"); state="finish"; return end
    if mem:read_u8(SYM.cur_room)==36 and mem:read_u8(SYM.dizzy_y)~=0 then
      print("mix3: game running in room 36"); state="finish"
    elseif now()>deadline then fail("game never started after SPACE"); state="finish" end

  elseif state=="finish" then
    if wraps==0 then fail("stream pointer never wrapped") end
    if #wrap_t>=2 then print(string.format("mix3: loop time %.2fs", wrap_t[2]-wrap_t[1])) end
    if #fails==0 then print("mix3title: PASS") else
      for _,m in ipairs(fails) do print("mix3title: FAIL "..m) end end
    state="done"; manager.machine:exit()
  end
end)
