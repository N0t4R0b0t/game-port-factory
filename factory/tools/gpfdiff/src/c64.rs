//! C64 backend: headless `x64sc` driven over the VICE binary monitor (TCP).
//!
//! Protocol notes live in ports/brickfall-c64/NOTES.md. In short: any command stops
//! the emulator; `0xaa` (exit) resumes it; a checkpoint hit sends 0x11 info, then
//! 0x31 registers, then 0x62 *stopped*. We park the CPU at `gpf_input_ret` (the RTS
//! of read_input), overwrite A with the scripted buttons, verify the write, resume.

use crate::state::{RawState, BRICKS_LEN, STATE_LEN};
use crate::target::Target;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const STX: u8 = 0x02;
const API: u8 = 0x02;
const EVENT_ID: u32 = 0xffff_ffff;

const CMD_MEM_GET: u8 = 0x01;
const CMD_CHECKPOINT_SET: u8 = 0x12;
const CMD_REGS_GET: u8 = 0x31;
const CMD_REGS_SET: u8 = 0x32;
const CMD_PING: u8 = 0x81;
const CMD_REGS_AVAIL: u8 = 0x83;
const CMD_EXIT: u8 = 0xaa;
const CMD_QUIT: u8 = 0xbb;
const CMD_AUTOSTART: u8 = 0xdd;
const CMD_DISPLAY_GET: u8 = 0x84;
const CMD_PALETTE_GET: u8 = 0x91;

const EV_STOPPED: u8 = 0x62;
const EV_RESUMED: u8 = 0x63;

/// Parse an acme `--vicelabels` file: lines `al C:c000 .gpf_state`.
pub fn parse_labels(text: &str) -> HashMap<String, u16> {
    let mut m = HashMap::new();
    for l in text.lines() {
        let t: Vec<&str> = l.split_whitespace().collect();
        if t.len() == 3 && t[0] == "al" {
            let addr = t[1].rsplit(':').next().unwrap();
            if let Ok(a) = u16::from_str_radix(addr, 16) {
                m.insert(t[2].trim_start_matches('.').to_string(), a);
            }
        }
    }
    m
}

#[derive(Clone, Debug)]
pub struct C64Config {
    pub x64sc: String,
    pub prg: String,
    pub labels: String,
    /// "auto" | "always" | "never": wrap x64sc in xvfb-run so no window appears.
    pub xvfb: String,
    /// Per-wait timeout (boot, and each step's checkpoint hit).
    pub timeout: Duration,
    pub debug: bool,
    /// Run at warp speed (default for traces). Screenshots want real time: warp skips frames.
    pub warp: bool,
}

struct Frame {
    rtype: u8,
    err: u8,
    id: u32,
    body: Vec<u8>,
}

pub struct C64Target {
    cfg: C64Config,
    gpf_state: u16,
    gpf_bricks: u16,
    input_ret: u16,
    labels: HashMap<String, u16>,
    child: Option<Child>,
    conn: Option<TcpStream>,
    buf: Vec<u8>,
    next_id: u32,
    stopped: bool,
    resumed: u32,
    stop_pc: u16,
    reg_a: u8,
    reg_pc: u8,
}

fn which(prog: &str) -> bool {
    std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| d.join(prog).is_file()))
        .unwrap_or(false)
}

impl C64Target {
    pub fn new(cfg: C64Config) -> Result<C64Target, String> {
        let text = std::fs::read_to_string(&cfg.labels)
            .map_err(|e| format!("{}: {e}", cfg.labels))?;
        let labels = parse_labels(&text);
        let get = |n: &str| {
            labels
                .get(n)
                .copied()
                .ok_or_else(|| format!("label `{n}` missing from {}", cfg.labels))
        };
        Ok(C64Target {
            gpf_state: get("gpf_state")?,
            gpf_bricks: get("gpf_bricks")?,
            input_ret: get("gpf_input_ret")?,
            labels: labels.clone(),
            cfg,
            child: None,
            conn: None,
            buf: vec![],
            next_id: 1,
            stopped: false,
            resumed: 0,
            stop_pc: 0,
            reg_a: 0,
            reg_pc: 3,
        })
    }

    fn dbg(&self, m: impl FnOnce() -> String) {
        if self.cfg.debug {
            eprintln!("[c64] {}", m());
        }
    }

