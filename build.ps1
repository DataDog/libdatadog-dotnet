#!/usr/bin/env pwsh
# SPDX-License-Identifier: Apache-2.0
#
# Unless explicitly stated otherwise all files in this repository are licensed
# under the Apache License Version 2.0.
# This product includes software developed at Datadog (https://www.datadoghq.com/).
# Copyright 2025-present Datadog, Inc.

# Build script for libdatadog-dotnet on Windows.
# The libdatadog version is controlled by the LIBDATADOG_VERSION file.
#
# Produces a Windows zip with the legacy layout the .NET tracer's vcpkg
# portfile and runtime DLL loader still expect:
#
#   release/dynamic/datadog_profiling_ffi.{dll,lib,pdb}   (DLL + import lib)
#   release/static/datadog_profiling_ffi.lib              (static archive)
#   debug/dynamic/datadog_profiling_ffi.{dll,lib,pdb}
#   debug/static/datadog_profiling_ffi.lib
#   include/datadog/...    cmake/DatadogConfig.cmake    LICENSE  NOTICE  ...
#
# The libdatadog builder crate strips the _ffi suffix and produces a flat
# lib/ layout on every platform, but dd-trace-dotnet's Windows side still
# expects the old names (cor_profiler.cpp loads "datadog_profiling_ffi.dll"
# by name, the MSI installer references it, etc.).  We therefore run the
# builder once per profile (release + debug) and re-assemble the layout
# from cargo's raw target/ outputs, which keep the _ffi names.

param(
    [string]$Platform = "x64-windows",
    [string]$OutputDir = "output",
    [string]$Features = "profiling,crashtracker,data-pipeline,symbolizer,library-config,log",
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

# Resolve target triple from platform name
$TargetMap = @{
    "x64-windows" = "x86_64-pc-windows-msvc"
    "x86-windows" = "i686-pc-windows-msvc"
}
$Target = if ($env:CARGO_BUILD_TARGET) {
    $env:CARGO_BUILD_TARGET
} elseif ($TargetMap.ContainsKey($Platform)) {
    $TargetMap[$Platform]
} else {
    $Platform
}

# Read the libdatadog version.  Update LIBDATADOG_VERSION to upgrade.
$Version = (Get-Content LIBDATADOG_VERSION).Trim()

Write-Host "Building libdatadog-dotnet" -ForegroundColor Cyan
Write-Host "  Platform : $Platform" -ForegroundColor Gray
Write-Host "  Target   : $Target" -ForegroundColor Gray
Write-Host "  Features : $Features" -ForegroundColor Gray
Write-Host "  Output   : $OutputDir" -ForegroundColor Gray
Write-Host "  Version  : $Version" -ForegroundColor Gray

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Host "Error: cargo not found. Install Rust from https://rustup.rs/" -ForegroundColor Red
    exit 1
}

