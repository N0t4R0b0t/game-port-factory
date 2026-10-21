//! The MAME child process, shared by the two MAME drivers (`mame.rs`: parked, breakpoint-driven;
//! `keysrun.rs`: free-running keys mode): spawn with piped stdout and stderr, merge both into one line
//! stream through reader threads, wait for the next `GPF ` line with a wall-clock timeout, keep the last few
//! non-protocol lines as context for error messages, and reap the process (grace period, then kill).

use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

/// How long a finished MAME is given to exit by itself before it is killed.
const EXIT_GRACE: Duration = Duration::from_secs(3);
/// How many non-protocol lines are kept as error context.
const CHATTER_KEEP: usize = 12;

/// One MAME process and its merged stdout/stderr line stream.
pub struct LineProc {
    pub child: Child,
    rx: Receiver<String>,
    chatter: Vec<String>,
}

impl LineProc {
    /// Spawn `cmd` (the caller has set args, env and stdin) with stdout and stderr piped and merged.
    /// stderr carries MAME's own complaints (missing ROM, bad snapshot), so it shows up as error context.
    pub fn spawn(cmd: &mut Command, name: &str) -> Result<LineProc, String> {
        cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = cmd.spawn().map_err(|e| format!("cannot start `{name}`: {e}"))?;
        let stdout = child.stdout.take().ok_or("no stdout")?;
        let (tx, rx) = channel();
        if let Some(stderr) = child.stderr.take() {
            let tx2 = tx.clone();
            std::thread::spawn(move || {
                for l in BufReader::new(stderr).lines().map_while(Result::ok) {
                    if tx2.send(l).is_err() {
                        break;
                    }
                }
            });
        }
        std::thread::spawn(move || {
            for l in BufReader::new(stdout).lines().map_while(Result::ok) {
                if tx.send(l).is_err() {
                    break;
                }
            }
        });
        Ok(LineProc { child, rx, chatter: vec![] })
    }

    /// ` (last MAME output: a | b)` or the empty string.
    pub fn context(&self) -> String {
        if self.chatter.is_empty() {
            String::new()
        } else {
            format!(" (last MAME output: {})", self.chatter.join(" | "))
        }
    }

    pub fn note(&mut self, l: String) {
        if self.chatter.len() >= CHATTER_KEEP {
            self.chatter.remove(0);
        }
        self.chatter.push(l);
    }

    /// Next `GPF ` line (prefix stripped), skipping chatter (which is remembered for `context`).
    pub fn next_gpf(&mut self, timeout: Duration, debug: bool) -> Result<String, String> {
        let deadline = Instant::now() + timeout;
        loop {
            let now = Instant::now();
            if now >= deadline {
                return Err(format!("timed out waiting for MAME{}", self.context()));
            }
            match self.rx.recv_timeout(deadline - now) {
                Ok(l) => {
                    if debug {
                        eprintln!("[mame] <- {l}");
                    }
                    if let Some(rest) = l.strip_prefix("GPF ") {
                        return Ok(rest.to_string());
                    }
                    self.note(l);
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return Err(format!("MAME exited unexpectedly{}", self.context())),
            }
        }
    }

    /// Wait up to the grace period for the process to exit, then kill it.
    pub fn reap(&mut self) {
        let end = Instant::now() + EXIT_GRACE;
        loop {
            match self.child.try_wait() {
                Ok(Some(_)) => break,
                Ok(None) if Instant::now() < end => std::thread::sleep(Duration::from_millis(20)),
                _ => {
                    let _ = self.child.kill();
                    let _ = self.child.wait();
                    break;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sh(script: &str) -> LineProc {
        LineProc::spawn(Command::new("sh").arg("-c").arg(script).stdin(Stdio::null()), "sh").unwrap()
    }

    #[test]
    fn skips_chatter_keeps_it_as_context_and_reports_exit() {
        let mut p = sh("echo noise; echo oops >&2; echo 'GPF READY'");
        assert_eq!(p.next_gpf(Duration::from_secs(5), false).unwrap(), "READY");
        let e = p.next_gpf(Duration::from_secs(5), false).unwrap_err();
        assert!(e.contains("MAME exited unexpectedly") && e.contains("noise"), "{e}");
        p.reap();
    }

    #[test]
    fn times_out_and_kills() {
        let mut p = sh("sleep 30");
        let e = p.next_gpf(Duration::from_millis(100), false).unwrap_err();
        assert!(e.contains("timed out waiting for MAME"), "{e}");
        let _ = p.child.kill();
        p.reap();
    }

    #[test]
    fn missing_binary_is_named() {
        let e = LineProc::spawn(&mut Command::new("/nonexistent/mame-x"), "mame-x").err().unwrap();
        assert!(e.contains("cannot start `mame-x`"), "{e}");
    }
}
