use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

#[derive(Debug, thiserror::Error)]
pub enum LeaderError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

#[derive(Debug, Clone)]
pub struct FencingCoordinator {
    token: Arc<AtomicU64>,
}

impl Default for FencingCoordinator {
    fn default() -> Self {
        Self::new()
    }
}

impl FencingCoordinator {
    pub fn new() -> Self {
        Self {
            token: Arc::new(AtomicU64::new(0)),
        }
    }

    pub fn acquire(&self) -> u64 {
        self.token.fetch_add(1, Ordering::SeqCst) + 1
    }

    pub fn current(&self) -> u64 {
        self.token.load(Ordering::SeqCst)
    }

    pub fn is_valid(&self, token: u64) -> bool {
        self.current() == token
    }
}

#[derive(Debug)]
pub struct FileLease {
    path: PathBuf,
}

impl FileLease {
    pub fn open<P: AsRef<Path>>(path: P) -> Result<Self, LeaderError> {
        let path = path.as_ref().to_path_buf();
        if !path.exists() {
            fs::write(&path, b"0")?;
        }
        Ok(Self { path })
    }

    pub fn acquire(&self) -> Result<u64, LeaderError> {
        let current = fs::read_to_string(&self.path)?
            .trim()
            .parse::<u64>()
            .unwrap_or(0);
        let next = current + 1;
        fs::write(&self.path, next.to_string())?;
        Ok(next)
    }

    pub fn current(&self) -> Result<u64, LeaderError> {
        Ok(fs::read_to_string(&self.path)?
            .trim()
            .parse::<u64>()
            .unwrap_or(0))
    }
}