if ($Clean) {
    Write-Host "Cleaning output directory..." -ForegroundColor Yellow
    if (Test-Path $OutputDir) { Remove-Item -Path $OutputDir -Recurse -Force }
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = (Resolve-Path $OutputDir).Path
$PackageDir = Join-Path $OutputDir "libdatadog-$Platform"

# Install the builder binary once.  Each subsequent profile run reuses it.
cargo install `
    --git https://github.com/DataDog/libdatadog `
    --tag "v${Version}" `
    --bin release `
    --root .builder `
    --no-default-features `
    --features $Features `
    --locked `
    --force `
    builder

if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: cargo install failed" -ForegroundColor Red
    exit 1
}

$HostTriple = (rustc -vV 2>&1 | Where-Object { $_ -match "^host:" }) -replace "^host:\s*", ""
$CargoTargetDir = Join-Path $PWD "target"

# Run the builder once per profile.  The builder leaves cargo artifacts in
# target/$Target/$profile/ (with the original _ffi names from cargo) and a
# packaged tree under --out (with the _ffi suffix stripped, flat lib/ layout).
# We discard the packaged tree's lib/ folder and assemble the legacy layout
# below.
function Invoke-Builder {
    param([string]$BuildProfile)

    Write-Host "Running builder for $BuildProfile profile..." -ForegroundColor Yellow

    $env:PROFILE = $BuildProfile
    $env:TARGET = $HostTriple
    $env:CARGO_PKG_VERSION = $Version
    $env:CARGO_TARGET_DIR = $CargoTargetDir

    $BuilderOut = Join-Path $OutputDir "_builder-$BuildProfile"
    if (Test-Path $BuilderOut) { Remove-Item -Path $BuilderOut -Recurse -Force }

    # Pipe the builder's stdout to Out-Host so it stays visible in CI logs
    # but doesn't get captured into the function's output stream alongside
    # $BuilderOut — otherwise lines like "cargo:rerun-if-env-changed=..."
    # would be returned to the caller and Join-Path would later try to
    # interpret "cargo:" as a PSDrive.
    & .\.builder\bin\release.exe --out "$BuilderOut" --target "$Target" | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Builder failed for profile $BuildProfile" -ForegroundColor Red
        exit 1
    }
    return $BuilderOut
}

$ReleaseOut = Invoke-Builder -BuildProfile "release"
$DebugOut   = Invoke-Builder -BuildProfile "debug"

# --- Assemble the dd-trace-dotnet-compatible package ---
Write-Host "Assembling legacy Windows package layout..." -ForegroundColor Yellow

if (Test-Path $PackageDir) { Remove-Item -Path $PackageDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $PackageDir | Out-Null

# Headers, license files, and cmake config are byte-identical between profiles
# (they don't depend on optimization level), so we copy them once from the
# release builder's output.
Copy-Item -Path (Join-Path $ReleaseOut "include") -Destination $PackageDir -Recurse
if (Test-Path (Join-Path $ReleaseOut "cmake")) {
    Copy-Item -Path (Join-Path $ReleaseOut "cmake") -Destination $PackageDir -Recurse
}
foreach ($f in @("LICENSE", "NOTICE", "LICENSE-3rdparty.yml")) {
    $src = Join-Path $ReleaseOut $f
    if (Test-Path $src) { Copy-Item -Path $src -Destination $PackageDir }
}

# Lay out release/dynamic, release/static, debug/dynamic, debug/static from
# cargo's raw target/ outputs.
#
# The libdd-profiling-ffi crate declares crate-type = ["lib", "staticlib", "cdylib"]
# in its Cargo.toml, so a single cargo build produces all variants at once:
#   - datadog_profiling_ffi.dll       (cdylib)
#   - datadog_profiling_ffi.dll.lib   (import library for the cdylib)
#   - datadog_profiling_ffi.lib       (staticlib)
#   - datadog_profiling_ffi.pdb
# The builder copies the .dll and the staticlib .lib but does not copy the
# import library, so we pick all four directly from the cargo target dir.
# The import library is renamed .dll.lib -> .lib in the dynamic slot to match
# what the tracer's vcpkg portfile expects.
foreach ($p in @("release", "debug")) {
    $cargoOut  = Join-Path $CargoTargetDir "$Target/$p"
    $dynDir    = Join-Path $PackageDir "$p/dynamic"
    $staticDir = Join-Path $PackageDir "$p/static"
    New-Item -ItemType Directory -Force -Path $dynDir, $staticDir | Out-Null

    Copy-Item -Path (Join-Path $cargoOut "datadog_profiling_ffi.dll")     -Destination (Join-Path $dynDir "datadog_profiling_ffi.dll")
    Copy-Item -Path (Join-Path $cargoOut "datadog_profiling_ffi.dll.lib") -Destination (Join-Path $dynDir "datadog_profiling_ffi.lib")
    Copy-Item -Path (Join-Path $cargoOut "datadog_profiling_ffi.pdb")     -Destination (Join-Path $dynDir "datadog_profiling_ffi.pdb")
    Copy-Item -Path (Join-Path $cargoOut "datadog_profiling_ffi.lib")     -Destination (Join-Path $staticDir "datadog_profiling_ffi.lib")
}

# Drop the builder's intermediate output trees.
Remove-Item -Path $ReleaseOut -Recurse -Force
Remove-Item -Path $DebugOut -Recurse -Force

Write-Host "Build complete!" -ForegroundColor Green
Write-Host "  Package directory: $PackageDir" -ForegroundColor Gray

# Display package contents for sanity-checking in CI logs.
Get-ChildItem -Path $PackageDir -Recurse -File | ForEach-Object {
    $relativePath = $_.FullName.Substring($PackageDir.Length + 1)
    $size = "{0:N2} KB" -f ($_.Length / 1KB)
    Write-Host "  $relativePath ($size)" -ForegroundColor Gray
}
