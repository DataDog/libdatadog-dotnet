# Guide for Coding Agents

Essential context for AI coding agents working on `libdatadog-dotnet`.

## Repository Purpose

A thin packaging wrapper around the official [libdatadog](https://github.com/DataDog/libdatadog) project. We produce prebuilt binaries (8 platforms) tailored for the .NET tracer's needs — fewer features → smaller artifacts → independent release cadence from upstream libdatadog.

## Build Approach

We **don't** orchestrate cargo + cbindgen ourselves. We install libdatadog's own `release` binary (from its `builder` crate) and let it produce the package:

```
cargo install \
    --git https://github.com/DataDog/libdatadog \
    --tag "v${LIBDATADOG_VERSION}" \
    --bin release \
    --no-default-features \
    --features "profiling,crashtracker,symbolizer,library-config" \
    builder
release --out <package-dir> --target <triple>
```

The builder handles the FFI cargo build, header generation (cbindgen + dedup), library stripping, and packaging. We just orchestrate per-platform Docker containers and (on Windows) reshape the resulting zip to match what dd-trace-dotnet expects.

## Version Pinning

The libdatadog version is in a single file: `LIBDATADOG_VERSION` (no `v` prefix, e.g. `30.0.0`).

⚠️ **It must match what dd-trace-dotnet's `build/cmake/FindLibdatadog.cmake` targets.** Mismatches surface in the tracer build as cryptic C++ errors like `error C2061: 'ddog_prof_SampleType'` — these are upstream API drifts between tags. Always check `gh api repos/DataDog/dd-trace-dotnet/contents/build/cmake/FindLibdatadog.cmake?ref=master --jq '.content' | base64 -d | grep LIBDATADOG_VERSION` before bumping.

## Per-Platform Build Setup

| Target | Where build runs | Rust source | Why |
|---|---|---|---|
| `x86_64-pc-windows-msvc` (x64-windows) | Native runner | Runner-installed | No GLIBC concern |
| `i686-pc-windows-msvc` (x86-windows) | Native runner | Runner-installed | Same |
| `x86_64-apple-darwin` | Native runner | Runner-installed | Same |
| `aarch64-apple-darwin` | Native runner | Runner-installed | Same |
| `x86_64-unknown-linux-gnu` | `cross-rs/x86_64-unknown-linux-gnu:main-centos` Docker | Host's `~/.cargo` mounted | GLIBC 2.17 baseline; rustup's gnu Rust is also linked against 2.17 |
| `aarch64-unknown-linux-gnu` | `quay.io/pypa/manylinux2014_aarch64`, **QEMU `--platform linux/arm64`** | Installed in image | `libdd-libunwind-sys` can't cross-compile (see Gotchas); manylinux2014 is the only CentOS 7 aarch64 with devtoolset |
| `x86_64-unknown-linux-musl` | `rust:alpine` Docker | Image-bundled | Native, no QEMU |
| `aarch64-unknown-linux-musl` | `rust:alpine`, **QEMU `--platform linux/arm64`** | Image-bundled | Same reason as aarch64-gnu |

`build.sh` has two helpers:
- `docker_run_gnu` — for x86_64-gnu only. Mounts the host's Rust toolchain into the container.
- `docker_run_musl` — for both musl variants **and** aarch64-gnu (despite the name). Image provides Rust; we mount only the cargo registry/git caches for download speed.

## Windows Zip Reconstruction

The builder crate produces a flat `lib/datadog_profiling.{dll,lib,pdb}` layout on Windows. dd-trace-dotnet's `vcpkg_local_ports/libdatadog/portfile.cmake` expects the legacy structure with `_ffi`-suffixed filenames:

```
release/dynamic/datadog_profiling_ffi.{dll,lib,pdb}   (DLL + import library)
release/static/datadog_profiling_ffi.lib              (static archive)
debug/dynamic/datadog_profiling_ffi.{dll,lib,pdb}
debug/static/datadog_profiling_ffi.lib
include/datadog/…  cmake/DatadogConfig.cmake  LICENSE  NOTICE
```

So `build.ps1`:
1. Runs the builder twice — once with `PROFILE=release`, once with `PROFILE=debug`.
2. Pulls headers / license / cmake from the release-builder output.
3. Pulls `.dll`, `.dll.lib`, `.lib` (static), `.pdb` **directly from `target/$Target/{release,debug}/`** because cargo there has the original `_ffi` names AND the `.dll.lib` import library that the builder doesn't copy.
4. Renames `.dll.lib` → `.lib` in each `dynamic/` slot.

## Gotchas

1. **`libdd-libunwind-sys` (new in libdatadog v30)** vendors libunwind 1.8 and runs `autoreconf -i` + `./configure` + `make` in its `build.rs`. Needs `autoconf`/`automake`/`libtool`/`m4` + GCC ≥ 4.9 (for `<stdatomic.h>`). And its build.rs has **no cross-compile wiring** — no `--host=`, no `CC=` — so it can only be built natively on the target arch. That's why aarch64-gnu must run under QEMU even though we'd love to cross-compile from x86_64.

2. **CentOS 7 + devtoolset-10**: CentOS 7's stock GCC is 4.8.5, no `stdatomic.h`. `Dockerfile.centos` installs `devtoolset-10` from SCL. CentOS 7's SCL was *never* published for aarch64, which is why aarch64-gnu uses `manylinux2014_aarch64` instead — pypa pre-installs devtoolset-10 there.

3. **CentOS 7 EOL repo rewrite**: all `mirror.centos.org` URLs are gone. `Dockerfile.centos` rewrites them to `vault.centos.org` *twice* — once for the base repos, then again after `centos-release-scl` drops new files pointing at the dead mirror.

4. **musl `-crt-static`**: the builder's `arch/musl.rs` sets RUSTFLAGS without `-C target-feature=-crt-static`, which breaks `cdylib` (musl defaults to crt-static). Our `docker_run_musl` injects it via `CARGO_ENCODED_RUSTFLAGS` (`\x1f`-separated, higher priority than the builder's `RUSTFLAGS` env).

