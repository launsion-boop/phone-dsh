// SPDX-License-Identifier: MIT
//! Bounded output capture with head/tail truncation.
//!
//! One [`OutputSink`] captures one stream (stdout or stderr). It counts every
//! byte written and retains at most `max_output_bytes` data bytes. When the
//! stream exceeds the budget it keeps the first 60 percent and the last
//! 40 percent of the budget and inserts a marker line between them; the marker
//! itself is not counted as output data.

use std::collections::VecDeque;

/// Proportion of the budget reserved for the head of a truncated stream.
pub const HEAD_PERCENT: usize = 60;

const MARKER_PREFIX: &str = "[pdsh-shell truncated ";
const MARKER_SUFFIX: &str = " bytes]\n";

/// The retained part of one stream after a run finished.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Output {
    /// Retained bytes, including the truncation marker when truncated.
    pub data: Vec<u8>,
    /// Number of bytes written to the sink, including dropped bytes.
    pub total_bytes: u64,
    /// True when the budget was exceeded.
    pub truncated: bool,
    /// Number of data bytes dropped by truncation.
    pub omitted_bytes: u64,
}

#[derive(Debug)]
enum State {
    Buffered(Vec<u8>),
    Truncated { head: Vec<u8>, tail: VecDeque<u8> },
}

/// A bounded, byte-counting output sink.
#[derive(Debug)]
pub struct OutputSink {
    max_bytes: usize,
    head_budget: usize,
    tail_budget: usize,
    total: u64,
    state: State,
}

impl OutputSink {
    /// Create a sink with the given per-stream budget.
    ///
    /// A budget of zero keeps no data bytes and reports the whole stream as
    /// omitted; the marker line is still produced.
    pub fn new(max_bytes: usize) -> Self {
        let head_budget = if max_bytes == 0 {
            0
        } else {
            max_bytes.saturating_mul(HEAD_PERCENT) / 100
        };
        let tail_budget = max_bytes.saturating_sub(head_budget);
        OutputSink {
            max_bytes,
            head_budget,
            tail_budget,
            total: 0,
            state: State::Buffered(Vec::new()),
        }
    }

    /// The configured budget in bytes.
    pub fn max_bytes(&self) -> usize {
        self.max_bytes
    }

    /// Number of bytes written so far, including bytes later dropped.
    pub fn total_bytes(&self) -> u64 {
        self.total
    }

    /// True once more than `max_bytes` data bytes were written.
    pub fn is_truncated(&self) -> bool {
        matches!(self.state, State::Truncated { .. })
    }

    /// Append bytes. Truncation starts exactly when the total exceeds the
    /// budget; no bytes are lost before that point.
    pub fn write(&mut self, data: &[u8]) {
        if data.is_empty() {
            return;
        }
        self.total = self.total.saturating_add(data.len() as u64);
        match &mut self.state {
            State::Buffered(buffer) => {
                let room = self.max_bytes.saturating_add(1).saturating_sub(buffer.len());
                let take = room.min(data.len());
                buffer.extend_from_slice(&data[..take]);
                if buffer.len() <= self.max_bytes {
                    return;
                }
                let head = buffer[..self.head_budget].to_vec();
                let tail_start = buffer.len().saturating_sub(self.tail_budget);
                let tail: VecDeque<u8> = buffer[tail_start..].iter().copied().collect();
                self.state = State::Truncated { head, tail };
                self.push_tail(&data[take..]);
            }
            State::Truncated { .. } => self.push_tail(data),
        }
    }

    /// Append a UTF-8 string.
    pub fn write_str(&mut self, text: &str) {
        self.write(text.as_bytes());
    }

    fn push_tail(&mut self, data: &[u8]) {
        let tail_budget = self.tail_budget;
        if tail_budget == 0 || data.is_empty() {
            return;
        }
        if let State::Truncated { tail, .. } = &mut self.state {
            if data.len() >= tail_budget {
                tail.clear();
                tail.extend(data[data.len() - tail_budget..].iter().copied());
                return;
            }
            let overflow = tail.len().saturating_add(data.len()).saturating_sub(tail_budget);
            if overflow > 0 {
                tail.drain(..overflow);
            }
            tail.extend(data.iter().copied());
        }
    }

    /// Render the current retained bytes without consuming the sink.
    pub fn capture(&self) -> Output {
        match &self.state {
            State::Buffered(buffer) => Output {
                data: buffer.clone(),
                total_bytes: self.total,
                truncated: false,
                omitted_bytes: 0,
            },
            State::Truncated { head, tail } => {
                let kept = head.len().saturating_add(tail.len()) as u64;
                let omitted = self.total.saturating_sub(kept);
                Output {
                    data: render_truncated(head, tail, omitted),
                    total_bytes: self.total,
                    truncated: true,
                    omitted_bytes: omitted,
                }
            }
        }
    }

