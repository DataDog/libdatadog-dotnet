# Setup Instructions for libdatadog-dotnet

This document provides step-by-step instructions for setting up and using the libdatadog-dotnet repository.

## Initial Setup (One-time)

### 1. Create GitHub Repository

```bash
# Initialize git repository
cd libdatadog-dotnet
git init
git add .
git commit -m "Initial commit: libdatadog-dotnet repository skeleton"

# Create GitHub repository (using gh CLI)
gh repo create DataDog/libdatadog-dotnet --public --source=. --remote=origin

# Push to GitHub
git push -u origin main
```

### 2. Configure GitHub Actions

The workflow is already configured in `.github/workflows/release.yml`. No additional setup needed - it will run automatically on tag pushes.

### 3. Create Initial Release

```bash
# Update version.txt if needed
echo "v25.0.0" > version.txt
git add version.txt
git commit -m "Set initial libdatadog version to v25.0.0"

# Create and push the first release tag
git tag v1.0.0
git push origin main --tags
```

This will trigger GitHub Actions to:
- Build Windows x64 binaries from libdatadog v25.0.0
- Create a GitHub release v1.0.0
- Upload `libdatadog-x64-windows.zip` as a release asset
- Generate release notes with SHA512 hashes

### 4. Update dd-trace-dotnet

Once the first release is created, update dd-trace-dotnet to use it:

1. **Update vcpkg.json**:
   ```bash
   cd dd-trace-dotnet/build/vcpkg_local_ports/libdatadog
   ```
   
   Edit `vcpkg.json`:
   ```json
   {
     "name": "libdatadog",
     "version-string": "1.0.0",
     "description": "Package providing libdatadog prebuilt binaries from libdatadog-dotnet."
   }
   ```

2. **Update portfile.cmake**:
   
   The URL is already updated to point to libdatadog-dotnet. Now update the hashes:
   
   ```cmake
   if(TARGET_TRIPLET STREQUAL "x64-windows" OR
      TARGET_TRIPLET STREQUAL "x64-windows-static")
       set(PLATFORM "x64")
       set(LIBDATADOG_HASH "<SHA512-from-release-notes>")
   ```
   
   Replace `<SHA512-from-release-notes>` with the actual hash from the GitHub release notes.

3. **Test the change**:
   ```bash
   cd dd-trace-dotnet/tracer
   ./build.cmd BuildTracerHome
   ```
   
   This will download the binaries from libdatadog-dotnet and verify the hash.

4. **Commit and create PR**:
   ```bash
   git add build/vcpkg_local_ports/libdatadog/
   git commit -m "Update to libdatadog-dotnet v1.0.0"
   git push origin <branch-name>
   # Create PR through GitHub UI or gh CLI
   ```

## Regular Usage

### Updating to a New libdatadog Version

When a new version of libdatadog is released:

```bash
cd libdatadog-dotnet

# Update version
echo "v25.1.0" > version.txt
git add version.txt
git commit -m "Update to libdatadog v25.1.0"

# Create new release
git tag v1.0.1
git push origin main --tags
```

Then update dd-trace-dotnet following step 4 above.

### Manual Build (for testing)

```powershell
# Build locally
./build.ps1 -LibdatadogVersion v25.0.0 -Clean

# Verify output
ls output/
Get-FileHash output/libdatadog-x64-windows.zip -Algorithm SHA512
```

### Triggering a Manual Release

You can also trigger a release manually without creating a tag:

1. Go to GitHub Actions in the libdatadog-dotnet repository
2. Select the "Release" workflow
3. Click "Run workflow"
4. Enter the libdatadog version to build
5. Click "Run workflow"

Note: This won't create a GitHub release automatically - it's mainly for testing.

## Verification

After updating dd-trace-dotnet, verify the integration:

1. **Build succeeds**:
   ```bash
   cd dd-trace-dotnet/tracer
   ./build.cmd BuildTracerHome
   ```

2. **Check artifacts**:
   ```bash
   ls shared/bin/monitoring-home/win-x64/datadog_profiling_ffi.dll
   ```

3. **Run tests**:
   ```bash
   ./build.cmd BuildAndRunManagedUnitTests
   ```

## Troubleshooting

### Release workflow fails

Check the GitHub Actions logs for specific errors. Common issues:
- Libdatadog version tag doesn't exist
- Rust build failures
- Missing artifacts

### dd-trace-dotnet build fails with hash mismatch

Ensure you copied the exact SHA512 hash from the libdatadog-dotnet release notes (all lowercase, no spaces).

### Missing files in the package

Check that `build.ps1` copies all necessary files. The package structure must match what dd-trace-dotnet's portfile.cmake expects.

## Next Steps

Future enhancements:
- Add Windows x86 support
- Add Linux support (x64, arm64)
- Add macOS support (x64, arm64, universal)
- Add additional libdatadog components (telemetry, etc.)
- Set up automated tests for the built binaries
