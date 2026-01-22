# Contributing to libdatadog-dotnet

This repository produces custom libdatadog binaries for the .NET SDK. This is primarily an automation repository managed by the Datadog .NET team.

## Updating libdatadog Version

The workflow supports both building for testing and creating releases. You have several options:

### Option 1: Build Latest Code Without Release (Testing)

**Use case:** Test the latest libdatadog code before creating an official release.

1. Go to [Actions → Release](https://github.com/DataDog/libdatadog-dotnet/actions/workflows/release.yml)
2. Click "Run workflow"
3. Configure parameters:
   - **Libdatadog version:** Leave **empty** (uses latest code from `main` branch)
   - **Release version:** Leave **empty** (no release created)
   - **Feature preset:** Select `minimal`, `standard`, or `full`
4. The workflow builds artifacts without creating a release
5. Download artifacts from the workflow run to test locally

### Option 2: Build Specific libdatadog Version Without Release

**Use case:** Test a specific libdatadog version before releasing.

1. Go to [Actions → Release](https://github.com/DataDog/libdatadog-dotnet/actions/workflows/release.yml)
2. Click "Run workflow"
3. Configure parameters:
   - **Libdatadog version:** Enter version (e.g., `v26.0.0`)
   - **Release version:** Leave **empty**
   - **Feature preset:** Select `minimal`, `standard`, or `full`

### Option 3: Build and Release Latest Code

**Use case:** Create a new libdatadog-dotnet release with the latest libdatadog code.

1. Go to [Actions → Release](https://github.com/DataDog/libdatadog-dotnet/actions/workflows/release.yml)
2. Click "Run workflow"
3. Configure parameters:
   - **Libdatadog version:** Leave **empty** (uses latest code from `main` branch)
   - **Release version:** Enter release tag (e.g., `v1.2.0`)
   - **Feature preset:** Select `minimal`, `standard`, or `full`
4. The workflow will:
   - Build artifacts from latest libdatadog code
   - Create the specified git tag
   - Create a GitHub release
   - Attach all built artifacts
   - Generate SHA512 hashes

### Option 4: Build and Release Specific libdatadog Version

**Use case:** Create a new libdatadog-dotnet release with a specific libdatadog version.

1. Go to [Actions → Release](https://github.com/DataDog/libdatadog-dotnet/actions/workflows/release.yml)
2. Click "Run workflow"
3. Configure parameters:
   - **Libdatadog version:** Enter version (e.g., `v26.0.0`)
   - **Release version:** Enter release tag (e.g., `v1.2.0`)
   - **Feature preset:** Select `minimal`, `standard`, or `full`

## Workflow Parameters

The release workflow accepts the following parameters:

### Libdatadog Version
- **Empty (default):** Uses the latest code from libdatadog's `main` branch
- **Specific version tag:** Uses that tagged version (e.g., `v26.0.0`)
- **Branch name:** Can specify any branch (e.g., `main`, `feature-branch`)

This parameter controls which libdatadog code is built into the binaries.

### Release Version
- **Empty (default):** Builds artifacts only, no release created
- **Semantic version tag:** Creates a GitHub release with that tag (e.g., `v1.2.0`)

Must follow the format `vX.Y.Z` where X, Y, Z are numbers. The workflow will:
- Validate the format
- Create the tag if it doesn't exist
- Create a GitHub release
- Upload all build artifacts

### Feature Preset
Controls which libdatadog components are included:
- **minimal (default):** Profiling only (~4MB) - fastest build
- **standard:** Profiling + crashtracker + telemetry (~5-6MB)
- **full:** All available components (~6.5MB)

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

Make sure the libdatadog version you specified is valid:
- If empty: Builds from `main` branch (always available)
- If specific version: Must be a valid git tag or branch in the libdatadog repository
- Check available versions at https://github.com/DataDog/libdatadog/tags

### Release creation fails with "invalid format"

The `release_version` parameter must follow semantic versioning: `vX.Y.Z`
- ✅ Valid: `v1.2.0`, `v2.0.0`, `v1.10.5`
- ❌ Invalid: `1.2.0` (missing 'v'), `v1.2` (missing patch), `v1.2.0-beta` (no pre-release tags)

### Missing artifacts in output

Check that the libdatadog build succeeded and that the artifact paths in `build.ps1` or `build.sh` match the actual output locations.

### SHA512 mismatch in dd-trace-dotnet

Ensure you're using the exact SHA512 hash from the release notes, not from a local build.

### Tag already exists error

If you're trying to create a release with a tag that already exists:
1. Choose a different release version number
2. Or delete the existing tag first:
   ```bash
   git tag -d v1.2.0
   git push origin :refs/tags/v1.2.0
   ```

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
