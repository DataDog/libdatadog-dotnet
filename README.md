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

## Building

### Prerequisites

- Rust 1.84.1 or newer
- cargo
- git
- PowerShell (for build script)

### Local Build

```powershell
# Build Windows x64 binaries
./build.ps1

# Build with specific libdatadog version
./build.ps1 -LibdatadogVersion v25.0.0

# Clean build
./build.ps1 -Clean
```

The build artifacts will be placed in the `output/` directory.

### What the build does

1. Clones the libdatadog repository at the specified version
2. Builds the profiling FFI crate in both debug and release configurations
3. Collects the built artifacts (DLLs, PDBs, headers)
4. Packages them in the structure expected by dd-trace-dotnet
5. Creates a zip archive with SHA512 hash

### Release Process

Releases are automated via GitHub Actions. There are three ways to trigger a release:

#### Option 1: Build Latest Version (Recommended)
1. Go to [Actions → Release](https://github.com/DataDog/libdatadog-dotnet/actions/workflows/release.yml)
2. Click "Run workflow"
3. Leave the version field **empty**
4. The workflow automatically fetches and builds the latest libdatadog version

#### Option 2: Build Specific Version
1. Go to [Actions → Release](https://github.com/DataDog/libdatadog-dotnet/actions/workflows/release.yml)
2. Click "Run workflow"
3. Enter a specific libdatadog version (e.g., `v25.0.0`)
4. Useful for testing or pinning to a specific version

#### Option 3: Tag-Triggered Build
```bash
git tag v1.0.0
git push origin main --tags
```
Automatically builds the latest libdatadog version and publishes release artifacts

## Releases

Release artifacts are published as GitHub Release assets:

- `libdatadog-x64-windows.zip` - Windows x64 binaries

Each release includes:
- Release and debug builds of the profiling FFI
- Header files for C/C++ integration
- License files
- SHA512 hash for integrity verification

## Component Versions

The libdatadog version is automatically determined at build time:
- **Manual trigger with empty version:** Uses the latest version from libdatadog repository
- **Manual trigger with specific version:** Uses the specified version (e.g., `v25.0.0`)
- **Tag-triggered build:** Uses the latest version from libdatadog repository

This allows you to release anytime, even if libdatadog hasn't released yet.

## Integration with dd-trace-dotnet

The dd-trace-dotnet repository downloads binaries from this repository's releases via vcpkg. 

### Updating dd-trace-dotnet

To use a new libdatadog-dotnet release in dd-trace-dotnet:

1. Update the version in `build/vcpkg_local_ports/libdatadog/vcpkg.json`
2. Update the URL and SHA512 hash in `build/vcpkg_local_ports/libdatadog/portfile.cmake`:
   ```cmake
   set(LIBDATADOG_VERSION v1.0.0)
   set(LIBDATADOG_URL "https://github.com/DataDog/libdatadog-dotnet/releases/download/v1.0.0/libdatadog-${PLATFORM}-windows.zip")
   set(LIBDATADOG_HASH "<sha512-from-release-notes>")
   ```

## Repository Structure

```
libdatadog-dotnet/
├── .github/
│   └── workflows/
│       └── release.yml       # GitHub Actions workflow for releases
├── build.ps1                 # PowerShell build script
├── .gitignore               # Git ignore rules
├── LICENSE                  # Apache 2.0 license
└── README.md                # This file
```

## License

Apache License 2.0. See [LICENSE](LICENSE) file.