    // ------------------------------------------------------------ transport
    fn send(&mut self, cmd: u8, body: &[u8]) -> Result<u32, String> {
        let id = self.next_id;
        self.next_id = if self.next_id >= 0xffff_fff0 { 1 } else { self.next_id + 1 };
        let mut m = vec![STX, API];
        m.extend_from_slice(&(body.len() as u32).to_le_bytes());
        m.extend_from_slice(&id.to_le_bytes());
        m.push(cmd);
        m.extend_from_slice(body);
        self.dbg(|| format!("-> cmd {cmd:#04x} id {id} body {body:02x?}"));
        self.conn
            .as_mut()
            .ok_or("not connected")?
            .write_all(&m)
            .map_err(|e| format!("monitor write: {e}"))?;
        Ok(id)
    }

    /// Read one frame, waiting at most until `deadline`.
    fn recv(&mut self, deadline: Instant) -> Result<Frame, String> {
        loop {
            if self.buf.len() >= 12 {
                if self.buf[0] != STX {
                    return Err(format!("monitor stream desync: byte {:#04x}", self.buf[0]));
                }
                let blen = u32::from_le_bytes(self.buf[2..6].try_into().unwrap()) as usize;
                if self.buf.len() >= 12 + blen {
                    let f = Frame {
                        rtype: self.buf[6],
                        err: self.buf[7],
                        id: u32::from_le_bytes(self.buf[8..12].try_into().unwrap()),
                        body: self.buf[12..12 + blen].to_vec(),
                    };
                    self.buf.drain(..12 + blen);
                    self.dbg(|| format!("<- type {:#04x} err {} id {:#x} body {:02x?}", f.rtype, f.err, f.id, &f.body[..f.body.len().min(24)]));
                    return Ok(f);
                }
            }
            let now = Instant::now();
            if now >= deadline {
                return Err("timed out waiting for the emulator".into());
            }
            let conn = self.conn.as_mut().ok_or("not connected")?;
            conn.set_read_timeout(Some((deadline - now).min(Duration::from_millis(500))))
                .map_err(|e| e.to_string())?;
            let mut tmp = [0u8; 4096];
            match conn.read(&mut tmp) {
                Ok(0) => return Err("emulator closed the monitor connection".into()),
                Ok(n) => self.buf.extend_from_slice(&tmp[..n]),
                Err(e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut => {}
                Err(e) => return Err(format!("monitor read: {e}")),
            }
            if let Some(c) = self.child.as_mut() {
                if let Ok(Some(st)) = c.try_wait() {
                    if self.buf.len() < 12 {
                        return Err(format!("x64sc exited ({st}) while waiting"));
                    }
                }
            }
        }
    }

    /// Track stop/resume events carried by a frame.
    fn note_event(&mut self, f: &Frame) {
        if f.id == EVENT_ID {
            match f.rtype {
                EV_STOPPED if f.body.len() >= 2 => {
                    self.stopped = true;
                    self.stop_pc = u16::from_le_bytes([f.body[0], f.body[1]]);
                }
                EV_RESUMED => {
                    self.stopped = false;
                    self.resumed += 1;
                }
                _ => {}
            }
        }
    }

    /// Send a command and return its reply (the frame with the same id), absorbing
    /// any events that arrive first.
    fn request(&mut self, cmd: u8, body: &[u8]) -> Result<Frame, String> {
        let id = self.send(cmd, body)?;
        let deadline = Instant::now() + self.cfg.timeout;
        loop {
            let f = self.recv(deadline)?;
            self.note_event(&f);
            if f.id == id {
                if f.err != 0 {
                    return Err(format!("monitor cmd {cmd:#04x} failed: error {:#04x}", f.err));
                }
                return Ok(f);
            }
        }
    }

    /// Block until a stopped event has been seen (event stream only).
    fn wait_stopped(&mut self) -> Result<(), String> {
        let deadline = Instant::now() + self.cfg.timeout;
        while !self.stopped {
            let f = self.recv(deadline)?;
            self.note_event(&f);
            if f.id != EVENT_ID {
                return Err(format!("unexpected reply type {:#04x} while waiting for a stop", f.rtype));
            }
        }
        Ok(())
    }

    fn read_mem(&mut self, addr: u16, len: usize) -> Result<Vec<u8>, String> {
        let end = addr + (len as u16 - 1);
        let mut b = vec![0u8];
        b.extend_from_slice(&addr.to_le_bytes());
        b.extend_from_slice(&end.to_le_bytes());
        b.push(0); // main memspace
        b.extend_from_slice(&0u16.to_le_bytes()); // default bank
        let f = self.request(CMD_MEM_GET, &b)?;
        if f.body.len() < 2 {
            return Err("short memory reply".into());
        }
        let n = u16::from_le_bytes([f.body[0], f.body[1]]) as usize;
        if n != len || f.body.len() < 2 + n {
            return Err(format!("memory reply length {n}, wanted {len}"));
        }
        Ok(f.body[2..2 + n].to_vec())
    }

    fn get_regs(&mut self) -> Result<HashMap<u8, u16>, String> {
        let f = self.request(CMD_REGS_GET, &[0])?;
        let b = &f.body;
        if b.len() < 2 {
            return Err("short register reply".into());
        }
        let n = u16::from_le_bytes([b[0], b[1]]) as usize;
        let mut m = HashMap::new();
        let mut o = 2;
        for _ in 0..n {
            let size = *b.get(o).ok_or("truncated register reply")? as usize;
            if size < 3 || o + 1 + size > b.len() {
                return Err("bad register item".into());
            }
            m.insert(b[o + 1], u16::from_le_bytes([b[o + 2], b[o + 3]]));
            o += 1 + size;
        }
        Ok(m)
    }

    fn lookup_register_ids(&mut self) -> Result<(), String> {
        let f = self.request(CMD_REGS_AVAIL, &[0])?;
        let b = &f.body;
        let n = u16::from_le_bytes([b[0], b[1]]) as usize;
        let mut o = 2;
        let (mut a, mut pc) = (None, None);
        for _ in 0..n {
            let size = b[o] as usize;
            let id = b[o + 1];
            let nl = b[o + 3] as usize;
            let name = String::from_utf8_lossy(&b[o + 4..o + 4 + nl]).to_string();
            match name.as_str() {
                "A" => a = Some(id),
                "PC" => pc = Some(id),
                _ => {}
            }
            o += 1 + size;
        }
        self.reg_a = a.ok_or("monitor has no register `A`")?;
        self.reg_pc = pc.ok_or("monitor has no register `PC`")?;
        Ok(())
    }

    /// After a stop: demand that we are exactly at gpf_input_ret.
    fn check_parked(&mut self) -> Result<(), String> {
        let regs = self.get_regs()?;
        let pc = *regs.get(&self.reg_pc).ok_or("no PC in register reply")?;
        if pc != self.input_ret || self.stop_pc != self.input_ret {
            return Err(format!(
                "stopped at PC ${pc:04x} (stop event ${:04x}), expected gpf_input_ret ${:04x}",
                self.stop_pc, self.input_ret
            ));
        }
        Ok(())
    }

    fn spawn(&mut self) -> Result<u16, String> {
        let port = TcpListener::bind("127.0.0.1:0")
            .and_then(|l| l.local_addr())
            .map_err(|e| format!("no free port: {e}"))?
            .port();
        let use_xvfb = match self.cfg.xvfb.as_str() {
            "always" => true,
            "never" => false,
            _ => which("xvfb-run"),
        };
        let mut cmd = if use_xvfb {
            let mut c = Command::new("xvfb-run");
            c.arg("-a").arg(&self.cfg.x64sc);
            c
        } else {
            Command::new(&self.cfg.x64sc)
        };
        cmd.args([
            "-default", // ignore any user vicerc: a fixed baseline configuration
            "-model", "c64", // PAL
            if self.cfg.warp { "-warp" } else { "+warp" },
            "+sound",
            "-autostartprgmode", "1", // inject straight into RAM, no virtual-FS LOAD
            "-binarymonitor",
            "-binarymonitoraddress",
        ])
        .arg(format!("ip4://127.0.0.1:{port}"));
        cmd.stdin(Stdio::null());
        if self.cfg.debug {
            cmd.stdout(Stdio::inherit()).stderr(Stdio::inherit());
        } else {
            cmd.stdout(Stdio::null()).stderr(Stdio::null());
        }
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
        self.dbg(|| format!("spawn {:?}", cmd));
        self.child = Some(cmd.spawn().map_err(|e| format!("cannot start `{}`: {e}", self.cfg.x64sc))?);
        Ok(port)
    }
}

impl Target for C64Target {
    fn boot(&mut self) -> Result<(), String> {
        let port = self.spawn()?;
        let t0 = Instant::now();
        let conn = loop {
            match TcpStream::connect(("127.0.0.1", port)) {
                Ok(c) => break c,
                Err(e) => {
                    if t0.elapsed() > self.cfg.timeout {
                        return Err(format!("could not connect to the VICE monitor: {e}"));
                    }
                    if let Some(c) = self.child.as_mut() {
                        if let Ok(Some(st)) = c.try_wait() {
                            return Err(format!("x64sc exited early ({st}); run with --debug"));
                        }
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
            }
        };
        let _ = conn.set_nodelay(true);
        self.conn = Some(conn);
        // The first command stops the (running) emulator: ping, then wait for the
        // stop event so everything below runs against a halted CPU.
        self.request(CMD_PING, &[])?;
        self.wait_stopped()?;
        self.lookup_register_ids()?;
        // Exec checkpoint on the RTS of read_input: stop when hit, enabled, exec.
        let mut cp = vec![];
        cp.extend_from_slice(&self.input_ret.to_le_bytes());
        cp.extend_from_slice(&self.input_ret.to_le_bytes());
        cp.extend_from_slice(&[1, 1, 4, 0]);
        self.request(CMD_CHECKPOINT_SET, &cp)?;
        // Load + run the PRG (after the checkpoint exists, so no step can be missed).
        let abs = std::fs::canonicalize(&self.cfg.prg)
            .map_err(|e| format!("{}: {e}", self.cfg.prg))?;
        let name = abs.to_string_lossy().to_string();
        let mut a = vec![1u8];
        a.extend_from_slice(&0u16.to_le_bytes());
        a.push(name.len() as u8);
        a.extend_from_slice(name.as_bytes());
        self.resumed = 0;
        self.request(CMD_AUTOSTART, &a)?;
        // Autostart resumes the machine by itself (0x63 event). Do NOT send exit now:
        // any command arriving while running stops the CPU at an arbitrary PC (that
        // produced hundreds of spurious stops during KERNAL boot). Wait for the
        // resume, then for the checkpoint hit.
        let deadline = Instant::now() + self.cfg.timeout;
        while self.resumed == 0 {
            let f = self.recv(deadline)?;
            self.note_event(&f);
        }
        let mut tries = 0;
        loop {
            self.wait_stopped()?;
            if self.stop_pc == self.input_ret {
                return self.check_parked();
            }
            // Unexpected stop elsewhere (never observed with this sequence): resume
            // a bounded number of times, then give up loudly.
            tries += 1;
            self.dbg(|| format!("boot: stop at ${:04x}, resuming", self.stop_pc));
            if tries > 5 {
                return Err(format!("never reached gpf_input_ret (last stop ${:04x})", self.stop_pc));
            }
            self.stopped = false;
            self.request(CMD_EXIT, &[])?;
        }
    }

    fn read_state(&mut self) -> Result<RawState, String> {
        let s = self.read_mem(self.gpf_state, STATE_LEN)?;
        let b = self.read_mem(self.gpf_bricks, BRICKS_LEN)?;
        Ok(RawState { state: s.try_into().unwrap(), bricks: b.try_into().unwrap() })
    }

    fn provide_input(&mut self, buttons: u8) -> Result<(), String> {
        // set A
        let mut body = vec![0u8];
        body.extend_from_slice(&1u16.to_le_bytes());
        body.push(3); // item size (id + value)
        body.push(self.reg_a);
        body.extend_from_slice(&(buttons as u16).to_le_bytes());
        self.request(CMD_REGS_SET, &body)?;
        // verify the write took, and that PC did not move
        let regs = self.get_regs()?;
        let a = *regs.get(&self.reg_a).ok_or("no A in register reply")?;
        let pc = *regs.get(&self.reg_pc).ok_or("no PC in register reply")?;
        if (a & 0xff) as u8 != buttons || pc != self.input_ret {
            return Err(format!(
                "register write did not take: wanted A={buttons:#04x} at ${:04x}, got A={:#04x} PC=${pc:04x}",
                self.input_ret,
                a & 0xff
            ));
        }
        self.stopped = false;
        self.request(CMD_EXIT, &[])?;
        self.wait_stopped()?;
        self.check_parked()
    }

    fn peek(&mut self, addr: u16, len: usize) -> Result<Vec<u8>, String> {
        self.read_mem(addr, len)
    }

    fn label(&self, name: &str) -> Option<u16> {
        self.labels.get(name).copied()
    }

    fn screenshot(&mut self) -> Result<crate::png::Image, String> {
        // Palette (RGB per index), then the indexed 8-bit display buffer; crop to the
        // inner area (visible screen incl. border).
        let p = self.request(CMD_PALETTE_GET, &[1])?;
        let pb = &p.body;
        let n = u16::from_le_bytes([pb[0], pb[1]]) as usize;
        let mut pal = vec![];
        let mut o = 2;
        for _ in 0..n {
            let sz = pb[o] as usize;
            pal.push([pb[o + 1], pb[o + 2], pb[o + 3]]);
            o += 1 + sz;
        }
        let d = self.request(CMD_DISPLAY_GET, &[1, 0])?;
        let b = &d.body;
        let u16at = |i: usize| u16::from_le_bytes([b[i], b[i + 1]]) as usize;
        let fl = u32::from_le_bytes(b[0..4].try_into().unwrap()) as usize;
        let (dw, dh, xo, yo, iw, ih) = (u16at(4), u16at(6), u16at(8), u16at(10), u16at(12), u16at(14));
        // PAL visible area incl. border: 384x272 around the 320x200 inner screen.
        let (cx, cy) = (xo.saturating_sub(32), yo.saturating_sub(35));
        let (cw, ch) = (iw + 64, ih + 72);
        if cx + cw > dw || cy + ch > dh {
            return Err(format!("crop {cw}x{ch}+{cx}+{cy} outside the {dw}x{dh} buffer"));
        }
        let bp = b[16];
        let bl = u32::from_le_bytes(b[17..21].try_into().unwrap()) as usize;
        // VICE 3.10 sends the buffer 4 bytes short of the announced length (observed:
        // body = 17 + bl). Only the unused bottom-right debug corner is missing, so
        // require just the rows we crop.
        if bp != 8 || fl != 13 || b.len() < 21 + (cy + ch) * dw {
            return Err(format!("unexpected display reply (bpp {bp}, fields {fl}, len {bl}, body {})", b.len()));
        }
        let buf = &b[21..];
        let mut rgb = Vec::with_capacity(cw * ch * 3);
        for y in 0..ch {
            for x in 0..cw {
                let px = buf[(cy + y) * dw + cx + x] as usize;
                rgb.extend_from_slice(pal.get(px).ok_or("pixel outside palette")?);
            }
        }
        Ok(crate::png::Image { w: cw, h: ch, rgb })
    }

    fn shutdown(&mut self) {
        if self.conn.is_some() {
            let _ = self.send(CMD_QUIT, &[]);
            self.conn = None;
        }
        if let Some(mut c) = self.child.take() {
            let t0 = Instant::now();
            loop {
                match c.try_wait() {
                    Ok(Some(_)) => break,
                    _ if t0.elapsed() > Duration::from_secs(3) => {
                        // kill the whole process group (xvfb-run + Xvfb + x64sc)
                        let _ = Command::new("kill")
                            .args(["-KILL", "--", &format!("-{}", c.id())])
                            .status();
                        let _ = c.kill();
                        let _ = c.wait();
                        break;
                    }
                    _ => std::thread::sleep(Duration::from_millis(50)),
                }
            }
        }
    }
}

impl Drop for C64Target {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_vice_labels() {
        let m = parse_labels("al C:c010 .gpf_bricks\nal C:08ba .gpf_input_ret\nbogus\nal C:zz .x\n");
        assert_eq!(m["gpf_bricks"], 0xc010);
        assert_eq!(m["gpf_input_ret"], 0x08ba);
        assert_eq!(m.len(), 2);
    }
}