    /// Consume the sink and return the retained bytes.
    pub fn finish(self) -> Output {
        match self.state {
            State::Buffered(buffer) => Output {
                data: buffer,
                total_bytes: self.total,
                truncated: false,
                omitted_bytes: 0,
            },
            State::Truncated { head, tail } => {
                let kept = head.len().saturating_add(tail.len()) as u64;
                let omitted = self.total.saturating_sub(kept);
                Output {
                    data: render_truncated(&head, &tail, omitted),
                    total_bytes: self.total,
                    truncated: true,
                    omitted_bytes: omitted,
                }
            }
        }
    }
}

fn render_truncated(head: &[u8], tail: &VecDeque<u8>, omitted: u64) -> Vec<u8> {
    let mut marker = String::with_capacity(48);
    if !head.is_empty() && head.last() != Some(&b'\n') {
        marker.push('\n');
    }
    marker.push_str(MARKER_PREFIX);
    marker.push_str(&omitted.to_string());
    marker.push_str(MARKER_SUFFIX);
    let mut data = Vec::with_capacity(head.len() + marker.len() + tail.len());
    data.extend_from_slice(head);
    data.extend_from_slice(marker.as_bytes());
    data.extend(tail.iter().copied());
    data
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repeated(len: usize) -> Vec<u8> {
        (0..len).map(|index| (index % 251) as u8).collect()
    }

    #[test]
    fn output_below_the_budget_is_untouched() {
        let mut sink = OutputSink::new(100);
        sink.write(b"hello ");
        sink.write_str("world");
        let output = sink.finish();
        assert_eq!(output.data, b"hello world");
        assert_eq!(output.total_bytes, 11);
        assert!(!output.truncated);
        assert_eq!(output.omitted_bytes, 0);
    }

    #[test]
    fn output_at_the_budget_is_untouched() {
        let mut sink = OutputSink::new(10);
        sink.write(&repeated(10));
        let output = sink.finish();
        assert_eq!(output.data, repeated(10));
        assert!(!output.truncated);
        assert_eq!(output.total_bytes, 10);
    }

    #[test]
    fn truncation_keeps_sixty_forty_and_counts_every_byte() {
        let data = repeated(1000);
        let mut sink = OutputSink::new(100);
        sink.write(&data);
        let output = sink.finish();
        assert!(output.truncated);
        assert_eq!(output.total_bytes, 1000);
        assert_eq!(output.omitted_bytes, 900);
        assert!(output.data.starts_with(&data[..60]));
        assert!(output.data.ends_with(&data[960..]));
        let marker = String::from_utf8_lossy(&output.data[60..output.data.len() - 40]);
        assert!(marker.contains("truncated 900 bytes"));
        assert_eq!(output.data.len(), 60 + marker.len() + 40);
    }

    #[test]
    fn truncation_is_chunk_boundary_independent() {
        let data = repeated(1000);
        let expected = {
            let mut sink = OutputSink::new(100);
            sink.write(&data);
            sink.finish()
        };
        let mut sink = OutputSink::new(100);
        for chunk in data.chunks(37) {
            sink.write(chunk);
        }
        assert_eq!(sink.finish(), expected);
    }

    #[test]
    fn one_byte_over_the_budget_keeps_head_and_tail() {
        let data = repeated(101);
        let mut sink = OutputSink::new(100);
        sink.write(&data);
        let output = sink.finish();
        assert!(output.truncated);
        assert_eq!(output.total_bytes, 101);
        assert_eq!(output.omitted_bytes, 1);
        assert!(output.data.starts_with(&data[..60]));
        assert!(output.data.ends_with(&data[61..]));
    }

    #[test]
    fn zero_budget_reports_every_byte_omitted() {
        let mut sink = OutputSink::new(0);
        sink.write(b"abc");
        let output = sink.finish();
        assert!(output.truncated);
        assert_eq!(output.total_bytes, 3);
        assert_eq!(output.omitted_bytes, 3);
        assert!(String::from_utf8_lossy(&output.data).contains("truncated 3 bytes"));
    }

    #[test]
    fn capture_does_not_consume_the_sink() {
        let mut sink = OutputSink::new(4);
        sink.write(b"abcdefgh");
        let first = sink.capture();
        let second = sink.capture();
        assert_eq!(first, second);
        assert_eq!(sink.total_bytes(), 8);
        assert_eq!(sink.finish(), first);
    }
}
