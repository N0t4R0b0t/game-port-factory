use brickfall_model::*;
use std::{fs, path::PathBuf};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
}
fn load(name: &str) -> Scenario {
    let p = root().join("scenarios").join(format!("{name}.toml"));
    Scenario::parse(&fs::read_to_string(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()))).unwrap()
}
const NAMES: [&str; 10] = [
    "launch_left", "launch_centre", "launch_right", "paddle_zones", "wall_bounces",
    "miss_then_wait", "game_over", "speedup", "full_win", "paddle_clamp_edges",
];

#[test]
fn determinism() {
    for n in NAMES {
        let s = load(n);
        assert_eq!(s.trace(), s.trace(), "{n}");
    }
}

#[test]
fn golden_traces_match() {
    for n in NAMES {
        let p = root().join("golden").join(format!("{n}.trace"));
        let g = fs::read_to_string(&p).unwrap_or_else(|_| panic!("missing golden {n}; run --golden"));
        assert_eq!(g, load(n).trace(), "golden mismatch: {n}");
    }
}

#[test]
fn state_block_layout() {
    let mut s = State::new();
    s.score = 0x0102;
    s.ball_vy = -0x0180;
    let b = s.to_bytes();
    assert_eq!(&b[4..6], &[0x02, 0x01]);
    assert_eq!(&b[14..16], &[0x80, 0xFE]);
    assert_eq!(s.bricks_bytes(), [0xFF; 5]);
}

fn last(n: &str) -> State {
    load(n).states().pop().unwrap()
}

#[test]
fn launches() {
    for (n, vx) in [("launch_left", -0x80), ("launch_centre", 0), ("launch_right", 0x80)] {
        let st = load(n).states();
        assert_eq!(st[1].mode, PLAY, "{n}");
        assert_eq!(st[1].ball_vx, vx, "{n}");
        assert_eq!(st[1].ball_vy, -0x180, "{n}");
    }
}

#[test]
fn scenario_end_states() {
    let s = last("miss_then_wait");
    assert_eq!((s.mode, s.lives), (WAIT, 2));
    let s = last("game_over");
    assert_eq!((s.mode, s.lives), (OVER, 0));
    let s = last("full_win");
    assert_eq!((s.mode, s.cleared, s.bricks), (WON, 40, 0));
    assert_eq!(s.score, 8 * (50 + 40 + 30 + 20 + 10) as u16);
    let s = last("paddle_clamp_edges");
    assert_eq!((s.mode, s.paddle_x), (WAIT, 0));
    // clamp reached both edges
    let pxs: Vec<u8> = load("paddle_clamp_edges").states().iter().map(|s| s.paddle_x).collect();
    assert!(pxs.contains(&0) && pxs.contains(&224));
    assert!(pxs.iter().all(|&p| p <= 224));
}

#[test]
fn paddle_zones_all_hit() {
    let st = load("paddle_zones").states();
    let mut seen = [false; 4];
    for w in st.windows(2) {
        if w[0].ball_vy > 0 && w[1].ball_vy < 0 && w[1].ball_y == 172 << 8 {
            let z = ZONE_VX.iter().position(|&v| v == w[1].ball_vx).expect("zone vx");
            seen[z] = true;
        }
    }
    assert_eq!(seen, [true; 4]);
}

#[test]
fn wall_bounces_all_three() {
    let st = load("wall_bounces").states();
    let (mut l, mut r, mut t) = (false, false, false);
    for w in st.windows(2) {
        if w[1].mode != PLAY {
            continue;
        }
        l |= w[1].ball_x == 0 && w[1].ball_vx > 0 && w[0].ball_vx < 0;
        r |= w[1].ball_x == 252 << 8 && w[1].ball_vx < 0 && w[0].ball_vx > 0;
        t |= w[1].ball_y == 0 && w[1].ball_vy > 0 && w[0].ball_vy < 0;
    }
    assert!(l && r && t, "left {l} right {r} top {t}");
}

#[test]
fn speedup_after_tenth_brick() {
    let st = load("speedup").states();
    assert!(st.last().unwrap().cleared >= 10);
    let mut saw = false;
    for w in st.windows(2) {
        if w[1].cleared == 10 && w[0].cleared == 9 {
            assert_eq!(w[1].ball_vy.abs(), w[0].ball_vy.abs() + 0x40);
            saw = true;
        }
    }
    assert!(saw);
    assert!(st.iter().all(|s| s.ball_vy.abs() <= 0x300));
}

#[test]
fn invariants() {
    for n in NAMES {
        let st = load(n).states();
        for w in st.windows(2) {
            assert_eq!(w[1].bricks & !w[0].bricks, 0, "{n}: brick reappeared");
            assert!(w[1].score >= w[0].score, "{n}: score decreased");
            assert!((w[1].cleared - w[0].cleared) <= 1, "{n}: >1 brick/step");
            assert!(w[1].ball_x <= 252 << 8, "{n}: ball x out of range");
            assert!(w[1].paddle_x <= 224, "{n}");
            assert!(w[1].lives <= w[0].lives, "{n}");
            assert_eq!(w[1].step, w[0].step + 1);
        }
        for s in &st {
            assert_eq!(s.cleared as u32, 40 - s.bricks.count_ones(), "{n}");
        }
    }
}
