# Guide for Coding Agents

This document provides essential context for AI coding agents working on the libdatadog-dotnet repository.

## Repository Overview

**Purpose:** Build custom libdatadog binaries optimized for .NET SDK integration across 8 platforms.

**Key Concept:** This is a **wrapper build system** around the official [libdatadog](https://github.com/DataDog/libdatadog) repository. We clone libdatadog, build it with custom feature sets, and package the results.

## Architecture

### Build System Structure

```
libdatadog-dotnet/
├── build.sh              # Linux/macOS build script
├── build.ps1             # Windows build script
├── .github/workflows/
│   ├── build-platform.yml  # Reusable workflow for building a single platform
│   ├── build.yml          # Main CI workflow (builds all platforms)
│   └── release.yml        # Release workflow (creates GitHub releases)
└── libdatadog/           # Cloned during build (not in git)
    ├── target/           # Cargo build outputs
    ├── tools/            # Contains dedup_headers tool
    └── libdd-*-ffi/      # FFI crates that generate headers
```

### Build Flow

1. **Clone libdatadog** at specified version/tag
2. **Build profiling FFI** with cargo (release + debug)
3. **Generate C headers** using cbindgen for each FFI module
4. **Deduplicate headers** using libdatadog's built-in tool
5. **Package binaries** with appropriate directory structure
6. **Upload artifacts** to GitHub Actions

## Critical Gotchas

### 1. Cross-Compilation and CARGO_BUILD_TARGET

**Problem:** When `CARGO_BUILD_TARGET` is set (CI environment), cargo places outputs in `target/{TARGET}/release/` instead of `target/release/`.

**Impact:** The `dedup_headers` tool must run on the **build host**, not the **target architecture**.

**Solution:**
```bash
# Save and unset CARGO_BUILD_TARGET when building dedup_headers
SAVED_TARGET="$CARGO_BUILD_TARGET"
unset CARGO_BUILD_TARGET
cargo build --release --bin dedup_headers  # Builds for host
export CARGO_BUILD_TARGET="$SAVED_TARGET"
```

**Where:** `build.sh` lines 540-560, `build.ps1` lines 268-295

### 2. Header Generation Must Be Explicit

**Problem:** Building `libdd-profiling-ffi` with `cbindgen` feature generates combined headers with duplicate type definitions.

**Solution:** Generate separate headers for each FFI module using cbindgen directly:
```bash
cd libdatadog/libdd-common-ffi
cbindgen --output "$PACKAGE_DIR/include/datadog/common.h"
cd ../../

cd libdatadog/libdd-profiling-ffi
cbindgen --output "$PACKAGE_DIR/include/datadog/profiling.h"
cd ../../
```

Then deduplicate to remove types from `profiling.h` that exist in `common.h`.

**Why:** This matches official libdatadog release structure and prevents `error C2011: 'struct' type redefinition` errors.

### 3. Argument Parsing in build.sh

**Problem:** Setting defaults like `LIBDATADOG_VERSION="${1:-v25.0.0}"` captures **named arguments** (e.g., `--platform`) as positional parameters before the parsing loop runs.

**Correct Pattern:**
```bash
# Use literal defaults
LIBDATADOG_VERSION="v25.0.0"
PLATFORM="x64-linux"

# Then parse named arguments in while loop
while [[ $# -gt 0 ]]; do
  case $1 in
    --version) LIBDATADOG_VERSION="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    # ...
  esac
done
```

### 4. Artifact Structure in Release Workflow

**Problem:** Downloaded artifacts are structured as:
```
artifacts/
  libdatadog-x64-windows/
    (contents directly here)
```

**Not:**
```
artifacts/
  libdatadog-x64-windows/
    libdatadog-x64-windows/
      (contents here)
```

**Solution:** Zip from artifacts directory:
```bash
cd artifacts
zip -r ../libdatadog-x64-windows.zip libdatadog-x64-windows/
cd ..
```

### 5. Absolute Paths for PACKAGE_DIR

**Problem:** Build scripts change directories frequently. Relative paths break.

**Solution:**
```bash
# Make OUTPUT_DIR absolute early
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# Then PACKAGE_DIR based on it will also be absolute
PACKAGE_DIR="$OUTPUT_DIR/libdatadog-$PLATFORM"
```

## Platform-Specific Considerations

### Directory Structures Differ by OS

**Windows:**
```
output/libdatadog-{platform}/
├── release/
│   ├── dynamic/    # datadog_profiling_ffi.dll, .lib, .pdb
│   └── static/     # datadog_profiling_ffi.lib
├── debug/
│   ├── dynamic/
│   └── static/
└── include/datadog/
```

**Linux/macOS:**
```
output/libdatadog-{platform}/
├── lib/            # libdatadog_profiling.so/.dylib, .a
├── include/datadog/
├── lib/pkgconfig/
└── cmake/
```

**Implication:** Artifact verification and packaging must handle both structures.

### Musl Targets Require Special Handling

**Issue:** Musl defaults to static linking (`+crt-static`) which prevents building cdylib (shared libraries).

**Solution:** Configure in `.cargo/config.toml`:
```toml
[target.x86_64-unknown-linux-musl]
rustflags = ["-C", "target-feature=-crt-static"]

[target.aarch64-unknown-linux-musl]
rustflags = ["-C", "target-feature=-crt-static"]
```

**Location:** `libdatadog/.cargo/config.toml` (created during build)

## Common Tasks

### Adding a New Platform

1. Add matrix entry in `.github/workflows/build-platform.yml`:
   ```yaml
   - arch: arm64
     platform: aarch64-unknown-linux-gnu
     target: aarch64-unknown-linux-gnu
     os: ubuntu-latest
   ```

2. Update verification in `build-platform.yml` if needed (check correct file paths)

3. Update release workflow to include new platform in archive creation

4. Update `PRDup.md` and this guide with new platform

### Updating libdatadog Version

Default versions are specified in:
- `build.sh`: line 15 (`LIBDATADOG_VERSION="v25.0.0"`)
- `build.ps1`: line 13 (`[string]$LibdatadogVersion = "v25.0.0"`)

Or override via:
- CLI: `./build.sh --version v26.0.0`
- Workflow input: `libdatadog_version` parameter

### Changing Feature Presets

Feature sets defined in:
- `build.sh`: lines 108-122
- `build.ps1`: lines 30-34

Structure:
```bash
minimal="ddcommon-ffi,cbindgen"
standard="ddcommon-ffi,crashtracker-ffi,crashtracker-collector,demangler,ddtelemetry-ffi,cbindgen"
full="ddcommon-ffi,...all features...,cbindgen"
```

**Note:** Always include `cbindgen` feature (required for header generation during cargo build).

### Debugging Build Issues

1. **Check directory location:** Add `pwd` commands to see where script is executing
2. **List files:** Add `ls -la` to see what exists
3. **Check environment:** Add `env | grep CARGO` to see cargo-related vars
4. **Verify paths:** Use `find` to locate missing files

Example debug pattern:
```bash
echo "Current directory: $(pwd)"
echo "CARGO_BUILD_TARGET: $CARGO_BUILD_TARGET"
ls -la libdatadog/target/
find libdatadog -name "dedup_headers*"
```

## Key Files Reference

### Build Scripts
- **build.sh** (700+ lines): Main Linux/macOS build logic
- **build.ps1** (300+ lines): Main Windows build logic
- Both should maintain feature parity

### Workflows
- **build-platform.yml**: Reusable workflow for single platform build
  - Matrix strategy for all 8 platforms
  - Artifact upload with 7-day retention
- **build.yml**: Triggers build-platform for all platforms (CI)
- **release.yml**: Downloads artifacts, creates archives, publishes GitHub release

### Configuration
- **LICENSE-3rdparty.csv**: Summary of dependencies (keep minimal)
- **.cargo/config.toml**: Rust target-specific configuration (created during build)

### Documentation
- **PRDup.md**: Pull request description for header generation fix
- **AGENTS.md**: This file

## Testing Guidelines

### Local Testing

```bash
# Minimal build (fastest)
./build.sh --version v25.0.0 --platform x64-linux --features minimal --clean

# Test with different features
./build.ps1 -LibdatadogVersion v25.0.0 -Platform x64-windows -Features standard -Clean

# Verify headers
ls -lh output/libdatadog-{platform}/include/datadog/*.h
grep -c "typedef struct ddog_Slice_CChar" output/.../common.h  # Should be > 0
grep -c "typedef struct ddog_Slice_CChar" output/.../profiling.h  # Should be 0
```

### CI Testing

- **Build workflow** runs on every push/PR
- **Release workflow** is manual (workflow_dispatch)
- Use `verify_artifacts: true` in build-platform.yml to enable verification

## Common Errors and Solutions

### "dedup_headers: cannot execute binary file: Exec format error"
**Cause:** Tool was compiled for target architecture, not host.
**Fix:** Unset CARGO_BUILD_TARGET when building dedup_headers (see Gotcha #1)

### "cbindgen not found"
**Cause:** cbindgen not installed in CI environment.
**Fix:** Add `cargo install cbindgen` step in workflow before build

### "name not matched: libdatadog-x64-windows/"
**Cause:** Trying to zip a non-existent subdirectory.
**Fix:** Zip from artifacts directory (see Gotcha #4)

### "rm: unrecognized option '--platform'"
**Cause:** Argument parsing capturing named args as positional.
**Fix:** Use literal defaults (see Gotcha #3)

### "Release DLL not found at output/.../lib/..."
**Cause:** Verification checking wrong path for Windows.
**Fix:** Windows uses `release/dynamic/` not `lib/` (see Platform-Specific section)

## Best Practices

### When Modifying Build Scripts

1. **Maintain parity** between build.sh and build.ps1
2. **Test locally** on target OS before pushing
3. **Add comments** for non-obvious logic (especially cross-compilation handling)
4. **Use absolute paths** for directories that persist across `cd` commands
5. **Quote variables** that might contain spaces: `"$PACKAGE_DIR"`

### When Modifying Workflows

1. **Test with manual trigger** (workflow_dispatch) before relying on automation
2. **Add debug output** for new steps (e.g., `ls -R artifacts/`)
3. **Check permissions** - use least privilege (read-only by default)
4. **Pin action versions** with full SHA (not just `@v1`)
5. **Handle errors explicitly** - don't assume success

### When Adding Dependencies

1. **Update LICENSE-3rdparty.csv** if adding new crates/features
2. **Copy LICENSE-3rdparty.yml** from libdatadog (don't duplicate)
3. **Test build size impact** (minimal: 4MB, standard: 5-6MB, full: 6.5MB targets)

## Debugging Checklist

When a build fails:

- [ ] Check which platform failed (Windows/Linux/macOS, x64/ARM64, GNU/musl)
- [ ] Look for "CARGO_BUILD_TARGET" in environment (affects output paths)
- [ ] Verify directory structure matches expectations (ls -R output/)
- [ ] Check if headers were generated (ls output/.../include/datadog/)
- [ ] Verify dedup_headers tool location and architecture
- [ ] Check for absolute vs relative path issues
- [ ] Review recent changes to build scripts for parity issues
- [ ] Confirm cbindgen and required tools are installed

## Version History

**Current:** Headers are generated per FFI module and deduplicated (post-fix)
**Previous:** Headers were combined with duplicate definitions (caused compilation errors)

**Key Change:** Explicit cbindgen per module + dedup_headers tool from libdatadog

See `PRDup.md` for full details on the header generation fix.

## Additional Resources

- [libdatadog repository](https://github.com/DataDog/libdatadog)
- [cbindgen documentation](https://github.com/mozilla/cbindgen)
- [GitHub Actions: Reusable workflows](https://docs.github.com/en/actions/using-workflows/reusing-workflows)
- [Cargo cross-compilation](https://doc.rust-lang.org/cargo/reference/config.html#targettriplelinker)

## Contributing

When making changes that affect this guide:
1. Update relevant sections in AGENTS.md
2. Add new gotchas as they're discovered
3. Update examples if build process changes
4. Keep "Common Errors" section current with real issues

---

**Last Updated:** 2025-02 (Header generation fix)
**Maintained By:** Coding agents and repository maintainers
**Purpose:** Preserve institutional knowledge for AI assistants
