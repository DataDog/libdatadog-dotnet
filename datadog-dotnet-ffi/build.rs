// Copyright 2026-Present Datadog, Inc. https://www.datadoghq.com/
// SPDX-License-Identifier: Apache-2.0

fn main() {
    // FileVersion from LIBDATADOG_PACKAGE_VERSION (build.ps1 -FileVersion): Windows Installer
    // compares it when deciding whether to replace the DLL on upgrade. No-op on other targets.
    build_common::embed_windows_version_info("datadog_profiling_ffi.dll", "Datadog libdatadog FFI");
}
