use crate::model::CoreEvent;
use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

#[derive(Debug, thiserror::Error)]
pub enum OutboxError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("serialize: {0}")]
    Serialize(#[from] serde_json::Error),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OutboxRecord {
    pub seq: u64,
    pub events: Vec<CoreEvent>,
}

pub trait EventSink {
    fn publish(&mut self, event: &CoreEvent) -> Result<(), String>;
}

#[derive(Debug)]
pub struct Outbox {
    records_path: PathBuf,
    cursor_path: PathBuf,
}

impl Outbox {
    pub fn open<P: AsRef<Path>>(dir: P) -> Result<Self, OutboxError> {
        fs::create_dir_all(&dir)?;
        let records_path = dir.as_ref().join("outbox.jsonl");
        let cursor_path = dir.as_ref().join("last_published_seq.txt");
        if !records_path.exists() {
            let _ = OpenOptions::new()
                .create(true)
                .append(true)
                .open(&records_path)?;
        }
        if !cursor_path.exists() {
            fs::write(&cursor_path, b"0")?;
        }
        Ok(Self {
            records_path,
            cursor_path,
        })
    }

    pub fn enqueue(&self, seq: u64, events: &[CoreEvent]) -> Result<(), OutboxError> {
        let record = OutboxRecord {
            seq,
            events: events.to_vec(),
        };
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.records_path)?;
        file.write_all(serde_json::to_string(&record)?.as_bytes())?;
        file.write_all(b"\n")?;
        file.sync_data()?;
        Ok(())
    }

    pub fn last_published_seq(&self) -> Result<u64, OutboxError> {
        let raw = fs::read_to_string(&self.cursor_path)?;
        Ok(raw.trim().parse::<u64>().unwrap_or(0))
    }

    pub fn set_last_published_seq(&self, seq: u64) -> Result<(), OutboxError> {
        fs::write(&self.cursor_path, seq.to_string())?;
        Ok(())
    }

    pub fn pending_records(&self) -> Result<Vec<OutboxRecord>, OutboxError> {
        let last = self.last_published_seq()?;
        let file = OpenOptions::new().read(true).open(&self.records_path)?;
        let reader = BufReader::new(file);
        let mut out = Vec::new();
        for line in reader.lines() {
            let line = line?;
            if line.trim().is_empty() {
                continue;
            }
            let record: OutboxRecord = serde_json::from_str(&line)?;
            if record.seq > last {
                out.push(record);
            }
        }
        out.sort_by_key(|r| r.seq);
        Ok(out)
    }

    pub fn publish_pending<S: EventSink + ?Sized>(
        &self,
        sink: &mut S,
        retries: usize,
    ) -> Result<(), OutboxError> {
        let records = self.pending_records()?;
        for record in records {
            let mut published_all = true;
            for event in &record.events {
                let mut attempts = 0;
                loop {
                    match sink.publish(event) {
                        Ok(()) => break,
                        Err(_) if attempts < retries => {
                            attempts += 1;
                            let backoff = 2_u64.saturating_pow(attempts as u32).min(64);
                            thread::sleep(Duration::from_millis(backoff));
                        }
                        Err(_) => {
                            published_all = false;
                            break;
                        }
                    }
                }
                if !published_all {
                    break;
                }
            }
            if !published_all {
                break;
            }
            self.set_last_published_seq(record.seq)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{build_envelope, CoreEvent, EngineCheckpointEvent};
    use tempfile::TempDir;

    #[derive(Default)]
    struct Sink {
        fail_first: usize,
        calls: usize,
        published: Vec<String>,
    }

    impl EventSink for Sink {
        fn publish(&mut self, event: &CoreEvent) -> Result<(), String> {
            self.calls += 1;
            if self.calls <= self.fail_first {
                return Err("temporary".to_string());
            }
            self.published.push(event.envelope().event_id.clone());
            Ok(())
        }
    }

    fn event(seq: u64) -> CoreEvent {
        CoreEvent::EngineCheckpoint(EngineCheckpointEvent {
            envelope: build_envelope("BTC-KRW", seq, "EngineCheckpoint", "corr", "cause"),
            state_hash: format!("hash-{seq}"),
        })
    }

    #[test]
    fn publisher_retries_and_advances_cursor() {
        let dir = TempDir::new().unwrap();
        let outbox = Outbox::open(dir.path()).unwrap();
        outbox.enqueue(1, &[event(1)]).unwrap();
        outbox.enqueue(2, &[event(2)]).unwrap();

        let mut sink = Sink {
            fail_first: 1,
            ..Sink::default()
        };

        outbox.publish_pending(&mut sink, 3).unwrap();
        assert_eq!(outbox.last_published_seq().unwrap(), 2);
        assert_eq!(sink.published.len(), 2);
    }

    #[test]
    fn restart_continues_from_cursor() {
        let dir = TempDir::new().unwrap();
        let outbox = Outbox::open(dir.path()).unwrap();
        outbox.enqueue(1, &[event(1)]).unwrap();
        outbox.enqueue(2, &[event(2)]).unwrap();

        outbox.set_last_published_seq(1).unwrap();

        let reloaded = Outbox::open(dir.path()).unwrap();
        let pending = reloaded.pending_records().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].seq, 2);
    }
}
