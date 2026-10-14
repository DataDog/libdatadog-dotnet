#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Unless explicitly stated otherwise all files in this repository are licensed
# under the Apache License Version 2.0.
# This product includes software developed at Datadog (https://www.datadoghq.com/).
# Copyright 2025-present Datadog, Inc.

# Build script for libdatadog-dotnet.
# The libdatadog revision is pinned by the libdatadog dependencies in datadog-dotnet-ffi/Cargo.toml.
# Linux builds run inside Docker (for GLIBC 2.17 / musl compatibility).
# macOS builds run natively via cargo.

set -e

PLATFORM=""
OUTPUT_DIR="output"
PROFILE="release"
CLEAN=false
LIBDATADOG_PATH=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --platform) PLATFORM="$2"; shift 2 ;;
        --output)   OUTPUT_DIR="$2"; shift 2 ;;
        --profile)  PROFILE="$2"; shift 2 ;;
        --clean)    CLEAN=true; shift ;;
        --libdatadog-path) LIBDATADOG_PATH="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 --platform PLATFORM [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --platform PLATFORM  Target platform / output directory suffix"
            echo "  --output DIR         Output directory (default: output)"
            echo "  --profile PROFILE    Build profile: debug or release (default: release)"
            echo "  --clean              Remove output directory before building"
            echo "  --libdatadog-path P  Build from a local libdatadog checkout instead of"
            echo "                       the revision in datadog-dotnet-ffi/Cargo.toml"
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

# Builder crate features: which FFI modules (headers etc.) the package contains. Feature names map
# to flags in builder/src/bin/release.rs in libdatadog. Must match the libdd-profiling-ffi features
# in datadog-dotnet-ffi/Cargo.toml, which the shipped library is built with.
FEATURES="profiling,crashtracker,symbolizer,library-config"

if [[ "$CLEAN" == true ]]; then
    rm -rf "$OUTPUT_DIR"
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
PACKAGE_DIR="$OUTPUT_DIR/libdatadog-${PLATFORM:-$TARGET}"

# A local libdatadog checkout replaces the libdatadog dependencies of datadog-dotnet-ffi via a
# cargo [patch] (passed with --config), and with them the sources tools/libdatadog.sh finds.
DOCKER_LIBDATADOG_ARGS=()
if [[ -n "$LIBDATADOG_PATH" ]]; then
    LIBDATADOG_PATH="$(cd "$LIBDATADOG_PATH" && pwd)"
    export LIBDATADOG_PATCH=target/libdatadog-patch.toml
    mkdir -p target
    {
        echo '[patch."https://github.com/DataDog/libdatadog"]'
        sed -n 's|^\([a-z0-9-]*\) = { git = "https://github.com/DataDog/libdatadog".*|\1|p' \
            datadog-dotnet-ffi/Cargo.toml | sort -u | while read -r crate; do
            echo "$crate = { path = \"$LIBDATADOG_PATH/$crate\" }"
        done
    } > "$LIBDATADOG_PATCH"
    # Mounted at the same path, so that the patch also applies inside the containers
    DOCKER_LIBDATADOG_ARGS=(-v "$LIBDATADOG_PATH:$LIBDATADOG_PATH" -e LIBDATADOG_PATCH)
fi

