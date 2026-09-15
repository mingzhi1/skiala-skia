# Skiala Windows Skia Cache Builder

This repository builds reproducible `x86_64-pc-windows-msvc` Skia binary caches with the static MSVC runtime (`/MT`). Upstream `rust-skia` Windows cache releases use `/MD`, so they cannot be used by Skiala's statically packaged Windows process benchmarks.

## Cache Profiles

| Profile | rust-skia | Native feature key | Consumer |
| --- | --- | --- | --- |
| `skiala-0.153.3-cpu` | `0.153.3` | `textlayout-static` | Minimal Skia CPU raster and future Skiala CPU renderer |
| `slint-0.99.0-opengl` | `0.99.0` | `d3d-gl-jpegd-jpege-pdf-textlayout-static` | Slint 1.17.1 Skia OpenGL startup reference |

The versions and feature sets are intentionally independent. A cache is valid only for the exact rust-skia source revision, target, native feature set, debug mode, and CRT mode encoded in its `key.txt`.

## CI Behavior

The Windows 2022 matrix performs these steps for each profile:

1. Clones the exact upstream rust-skia tag.
2. Enables Git long-path handling and builds from short drive-root source/target paths to stay below legacy Ninja/MSVC path limits.
3. Forces a source build with `RUSTFLAGS=-C target-feature=+crt-static`.
4. Uses rust-skia's own cache exporter to produce the canonical `skia-binaries/` layout.
5. Verifies the expected cache key and checks `skia-bindings.lib` for `DEFAULTLIB:LIBCMT`.
6. Creates a `tar.gz`, then deletes the built bindings and rebuilds through `SKIA_BINARIES_URL` to validate import.
7. Uploads the archive, SHA-256 file, resolved upstream `Cargo.lock`, and toolchain metadata as a GitHub Actions artifact.

Pushes to `main` and manual dispatches retain artifacts for 30 days. A `cache-v*` tag publishes the validated files as durable GitHub Release assets.

## Run Locally

Use a Visual Studio 2022 Developer PowerShell with Rust, Git, LLVM/Clang, Python, Ninja, and `tar.exe` available:

```powershell
./scripts/build-skia-cache.ps1 -Profile skiala-0.153.3-cpu
./scripts/build-skia-cache.ps1 -Profile slint-0.99.0-opengl
```

Builds may take substantial time because `FORCE_SKIA_BUILD=1` deliberately bypasses upstream dynamic-CRT caches.

## Consume A Cache

Set the archive URL before building the matching consumer:

```powershell
$env:RUSTFLAGS = "-C target-feature=+crt-static"
$env:SKIA_BINARIES_URL = "https://github.com/OWNER/REPOSITORY/releases/download/cache-v1/skia-binaries-CACHE_KEY.tar.gz"
$env:FORCE_SKIA_BINARIES_DOWNLOAD = "1"
cargo build --release --locked --target x86_64-pc-windows-msvc
```

`SKIA_BINARIES_URL` points to one exact archive, so build the Skiala and Slint fixtures separately with their respective URLs. Do not rename or substitute an upstream `/MD` archive: mixing it with a `/MT` Rust executable violates the packaging baseline and can cross incompatible CRT allocation boundaries.

Each archive contains Skia's license as `LICENSE_SKIA`. The rust-skia release tags do not ship a directly usable workspace lockfile, so CI resolves one during the build and publishes it with its SHA-256 in metadata. Release assets should retain the archive, generated lockfile, metadata, and checksum together.
