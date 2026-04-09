#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Unless explicitly stated otherwise all files in this repository are licensed
# under the Apache License Version 2.0.
# This product includes software developed at Datadog (https://www.datadoghq.com/).
# Copyright 2025-present Datadog, Inc.

# Build script for libdatadog-dotnet.
# The libdatadog version is controlled by the LIBDATADOG_VERSION file.
# Linux builds run inside Docker (for GLIBC 2.17 / musl compatibility).
# macOS builds run natively via cargo.

set -e

PLATFORM=""
OUTPUT_DIR="output"
PROFILE="release"
FEATURES=""
CLEAN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --platform) PLATFORM="$2"; shift 2 ;;
        --output)   OUTPUT_DIR="$2"; shift 2 ;;
        --profile)  PROFILE="$2"; shift 2 ;;
        --features) FEATURES="$2"; shift 2 ;;
        --clean)    CLEAN=true; shift ;;
        -h|--help)
            echo "Usage: $0 --platform PLATFORM [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --platform PLATFORM  Target platform / output directory suffix"
            echo "  --output DIR         Output directory (default: output)"
            echo "  --profile PROFILE    Build profile: debug or release (default: release)"
            echo "  --features FEATURES  Comma-separated builder crate features"
            echo "                       (default: profiling,crashtracker,data-pipeline,"
            echo "                                symbolizer,library-config,log)"
            echo "  --clean              Remove output directory before building"
            echo "  -h, --help           Show this help"
            echo ""
            echo "Environment variables:"
            echo "  CARGO_BUILD_TARGET   Override the Rust target triple"
            echo "                       (defaults to the value of --platform)"
            echo ""
            echo "Examples:"
            echo "  $0 --platform x86_64-unknown-linux-gnu"
            echo "  $0 --platform aarch64-apple-darwin --output dist"
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$PLATFORM" && -z "$CARGO_BUILD_TARGET" ]]; then
    echo "Error: --platform or CARGO_BUILD_TARGET is required" >&2
    exit 1
fi

TARGET="${CARGO_BUILD_TARGET:-$PLATFORM}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Read the libdatadog version.  Update LIBDATADOG_VERSION to upgrade.
VERSION=$(cat LIBDATADOG_VERSION)

# Builder crate features compiled into the release binary.
# These control which FFI modules are included in the output library.
# Feature names map to flags in builder/src/bin/release.rs in libdatadog.
# Override via --features on the command line.
FEATURES="${FEATURES:-profiling,crashtracker,data-pipeline,symbolizer,library-config,log}"

if [[ "$CLEAN" == true ]]; then
    rm -rf "$OUTPUT_DIR"
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
PACKAGE_DIR="$OUTPUT_DIR/libdatadog-${PLATFORM:-$TARGET}"

# docker_run IMAGE TARGET PLATFORM
# Installs the builder binary inside the container and runs it.
# The host ~/.cargo is mounted so the registry and git cache are reused
# across runs without re-downloading.
docker_run() {
    local image="$1"
    local target="$2"
    local platform="$3"
    docker run --rm \
        -v "$HOME/.cargo/registry:/root/.cargo/registry" \
        -v "$HOME/.cargo/git:/root/.cargo/git" \
        -v "$SCRIPT_DIR:/workspace" \
        -w /workspace \
        -e CARGO_HOME=/root/.cargo \
        -e BUILDER_VERSION="$VERSION" \
        -e BUILDER_FEATURES="$FEATURES" \
        -e BUILDER_PROFILE="$PROFILE" \
        -e BUILDER_TARGET="$target" \
        -e BUILDER_PLATFORM="$platform" \
        "$image" \
        bash -c '
            set -e
            cargo install \
                --git https://github.com/DataDog/libdatadog \
                --tag "v${BUILDER_VERSION}" \
                --bin release \
                --root /tmp/builder \
                --no-default-features \
                --features "${BUILDER_FEATURES}" \
                --force \
                builder
            HOST_TRIPLE=$(rustc -vV | grep "^host:" | awk "{print \$2}")
            PROFILE="${BUILDER_PROFILE}" \
            TARGET="${HOST_TRIPLE}" \
            CARGO_PKG_VERSION="${BUILDER_VERSION}" \
            CARGO_TARGET_DIR="/workspace/target" \
            /tmp/builder/bin/release \
                --out "/workspace/output/libdatadog-${BUILDER_PLATFORM}" \
                --target "${BUILDER_TARGET}"
        '
}

case "$TARGET" in
    x86_64-unknown-linux-gnu)
        docker build -q -t libdatadog-build-linux-x64 \
            -f tools/docker/Dockerfile.centos tools/docker/
        docker_run libdatadog-build-linux-x64 "$TARGET" "${PLATFORM:-$TARGET}"
        ;;
    aarch64-unknown-linux-gnu)
        docker build -q -t libdatadog-build-linux-aarch64 \
            -f tools/docker/Dockerfile.centos-aarch64 tools/docker/
        docker_run libdatadog-build-linux-aarch64 "$TARGET" "${PLATFORM:-$TARGET}"
        ;;
    x86_64-unknown-linux-musl)
        docker_run ghcr.io/cross-rs/x86_64-unknown-linux-musl:main "$TARGET" "${PLATFORM:-$TARGET}"
        ;;
    aarch64-unknown-linux-musl)
        docker build -q -t libdatadog-build-linux-musl-aarch64 \
            -f tools/docker/Dockerfile.musl-aarch64 tools/docker/
        docker_run libdatadog-build-linux-musl-aarch64 "$TARGET" "${PLATFORM:-$TARGET}"
        ;;
    *-apple-darwin)
        if ! command -v cargo &>/dev/null; then
            echo "Error: cargo not found. Install Rust from https://rustup.rs/" >&2
            exit 1
        fi
        # Unset CARGO_BUILD_TARGET so that cargo install compiles the builder
        # binary for the host.  The builder receives --target as a CLI arg and
        # handles cross-compilation internally (e.g. x86_64 on an arm64 runner).
        unset CARGO_BUILD_TARGET
        cargo install \
            --git https://github.com/DataDog/libdatadog \
            --tag "v${VERSION}" \
            --bin release \
            --root .builder \
            --no-default-features \
            --features "$FEATURES" \
            --force \
            builder
        HOST_TRIPLE=$(rustc -vV | grep "^host:" | awk '{print $2}')
        PROFILE="$PROFILE" \
        TARGET="$HOST_TRIPLE" \
        CARGO_PKG_VERSION="$VERSION" \
        CARGO_TARGET_DIR="$SCRIPT_DIR/target" \
        .builder/bin/release \
            --out "$PACKAGE_DIR" \
            --target "$TARGET"
        ;;
    *)
        echo "Error: unsupported target '$TARGET'" >&2
        echo "Supported targets: x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu," >&2
        echo "                   x86_64-unknown-linux-musl, aarch64-unknown-linux-musl," >&2
        echo "                   x86_64-apple-darwin, aarch64-apple-darwin" >&2
        exit 1
        ;;
esac
