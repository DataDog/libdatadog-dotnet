#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Builds the datadog-dotnet-ffi library (libdatadog's profiling FFI plus the .NET specific FFI,
# e.g. remote config) and replaces the profiling shared library of the package produced by
# libdatadog's builder with it, keeping its name.
#
# Usage: tools/build-ffi.sh TARGET PROFILE PACKAGE_DIR
# Runs on the host (macOS) or inside the build containers, right after the builder, so that
# it gets the same environment (compilers, CARGO_ENCODED_RUSTFLAGS, ...).

set -e

TARGET="$1"
PROFILE="$2"
PACKAGE_DIR="$3"

cd "$(dirname "$0")/.."

# The committed Cargo.lock, unless patched to a local libdatadog checkout (see build.sh)
if [ -n "$LIBDATADOG_PATCH" ]; then
    CARGO_ARGS="--config $LIBDATADOG_PATCH"
else
    CARGO_ARGS="--locked"
fi

case "$TARGET" in
    *-apple-darwin)
        LIB=libdatadog_profiling.dylib
        BUILT=libdatadog_dotnet_ffi.dylib
        LINK_ARG="-Wl,-install_name,@rpath/$LIB"
        ;;
    *)
        LIB=libdatadog_profiling.so
        BUILT=libdatadog_dotnet_ffi.so
        LINK_ARG="-Wl,-soname,$LIB"
        ;;
esac

# The musl builds pass their flags (including the soname) via CARGO_ENCODED_RUSTFLAGS.
if [ -z "$CARGO_ENCODED_RUSTFLAGS" ]; then
    export RUSTFLAGS="-C relocation-model=pic -C link-arg=$LINK_ARG"
fi

case "$PROFILE" in
    debug|dev) CARGO_PROFILE=dev; PROFILE_DIR=debug ;;
    *) CARGO_PROFILE="$PROFILE"; PROFILE_DIR="$PROFILE" ;;
esac

# Not in the builder's target directory: some libdatadog crates have library file names without
# a hash, which the builder's and this build would overwrite for each other.
cargo build -p datadog-dotnet-ffi --target "$TARGET" --profile "$CARGO_PROFILE" \
    --target-dir target/dotnet-ffi $CARGO_ARGS

cp "target/dotnet-ffi/$TARGET/$PROFILE_DIR/$BUILT" "$PACKAGE_DIR/lib/$LIB"

# Same post-processing as libdatadog's builder (builder/src/arch/*.rs)
case "$TARGET" in
    *-apple-darwin)
        strip -S "$PACKAGE_DIR/lib/$LIB"
        ;;
    *)
        objcopy --only-keep-debug "$PACKAGE_DIR/lib/$LIB" "$PACKAGE_DIR/lib/libdatadog_profiling.debug"
        strip -S "$PACKAGE_DIR/lib/$LIB"
        objcopy --add-gnu-debuglink="$PACKAGE_DIR/lib/libdatadog_profiling.debug" "$PACKAGE_DIR/lib/$LIB"
        ;;
esac

echo "Replaced $PACKAGE_DIR/lib/$LIB with the datadog-dotnet-ffi library"
