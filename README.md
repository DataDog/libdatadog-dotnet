# libdatadog-dotnet

Prebuilt [libdatadog](https://github.com/DataDog/libdatadog) binaries packaged for the .NET tracer ([dd-trace-dotnet](https://github.com/DataDog/dd-trace-dotnet)).

## Purpose

A thin packaging layer over upstream libdatadog. Ships only the FFI components the .NET tracer needs — fewer features → smaller binaries → independent release cadence from upstream.

## Building

### Prerequisites

- Rust 1.87.0 or newer (CI pins to 1.87.0 to match libdatadog's MSRV)
- Git
- PowerShell on Windows; Bash + Docker (with buildx and QEMU for aarch64 Linux builds) elsewhere

### Local build

```bash
# Linux GNU x64
./build.sh --platform x86_64-unknown-linux-gnu --clean

# macOS arm64
./build.sh --platform aarch64-apple-darwin --clean

# Windows
./build.ps1 -Platform x64-windows -Clean
```

Output lands in `output/libdatadog-<platform>/`.

To upgrade the upstream libdatadog version, edit the `LIBDATADOG_VERSION` file (e.g. `30.0.0` — no `v` prefix). The version must match what `dd-trace-dotnet`'s `build/cmake/FindLibdatadog.cmake` targets; otherwise the tracer's C++ build fails on missing identifiers.

### Features

Built with the comma-separated feature set the .NET tracer needs (see `build.ps1` / workflow inputs):

```
profiling,crashtracker,symbolizer,library-config
```

These are the builder-crate feature flags upstream libdatadog exposes — names map to the underlying cargo features inside libdatadog. Upstream's default release additionally enables `telemetry`, `data-pipeline`, `log`, `ddsketch`, and `ffe`; we omit them, saving binary size. (`data-pipeline` and `log` were dropped once dd-trace-dotnet removed the libdatadog-based trace exporter and its logger — DataDog/dd-trace-dotnet#8703.)

## How It Works

We install libdatadog's own `release` binary (from its `builder` crate) at the pinned tag, then let it produce the package:

```
cargo install \
    --git https://github.com/DataDog/libdatadog \
    --tag "v${LIBDATADOG_VERSION}" \
    --bin release \
    --no-default-features \
    --features "<feature-list>" \
    builder
release --out <package-dir> --target <triple>
```

The builder handles the FFI cargo build, header generation (cbindgen + dedup), library stripping, and packaging.

**Windows quirk**: the builder produces a flat `lib/datadog_profiling.{dll,lib,pdb}` layout, but dd-trace-dotnet's vcpkg portfile expects the legacy `release/{dynamic,static}` + `debug/{dynamic,static}` tree with `_ffi`-suffixed filenames. `build.ps1` runs the builder twice (release + debug) and reassembles that layout from cargo's raw `target/` output.

## GLIBC Compatibility

Linux GNU builds target **GLIBC 2.17** (CentOS 7 baseline) so the resulting binaries run on older enterprise distros:

- `x86_64-unknown-linux-gnu` — built in a CentOS 7 container (`cross-rs/x86_64-unknown-linux-gnu:main-centos`) with devtoolset-10 GCC.
- `aarch64-unknown-linux-gnu` — built natively under QEMU `linux/arm64` in `quay.io/pypa/manylinux2014_aarch64` (the only CentOS 7 aarch64 image with devtoolset). aarch64-musl follows the same QEMU pattern using `alpine:3.18` + rustup.

macOS and Windows builds run natively on the appropriate GitHub-hosted runner.

## Release Process

Manual dispatch: **Actions → Release → Run workflow**. The workflow builds all 8 platforms, creates a git tag, and publishes a GitHub release with checksums.

**Prerequisites**: a `RELEASE_TOKEN` secret (a fine-grained PAT with Contents: Read+Write, issued from an account on the repo's ruleset bypass list). The default `GITHUB_TOKEN` is blocked from creating tag refs.

**Inputs**:

| Input | Default | Notes |
|---|---|---|
| `version_increment` | `patch` | `patch` / `minor` / `major` — ignored if `release_version` is set |
| `release_version` | _(empty)_ | Manual override, e.g. `v1.4.0` |

The upstream libdatadog version isn't a workflow input — it's pinned in the `LIBDATADOG_VERSION` file at the time of the release commit.

For CI runs without publishing a release, use the **Build** workflow (auto-triggered on every PR and push to `main`).

## Release Artifacts

Published as GitHub Release assets:

| Platform | Asset |
|---|---|
| Windows x64 | `libdatadog-x64-windows.zip` |
| Windows x86 | `libdatadog-x86-windows.zip` |
| Linux x64 (glibc) | `libdatadog-x86_64-unknown-linux-gnu.tar.gz` |
| Linux aarch64 (glibc) | `libdatadog-aarch64-unknown-linux-gnu.tar.gz` |
| Linux x64 (musl/Alpine) | `libdatadog-x86_64-alpine-linux-musl.tar.gz` |
| Linux aarch64 (musl/Alpine) | `libdatadog-aarch64-alpine-linux-musl.tar.gz` |
| macOS x64 (Intel) | `libdatadog-x86_64-apple-darwin.tar.gz` |
| macOS arm64 (Apple Silicon) | `libdatadog-aarch64-apple-darwin.tar.gz` |

Each release body includes SHA256 + SHA512 checksums.

For security vulnerabilities, see [SECURITY.md](SECURITY.md).

## License

Apache 2.0 — see [LICENSE](LICENSE). Packages bundle the upstream `LICENSE-3rdparty.csv` with full third-party license texts.
