//! Bit-exact reference simulation of games/brickfall/recipe/README.md.
//! Integer-only. See the "Resolved ambiguities" section of the README.

pub const LEFT: u8 = 1;
pub const RIGHT: u8 = 2;
pub const FIRE: u8 = 4;

pub const WAIT: u8 = 0;
pub const PLAY: u8 = 1;
pub const OVER: u8 = 2;
pub const WON: u8 = 3;

pub const PADDLE_Y: i32 = 176;
pub const PADDLE_W: i32 = 32;
pub const PADDLE_MAX: i32 = 224;
pub const BALL: i32 = 4;
pub const FULL_MASK: u64 = (1u64 << 40) - 1;
pub const ZONE_VX: [i16; 4] = [-0x0180, -0x00C0, 0x00C0, 0x0180];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct State {
    pub step: u16,
    pub mode: u8,
    pub lives: u8,
    pub score: u16,
    pub paddle_x: u8,
    pub cleared: u8,
    pub ball_x: u16,
    pub ball_y: u16,
    pub ball_vx: i16,
    pub ball_vy: i16,
    pub bricks: u64,
}

impl Default for State {
    fn default() -> Self {
        Self::new()
    }
}

impl State {
    pub fn new() -> State {
        let mut s = State {
            step: 0,
            mode: WAIT,
            lives: 3,
            score: 0,
            paddle_x: 112,
            cleared: 0,
            ball_x: 0,
            ball_y: 0,
            ball_vx: 0,
            ball_vy: 0,
            bricks: FULL_MASK,
        };
        s.attach_ball();
        s
    }

    fn attach_ball(&mut self) {
        self.ball_x = (((self.paddle_x as i32) + 14) << 8) as u16;
        self.ball_y = (((PADDLE_Y - BALL) << 8)) as u16;
        self.ball_vx = 0;
        self.ball_vy = 0;
    }

    pub fn to_bytes(&self) -> [u8; 16] {
        let mut b = [0u8; 16];
        b[0..2].copy_from_slice(&self.step.to_le_bytes());
        b[2] = self.mode;
        b[3] = self.lives;
        b[4..6].copy_from_slice(&self.score.to_le_bytes());
        b[6] = self.paddle_x;
        b[7] = self.cleared;
        b[8..10].copy_from_slice(&self.ball_x.to_le_bytes());
        b[10..12].copy_from_slice(&self.ball_y.to_le_bytes());
        b[12..14].copy_from_slice(&self.ball_vx.to_le_bytes());
        b[14..16].copy_from_slice(&self.ball_vy.to_le_bytes());
        b
    }

    pub fn bricks_bytes(&self) -> [u8; 5] {
        let b = self.bricks.to_le_bytes();
        [b[0], b[1], b[2], b[3], b[4]]
    }

    /// One 50 Hz simulation step.
    pub fn step(&mut self, buttons: u8) {
        self.step = self.step.wrapping_add(1);
        if self.mode == OVER || self.mode == WON {
            return;
        }
        // 1. paddle movement (LEFT and RIGHT together cancel), clamped.
        let mut px = self.paddle_x as i32;
        if buttons & LEFT != 0 {
            px -= 4;
        }
        if buttons & RIGHT != 0 {
            px += 4;
        }
        px = px.clamp(0, PADDLE_MAX);
        self.paddle_x = px as u8;

        if self.mode == WAIT {
            self.attach_ball();
            if buttons & FIRE != 0 {
                self.ball_vy = -0x0180;
                self.ball_vx = if buttons & LEFT != 0 {
                    -0x0080
                } else if buttons & RIGHT != 0 {
                    0x0080
                } else {
                    0
                };
                self.mode = PLAY;
            }
            return;
        }

        // PLAY: 2. move
        let mut x = self.ball_x as i32 + self.ball_vx as i32;
        let mut y = self.ball_y as i32 + self.ball_vy as i32;
        let mut vx = self.ball_vx as i32;
        let mut vy = self.ball_vy as i32;

        // 3. walls
        if x < 0 {
            x = 0;
            vx = vx.abs();
        } else if x > (256 - BALL) << 8 {
            x = (256 - BALL) << 8;
            vx = -vx.abs();
        }
        if y < 0 {
            y = 0;
            vy = vy.abs();
        }

        // 4. paddle
        let bx = x >> 8;
        let by = y >> 8;
        if vy > 0
            && by + BALL >= PADDLE_Y
            && by < PADDLE_Y + 8
            && bx + BALL > px
            && bx < px + PADDLE_W
        {
            y = (PADDLE_Y - BALL) << 8;
            vy = -vy.abs();
            let zone = ((bx + 2 - px).clamp(0, PADDLE_W - 1) >> 3) as usize;
            vx = ZONE_VX[zone] as i32;
        }

        // 5. bricks (first overlapped, row-major, at most one)
        let bx = x >> 8;
        let by = y >> 8;
        'scan: for row in 0..5i32 {
            for col in 0..8i32 {
                let bit = (row * 8 + col) as u32;
                if self.bricks & (1u64 << bit) == 0 {
                    continue;
                }
                let l = col * 32;
                let t = 24 + row * 8;
                if bx < l + 32 && bx + BALL > l && by < t + 8 && by + BALL > t {
                    self.bricks &= !(1u64 << bit);
                    self.score += (50 - 10 * row) as u16;
                    self.cleared += 1;
                    vy = -vy;
                    if self.cleared % 10 == 0 {
                        let m = (vy.abs() + 0x40).min(0x300);
                        vy = if vy < 0 { -m } else { m };
                    }
                    break 'scan;
                }
            }
        }

