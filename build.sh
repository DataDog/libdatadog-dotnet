#!/bin/bash
# Build script for libdatadog-dotnet
# This script builds custom libdatadog binaries for the .NET SDK

set -e

# Default parameters
LIBDATADOG_VERSION="${1:-v25.0.0}"
PLATFORM="${2:-x64-linux}"
OUTPUT_DIR="${3:-output}"
CLEAN=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --version)
            LIBDATADOG_VERSION="$2"
            shift 2
            ;;
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --version VERSION   Libdatadog version (default: v25.0.0)"
            echo "  --platform PLATFORM Target platform (default: x64-linux)"
            echo "  --output DIR        Output directory (default: output)"
            echo "  --clean             Clean build directories before building"
            echo "  -h, --help          Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  CARGO_BUILD_TARGET  Cargo target for cross-compilation"
            echo ""
            echo "Examples:"
            echo "  $0 --version v25.0.0 --platform x64-linux"
            echo "  CARGO_BUILD_TARGET=x86_64-unknown-linux-gnu $0 --clean"
            exit 0
            ;;
        *)
            # Positional arguments (for backward compatibility)
            if [ -z "$LIBDATADOG_VERSION_SET" ]; then
                LIBDATADOG_VERSION="$1"
                LIBDATADOG_VERSION_SET=true
            elif [ -z "$PLATFORM_SET" ]; then
                PLATFORM="$1"
                PLATFORM_SET=true
            elif [ -z "$OUTPUT_DIR_SET" ]; then
                OUTPUT_DIR="$1"
                OUTPUT_DIR_SET=true
            fi
            shift
            ;;
    esac
done

# Color output functions
print_cyan() {
    echo -e "\033[0;36m$1\033[0m"
}

print_gray() {
    echo -e "\033[0;90m$1\033[0m"
}

print_yellow() {
    echo -e "\033[0;33m$1\033[0m"
}

print_red() {
    echo -e "\033[0;31m$1\033[0m"
}

print_green() {
    echo -e "\033[0;32m$1\033[0m"
}

print_cyan "Building libdatadog-dotnet"
print_gray "  Libdatadog version: $LIBDATADOG_VERSION"
print_gray "  Platform: $PLATFORM"
print_gray "  Output directory: $OUTPUT_DIR"

# Check prerequisites
if ! command -v cargo &> /dev/null; then
    print_red "Error: Required tools not found. Please install:"
    print_red "  - Rust (https://rustup.rs/)"
    exit 1
fi

if ! command -v git &> /dev/null; then
    print_red "Error: Required tools not found. Please install:"
    print_red "  - Git (https://git-scm.com/)"
    exit 1
fi

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Clean if requested
if [ "$CLEAN" = true ]; then
    print_yellow "Cleaning build directories..."
    rm -rf libdatadog
    rm -rf "$OUTPUT_DIR"
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# Clone libdatadog if not already present
if [ ! -d "libdatadog" ]; then
    print_yellow "Cloning libdatadog..."
    git clone --depth 1 --branch "$LIBDATADOG_VERSION" https://github.com/DataDog/libdatadog.git
    if [ $? -ne 0 ]; then
        print_red "Error: Failed to clone libdatadog. Is $LIBDATADOG_VERSION a valid tag?"
        exit 1
    fi
else
    print_gray "Using existing libdatadog clone"
    cd libdatadog
    CURRENT_TAG=$(git describe --tags --exact-match 2>/dev/null || echo "unknown")
    if [ "$CURRENT_TAG" != "$LIBDATADOG_VERSION" ]; then
        print_yellow "  Warning: Existing clone is at $CURRENT_TAG, not $LIBDATADOG_VERSION"
        print_yellow "  Use --clean to clone the correct version"
    fi
    cd ..
fi

# Build libdatadog profiling FFI
print_yellow "Building libdatadog profiling FFI..."

