#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Unless explicitly stated otherwise all files in this repository are licensed
# under the Apache License Version 2.0.
# This product includes software developed at Datadog (https://www.datadoghq.com/).
# Copyright 2025-present Datadog, Inc.

# Build script for libdatadog-dotnet
# This script builds custom libdatadog binaries for the .NET SDK

set -e

# Default parameters
LIBDATADOG_VERSION="v25.0.0"
PLATFORM="x64-linux"
OUTPUT_DIR="output"
FEATURES="minimal"
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
        --features)
            FEATURES="$2"
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
            echo "  --features PRESET   Feature preset: minimal, standard, or full (default: minimal)"
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
print_gray "  Feature preset: $FEATURES"
print_gray "  Output directory: $OUTPUT_DIR"

# Define feature sets
case "$FEATURES" in
    minimal)
        FEATURE_FLAGS="ddcommon-ffi,cbindgen"  # Core profiling only (~4MB) - fastest build
        ;;
    standard)
        FEATURE_FLAGS="ddcommon-ffi,crashtracker-ffi,crashtracker-collector,demangler,ddtelemetry-ffi,cbindgen"  # Most common features (~5-6MB)
        ;;
    full)
        FEATURE_FLAGS="ddcommon-ffi,crashtracker-ffi,crashtracker-collector,crashtracker-receiver,demangler,ddtelemetry-ffi,data-pipeline-ffi,symbolizer,ddsketch-ffi,datadog-log-ffi,datadog-library-config-ffi,datadog-ffe-ffi,cbindgen"  # All features (~6.5MB) - matches original libdatadog
        ;;
    *)
        print_red "Error: Invalid feature preset '$FEATURES'. Must be: minimal, standard, or full"
        exit 1
        ;;
esac

print_gray "  Features: $FEATURE_FLAGS"

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
    # Use cross for musl and ARM64 Linux targets that require C cross-compilers
    # Don't use cross for macOS - use native cargo cross-compilation instead
    case "$CARGO_BUILD_TARGET" in
        *-apple-darwin)
            # macOS targets don't need cross - use native cargo
            USE_CROSS=false
            ;;
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
$CARGO_CMD build --release -p libdd-profiling-ffi --features "$FEATURE_FLAGS" $CARGO_TARGET_ARG
if [ $? -ne 0 ]; then
    print_red "Error: Release build failed"
    exit 1
fi

# Build debug version
print_gray "  Building debug configuration with $CARGO_CMD..."
$CARGO_CMD build -p libdd-profiling-ffi --features "$FEATURE_FLAGS" $CARGO_TARGET_ARG
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

# Determine library extension based on platform
case "$CARGO_BUILD_TARGET" in
    *-apple-darwin)
        # macOS uses .dylib
        DYNAMIC_LIB_EXT="dylib"
        DYNAMIC_LIB_NAME="libdatadog_profiling.dylib"
        ;;
    *)
        # Linux uses .so
        DYNAMIC_LIB_EXT="so"
        DYNAMIC_LIB_NAME="libdatadog_profiling.so"
        ;;
esac

# Dynamic build (shared library) - rename to libdatadog_profiling.so/.dylib
if [ -f "$RELEASE_DIR/libdatadog_profiling_ffi.$DYNAMIC_LIB_EXT" ]; then
    cp "$RELEASE_DIR/libdatadog_profiling_ffi.$DYNAMIC_LIB_EXT" "$PACKAGE_DIR/lib/$DYNAMIC_LIB_NAME"
else
    print_yellow "  Warning: Release shared library (.$DYNAMIC_LIB_EXT) not found"
fi

# Static build (static library .a) - rename to libdatadog_profiling.a
if [ -f "$RELEASE_DIR/libdatadog_profiling_ffi.a" ]; then
    cp "$RELEASE_DIR/libdatadog_profiling_ffi.a" "$PACKAGE_DIR/lib/libdatadog_profiling.a"
else
    print_yellow "  Warning: Release static library (.a) not found"
fi

# Strip libraries (matches libdatadog's exact process)
print_gray "  Stripping binaries and extracting debug symbols..."

# Determine tool prefix for cross-compilation
OBJCOPY_CMD="objcopy"
STRIP_CMD="strip"

