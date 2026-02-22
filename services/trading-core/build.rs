use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let mut includes: Vec<PathBuf> = vec![PathBuf::from("../../contracts/proto")];

    if let Ok(custom_include) = env::var("PROTOC_INCLUDE") {
        let trimmed = custom_include.trim();
        if !trimmed.is_empty() {
            includes.push(PathBuf::from(trimmed));
        }
    }

    for candidate in ["/opt/homebrew/include", "/usr/local/include"] {
        let path = PathBuf::from(candidate);
        if path.join("google/protobuf/timestamp.proto").exists() {
            includes.push(path);
        }
    }

    if let Ok(output) = Command::new("brew").args(["--prefix", "protobuf"]).output() {
        if output.status.success() {
            let prefix = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !prefix.is_empty() {
                let include = PathBuf::from(prefix).join("include");
                if include.join("google/protobuf/timestamp.proto").exists() {
                    includes.push(include);
                }
            }
        }
    }

    tonic_build::configure()
        .build_server(true)
        .build_client(false)
        .compile_protos(
            &[
                "../../contracts/proto/exchange/v1/trading.proto",
                "../../contracts/proto/exchange/v1/common.proto",
            ],
            &includes,
        )
        .unwrap_or_else(|err| {
            panic!(
                "failed to compile protos: {err}. Hint: install protobuf via `brew install protobuf` and ensure google/protobuf/*.proto is under /opt/homebrew/include or /usr/local/include, or set PROTOC_INCLUDE."
            )
        });
}