# Check if CARGO_BUILD_TARGET is set for cross-compilation
CARGO_TARGET_ARG=""
TARGET_SUBDIR=""
USE_CROSS=false
EXTRA_RUSTFLAGS=""

if [ -n "$CARGO_BUILD_TARGET" ]; then
    CARGO_TARGET_ARG="--target $CARGO_BUILD_TARGET"
    TARGET_SUBDIR="$CARGO_BUILD_TARGET/"
    print_cyan "  Target architecture: $CARGO_BUILD_TARGET"

    # Enable dynamic linking for musl targets
    # By default, musl uses static linking which prevents cdylib from being built
    case "$CARGO_BUILD_TARGET" in
        *-musl)
            EXTRA_RUSTFLAGS="-C target-feature=-crt-static"
            print_cyan "  Enabling dynamic linking for musl target"
            ;;
    esac

    # Determine if we need to use cross for this target
    # Use cross for musl and ARM64 targets that require C cross-compilers
    case "$CARGO_BUILD_TARGET" in
        x86_64-unknown-linux-musl|aarch64-unknown-linux-gnu|aarch64-unknown-linux-musl)
            if command -v cross &> /dev/null; then
                USE_CROSS=true
                print_cyan "  Using 'cross' for cross-compilation"
            else
                print_yellow "  Warning: 'cross' not found, trying native cargo (may fail for targets requiring C cross-compiler)"
            fi
            ;;
    esac
fi

cd libdatadog

# Select cargo or cross
CARGO_CMD="cargo"
if [ "$USE_CROSS" = true ]; then
    CARGO_CMD="cross"
fi

# Set RUSTFLAGS if needed (append to existing)
if [ -n "$EXTRA_RUSTFLAGS" ]; then
    export RUSTFLAGS="${RUSTFLAGS:-} $EXTRA_RUSTFLAGS"
fi

# Build release version
# Note: The Cargo.toml already has optimized release profile:
#   - opt-level = "s" (optimize for size)
#   - lto = true (link-time optimization)
#   - codegen-units = 1 (better optimization)
#   - debug = "line-tables-only" (minimal debug info)
print_gray "  Building release configuration with $CARGO_CMD..."
$CARGO_CMD build --release -p libdd-profiling-ffi $CARGO_TARGET_ARG
if [ $? -ne 0 ]; then
    print_red "Error: Release build failed"
    exit 1
fi

# Build debug version
print_gray "  Building debug configuration with $CARGO_CMD..."
$CARGO_CMD build -p libdd-profiling-ffi $CARGO_TARGET_ARG
if [ $? -ne 0 ]; then
    print_red "Error: Debug build failed"
    exit 1
fi

cd ..

# Verify build outputs exist (with target subdirectory if cross-compiling)
RELEASE_DIR="libdatadog/target/${TARGET_SUBDIR}release"
DEBUG_DIR="libdatadog/target/${TARGET_SUBDIR}debug"

# Check for build outputs
# Note: musl targets may not produce .so files (cdylib) and only produce .a files (staticlib)
if [ ! -f "$RELEASE_DIR/libdatadog_profiling_ffi.so" ] && [ ! -f "$RELEASE_DIR/libdatadog_profiling_ffi.a" ]; then
    print_red "Error: Release build did not produce expected libraries"
    print_red "  Expected either: $RELEASE_DIR/libdatadog_profiling_ffi.so"
    print_red "               or: $RELEASE_DIR/libdatadog_profiling_ffi.a"
    exit 1
fi

# Warn if only static library is available (common for musl targets)
if [ ! -f "$RELEASE_DIR/libdatadog_profiling_ffi.so" ] && [ -f "$RELEASE_DIR/libdatadog_profiling_ffi.a" ]; then
    print_yellow "  Note: Only static library available (typical for musl targets)"
fi

# Package the binaries
print_yellow "Packaging binaries..."

PACKAGE_DIR="$OUTPUT_DIR/libdatadog-$PLATFORM"
mkdir -p "$PACKAGE_DIR"

