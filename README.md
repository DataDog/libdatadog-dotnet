# libdatadog-dotnet

Custom libdatadog binary builds for the .NET SDK (dd-trace-dotnet).

## Purpose

This repository produces SDK-specific libdatadog binaries that include only the components required by dd-trace-dotnet. This allows the .NET team to:

- Update individual libdatadog components independently
- Reduce binary size by excluding unused components
- Avoid blocking changes caused by monolithic libdatadog releases

## Architecture

This repository builds custom libdatadog binaries from the [libdatadog repository](https://github.com/DataDog/libdatadog) at a specific version, packaging only the components needed for .NET tracing:

- Profiling FFI (`datadog-profiling-ffi`)
- Core dependencies required by the profiling component
- C/C++ header files for integration

## Building

### Prerequisites

- Rust 1.84.1 or newer
- cargo
- git
- PowerShell (Windows) or Bash (Linux/macOS)

### Local Build

**Windows:**
```powershell
# Build Windows x64 binaries
./build.ps1

# Build with specific libdatadog version
./build.ps1 -LibdatadogVersion v25.0.0

# Build with different feature preset
./build.ps1 -LibdatadogVersion v25.0.0

# Clean build
./build.ps1 -Clean
```

**Linux/macOS:**
```bash
# Build binaries
./build.sh

# Build with specific libdatadog version
./build.sh --version v25.0.0

# Build with different feature preset
./build.sh --version v25.0.0

# Clean build
./build.sh --clean
```

The build artifacts will be placed in the `output/` directory.

### Features

The build includes the core features required by dd-trace-dotnet:

- Profiling FFI, crashtracker, symbolizer, demangler, library-config, data-pipeline, log

### What the Build Does

1. Clones the libdatadog repository at the specified version
2. Builds the profiling FFI crate using `cargo rustc --crate-type cdylib/staticlib` (release + debug)
3. Generates C/C++ headers using external `cbindgen` CLI per crate
4. Deduplicates headers using libdatadog's `dedup_headers` tool
5. Strips binaries and extracts debug symbols (Linux/macOS)
6. Packages binaries, headers, and license files for dd-trace-dotnet

### Alignment with Official libdatadog Build

The build process is designed to match the official libdatadog compilation as closely as possible, differing only where needed for .NET-specific requirements:

- **Build command**: Uses `cargo rustc --crate-type` with explicit crate types, same as `windows/build-artifacts.ps1`
- **RUSTFLAGS**: Identical per platform (PIC, crt-static on Windows, SONAME on Linux)
- **Header generation**: External `cbindgen` CLI per FFI crate with `dedup_headers`, same as the official scripts
- **Library stripping**: Same objcopy/strip pipeline (debug symbol extraction, LLVM bitcode removal)
- **Release profile**: Same `opt-level = "s"`, `lto = true`, `codegen-units = 1` from the workspace Cargo.toml

The build includes only the features dd-trace-dotnet needs, reducing binary size compared to the official release.

### Linux Builds and GLIBC Compatibility

Linux builds (x86_64 and ARM64) are compiled with **GLIBC 2.17 compatibility** to support CentOS 7 and other older distributions. This is achieved using:

- **cross-rs** tool with custom CentOS 7-based Docker images
- Custom Dockerfiles in `tools/docker/` (Dockerfile.centos for x86_64, Dockerfile.centos-aarch64 for ARM64)
- `Cross.toml` configuration for target-specific Docker images

The binaries include proper SONAME (`libdatadog_profiling.so`) for dynamic linking and use position-independent code (PIC) for shared library compatibility.

**Note:** ARM64 builds require special compilation flags (`-D__ARM_ARCH=8 -DAT_HWCAP2=26`) to work with CentOS 7's older glibc headers.

## Release Process

Releases are automated via GitHub Actions. Go to [Actions → Release](https://github.com/DataDog/libdatadog-dotnet/actions/workflows/release.yml) and click "Run workflow".

**Prerequisites:** The repository requires a `RELEASE_TOKEN` secret (Personal Access Token with repo permissions) to create tags due to repository protection rules.

### Build Without Release (Testing)

To build and test without creating a release, use the **Build workflow** instead:
- Go to **Actions → Build**
- Triggered automatically on PRs and pushes to main
- Can also be triggered manually via workflow_dispatch

### Create a Release

The Release workflow builds binaries and creates a GitHub release:

**Parameters:**
- **Libdatadog version**: Leave empty for latest code, or specify a version (e.g., `v26.0.0`)
- **Version increment**: Choose how to bump the version (default: `patch`)
  - `patch`: v1.0.9 → v1.0.10 (bug fixes)
  - `minor`: v1.0.9 → v1.1.0 (new features)
  - `major`: v1.0.9 → v2.0.0 (breaking changes)
- **Release version** (optional): Manually specify version (e.g., `v1.2.0`) to override auto-increment
- **Feature preset**: `minimal` (core features for dd-trace-dotnet)

The workflow will:
- Build binaries for all 8 platforms
- Auto-increment version (or use manual override)
- Create a git tag
- Create a GitHub release with artifacts and checksums

**Note:** This workflow always creates a release. For testing builds without releasing, use the Build workflow.

## Releases

Release artifacts are published as GitHub Release assets for all supported platforms:

**Windows:**
- `libdatadog-x64-windows.zip` - Windows x64 binaries
- `libdatadog-x86-windows.zip` - Windows x86 binaries

**Linux (glibc):**
- `libdatadog-x86_64-unknown-linux-gnu.tar.gz` - Linux x64
- `libdatadog-aarch64-unknown-linux-gnu.tar.gz` - Linux ARM64

**Linux (musl/Alpine):**
- `libdatadog-x86_64-alpine-linux-musl.tar.gz` - Linux x64
- `libdatadog-aarch64-alpine-linux-musl.tar.gz` - Linux ARM64

**macOS:**
- `libdatadog-x86_64-apple-darwin.tar.gz` - macOS x64 (Intel)
- `libdatadog-aarch64-apple-darwin.tar.gz` - macOS ARM64 (Apple Silicon)

## Component Versions

The libdatadog version is automatically determined at build time:
- **Manual trigger with empty version:** Uses the latest code from the `main` branch (not the latest release)
- **Manual trigger with specific version:** Uses the specified version tag or branch (e.g., `v26.0.0` or `main`)

This allows you to build and release the latest libdatadog code anytime, even if libdatadog hasn't released a new version yet.

For security vulnerabilities, please see our [Security Policy](SECURITY.md).

## License

Apache License 2.0. See [LICENSE](LICENSE) file.

Packages include `LICENSE-3rdparty.yml` from libdatadog with full third-party license texts.