        self.ball_x = x as u16;
        self.ball_y = y as u16;
        self.ball_vx = vx as i16;
        self.ball_vy = vy as i16;

        // 6. win / miss
        if self.bricks == 0 {
            self.mode = WON;
        } else if (y >> 8) > 192 {
            self.lives -= 1;
            if self.lives == 0 {
                self.mode = OVER;
                self.ball_vx = 0;
                self.ball_vy = 0;
            } else {
                self.mode = WAIT;
                self.attach_ball();
            }
        }
    }
}

// ---------------------------------------------------------------- scenarios

#[derive(Clone, Debug, Default)]
pub struct Scenario {
    pub steps: u32,
    pub sample_every: u32,
    /// (step, buttons), sorted; buttons hold from `step` until the next entry.
    pub inputs: Vec<(u32, u8)>,
}

impl Scenario {
    pub fn parse(text: &str) -> Result<Scenario, String> {
        let mut sc = Scenario { steps: 0, sample_every: 1, inputs: vec![] };
        let mut cur: Option<(Option<u32>, Option<u8>)> = None;
        let flush = |c: &mut Option<(Option<u32>, Option<u8>)>, sc: &mut Scenario| -> Result<(), String> {
            if let Some((s, b)) = c.take() {
                sc.inputs.push((
                    s.ok_or("[[input]] missing step")?,
                    b.ok_or("[[input]] missing buttons")?,
                ));
            }
            Ok(())
        };
        for raw in text.lines() {
            let line = raw.split('#').next().unwrap().trim();
            if line.is_empty() {
                continue;
            }
            if line == "[[input]]" {
                flush(&mut cur, &mut sc)?;
                cur = Some((None, None));
                continue;
            }
            let (k, v) = line.split_once('=').ok_or(format!("bad line: {raw}"))?;
            let (k, v) = (k.trim(), v.trim());
            let n: u32 = v.parse().map_err(|_| format!("bad number: {raw}"))?;
            match (k, cur.as_mut()) {
                ("steps", None) => sc.steps = n,
                ("sample_every", None) => sc.sample_every = n.max(1),
                ("step", Some(c)) => c.0 = Some(n),
                ("buttons", Some(c)) => c.1 = Some(n as u8),
                _ => return Err(format!("unexpected key: {raw}")),
            }
        }
        flush(&mut cur, &mut sc)?;
        sc.inputs.sort_by_key(|i| i.0);
        Ok(sc)
    }

    pub fn buttons_at(&self, step: u32) -> u8 {
        let mut b = 0;
        for &(s, v) in &self.inputs {
            if s <= step {
                b = v;
            } else {
                break;
            }
        }
        b
    }

    /// Every state after each step 0..=steps (index = step count).
    pub fn states(&self) -> Vec<State> {
        let mut s = State::new();
        let mut v = vec![s.clone()];
        for i in 0..self.steps {
            s.step(self.buttons_at(i));
            v.push(s.clone());
        }
        v
    }

    pub fn trace(&self) -> String {
        let mut out = String::new();
        for s in self.states() {
            if (s.step as u32) % self.sample_every == 0 {
                out.push_str(&trace_line(&s));
                out.push('\n');
            }
        }
        out
    }
}

pub fn trace_line(s: &State) -> String {
    let b = s.bricks_bytes();
    format!(
        "{} {} {} {} {} {} {} {} {} {} {:02x}{:02x}{:02x}{:02x}{:02x}",
        s.step, s.mode, s.lives, s.score, s.paddle_x, s.cleared, s.ball_x, s.ball_y,
        s.ball_vx, s.ball_vy, b[0], b[1], b[2], b[3], b[4]
    )
}
