use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-env-changed=HYDRA_SRT_VERSION");
    let version = env::var("HYDRA_SRT_VERSION")
        .ok()
        .filter(|value| !value.is_empty())
        .or_else(|| {
            let manifest_dir = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR")?);
            let version_path = manifest_dir.join("../../../VERSION");
            println!("cargo:rerun-if-changed={}", version_path.display());
            fs::read_to_string(version_path)
                .ok()
                .map(|value| value.trim().to_owned())
                .filter(|value| !value.is_empty())
        })
        .unwrap_or_else(|| {
            env::var("CARGO_PKG_VERSION").expect("Cargo must provide a package version")
        });

    println!("cargo:rustc-env=HYDRA_SRT_VERSION={version}");
}
