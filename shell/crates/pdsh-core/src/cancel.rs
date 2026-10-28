// SPDX-License-Identifier: MIT
//! Cancellation flag plus optional deadline.
//!
//! A [`CancelToken`] is cheap to clone: every clone shares the same atomic flag
//! and deadline. Commands call [`CancelToken::check`] at least once per
//! processed file and at least once per 64 KiB of output (see
//! [`crate::ctx::Ctx::emit_stdout`]); the FFI watchdog sets the flag when the
//! request deadline expires.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use crate::error::{Error, Result};

const NEVER: Option<Instant> = None;

#[derive(Debug)]
struct Inner {
    cancelled: AtomicBool,
    deadline: Mutex<Option<Instant>>,
}

/// A shared cancellation flag with an optional wall-clock deadline.
#[derive(Debug, Clone)]
pub struct CancelToken {
    inner: Arc<Inner>,
}

impl Default for CancelToken {
    fn default() -> Self {
        CancelToken::new()
    }
}

impl CancelToken {
    /// A token that only fires on an explicit [`CancelToken::cancel`].
    pub fn new() -> Self {
        CancelToken {
            inner: Arc::new(Inner {
                cancelled: AtomicBool::new(false),
                deadline: Mutex::new(NEVER),
            }),
        }
    }

    /// A token that also fires once `deadline` has passed.
    pub fn with_deadline(deadline: Instant) -> Self {
        let token = CancelToken::new();
        token.set_deadline(deadline);
        token
    }

    /// A token whose deadline is `timeout` from now.
    pub fn with_timeout(timeout: std::time::Duration) -> Self {
        CancelToken::with_deadline(Instant::now() + timeout)
    }

    /// Arm (or replace) the deadline.
    pub fn set_deadline(&self, deadline: Instant) {
        let mut guard = self
            .inner
            .deadline
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        *guard = Some(deadline);
    }

    /// Remove the deadline.
    pub fn clear_deadline(&self) {
        let mut guard = self
            .inner
            .deadline
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        *guard = NEVER;
    }

    /// The current deadline, if one is armed.
    pub fn deadline(&self) -> Option<Instant> {
        *self
            .inner
            .deadline
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    /// Whether the deadline has already passed (independent of the flag).
    pub fn is_deadline_expired(&self) -> bool {
        self.deadline()
            .map(|deadline| Instant::now() >= deadline)
            .unwrap_or(false)
    }

    /// Set the flag. Idempotent; safe from any thread.
    pub fn cancel(&self) {
        self.inner.cancelled.store(true, Ordering::SeqCst);
    }

    /// True once [`CancelToken::cancel`] was called or the deadline passed.
    pub fn is_cancelled(&self) -> bool {
        self.inner.cancelled.load(Ordering::SeqCst) || self.is_deadline_expired()
    }

    /// Return `Err(Error::Cancelled)` once the token fired.
    pub fn check(&self) -> Result<()> {
        if self.is_cancelled() {
            Err(Error::Cancelled)
        } else {
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn a_fresh_token_is_not_cancelled() {
        let token = CancelToken::new();
        assert!(!token.is_cancelled());
        assert!(token.check().is_ok());
    }

    #[test]
    fn cancel_is_visible_through_every_clone() {
        let token = CancelToken::new();
        let clone = token.clone();
        assert!(clone.check().is_ok());
        token.cancel();
        assert!(matches!(clone.check(), Err(Error::Cancelled)));
        assert!(token.is_cancelled());
    }

    #[test]
    fn a_past_deadline_is_cancelled() {
        let past = Instant::now()
            .checked_sub(Duration::from_secs(1))
            .expect("monotonic clock");
        let token = CancelToken::with_deadline(past);
        assert!(token.is_deadline_expired());
        assert!(matches!(token.check(), Err(Error::Cancelled)));
    }

    #[test]
    fn a_future_deadline_is_not_cancelled_and_clears() {
        let token = CancelToken::with_timeout(Duration::from_secs(60));
        assert!(token.deadline().is_some());
        assert!(token.check().is_ok());
        token.clear_deadline();
        assert!(token.deadline().is_none());
        assert!(!token.is_deadline_expired());
    }
}