# docker_run_gnu IMAGE TARGET PLATFORM
# Runs the builder inside an x86_64 GNU/glibc container (CentOS 7 sysroot).
# The host Rust toolchain is mounted read-write so that:
#   - cargo/rustc binaries compiled against glibc 2.17 run on CentOS 7 without issues.
#   - rustup target add can install any missing cross-compilation target components.
#   - The Cargo registry/git caches on the host are reused across runs.
# aarch64-unknown-linux-gnu does NOT use this path — it goes through
# docker_run_musl with --platform linux/arm64 because libdd-libunwind-sys
# can't be cross-compiled (its build.rs runs ./configure with no cross
# wiring), so target = host inside a QEMU-emulated arm64 container.
docker_run_gnu() {
    local image="$1"
    local target="$2"
    local platform="$3"
    local cargo_home="${CARGO_HOME:-$HOME/.cargo}"
    local rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"
    docker run --rm \
        -v "${cargo_home}:/usr/local/cargo" \
        -v "${rustup_home}:/usr/local/rustup" \
        -v "$SCRIPT_DIR:/workspace" \
        "${DOCKER_LIBDATADOG_ARGS[@]}" \
        -w /workspace \
        -e CARGO_HOME=/usr/local/cargo \
        -e RUSTUP_HOME=/usr/local/rustup \
        -e BUILDER_FEATURES="$FEATURES" \
        -e BUILDER_PROFILE="$PROFILE" \
        -e BUILDER_TARGET="$target" \
        -e BUILDER_PLATFORM="$platform" \
        "$image" \
        sh -c '
            set -e
            export PATH="/usr/local/cargo/bin:${PATH}"
            rustup target add "${BUILDER_TARGET}"
            # Unset CARGO_ENCODED_RUSTFLAGS so cargo install builds the builder
            # binary without interference from any RUSTFLAGS overrides.
            unset CARGO_ENCODED_RUSTFLAGS
            LIBDATADOG_DIR=$(sh tools/libdatadog.sh dir)
            cargo install \
                --path "${LIBDATADOG_DIR}/builder" \
                --bin release \
                --root /tmp/builder \
                --no-default-features \
                --features "${BUILDER_FEATURES}" \
                --locked \
                --force \
                builder
            HOST_TRIPLE=$(rustc -vV | grep "^host:" | awk "{print \$2}")
            # Native build (x86_64 host = x86_64 target), so cmake::Config::build()
            # gets TARGET = HOST and stays out of cross-compile mode.
            BUILDER_CMAKE_TARGET="${HOST_TRIPLE}"
            # The builder calls cmake::Config::build() at runtime, outside of a
            # cargo build-script context.  The cmake crate reads cargo-specific
            # env vars that cargo normally provides automatically; since we run
            # the builder as a standalone binary we must supply them ourselves.
            OPT_LEVEL=3
            DEBUG=false
            case "${BUILDER_PROFILE}" in
                debug) OPT_LEVEL=0; DEBUG=true ;;
            esac
            PROFILE="${BUILDER_PROFILE}" \
            HOST="${HOST_TRIPLE}" \
            TARGET="${BUILDER_CMAKE_TARGET}" \
            OUT_DIR="/workspace/target/out" \
            OPT_LEVEL="${OPT_LEVEL}" \
            DEBUG="${DEBUG}" \
            NUM_JOBS="$(nproc 2>/dev/null || echo 4)" \
            CARGO_PKG_VERSION="$(sh tools/libdatadog.sh version)" \
            CARGO_TARGET_DIR="/workspace/target" \
            /tmp/builder/bin/release \
                --out "/workspace/output/libdatadog-${BUILDER_PLATFORM}" \
                --target "${BUILDER_TARGET}"
            sh tools/build-ffi.sh "${BUILDER_TARGET}" "${BUILDER_PROFILE}" \
                "/workspace/output/libdatadog-${BUILDER_PLATFORM}"
        '
}

# docker_run_musl IMAGE TARGET PLATFORM
# Runs the builder inside an Alpine (musl) container.
# Rust is installed via rustup inside the image (see tools/docker/Dockerfile.musl-*);
# Alpine is pinned to 3.17 (x64) / 3.18 (aarch64) to match dd-trace-dotnet's build env.
# The host ~/.cargo registry and git caches are mounted to avoid re-downloading.
docker_run_musl() {
    local image="$1"
    local target="$2"
    local platform="$3"
    local docker_platform="$4"
    docker run --rm \
        --platform "$docker_platform" \
        -v "$HOME/.cargo/registry:/root/.cargo/registry" \
        -v "$HOME/.cargo/git:/root/.cargo/git" \
        -v "$SCRIPT_DIR:/workspace" \
        "${DOCKER_LIBDATADOG_ARGS[@]}" \
        -w /workspace \
        -e CARGO_HOME=/root/.cargo \
        -e BUILDER_FEATURES="$FEATURES" \
        -e BUILDER_PROFILE="$PROFILE" \
        -e BUILDER_TARGET="$target" \
        -e BUILDER_PLATFORM="$platform" \
        "$image" \
        sh -c '
            set -e
            export PATH="${CARGO_HOME}/bin:/usr/local/cargo/bin:${PATH}"
            # Unset CARGO_ENCODED_RUSTFLAGS so cargo install builds the builder
            # binary without interference from any RUSTFLAGS overrides.
            unset CARGO_ENCODED_RUSTFLAGS
            LIBDATADOG_DIR=$(sh tools/libdatadog.sh dir)
            cargo install \
                --path "${LIBDATADOG_DIR}/builder" \
                --bin release \
                --root /tmp/builder \
                --no-default-features \
                --features "${BUILDER_FEATURES}" \
                --locked \
                --force \
                builder
            HOST_TRIPLE=$(rustc -vV | grep "^host:" | awk "{print \$2}")
            # The builder crate sets RUSTFLAGS via .env("RUSTFLAGS", ...) on the
            # cargo subprocess it spawns, which normally overrides any external
            # RUSTFLAGS.  CARGO_ENCODED_RUSTFLAGS has higher priority in cargo
            # and cannot be overridden by the builder that way.
            # For musl targets, the builder'"'"'s musl.rs RUSTFLAGS is missing
            # -C target-feature=-crt-static, which is required to build a cdylib
            # (musl defaults to crt-static=true, disabling cdylib support).
            # Flags are separated by \x1f (ASCII unit separator, octal \037).
            case "${BUILDER_TARGET}" in
                *-musl)
                    SEP=$(printf "\037")
                    export CARGO_ENCODED_RUSTFLAGS="-C${SEP}relocation-model=pic${SEP}-C${SEP}target-feature=-crt-static${SEP}-C${SEP}link-arg=-Wl,-soname,libdatadog_profiling.so"
                    ;;
            esac
            # The builder calls cmake::Config::build() at runtime, outside of a
            # cargo build-script context.  The cmake crate reads cargo-specific
            # env vars that cargo normally provides automatically; since we run
            # the builder as a standalone binary we must supply them ourselves.
            OPT_LEVEL=3
            DEBUG=false
            case "${BUILDER_PROFILE}" in
                debug) OPT_LEVEL=0; DEBUG=true ;;
            esac
            PROFILE="${BUILDER_PROFILE}" \
            HOST="${HOST_TRIPLE}" \
            TARGET="${HOST_TRIPLE}" \
            OUT_DIR="/workspace/target/out" \
            OPT_LEVEL="${OPT_LEVEL}" \
            DEBUG="${DEBUG}" \
            NUM_JOBS="$(nproc 2>/dev/null || echo 4)" \
            CARGO_PKG_VERSION="$(sh tools/libdatadog.sh version)" \
            CARGO_TARGET_DIR="/workspace/target" \
            /tmp/builder/bin/release \
                --out "/workspace/output/libdatadog-${BUILDER_PLATFORM}" \
                --target "${BUILDER_TARGET}"
            sh tools/build-ffi.sh "${BUILDER_TARGET}" "${BUILDER_PROFILE}" \
                "/workspace/output/libdatadog-${BUILDER_PLATFORM}"
        '
}