5. **cmake-rs needs cargo build-script env on macOS**: the builder calls `cmake::Config::build()` for the crashtracker C++ receiver outside a cargo build-script context. cmake-rs / cc-rs read `HOST` / `OUT_DIR` / `OPT_LEVEL` / `DEBUG` / `NUM_JOBS`. The macOS branch of `build.sh` sets all of them; missing any one panics with `environment variable 'X' not defined`. (Windows doesn't hit this — `BUILD_CRASHTRACKER = false` in the builder's `arch/windows.rs`.)

6. **Toolchain pinned to upstream libdatadog's**: Rust `1.87.0` (matches libdatadog's workspace `rust-version`) and macOS runners `macos-14` / `macos-14-large` (Sonoma, matches libdatadog's libddprof-build pipeline). When upstream libdatadog bumps its MSRV or its macOS build version, update both here — building with a different toolchain than upstream can introduce subtle codegen / ABI differences. The pin lives in: `build-platform.yml` (Setup Rust step + matrix `os:` fields), `Dockerfile.centos-aarch64` (rustup-init `--default-toolchain`), and `Dockerfile.musl-*` (`ARG RUST_VERSION` consumed by the rustup install).

7. **Release workflow needs `RELEASE_TOKEN`**: the repo's ref-creation ruleset blocks `GITHUB_TOKEN` from creating new tags, so `actions/github-script` in `release.yml` uses `github-token: ${{ secrets.RELEASE_TOKEN }}` (a fine-grained PAT with Contents: Read+Write, from a user on the ruleset's bypass list). Sometimes this secret needs rotating — symptom is the release job failing with `Cannot create ref due to creations being restricted` followed by `Published releases must have a valid tag`.

## File Layout