# Create Linux directory structure (matches original libdatadog)
DIRS=(
    "include/datadog"
    "lib/pkgconfig"
    "cmake"
)

for DIR in "${DIRS[@]}"; do
    mkdir -p "$PACKAGE_DIR/$DIR"
done

# Copy release artifacts and rename to match original libdatadog naming
print_gray "  Copying release artifacts..."

# Dynamic build (shared library .so) - rename to libdatadog_profiling.so
if [ -f "$RELEASE_DIR/libdatadog_profiling_ffi.so" ]; then
    cp "$RELEASE_DIR/libdatadog_profiling_ffi.so" "$PACKAGE_DIR/lib/libdatadog_profiling.so"
else
    print_yellow "  Warning: Release shared library (.so) not found"
fi

# Static build (static library .a) - rename to libdatadog_profiling.a
if [ -f "$RELEASE_DIR/libdatadog_profiling_ffi.a" ]; then
    cp "$RELEASE_DIR/libdatadog_profiling_ffi.a" "$PACKAGE_DIR/lib/libdatadog_profiling.a"
else
    print_yellow "  Warning: Release static library (.a) not found"
fi

# Strip libraries (matches libdatadog's exact process)
print_gray "  Stripping binaries and extracting debug symbols..."

# Step 1: Remove LLVM bitcode section from static library (reduces size significantly)
if [ -f "$PACKAGE_DIR/lib/libdatadog_profiling.a" ]; then
    if command -v objcopy &> /dev/null; then
        print_gray "    Removing .llvmbc section from static library..."
        objcopy --remove-section .llvmbc "$PACKAGE_DIR/lib/libdatadog_profiling.a" 2>/dev/null || {
            print_yellow "    Warning: Failed to remove .llvmbc section (objcopy may not be available)"
        }
    fi
fi

# Step 2-4: Extract debug symbols, strip .so, and link debug file
if [ -f "$PACKAGE_DIR/lib/libdatadog_profiling.so" ]; then
    # Check if tools are available
    if command -v objcopy &> /dev/null && command -v strip &> /dev/null; then
        # Step 2: Extract debug symbols
        print_gray "    Extracting debug symbols..."
        objcopy --only-keep-debug \
            "$PACKAGE_DIR/lib/libdatadog_profiling.so" \
            "$PACKAGE_DIR/lib/libdatadog_profiling.debug" || {
            print_yellow "    Warning: Failed to extract debug symbols"
        }

        # Step 3: Strip the shared library
        # Use -S for glibc (preserves global symbols), -s for musl (strip all)
        print_gray "    Stripping shared library..."
        case "$CARGO_BUILD_TARGET" in
            *-musl)
                # musl uses full strip (-s)
                strip -s "$PACKAGE_DIR/lib/libdatadog_profiling.so" || {
                    print_yellow "    Warning: Failed to strip library"
                }
                ;;
            *)
                # glibc uses -S (strip debug symbols but keep global symbols)
                strip -S "$PACKAGE_DIR/lib/libdatadog_profiling.so" || {
                    print_yellow "    Warning: Failed to strip library"
                }
                ;;
        esac

        # Step 4: Link debug symbols to stripped binary
        if [ -f "$PACKAGE_DIR/lib/libdatadog_profiling.debug" ]; then
            print_gray "    Linking debug symbols..."
            objcopy --add-gnu-debuglink="$PACKAGE_DIR/lib/libdatadog_profiling.debug" \
                "$PACKAGE_DIR/lib/libdatadog_profiling.so" || {
                print_yellow "    Warning: Failed to link debug symbols"
            }
        fi
    else
        print_yellow "    Warning: objcopy and/or strip not available, binaries will not be stripped"
        print_yellow "    This will result in much larger files than the original libdatadog releases"
    fi
fi

# Copy all headers from libdatadog
print_gray "  Copying headers..."

