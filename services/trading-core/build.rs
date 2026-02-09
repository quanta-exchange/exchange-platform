fn main() {
    tonic_build::configure()
        .build_server(true)
        .build_client(false)
        .compile(
            &[
                "../../contracts/proto/exchange/v1/trading.proto",
                "../../contracts/proto/exchange/v1/common.proto",
            ],
            &["../../contracts/proto"],
        )
        .expect("failed to compile protos");
}
