use crate::model::CoreEvent;
use crc32fast::Hasher;
use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, Read, Write};
use std::path::{Path, PathBuf};

const SEGMENT_MAGIC: &[u8] = b"XWALv1\0";

#[derive(Debug, thiserror::Error)]
pub enum WalError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("serialize: {0}")]
    Serialize(#[from] serde_json::Error),
    #[error("crc mismatch")]
    CrcMismatch,
    #[error("invalid segment magic")]
    InvalidMagic,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WalRecord {
    pub seq: u64,
    pub command_id: String,
    pub symbol: String,
    pub events: Vec<CoreEvent>,
    pub state_hash: String,
    pub fencing_token: u64,
}

#[derive(Debug)]
pub struct Wal {
    dir: PathBuf,
    max_segment_bytes: u64,
    current_segment: u64,
    current_size: u64,
    current_file: File,
}

impl Wal {
    pub fn open<P: AsRef<Path>>(dir: P, max_segment_bytes: u64) -> Result<Self, WalError> {
        fs::create_dir_all(&dir)?;
        let dir = dir.as_ref().to_path_buf();
        let current_segment = Self::latest_segment(&dir)?;
        let segment_path = segment_path(&dir, current_segment);
        let current_file = ensure_segment_file(&segment_path)?;
        let current_size = current_file.metadata()?.len();

        Ok(Self {
            dir,
            max_segment_bytes,
            current_segment,
            current_size,
            current_file,
        })
    }

    pub fn append(&mut self, record: &WalRecord) -> Result<(), WalError> {
        let payload = serde_json::to_vec(record)?;
        let mut hasher = Hasher::new();
        hasher.update(&payload);
        let crc = hasher.finalize();

        let mut frame = Vec::with_capacity(8 + payload.len());
        frame.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        frame.extend_from_slice(&payload);
        frame.extend_from_slice(&crc.to_le_bytes());

        if self.current_size + frame.len() as u64 > self.max_segment_bytes {
            self.rotate()?;
        }

        self.current_file.write_all(&frame)?;
        self.current_file.sync_data()?;
        self.current_size += frame.len() as u64;
        Ok(())
    }

    pub fn replay_all(&self) -> Result<Vec<WalRecord>, WalError> {
        let mut files = segment_files(&self.dir)?;
        files.sort();

        let mut out = Vec::new();
        for file in files {
            let mut reader = BufReader::new(File::open(&file)?);
            let mut magic = vec![0_u8; SEGMENT_MAGIC.len()];
            reader.read_exact(&mut magic)?;
            if magic != SEGMENT_MAGIC {
                return Err(WalError::InvalidMagic);
            }

            loop {
                let mut len_buf = [0_u8; 4];
                match reader.read_exact(&mut len_buf) {
                    Ok(()) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
                    Err(e) => return Err(WalError::Io(e)),
                }
                let len = u32::from_le_bytes(len_buf) as usize;
                let mut payload = vec![0_u8; len];
                reader.read_exact(&mut payload)?;
                let mut crc_buf = [0_u8; 4];
                reader.read_exact(&mut crc_buf)?;
                let expected_crc = u32::from_le_bytes(crc_buf);

                let mut hasher = Hasher::new();
                hasher.update(&payload);
                let actual_crc = hasher.finalize();
                if actual_crc != expected_crc {
                    return Err(WalError::CrcMismatch);
                }

                let record: WalRecord = serde_json::from_slice(&payload)?;
                out.push(record);
            }
        }

        Ok(out)
    }

    pub fn replay_from_seq(&self, seq: u64) -> Result<Vec<WalRecord>, WalError> {
        Ok(self
            .replay_all()?
            .into_iter()
            .filter(|r| r.seq >= seq)
            .collect())
    }

    pub fn segment_dir(&self) -> &Path {
        &self.dir
    }

    fn rotate(&mut self) -> Result<(), WalError> {
        self.current_segment += 1;
        let path = segment_path(&self.dir, self.current_segment);
        self.current_file = ensure_segment_file(&path)?;
        self.current_size = self.current_file.metadata()?.len();
        Ok(())
    }

    fn latest_segment(dir: &Path) -> Result<u64, WalError> {
        let files = segment_files(dir)?;
        let mut latest = 1;
        for file in files {
            if let Some(name) = file.file_name().and_then(|n| n.to_str()) {
                if let Some(idx) = name
                    .strip_prefix("segment-")
                    .and_then(|v| v.strip_suffix(".wal"))
                    .and_then(|v| v.parse::<u64>().ok())
                {
                    latest = latest.max(idx);
                }
            }
        }
        Ok(latest)
    }
}

fn ensure_segment_file(path: &Path) -> Result<File, WalError> {
    let exists = path.exists();
    let mut file = OpenOptions::new().create(true).append(true).read(true).open(path)?;
    if !exists {
        file.write_all(SEGMENT_MAGIC)?;
        file.sync_data()?;
    }
    Ok(file)
}

fn segment_files(dir: &Path) -> Result<Vec<PathBuf>, WalError> {
    let mut out = Vec::new();
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path
            .file_name()
            .and_then(|v| v.to_str())
            .map(|name| name.starts_with("segment-") && name.ends_with(".wal"))
            .unwrap_or(false)
        {
            out.push(path);
        }
    }
    Ok(out)
}

fn segment_path(dir: &Path, idx: u64) -> PathBuf {
    dir.join(format!("segment-{idx:06}.wal"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{build_envelope, CoreEvent, EngineCheckpointEvent};
    use tempfile::TempDir;

    fn sample_record(seq: u64) -> WalRecord {
        WalRecord {
            seq,
            command_id: format!("cmd-{seq}"),
            symbol: "BTC-KRW".to_string(),
            events: vec![CoreEvent::EngineCheckpoint(EngineCheckpointEvent {
                envelope: build_envelope("BTC-KRW", seq, "EngineCheckpoint", "corr", "cause"),
                state_hash: format!("hash-{seq}"),
            })],
            state_hash: format!("hash-{seq}"),
            fencing_token: 1,
        }
    }

    #[test]
    fn append_and_replay() {
        let dir = TempDir::new().unwrap();
        let mut wal = Wal::open(dir.path(), 1024 * 1024).unwrap();
        wal.append(&sample_record(1)).unwrap();
        wal.append(&sample_record(2)).unwrap();

        let replayed = wal.replay_all().unwrap();
        assert_eq!(replayed.len(), 2);
        assert_eq!(replayed[1].seq, 2);
    }

    #[test]
    fn corruption_is_detected() {
        let dir = TempDir::new().unwrap();
        let mut wal = Wal::open(dir.path(), 1024 * 1024).unwrap();
        wal.append(&sample_record(1)).unwrap();

        let mut files = std::fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().path())
            .collect::<Vec<_>>();
        files.sort();
        let file_path = files.into_iter().find(|p| p.to_string_lossy().ends_with(".wal")).unwrap();
        let mut bytes = std::fs::read(&file_path).unwrap();
        let last = bytes.len() - 1;
        bytes[last] ^= 0xAA;
        std::fs::write(file_path, bytes).unwrap();

        let err = Wal::open(dir.path(), 1024 * 1024).unwrap().replay_all().unwrap_err();
        assert!(matches!(err, WalError::CrcMismatch));
    }
}