if [ -n "$CARGO_BUILD_TARGET" ]; then
    case "$CARGO_BUILD_TARGET" in
        aarch64-*-gnu)
            # ARM64 GNU targets need aarch64-linux-gnu- prefix
            OBJCOPY_CMD="aarch64-linux-gnu-objcopy"
            STRIP_CMD="aarch64-linux-gnu-strip"
            ;;
        aarch64-*-musl)
            # ARM64 musl targets - try specific tool first, fall back to gnu
            if command -v aarch64-linux-musl-objcopy &> /dev/null; then
                OBJCOPY_CMD="aarch64-linux-musl-objcopy"
                STRIP_CMD="aarch64-linux-musl-strip"
            else
                OBJCOPY_CMD="aarch64-linux-gnu-objcopy"
                STRIP_CMD="aarch64-linux-gnu-strip"
            fi
            ;;
        x86_64-*-musl)
            # x86_64 musl can use native tools
            OBJCOPY_CMD="objcopy"
            STRIP_CMD="strip"
            ;;
    esac
fi

print_gray "    Using tools: $OBJCOPY_CMD, $STRIP_CMD"

# Step 1: Remove LLVM bitcode section from static library (reduces size significantly)
if [ -f "$PACKAGE_DIR/lib/libdatadog_profiling.a" ]; then
    case "$CARGO_BUILD_TARGET" in
        *-apple-darwin)
            # macOS: Remove __LLVM,__bitcode section using llvm-objcopy
            # objcopy is not available on macOS, so we use llvm-objcopy
            if command -v llvm-objcopy &> /dev/null; then
                print_gray "    Removing LLVM bitcode from static library (macOS)..."
                # Create temporary directory for extraction
                TEMP_DIR=$(mktemp -d)
                cd "$TEMP_DIR"

                # Extract all object files from the archive
                ar -x "$PACKAGE_DIR/lib/libdatadog_profiling.a"

                # Remove __LLVM,__bitcode section from each object file
                for obj in *.o; do
                    llvm-objcopy --remove-section=__LLVM,__bitcode "$obj" 2>/dev/null || true
                done

                # Rebuild the archive
                rm -f "$PACKAGE_DIR/lib/libdatadog_profiling.a"
                ar -crs "$PACKAGE_DIR/lib/libdatadog_profiling.a" *.o

                # Clean up
                cd - > /dev/null
                rm -rf "$TEMP_DIR"

                print_gray "    LLVM bitcode removed successfully"
            else
                print_yellow "    Warning: llvm-objcopy not available, static library will be larger"
            fi
            ;;
        *)
            # Linux: Remove .llvmbc section using objcopy
            if command -v $OBJCOPY_CMD &> /dev/null; then
                print_gray "    Removing .llvmbc section from static library..."
                $OBJCOPY_CMD --remove-section .llvmbc "$PACKAGE_DIR/lib/libdatadog_profiling.a" 2>/dev/null || {
                    print_yellow "    Warning: Failed to remove .llvmbc section (may not be available for this target)"
                }
            else
                print_yellow "    Warning: $OBJCOPY_CMD not available, cannot optimize static library"
            fi
            ;;
    esac
fi

