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

if [ -n "$CARGO_BUILD_TARGET" ]; then
    CARGO_TARGET_ARG="--target $CARGO_BUILD_TARGET"
    TARGET_SUBDIR="$CARGO_BUILD_TARGET/"
    print_cyan "  Target architecture: $CARGO_BUILD_TARGET"

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

# Check for .so file (dynamic library on Linux)
if [ ! -f "$RELEASE_DIR/libdatadog_profiling_ffi.so" ]; then
    print_red "Error: Release build did not produce expected shared library"
    print_red "  Expected: $RELEASE_DIR/libdatadog_profiling_ffi.so"
    exit 1
fi

# Package the binaries
print_yellow "Packaging binaries..."

PACKAGE_DIR="$OUTPUT_DIR/libdatadog-$PLATFORM"
mkdir -p "$PACKAGE_DIR"

# Create directory structure
DIRS=(
    "include"
    "release/dynamic"
    "release/static"
    "debug/dynamic"
    "debug/static"
)

for DIR in "${DIRS[@]}"; do
    mkdir -p "$PACKAGE_DIR/$DIR"
done

# Copy release artifacts
print_gray "  Copying release artifacts..."

# Dynamic build (shared library .so)
cp "$RELEASE_DIR/libdatadog_profiling_ffi.so" "$PACKAGE_DIR/release/dynamic/" 2>/dev/null || {
    print_yellow "  Warning: Release shared library (.so) not found"
}

# Static build (static library .a)
cp "$RELEASE_DIR/libdatadog_profiling_ffi.a" "$PACKAGE_DIR/release/static/" 2>/dev/null || {
    print_yellow "  Warning: Release static library (.a) not found"
}

# Copy debug artifacts
print_gray "  Copying debug artifacts..."

# Dynamic build (shared library .so)
cp "$DEBUG_DIR/libdatadog_profiling_ffi.so" "$PACKAGE_DIR/debug/dynamic/" 2>/dev/null || {
    print_yellow "  Warning: Debug shared library (.so) not found"
}

# Static build (static library .a)
cp "$DEBUG_DIR/libdatadog_profiling_ffi.a" "$PACKAGE_DIR/debug/static/" 2>/dev/null || {
    print_yellow "  Warning: Debug static library (.a) not found"
}

# Copy or generate headers
print_gray "  Copying headers..."

# Check common locations for generated headers
HEADER_LOCATIONS=(
    "libdatadog/target/include/datadog/profiling.h"
    "libdatadog/libdd-profiling-ffi/datadog/profiling.h"
    "libdatadog/include/datadog/profiling.h"
)

HEADER_FOUND=false
for HEADER_PATH in "${HEADER_LOCATIONS[@]}"; do
    if [ -f "$HEADER_PATH" ]; then
        print_gray "  Found header at: $HEADER_PATH"
        cp "$HEADER_PATH" "$PACKAGE_DIR/include/"
        HEADER_FOUND=true
        break
    fi
done

if [ "$HEADER_FOUND" = false ]; then
    print_yellow "  Warning: Header file not found in common locations. Attempting to generate..."
    cd libdatadog/libdd-profiling-ffi

    # Try to generate headers with cbindgen if available
    if command -v cbindgen &> /dev/null; then
        cbindgen --output "$PACKAGE_DIR/include/profiling.h"
        if [ $? -eq 0 ]; then
            print_gray "  Generated header with cbindgen"
            HEADER_FOUND=true
        fi
    else
        print_yellow "  Warning: cbindgen not found. Header files will be missing."
        print_yellow "  Install cbindgen with: cargo install cbindgen"
    fi

    cd ../..
fi

# Copy license
print_gray "  Copying license..."
cp libdatadog/LICENSE "$PACKAGE_DIR/" 2>/dev/null || true
cp libdatadog/LICENSE-3rdparty.csv "$PACKAGE_DIR/" 2>/dev/null || true
cp libdatadog/NOTICE "$PACKAGE_DIR/" 2>/dev/null || true

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