```
libdatadog-dotnet/
├── LIBDATADOG_VERSION              # Pinned upstream libdatadog tag (no "v")
├── build.sh                        # Linux/macOS — docker orchestration + macOS native
├── build.ps1                       # Windows — runs builder twice, re-assembles legacy zip
├── tools/docker/
│   ├── Dockerfile.centos           # x86_64-gnu: cross-rs centos7 + devtoolset-10
│   ├── Dockerfile.centos-aarch64   # aarch64-gnu: manylinux2014_aarch64 + rustup
│   ├── Dockerfile.musl-x64         # x86_64-musl: alpine:3.17 + rustup
│   └── Dockerfile.musl-aarch64     # aarch64-musl: alpine:3.18 + rustup
└── .github/workflows/
    ├── build-platform.yml          # Reusable matrix workflow (8 platforms)
    ├── build.yml                   # CI on PRs + push to main
    └── release.yml                 # Manual dispatch → builds + GitHub release
```

## Common Tasks

**Update libdatadog version**: edit `LIBDATADOG_VERSION`. First confirm dd-trace-dotnet master's `FindLibdatadog.cmake` targets the same version.

**Change feature set**: edit the `FEATURES` default in `build.sh`, the `Features` default in `build.ps1`, and the `features` input default in `build-platform.yml` / `release.yml` / `build.yml`. Feature names are the builder crate's high-level features (`profiling`, `crashtracker`, `data-pipeline`, `symbolizer`, `library-config`, `log`, `telemetry`, `ddsketch`, `ffe`), not the underlying cargo features.

**Add a platform**: matrix entry in `build-platform.yml`; if it's not host-native, either add a Dockerfile + dispatch case in `build.sh`, or use QEMU. Update the release archive list in `release.yml`.

**Cut a release**: Actions → Release → Run workflow. Default `version_increment: patch` is usually right. The job tag + publish step needs `RELEASE_TOKEN` (see gotcha #6).

## Workflow Files

- **`build-platform.yml`** — reusable matrix workflow. Steps: checkout → setup Rust → cache `~/.cargo/{registry,git}` → setup QEMU (only for aarch64 Linux targets) → run `build.{sh,ps1}` → verify output → upload artifact.
- **`build.yml`** — calls `build-platform.yml` on PR / push to main with `verify_artifacts: true`.
- **`release.yml`** — manual dispatch. Builds all 8 platforms (no verify), archives them, computes SHA256 + SHA512, creates a GitHub release with assets and a checksums-in-the-body note. Uses `RELEASE_TOKEN`.

## Testing Locally

```bash
# Linux GNU (x86_64), full clean build
./build.sh --platform x86_64-unknown-linux-gnu --clean

# Windows
./build.ps1 -Platform x64-windows -Clean

# macOS
./build.sh --platform aarch64-apple-darwin --clean
```

Output lands in `output/libdatadog-<platform>/`. For aarch64 Linux targets you need Docker Desktop with buildx + QEMU (`docker buildx ls` should show `linux/arm64` under available platforms).

## Recent Changes (Reverse Chronological)

- **2026-05**: aarch64-gnu switched from cross-rs cross-compile to QEMU + native manylinux2014_aarch64. Necessary because libdd-libunwind-sys (v30) can't be cross-compiled.
- **2026-05**: Bumped to libdatadog v30 to match dd-trace-dotnet's API expectations.
- **2026-05**: `build.ps1` rewritten to produce the legacy Windows zip layout (release+debug × dynamic+static) for dd-trace-dotnet portfile compatibility.
- **2026-04**: Replaced manual `cargo rustc` + external cbindgen + `dedup_headers` orchestration with libdatadog's `release` builder binary. Cross.toml deleted. ~600 net lines removed from `build.sh` / `build.ps1`.
- **2026-05**: Pinned Rust to `1.84.1` (libdatadog's MSRV) and macOS runners to `macos-14` (Sonoma) to match upstream libdatadog's build toolchain.