# Step 2-4: Platform-specific stripping
if [ -f "$PACKAGE_DIR/lib/$DYNAMIC_LIB_NAME" ]; then
    case "$CARGO_BUILD_TARGET" in
        *-apple-darwin)
            # macOS stripping (simpler - no separate debug file)
            if command -v strip &> /dev/null; then
                print_gray "    Stripping macOS library..."
                strip -S "$PACKAGE_DIR/lib/$DYNAMIC_LIB_NAME" || {
                    print_yellow "    Warning: Failed to strip library"
                }

                # Fix rpath using install_name_tool (macOS-specific)
                if command -v install_name_tool &> /dev/null; then
                    print_gray "    Fixing rpath with install_name_tool..."
                    install_name_tool -id "@rpath/$DYNAMIC_LIB_NAME" "$PACKAGE_DIR/lib/$DYNAMIC_LIB_NAME" || {
                        print_yellow "    Warning: Failed to fix rpath"
                    }
                fi
            else
                print_yellow "    Warning: strip not available, binary will not be stripped"
            fi
            ;;
        *)
            # Linux stripping (with separate debug file)
            if command -v $OBJCOPY_CMD &> /dev/null && command -v $STRIP_CMD &> /dev/null; then
                # Step 2: Extract debug symbols
                print_gray "    Extracting debug symbols..."
                $OBJCOPY_CMD --only-keep-debug \
                    "$PACKAGE_DIR/lib/$DYNAMIC_LIB_NAME" \
                    "$PACKAGE_DIR/lib/libdatadog_profiling.debug" || {
                    print_yellow "    Warning: Failed to extract debug symbols"
                }

                # Step 3: Strip the shared library
                # Use -S for glibc (preserves global symbols), -s for musl (strip all)
                print_gray "    Stripping shared library..."
                case "$CARGO_BUILD_TARGET" in
                    *-musl)
                        # musl uses full strip (-s)
                        $STRIP_CMD -s "$PACKAGE_DIR/lib/$DYNAMIC_LIB_NAME" || {
                            print_yellow "    Warning: Failed to strip library"
                        }
                        ;;
                    *)
                        # glibc uses -S (strip debug symbols but keep global symbols)
                        $STRIP_CMD -S "$PACKAGE_DIR/lib/$DYNAMIC_LIB_NAME" || {
                            print_yellow "    Warning: Failed to strip library"
                        }
                        ;;
                esac

                # Step 4: Link debug symbols to stripped binary
                if [ -f "$PACKAGE_DIR/lib/libdatadog_profiling.debug" ]; then
                    print_gray "    Linking debug symbols..."
                    $OBJCOPY_CMD --add-gnu-debuglink="$PACKAGE_DIR/lib/libdatadog_profiling.debug" \
                        "$PACKAGE_DIR/lib/$DYNAMIC_LIB_NAME" || {
                        print_yellow "    Warning: Failed to link debug symbols"
                    }
                fi
            else
                print_yellow "    Warning: $OBJCOPY_CMD and/or $STRIP_CMD not available, binaries will not be stripped"
                print_yellow "    This will result in much larger files than the original libdatadog releases"
            fi
            ;;
    esac
fi

# Generate headers using cbindgen
print_gray "  Generating headers with cbindgen..."

# Check if cbindgen is installed
if ! command -v cbindgen &> /dev/null; then
    print_red "Error: cbindgen not found. Please install it with: cargo install cbindgen"
    exit 1
fi

# Generate common.h from libdd-common-ffi
print_gray "    Generating common.h..."
cd libdatadog/libdd-common-ffi
cbindgen --output "$PACKAGE_DIR/include/datadog/common.h"
if [ $? -ne 0 ]; then
    print_red "Error: Failed to generate common.h"
    cd ../..
    exit 1
fi
cd ../..

# Determine which headers to generate based on feature preset
HEADERS_TO_GENERATE=("profiling")

case "$FEATURES" in
    standard)
        HEADERS_TO_GENERATE+=("crashtracker" "telemetry")
        ;;
    full)
        HEADERS_TO_GENERATE+=("crashtracker" "telemetry" "data-pipeline" "library-config" "log" "ddsketch" "ffe")
        ;;
esac

# Generate each header
GENERATED_HEADERS=()
for HEADER_NAME in "${HEADERS_TO_GENERATE[@]}"; do
    # Map header name to FFI crate directory
    case "$HEADER_NAME" in
        profiling) FFI_CRATE="libdd-profiling-ffi" ;;
        crashtracker) FFI_CRATE="libdd-crashtracker-ffi" ;;
        telemetry) FFI_CRATE="libdd-telemetry-ffi" ;;
        data-pipeline) FFI_CRATE="libdd-data-pipeline-ffi" ;;
        library-config) FFI_CRATE="libdd-library-config-ffi" ;;
        log) FFI_CRATE="libdd-log-ffi" ;;
        ddsketch) FFI_CRATE="libdd-ddsketch-ffi" ;;
        ffe) FFI_CRATE="datadog-ffe-ffi" ;;
        *) continue ;;
    esac

    # Check if cbindgen.toml exists for this crate
    if [ ! -f "libdatadog/$FFI_CRATE/cbindgen.toml" ]; then
        print_yellow "    Warning: cbindgen.toml not found for $FFI_CRATE, skipping..."
        continue
    fi

    print_gray "    Generating $HEADER_NAME.h..."
    cd "libdatadog/$FFI_CRATE"
    cbindgen --output "$PACKAGE_DIR/include/datadog/$HEADER_NAME.h"
    if [ $? -eq 0 ]; then
        GENERATED_HEADERS+=("$PACKAGE_DIR/include/datadog/$HEADER_NAME.h")
    else
        print_yellow "    Warning: Failed to generate $HEADER_NAME.h"
    fi
    cd ../..
