-- harness/heartref.lua -- T0228: an INDEPENDENT reference of the original's heart demo
-- (X-ALL.TXT theheartdemo/heartdemo/updatehearts/printheart/getvalue/getsincos/multiply
-- 3517-3720 and `random` 5128), used by tape_daisy94.lua and tape_daisy_ending.lua to
-- check the port's hearts against the original's arithmetic, pixel for pixel.
--
-- Nothing here reads the port's code: the 64-entry sincostable, the 8-bit wraps, the
-- window clip (x units 34..93, y 48..183), the XOR plot and the three heart bitmaps
-- (FRAMES.DAT frames 29/30/31, extracted/frmtable.json) are written out again from the
-- original source.  The port's 17-entry folded sine table, its nibble-shift blit and its
-- direct-page variables are therefore all under test.
--
-- How the check works (monitor): a MAME write tap on the last heart's age byte
-- (table entry 31, in the HIDDEN framebuffer at +$17C0).  Each updatehearts run writes it
-- once, AFTER hearts 0..30 have been erased/aged/redrawn and with heart 31 erased and not
-- yet redrawn.  So at every tap  live page = base XOR hearts(0..30)  and the XOR of two
-- consecutive snapshots must equal  render(table_n) XOR render(table_n-1)  exactly --
-- with no knowledge of the room-3 picture underneath.  Also asserted per tap: ages
-- (8*i + 4*n), the random path bytes (`random` replayed from the seed), the add/sub
-- direction flip per demo.
local M={}

-- sincostable, X-ALL.TXT 3703-3706 (64 entries; "-0" is 0)
M.SIN={ 0,6,12,18,24,30,35,40,45,49,53,56,59,61,62,63,
        64,63,62,61,59,56,53,49,45,40,35,30,24,18,12,6,
        0,-6,-12,-18,-24,-30,-35,-40,-45,-49,-53,-56,-59,-61,-62,-63,
        -64,-63,-62,-61,-59,-56,-53,-49,-45,-40,-35,-30,-24,-18,-12,-6 }
-- frames 29/30/31 (extracted/frmtable.json): 16 px wide, rows as 16-bit words
M.HEART={
  [1]={0x0360,0x07f0,0x07f0,0x03e0,0x03e0,0x01c0},
  [2]={0x0e38,0x1f7c,0x1ffc,0x1ffc,0x1ffc,0x0ff8,0x0ff8,0x07f0,0x03e0,0x01c0},
  [3]={0x1e3c,0x3f7e,0x7fff,0x7fff,0x7fff,0x3ffe,0x3ffe,0x3ffe,0x1ffc,0x1ffc,0x0ff8,0x07f0,0x03e0,0x01c0},
}

-- getvalue: A = phase 0..127, age -> the Z80's A (a byte, two's complement)
function M.getvalue(phase,age)
  local s=M.SIN[(phase>>1)+1]
  local neg=false
  if s<0 then s=-s; neg=true end
  local h=(age*s)>>8                 -- `multiply` (8x8 -> 16), `ld a,h`
  if neg then h=(-h)&255 end
  return h&255
end

-- printheart's geometry: returns size (0 = not drawn), x (frmx), y (frmy)
function M.place(age,path,dir)
  local size=(age>>5)&3
  if size==0 then return 0 end
  local ph=((dir~=0) and (path+age) or (path-age))&127     -- add/sub patch, `and 127`
  local x=(M.getvalue(ph,age)+62)&255
  local v=M.getvalue((ph+32)&127,age)
  local y=(v*3+110)&255                                    -- add a,a / add a,c / add a,110
  return size,x,y
end

-- XOR-render hearts 0..nmax-1 of `tab` (tab[2i]=age, tab[2i+1]=path) into page (0..6143)
function M.render(tab,dir,nmax)
  local page={}
  for i=0,6143 do page[i]=0 end
  local drawn=0
  for i=0,nmax-1 do
    local size,x,y=M.place(tab[2*i],tab[2*i+1],dir)
    if size>0 and y<184 then
      drawn=drawn+1
      local rows=M.HEART[size]
      for r=0,#rows-1 do
        local yy=y+r
        if yy>=48 and yy<184 then
          for c=0,15 do
            if (rows[r+1]>>(15-c))&1==1 then
              local unit=x+(c>>2)
              if unit>=34 and unit<94 then            -- the window, `frame`'s clip
                local px=4*(unit-32)+(c&3)
                local idx=yy*32+(px>>3)
                page[idx]=page[idx]~(1<<(7-(px&7)))
              end
            end
          end
        end
      end
    end
  end
  return page,drawn