case "$TARGET" in
    x86_64-unknown-linux-gnu)
        docker build -q -t libdatadog-build-linux-x64 \
            -f tools/docker/Dockerfile.centos tools/docker/
        docker_run_gnu libdatadog-build-linux-x64 "$TARGET" "${PLATFORM:-$TARGET}"
        ;;
    aarch64-unknown-linux-gnu)
        # Run native arm64 under QEMU emulation (matches libdatadog's own
        # docker-bake.hcl pattern) — libdd-libunwind-sys's build.rs runs
        # ./configure + make without any cross-compile wiring, so it has
        # to be built on the target arch.  Image bundles its own Rust.
        docker build -q --platform linux/arm64 -t libdatadog-build-linux-aarch64 \
            -f tools/docker/Dockerfile.centos-aarch64 tools/docker/
        docker_run_musl libdatadog-build-linux-aarch64 "$TARGET" "${PLATFORM:-$TARGET}" linux/arm64
        ;;
    x86_64-unknown-linux-musl)
        docker build -q -t libdatadog-build-linux-musl-x64 \
            -f tools/docker/Dockerfile.musl-x64 tools/docker/
        docker_run_musl libdatadog-build-linux-musl-x64 "$TARGET" "${PLATFORM:-$TARGET}" linux/amd64
        ;;
    aarch64-unknown-linux-musl)
        # Build the image for linux/arm64 so it matches the runtime arch (QEMU).
        docker build -q --platform linux/arm64 -t libdatadog-build-linux-musl-aarch64 \
            -f tools/docker/Dockerfile.musl-aarch64 tools/docker/
        docker_run_musl libdatadog-build-linux-musl-aarch64 "$TARGET" "${PLATFORM:-$TARGET}" linux/arm64
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
        LIBDATADOG_DIR=$(sh tools/libdatadog.sh dir)
        cargo install \
            --path "$LIBDATADOG_DIR/builder" \
            --bin release \
            --root .builder \
            --no-default-features \
            --features "$FEATURES" \
            --locked \
            --force \
            builder
        HOST_TRIPLE=$(rustc -vV | grep "^host:" | awk '{print $2}')
        # The builder calls cmake::Config::build() at runtime, outside of a
        # cargo build-script context.  cmake-rs reads HOST/TARGET/OUT_DIR/
        # OPT_LEVEL/DEBUG/NUM_JOBS from the env (cargo would normally provide
        # them); we must supply them ourselves or it panics with
        # "environment variable HOST not defined" at lib.rs:1132.
        OPT_LEVEL=3
        DEBUG=false
        case "$PROFILE" in
            debug) OPT_LEVEL=0; DEBUG=true ;;
        esac
        PROFILE="$PROFILE" \
        HOST="$HOST_TRIPLE" \
        TARGET="$HOST_TRIPLE" \
        OUT_DIR="$SCRIPT_DIR/target/out" \
        OPT_LEVEL="$OPT_LEVEL" \
        DEBUG="$DEBUG" \
        NUM_JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" \
        CARGO_PKG_VERSION="$(sh tools/libdatadog.sh version)" \
        CARGO_TARGET_DIR="$SCRIPT_DIR/target" \
        .builder/bin/release \
            --out "$PACKAGE_DIR" \
            --target "$TARGET"
        sh tools/build-ffi.sh "$TARGET" "$PROFILE" "$PACKAGE_DIR"
        ;;
    *)
        echo "Error: unsupported target '$TARGET'" >&2
        echo "Supported targets: x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu," >&2
        echo "                   x86_64-unknown-linux-musl, aarch64-unknown-linux-musl," >&2
        echo "                   x86_64-apple-darwin, aarch64-apple-darwin" >&2
        exit 1
        ;;
esac