done

# Deduplicate headers - remove definitions from child headers that exist in common.h
if [ ${#GENERATED_HEADERS[@]} -gt 0 ]; then
    print_gray "  Deduplicating headers..."

    # Build the dedup_headers tool from libdatadog/tools if needed
    if [ ! -f "libdatadog/target/release/dedup_headers" ] && [ ! -f "libdatadog/target/debug/dedup_headers" ]; then
        print_gray "    Building dedup_headers tool..."
        cd libdatadog
        $CARGO_CMD build --release --bin dedup_headers --manifest-path tools/Cargo.toml
        if [ $? -ne 0 ]; then
            print_yellow "    Warning: Failed to build dedup_headers tool. Headers may contain duplicate definitions."
        fi
        cd ..
    fi

    # Use the dedup_headers tool
    if [ -f "libdatadog/target/release/dedup_headers" ]; then
        ./libdatadog/target/release/dedup_headers "$PACKAGE_DIR/include/datadog/common.h" "${GENERATED_HEADERS[@]}"
    elif [ -f "libdatadog/target/debug/dedup_headers" ]; then
        ./libdatadog/target/debug/dedup_headers "$PACKAGE_DIR/include/datadog/common.h" "${GENERATED_HEADERS[@]}"
    else
        print_yellow "  Warning: dedup_headers tool not found. Headers may contain duplicate definitions."
    fi
fi

# Verify critical headers exist
if [ ! -f "$PACKAGE_DIR/include/datadog/common.h" ]; then
    print_red "Error: common.h not generated"
    exit 1
fi

if [ ! -f "$PACKAGE_DIR/include/datadog/profiling.h" ]; then
    print_red "Error: profiling.h not generated"
    exit 1
fi

print_gray "  Headers generated successfully"

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

# Determine library location for CMake based on platform
case "$CARGO_BUILD_TARGET" in
    *-apple-darwin)
        CMAKE_LIB_LOCATION="\${DATADOG_LIBRARY_DIRS}/libdatadog_profiling.dylib"
        ;;
    *)
        CMAKE_LIB_LOCATION="\${DATADOG_LIBRARY_DIRS}/libdatadog_profiling.so"
        ;;
esac

cat > "$PACKAGE_DIR/cmake/DatadogConfig.cmake" << EOF
# DatadogConfig.cmake
get_filename_component(DATADOG_CMAKE_DIR "\${CMAKE_CURRENT_LIST_FILE}" PATH)
set(DATADOG_INCLUDE_DIRS "\${DATADOG_CMAKE_DIR}/../include")
set(DATADOG_LIBRARY_DIRS "\${DATADOG_CMAKE_DIR}/../lib")
set(DATADOG_LIBRARIES datadog_profiling)

# Set up imported target
add_library(Datadog::Profiling SHARED IMPORTED)
set_target_properties(Datadog::Profiling PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "\${DATADOG_INCLUDE_DIRS}"
    IMPORTED_LOCATION "$CMAKE_LIB_LOCATION"
)
EOF

# Copy license files
print_gray "  Copying license files..."
# Copy LICENSE from libdatadog (Apache 2.0)
cp libdatadog/LICENSE "$PACKAGE_DIR/" 2>/dev/null || true
# Copy NOTICE from libdatadog
[ -f "libdatadog/NOTICE" ] && cp libdatadog/NOTICE "$PACKAGE_DIR/" 2>/dev/null || true
# Copy LICENSE-3rdparty.csv from libdatadog-dotnet root (summary of components)
[ -f "LICENSE-3rdparty.csv" ] && cp LICENSE-3rdparty.csv "$PACKAGE_DIR/" 2>/dev/null || true
# Copy LICENSE-3rdparty.yml from libdatadog (full license texts)
[ -f "libdatadog/LICENSE-3rdparty.yml" ] && cp libdatadog/LICENSE-3rdparty.yml "$PACKAGE_DIR/" 2>/dev/null || true

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
