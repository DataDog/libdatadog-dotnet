# Contributing to libdatadog-dotnet

This repository produces custom libdatadog binaries for the .NET SDK. This is primarily an automation repository managed by the Datadog .NET team.

## Updating libdatadog Version

To build a new version of libdatadog, you have three options:

### Option 1: Build Latest Version (Recommended)

1. Go to [Actions → Release](https://github.com/DataDog/libdatadog-dotnet/actions/workflows/release.yml)
2. Click "Run workflow"
3. Leave the version field **empty**
4. The workflow automatically fetches and builds the latest libdatadog version

### Option 2: Build Specific Version

1. Go to [Actions → Release](https://github.com/DataDog/libdatadog-dotnet/actions/workflows/release.yml)
2. Click "Run workflow"
3. Enter the specific libdatadog version (e.g., `v25.1.0`)
4. Useful for testing or pinning to a specific version

### Option 3: Tag-Triggered Release

1. Create and push a tag (builds latest libdatadog version):
   ```bash
   git tag v1.1.0
   git push origin main --tags
   ```

2. GitHub Actions will automatically:
   - Fetch the latest libdatadog version
   - Build the binaries from that version
   - Create a GitHub release
   - Attach the built artifacts
   - Generate SHA512 hashes

### Updating dd-trace-dotnet

After a new release is created:

1. Update `build/vcpkg_local_ports/libdatadog/vcpkg.json` with the new libdatadog-dotnet version
2. Update `build/vcpkg_local_ports/libdatadog/portfile.cmake` with the new SHA512 hashes from the release notes

## Adding New Components

Currently, this repository builds only the profiling FFI component. To add additional components:

1. Update `build.ps1` to build the additional crates:
   ```powershell
   cargo build --release -p datadog-profiling-ffi -p datadog-telemetry-ffi
   ```

2. Update the packaging section to include the new artifacts:
   ```powershell
   Copy-Item "$ReleaseDir/datadog_telemetry_ffi.dll" -Destination "$PackageDir/release/dynamic/"
   ```

3. Update the README to document the new components

## Adding New Platforms

Currently, only Windows x64 is supported. To add support for additional platforms:

### Windows x86

1. Update `build.ps1` to support x86 target:
   ```powershell
   rustup target add i686-pc-windows-msvc
   cargo build --release --target i686-pc-windows-msvc -p datadog-profiling-ffi
   ```

2. Add a new GitHub Actions job for x86 in `.github/workflows/release.yml`

3. Update the artifact packaging logic

### Linux

1. Create a new build script `build.sh` for Linux
2. Add Linux-specific GitHub Actions jobs
3. Update dd-trace-dotnet's vcpkg configuration for Linux

### macOS

Similar to Linux, create build scripts and CI jobs for macOS.

## Testing Locally

Before creating a release, you can test the build locally:

```powershell
# Clean build
./build.ps1 -Clean

# Verify the output
ls output/
Expand-Archive output/libdatadog-x64-windows.zip -DestinationPath test-extract/
ls test-extract/libdatadog-x64-windows/

# Calculate hash
Get-FileHash output/libdatadog-x64-windows.zip -Algorithm SHA512
```

## Troubleshooting

### Build fails with "crate not found"

Make sure the libdatadog version you specified (or the latest version fetched automatically) is a valid git tag in the libdatadog repository. You can check available versions at https://github.com/DataDog/libdatadog/tags

### Missing artifacts in output

Check that the libdatadog build succeeded and that the artifact paths in `build.ps1` match the actual output locations.

### SHA512 mismatch in dd-trace-dotnet

Ensure you're using the exact SHA512 hash from the release notes, not from a local build.

## Release Versioning

This repository uses semantic versioning independent of libdatadog:

- **Major version** (1.x.x): Breaking changes to the package structure
- **Minor version** (x.1.x): New components or platform support
- **Patch version** (x.x.1): Libdatadog version updates or build fixes

Example:
- v1.0.0: Initial release with libdatadog v25.0.0, Windows x64 only
- v1.1.0: Added telemetry component
- v1.0.1: Updated to libdatadog v25.1.0
- v2.0.0: Changed package structure (breaking change)
