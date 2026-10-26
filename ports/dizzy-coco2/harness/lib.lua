-- harness/lib.lua -- code shared by the MAME harnesses (dofile("harness/lib.lua"), cwd = the port root,
-- as with harness/orig.lua and harness/heartref.lua).
--
--   local HLIB = dofile("harness/lib.lua")
--   local function load_decb(path) return HLIB.load_decb(path, mem) end   -- mem: the maincpu space
local M = {}

-- load_decb(path, mem): write a DECB .bin into `mem` and return its exec address (nil if malformed).
-- The $FFDF idiom: the first block at >= $8000 flips the SAM to all-RAM mode ONCE, so the rest of
-- the image (code above $8000) lands in RAM, not in the BASIC ROMs.
function M.load_decb(path, mem)
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

return M