end

-- `random` (X-ALL.TXT 5128), flag-exact; seed = {s0,s1,s2} is advanced in place
function M.random(seed)
  local a=(seed[1]-1)&255          -- dec a
  a=a~seed[2]                      -- xor (ix+1): carry := 0
  local c=(a>>7)&1; a=(a<<1)&255   -- rla (carry-in 0)
  local s2=seed[3]
  local c2=s2&1; seed[3]=(s2>>1)|(c<<7); c=c2   -- rr (ix+2)
  seed[1]=a                        -- ld (ix+0),a
  a=(~a)&255                       -- cpl
  local c3=(a>>7)&1; a=((a<<1)&255)|c; c=c3     -- rla
  a=a~48                           -- xor 48
  a=a~seed[2]                      -- xor (ix+1)
  seed[2]=a                        -- ld (ix+1),a
  return a~seed[3]                 -- xor (ix+2)
end

-- text check: do the glyphs of `str` sit in page `fb` at x unit `xu` (4 px units), pixel row y?
-- GLYPH = {[ascii]={8 row bytes}} from target/font_data.asm
function M.load_glyphs(path)
  local G={}
  for line in io.lines(path) do
    local n,rest=line:match("^glyph_(%d+)%s+fcb%s+(.*)$")
    if n then local t={} for h in rest:gmatch("%$(%x%x)") do t[#t+1]=tonumber(h,16) end G[tonumber(n)]=t end
  end
  return G
end
function M.text_at(G,fb,str,xu,y)
  local bad=0
  for i=1,#str do
    local g=G[str:byte(i)]
    for rr=0,7 do
      for b=0,7 do
        local px=xu*4+(i-1)*8+b
        local want=(g[rr+1]>>(7-b))&1
        local have=(fb[(y+rr)*32+(px>>3)]>>(7-(px&7)))&1
        if want~=have then bad=bad+1 end
      end
    end
  end
  return bad
end

-- T0241: where the heart demo's CODE is.  Tape build: [tape_heart_demo, hd_sin) in the resident map.  FLOPPY build
-- (env FLOPPY_OVL_DIR=target/floppy): the demo is an overlay loaded into the hidden framebuffer, one blob per buffer
-- (heart_A.map / heart_B.map written by tools/floppy_pack.sh) -> two ranges.
M.ovl_ranges=nil
-- The overlay sits where the completion tune's blob sits (hidden buffer + 1536), so a PC range alone cannot tell
-- "the demo" from "the tune": a range only counts while the overlay's own first bytes are in memory there.
function M.load_overlay_ranges(dir,mem)
  M.ovl_ranges={}
  M.ovl_mem=mem
  for _,v in ipairs({"A","B"}) do
    local s={}
    for line in io.lines(dir.."/heart_"..v..".map") do local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then s[n]=tonumber(a,16) end end
    local fh=io.open(dir.."/heart_"..v..".bin","rb"); local bin=fh:read("*all"); fh:close()
    M.ovl_ranges[#M.ovl_ranges+1]={s.tape_heart_demo,s.hd_sin,v,s,bin:sub(1,24)}
  end
  return M.ovl_ranges
end
-- true while the demo overlay (not the tune's blob) is what sits at the hidden buffer + 1536
function M.overlay_loaded()
  if not M.ovl_ranges then return false end
  for _,r in ipairs(M.ovl_ranges) do
    local same=true
    for i=1,#r[5] do if M.ovl_mem:read_u8(r[1]+i-1)~=r[5]:byte(i) then same=false; break end end
    if same then return true end
  end
  return false
end
function M.in_hearts(p,SYM)
  if M.ovl_ranges then
    for _,r in ipairs(M.ovl_ranges) do
      if p>=r[1] and p<r[2] then
        local same=true
        for i=1,#r[5] do if M.ovl_mem:read_u8(r[1]+i-1)~=r[5]:byte(i) then same=false; break end end
        if same then return true end
      end
    end
    return false
  end
  return p>=SYM.tape_heart_demo and p<SYM.hd_sin
end

-- monitor: installs the taps and the per-update checks.
--   env = {mem=, cpu=, SYM=, dumpdir=optional, dump_at={[n]="name"...}, log=function(msg)}
-- m.demos = list of finished/running demos {n=updates seen, bad=pixel-diff bytes, ...}
function M.monitor(env)
  local mem,cpu,SYM=env.mem,env.cpu,env.SYM
  local m={seed={0x59,0xA3,0x13}, demos={}, cur=nil, errors={}, taps={}}
  local function in_code()
    return M.in_hearts(cpu.state["PC"].value, SYM)
  end
  local function err(s) if #m.errors<12 then m.errors[#m.errors+1]=s end end
  local function snapshot(live)
    local t={} for i=0,6143 do t[i]=mem:read_u8(live+i) end return t
  end
  local function on_tap(base)
    if not in_code() then return end
    local live=(base==0x4000) and 0x6000 or 0x4000
    local tab={}
    for i=0,63 do tab[i]=mem:read_u8(base+0x17C0+i) end
    local dir=mem:read_u8(SYM.hd_dir)
    local snap=snapshot(live)
    local cur=m.cur
    if not cur or cur.finished then
      cur={n=0,bad=0,badmax=0,dir=dir,t0=manager.machine.time:as_double(),paths={},finished=false,drawn_total=0,drawn_max=0,age_ok=true,path_ok=true}
      m.cur=cur; m.demos[#m.demos+1]=cur
      -- reset tap: hearts 0..30 have their first age/path/draw; replay `random` for them
      for i=0,31 do cur.paths[i]=M.random(m.seed) end
      local prev=m.demos[#m.demos-1]
      cur.dir_flipped=(prev==nil) or ((prev.dir~=0)~=(dir~=0))
      if prev==nil and dir==0 then err("first demo: hd_dir is still 0 (the first resethearts must flip it to add)") end
    else
      cur.n=cur.n+1
    end
    for i=0,30 do
      local age_want=(8*i+4*cur.n)&255
      if tab[2*i]~=age_want then cur.age_ok=false; err(string.format("demo %d n=%d heart %d age %d want %d",#m.demos,cur.n,i,tab[2*i],age_want)) end
      if tab[2*i+1]~=cur.paths[i] then cur.path_ok=false; err(string.format("demo %d n=%d heart %d path %d want %d",#m.demos,cur.n,i,tab[2*i+1],cur.paths[i])) end
    end
    if cur.n>=1 and tab[63]~=cur.paths[31] then cur.path_ok=false; err(string.format("heart 31 path %d want %d",tab[63],cur.paths[31])) end
    local ref,drawn=M.render(tab,dir,31)
    cur.drawn_total=cur.drawn_total+drawn
    if drawn>cur.drawn_max then cur.drawn_max=drawn end
    if cur.prev_snap then
      local bad=0
      for i=0,6143 do
        if (snap[i]~cur.prev_snap[i])~=(ref[i]~cur.prev_ref[i]) then
          bad=bad+1
          if bad==1 then err(string.format("demo %d n=%d first pixel-diff byte at row %d col %d: live^prev=%02x ref^prev=%02x",#m.demos,cur.n,i//32,i%32,snap[i]~cur.prev_snap[i],ref[i]~cur.prev_ref[i])) end
        end
      end
      cur.bad=cur.bad+bad; if bad>cur.badmax then cur.badmax=bad end
    end
    cur.prev_snap=snap; cur.prev_ref=ref
    local name=env.dump_at and env.dump_at[cur.n]
    if name and env.dumpdir then
      local fh=io.open(string.format("%s/%s_demo%d.raw",env.dumpdir,name,#m.demos),"wb")
      for i=0,6143 do fh:write(string.char(snap[i])) end fh:close()
    end
    if cur.n==255 then cur.finished=true; cur.t1=manager.machine.time:as_double(); cur.prev_snap=nil; cur.prev_ref=nil end
  end
  for _,base in ipairs({0x4000,0x6000}) do
    local a=base+0x17FE      -- table entry 31's age byte
    m.taps[#m.taps+1]=mem:install_write_tap(a,a,"heart"..base,function() on_tap(base) end)
  end
  return m
end

return M
