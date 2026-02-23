use std::env;
use std::path::PathBuf;

use trading_core::engine::{CoreConfig, TradingCore};
use trading_core::leader::FencingCoordinator;
use trading_core::snapshot::Snapshot;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = env::args().skip(1);
    let Some(cmd) = args.next() else {
        print_usage();
        std::process::exit(2);
    };

    match cmd.as_str() {
        "create" => run_create(args.collect())?,
        "verify" => run_verify(args.collect())?,
        _ => {
            eprintln!("unknown subcommand: {cmd}");
            print_usage();
            std::process::exit(2);
        }
    }

    Ok(())
}

fn run_create(args: Vec<String>) -> Result<(), Box<dyn std::error::Error>> {
    let opts = parse_common_args(args)?;
    let snapshot = opts
        .snapshot
        .clone()
        .ok_or_else(|| "create requires --snapshot <path>".to_string())?;

    let cfg = build_config(&opts);
    let core = TradingCore::new(cfg, FencingCoordinator::new())?;
    core.take_snapshot(&snapshot)?;

    let loaded = Snapshot::load(&snapshot)?;
    println!("snapshot_tool_action=create");
    println!("snapshot_tool_snapshot={}", snapshot.display());
    println!("snapshot_tool_seq={}", loaded.last_seq);
    println!("snapshot_tool_state_hash={}", loaded.state_hash);
    println!("snapshot_tool_mode={:?}", loaded.symbol_mode);
    Ok(())
}

fn run_verify(args: Vec<String>) -> Result<(), Box<dyn std::error::Error>> {
    let opts = parse_common_args(args)?;
    let snapshot = opts
        .snapshot
        .clone()
        .ok_or_else(|| "verify requires --snapshot <path>".to_string())?;
    let snap = Snapshot::load(&snapshot)?;

    let cfg = build_config(&opts);
    let baseline = TradingCore::new(cfg.clone(), FencingCoordinator::new())?;
    let baseline_seq = baseline.current_seq();
    let baseline_hash = baseline.last_state_hash().to_string();
    let baseline_mode = baseline.symbol_mode();

    let mut rehearse = TradingCore::new(cfg, FencingCoordinator::new())?;
    rehearse.recover_from_snapshot(&snapshot)?;
    let rehearsal_seq = rehearse.current_seq();
    let rehearsal_hash = rehearse.last_state_hash().to_string();
    let rehearsal_mode = rehearse.symbol_mode();

    let snapshot_not_future = snap.last_seq <= baseline_seq;
    let match_seq = baseline_seq == rehearsal_seq;
    let match_hash = baseline_hash == rehearsal_hash;
    let match_mode = baseline_mode == rehearsal_mode;
    let ok = snapshot_not_future && match_seq && match_hash && match_mode;

    println!("snapshot_tool_action=verify");
    println!("snapshot_tool_snapshot={}", snapshot.display());
    println!("snapshot_tool_snapshot_seq={}", snap.last_seq);
    println!("snapshot_tool_snapshot_hash={}", snap.state_hash);
    println!("snapshot_tool_baseline_seq={}", baseline_seq);
    println!("snapshot_tool_baseline_hash={}", baseline_hash);
    println!("snapshot_tool_baseline_mode={:?}", baseline_mode);
    println!("snapshot_tool_rehearsal_seq={}", rehearsal_seq);
    println!("snapshot_tool_rehearsal_hash={}", rehearsal_hash);
    println!("snapshot_tool_rehearsal_mode={:?}", rehearsal_mode);
    println!(
        "snapshot_tool_snapshot_not_future={}",
        bool_str(snapshot_not_future)
    );
    println!("snapshot_tool_match_seq={}", bool_str(match_seq));
    println!("snapshot_tool_match_hash={}", bool_str(match_hash));
    println!("snapshot_tool_match_mode={}", bool_str(match_mode));
    println!("snapshot_tool_ok={}", bool_str(ok));

    if ok {
        Ok(())
    } else {
        Err("snapshot verification failed".into())
    }
}

fn bool_str(v: bool) -> &'static str {
    if v {
        "true"
    } else {
        "false"
    }
}

#[derive(Debug, Clone)]
struct SnapshotToolOptions {
    symbol: String,
    wal_dir: PathBuf,
    outbox_dir: PathBuf,
    snapshot: Option<PathBuf>,
}

fn parse_common_args(args: Vec<String>) -> Result<SnapshotToolOptions, Box<dyn std::error::Error>> {
    let mut symbol = "BTC-KRW".to_string();
    let mut wal_dir = PathBuf::from("/tmp/trading-core/wal");
    let mut outbox_dir = PathBuf::from("/tmp/trading-core/outbox");
    let mut snapshot: Option<PathBuf> = None;

    let mut i = 0;
    while i < args.len() {
        let flag = &args[i];
        let next = |idx: usize, name: &str| -> Result<String, Box<dyn std::error::Error>> {
            args.get(idx + 1)
                .cloned()
                .ok_or_else(|| format!("{name} requires value").into())
        };
        match flag.as_str() {
            "--symbol" => {
                symbol = next(i, "--symbol")?;
                i += 2;
            }
            "--wal-dir" => {
                wal_dir = PathBuf::from(next(i, "--wal-dir")?);
                i += 2;
            }
            "--outbox-dir" => {
                outbox_dir = PathBuf::from(next(i, "--outbox-dir")?);
                i += 2;
            }
            "--snapshot" => {
                snapshot = Some(PathBuf::from(next(i, "--snapshot")?));
                i += 2;
            }
            _ => return Err(format!("unknown flag: {flag}").into()),
        }
    }

    Ok(SnapshotToolOptions {
        symbol,
        wal_dir,
        outbox_dir,
        snapshot,
    })
}

fn build_config(opts: &SnapshotToolOptions) -> CoreConfig {
    let mut cfg = CoreConfig::default();
    cfg.symbol = opts.symbol.clone();
    cfg.wal_dir = opts.wal_dir.clone();
    cfg.outbox_dir = opts.outbox_dir.clone();
    cfg
}

fn print_usage() {
    eprintln!("snapshot-tool usage:");
    eprintln!("  snapshot-tool create --snapshot <path> [--symbol <sym>] [--wal-dir <dir>] [--outbox-dir <dir>]");
    eprintln!("  snapshot-tool verify --snapshot <path> [--symbol <sym>] [--wal-dir <dir>] [--outbox-dir <dir>]");
}
