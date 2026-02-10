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
./build.ps1 -Features standard

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
./build.sh --features standard

# Clean build
./build.sh --clean
```

The build artifacts will be placed in the `output/` directory.

### Feature Presets

Three feature presets are available to control binary size and included components:

- **minimal** (~4MB): Core profiling only - fastest build, smallest binaries
- **standard** (~5-6MB): Includes crashtracker, telemetry, and demangler
- **full** (~6.5MB): All features - matches original libdatadog

Default is `minimal`.

### What the Build Does

1. Clones the libdatadog repository at the specified version
2. Builds the profiling FFI crate with cbindgen feature for header generation
3. Generates C/C++ header files (`include/datadog/*.h`)
4. Builds both debug and release configurations
5. Collects binaries, headers, and license files
6. Packages them in the structure expected by dd-trace-dotnet

## Release Process

Releases are automated via GitHub Actions. Go to [Actions → Release](https://github.com/DataDog/libdatadog-dotnet/actions/workflows/release.yml) and click "Run workflow".

**Prerequisites:** The repository requires a `RELEASE_TOKEN` secret (Personal Access Token with repo permissions) to create tags due to repository protection rules.

### Build Without Release (Testing)

Build binaries without creating a GitHub release (useful for testing):

**Parameters:**
- **Libdatadog version**: Leave empty for latest code, or specify a version (e.g., `v26.0.0`)
- **Release version**: Leave **empty** to skip release creation
- **Feature preset**: Choose `minimal`, `standard`, or `full`

The workflow will build artifacts that you can download from the workflow run.

### Build and Release

Build binaries and create a GitHub release:

**Parameters:**
- **Libdatadog version**: Leave empty for latest code, or specify a version (e.g., `v26.0.0`)
- **Version increment**: Choose `patch`, `minor`, or `major` to auto-increment from the latest tag
  - `patch`: v1.0.9 → v1.0.10 (bug fixes)
  - `minor`: v1.0.9 → v1.1.0 (new features)
  - `major`: v1.0.9 → v2.0.0 (breaking changes)
- **Release version** (optional): Manually specify a version tag (e.g., `v1.2.0`) to override auto-increment
- **Feature preset**: Choose `minimal`, `standard`, or `full`

The workflow will:
- Build binaries for all 8 platforms
- Auto-increment version or use manual version
- Create a git tag with the version
- Create a GitHub release with all artifacts and checksums

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

For third-party licenses, see [LICENSE-3rdparty.csv](LICENSE-3rdparty.csv).