# Copy all datadog headers if they exist
if [ -d "libdatadog/include/datadog" ]; then
    cp -r libdatadog/include/datadog/* "$PACKAGE_DIR/include/datadog/" 2>/dev/null || true
fi

# Also check target/include location
if [ -d "libdatadog/target/include/datadog" ]; then
    cp -r libdatadog/target/include/datadog/* "$PACKAGE_DIR/include/datadog/" 2>/dev/null || true
fi

# Ensure profiling.h exists (critical)
if [ ! -f "$PACKAGE_DIR/include/datadog/profiling.h" ]; then
    print_yellow "  Warning: profiling.h not found. Attempting to generate..."
    cd libdatadog/libdd-profiling-ffi
    if command -v cbindgen &> /dev/null; then
        cbindgen --output "$PACKAGE_DIR/include/datadog/profiling.h"
        [ $? -eq 0 ] && print_gray "  Generated profiling.h with cbindgen"
    else
        print_yellow "  Warning: cbindgen not found. Install with: cargo install cbindgen"
    fi
    cd ../..
fi

# Create pkg-config files
print_gray "  Creating pkg-config files..."
cat > "$PACKAGE_DIR/lib/pkgconfig/datadog_profiling.pc" << EOF
prefix=\${pcfiledir}/../..
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: datadog_profiling
Description: Datadog profiling library (shared)
Version: ${LIBDATADOG_VERSION#v}
Libs: -L\${libdir} -ldatadog_profiling
Cflags: -I\${includedir}
EOF

cat > "$PACKAGE_DIR/lib/pkgconfig/datadog_profiling-static.pc" << EOF
prefix=\${pcfiledir}/../..
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: datadog_profiling
Description: Datadog profiling library (static)
Version: ${LIBDATADOG_VERSION#v}
Libs: -L\${libdir} -ldatadog_profiling
Cflags: -I\${includedir}
EOF

# Create CMake config file
print_gray "  Creating CMake config..."
cat > "$PACKAGE_DIR/cmake/DatadogConfig.cmake" << 'EOF'
# DatadogConfig.cmake
get_filename_component(DATADOG_CMAKE_DIR "${CMAKE_CURRENT_LIST_FILE}" PATH)
set(DATADOG_INCLUDE_DIRS "${DATADOG_CMAKE_DIR}/../include")
set(DATADOG_LIBRARY_DIRS "${DATADOG_CMAKE_DIR}/../lib")
set(DATADOG_LIBRARIES datadog_profiling)

# Set up imported target
add_library(Datadog::Profiling SHARED IMPORTED)
set_target_properties(Datadog::Profiling PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${DATADOG_INCLUDE_DIRS}"
    IMPORTED_LOCATION "${DATADOG_LIBRARY_DIRS}/libdatadog_profiling.so"
)
EOF

# Copy license files
print_gray "  Copying license files..."
cp libdatadog/LICENSE "$PACKAGE_DIR/" 2>/dev/null || true
cp libdatadog/NOTICE "$PACKAGE_DIR/" 2>/dev/null || true

# Look for LICENSE-3rdparty in yml or csv format
if [ -f "libdatadog/LICENSE-3rdparty.yml" ]; then
    cp libdatadog/LICENSE-3rdparty.yml "$PACKAGE_DIR/"
elif [ -f "libdatadog/LICENSE-3rdparty.csv" ]; then
    cp libdatadog/LICENSE-3rdparty.csv "$PACKAGE_DIR/"
fi

print_green "Build complete!"
print_gray "  Package directory: $PACKAGE_DIR"

# Display package contents
echo ""
print_cyan "Package contents:"
find "$PACKAGE_DIR" -type f | sort | while read -r file; do
    RELATIVE_PATH="${file#$PACKAGE_DIR/}"
    SIZE=$(du -h "$file" | cut -f1)
    print_gray "  $RELATIVE_PATH ($SIZE)"
done
