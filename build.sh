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
LIBDATADOG_VERSION="${1:-v25.0.0}"
PLATFORM="${2:-x64-linux}"
OUTPUT_DIR="${3:-output}"
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

# Map feature presets to builder features
# The builder crate has its own feature flags that control which FFI modules are included
case "$FEATURES" in
    minimal)
        BUILDER_FEATURES="profiling"  # Core profiling only (~4MB) - fastest build
        CARGO_FEATURES="--no-default-features --features $BUILDER_FEATURES"
        ;;
    standard)
        BUILDER_FEATURES="profiling,crashtracker,telemetry"  # Most common features (~5-6MB)
        CARGO_FEATURES="--no-default-features --features $BUILDER_FEATURES"
        ;;
    full)
        BUILDER_FEATURES="default"  # All features (~6.5MB) - uses default features which include everything
        CARGO_FEATURES=""  # Use default features
        ;;
    *)
        print_red "Error: Invalid feature preset '$FEATURES'. Must be: minimal, standard, or full"
        exit 1
        ;;
esac

if [ "$BUILDER_FEATURES" = "default" ]; then
    print_gray "  Using default features (full)"
else
    print_gray "  Builder features: $BUILDER_FEATURES"
fi

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

# Build using libdatadog builder crate
print_yellow "Building libdatadog using builder crate..."

# Create temporary build output directory
TEMP_BUILD_DIR="$OUTPUT_DIR/temp-build"
mkdir -p "$TEMP_BUILD_DIR"

cd libdatadog

# Prepare builder command
BUILDER_CMD="cargo run --release --bin release $CARGO_FEATURES --"

# Add output directory
BUILDER_CMD="$BUILDER_CMD --out \"$TEMP_BUILD_DIR\""

# Add target if cross-compiling
if [ -n "$CARGO_BUILD_TARGET" ]; then
    print_cyan "  Target architecture: $CARGO_BUILD_TARGET"
    BUILDER_CMD="$BUILDER_CMD --target $CARGO_BUILD_TARGET"
fi

print_gray "  Running builder..."
print_gray "  Command: $BUILDER_CMD"
eval $BUILDER_CMD
if [ $? -ne 0 ]; then
    print_red "Error: Builder failed"
    exit 1
fi

cd ..

# The builder creates output directly in the temp-build directory
print_gray "  Builder output: $TEMP_BUILD_DIR"

# Package the binaries
print_yellow "Packaging binaries..."

# Copy builder output to final package directory
PACKAGE_DIR="$OUTPUT_DIR/libdatadog-$PLATFORM"
print_gray "  Copying builder output to package directory..."
cp -r "$TEMP_BUILD_DIR" "$PACKAGE_DIR"

# Add our LICENSE-3rdparty.csv (summary) alongside the full yml from libdatadog
print_gray "  Adding LICENSE-3rdparty.csv..."
[ -f "LICENSE-3rdparty.csv" ] && cp LICENSE-3rdparty.csv "$PACKAGE_DIR/" 2>/dev/null || true

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
