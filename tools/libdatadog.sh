#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Prints the directory (dir) or the version (version) of the libdatadog sources datadog-dotnet-ffi
# is built from: cargo's checkout of the libdatadog dependencies in datadog-dotnet-ffi/Cargo.toml,
# or the local checkout they are patched to (LIBDATADOG_PATCH, see build.sh --libdatadog-path).
# libdatadog's builder is installed from there, so that the headers etc. match the library.
#
# Usage: tools/libdatadog.sh dir|version

set -e

cd "$(dirname "$0")/.."

HOST=$(rustc -vV | sed -n 's/^host: //p')
DIR=$(cargo metadata --format-version 1 --filter-platform "$HOST" ${LIBDATADOG_PATCH:+--config "$LIBDATADOG_PATCH"} |
    grep -o '"manifest_path":"[^"]*/libdd-profiling-ffi/Cargo.toml"' |
    sed 's|^"manifest_path":"\(.*\)/libdd-profiling-ffi/Cargo.toml"$|\1|')
if [ -z "$DIR" ]; then
    echo "Error: libdd-profiling-ffi not found in the dependencies of datadog-dotnet-ffi" >&2
    exit 1
fi

case "$1" in
    dir) echo "$DIR" ;;
    version) sed -n '/^\[workspace\.package\]/,/^\[/s/^version = "\(.*\)"$/\1/p' "$DIR/Cargo.toml" ;;
    *) echo "Usage: $0 dir|version" >&2; exit 1 ;;
esac
