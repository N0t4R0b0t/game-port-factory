-- T0089 follow-up: measure INPUT LATENCY -- keypress to the game acting
-- on it -- in 60Hz video frames. A playtest reported "sound effects seem
-- delayed"; the sounds turned out to be fine, and this is what was
-- actually being heard. The new audio simply made the pre-existing lag
-- audible for the first time, because a sharp transient pins down the
-- exact moment the game notices a key far better than Dizzy starting to
-- move does.
--
-- Method: press UP only when Dizzy is grounded and idle, then wait for
-- dizzy_dy to go negative -- the instant the jump is processed, which is
-- also exactly where play_jump fires. Repeats until it has 14 samples
-- and reports the spread, because the interesting number is the RANGE:
-- a press lands uniformly anywhere inside a mainloop pass, so latency
-- varies by a whole pass depending on when it arrives.
--
-- Usage:
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -seconds_to_run 90 \
--     -autoboot_script harness/inputlag.lua
--
-- NOTE the long -seconds_to_run: it has to land 14 separate jumps, each
-- needing Dizzy back on the ground first. Do not trim it to match a
-- shorter test; with too few seconds it silently reports nothing.
-- Measure keypress -> game-acts latency, in 60Hz video frames.
-- Presses UP only when Dizzy is grounded and idle, then waits for
-- dizzy_dy to go negative (the jump being processed, which is also
-- exactly where play_jump fires).
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
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end
local f,loaded,state,press_f,results,started=0,false,"wait",0,{},false
local function s8(v) return v>127 and v-256 or v end
emu.register_periodic(function()
  f=f+1

  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded then return end
  -- keep dismissing the title until the game is actually running
  if not started then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if mem:read_u8(SYM.cur_room)==36 and mem:read_u8(SYM.dizzy_y)~=0 then
      started=true; key("SPACE",false)
    end
    return
  end
  if mem:read_u8(SYM.cur_room)~=36 then return end
  local dy=s8(mem:read_u8(SYM.dizzy_dy)); local floor=mem:read_u8(SYM.dizzy_floor)
  if state=="wait" then
    if floor==1 and dy==0 then key("UP",true); press_f=f; state="pressed" end
  elseif state=="pressed" then
    if dy<0 then
      results[#results+1]=f-press_f
      key("UP",false); state="airborne"
    elseif f-press_f>40 then key("UP",false); state="airborne" end
  elseif state=="airborne" then
    if floor==1 and dy==0 and f-press_f>25 then state="wait" end
  end
  if #results>=14 then
    table.sort(results)
    local sum=0 ; for _,v in ipairs(results) do sum=sum+v end
    io.write("LATENCY samples(frames): ")
    for _,v in ipairs(results) do io.write(v.." ") end
    io.write(string.format("\n  n=%d  min=%d  median=%d  max=%d  mean=%.1f frames"..
      "  => min=%.0fms median=%.0fms max=%.0fms\n", #results, results[1],
      results[#results//2+1], results[#results], sum/#results,
      results[1]*16.7, results[#results//2+1]*16.7, results[#results]*16.7))
    results={} ; state="done"
  end
end)
