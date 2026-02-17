#!/usr/bin/env pwsh
# SPDX-License-Identifier: Apache-2.0
#
# Unless explicitly stated otherwise all files in this repository are licensed
# under the Apache License Version 2.0.
# This product includes software developed at Datadog (https://www.datadoghq.com/).
# Copyright 2025-present Datadog, Inc.

# Build script for libdatadog-dotnet
# This script builds custom libdatadog binaries for the .NET SDK

param(
    [string]$LibdatadogVersion = "v25.0.0",
    [string]$OutputDir = "output",
    [string]$Platform = "x64-windows",
    [ValidateSet("minimal", "standard")]
    [string]$Features = "minimal",
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

Write-Host "Building libdatadog-dotnet" -ForegroundColor Cyan
Write-Host "  Libdatadog version: $LibdatadogVersion" -ForegroundColor Gray
Write-Host "  Platform: $Platform" -ForegroundColor Gray
Write-Host "  Feature preset: $Features" -ForegroundColor Gray
Write-Host "  Output directory: $OutputDir" -ForegroundColor Gray

# Define feature sets
$featureSets = @{
    "minimal" = "ddcommon-ffi,crashtracker-ffi,crashtracker-collector,demangler,symbolizer,datadog-library-config-ffi,data-pipeline-ffi,datadog-log-ffi"  # Core features needed by dd-trace-dotnet
    "standard" = "data-pipeline-ffi,crashtracker-collector,crashtracker-receiver,ddtelemetry-ffi,demangler,datadog-library-config-ffi,datadog-ffe-ffi,datadog-log-ffi"  # Matches official libdatadog build features
}

$featureFlags = $featureSets[$Features]
Write-Host "  Features: $featureFlags" -ForegroundColor Gray

# Check prerequisites
try {
    $null = Get-Command cargo -ErrorAction Stop
    $null = Get-Command git -ErrorAction Stop
} catch {
    Write-Host "Error: Required tools not found. Please install:" -ForegroundColor Red
    Write-Host "  - Rust (https://rustup.rs/)" -ForegroundColor Red
    Write-Host "  - Git (https://git-scm.com/)" -ForegroundColor Red
    exit 1
}

# Clean if requested
if ($Clean) {
    Write-Host "Cleaning build directories..." -ForegroundColor Yellow
    if (Test-Path "libdatadog") { Remove-Item -Path "libdatadog" -Recurse -Force }
    if (Test-Path $OutputDir) { Remove-Item -Path $OutputDir -Recurse -Force }
}

# Create output directory
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = Resolve-Path $OutputDir

# Clone libdatadog if not already present
if (-not (Test-Path "libdatadog")) {
    Write-Host "Cloning libdatadog..." -ForegroundColor Yellow
    git clone --depth 1 --branch $LibdatadogVersion https://github.com/DataDog/libdatadog.git
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Failed to clone libdatadog. Is $LibdatadogVersion a valid tag?" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "Checking existing libdatadog clone..." -ForegroundColor Gray
    Push-Location libdatadog
    $currentTag = git describe --tags --exact-match 2>$null
    Pop-Location

    if ($currentTag -ne $LibdatadogVersion) {
        Write-Host "  Existing clone is at $currentTag, but need $LibdatadogVersion" -ForegroundColor Yellow
        Write-Host "  Removing old clone and cloning correct version..." -ForegroundColor Yellow
        Remove-Item -Path "libdatadog" -Recurse -Force -ErrorAction Stop
        git clone --depth 1 --branch $LibdatadogVersion https://github.com/DataDog/libdatadog.git
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Error: Failed to clone libdatadog. Is $LibdatadogVersion a valid tag?" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "  Using existing clone at correct version $LibdatadogVersion" -ForegroundColor Gray
    }
}

# Build libdatadog profiling FFI
Write-Host "Building libdatadog profiling FFI..." -ForegroundColor Yellow

# Check if CARGO_BUILD_TARGET is set for cross-compilation
$cargoTargetArg = ""
$targetSubdir = ""
if ($env:CARGO_BUILD_TARGET) {
    $cargoTargetArg = "--target $env:CARGO_BUILD_TARGET"
    $targetSubdir = "$env:CARGO_BUILD_TARGET/"
    Write-Host "  Target architecture: $env:CARGO_BUILD_TARGET" -ForegroundColor Cyan
}

# Set RUSTFLAGS to match official libdatadog build (builder/src/arch/windows.rs)
# +crt-static: statically link the Visual C++ runtime so the DLL has no external CRT dependency
# relocation-model=pic: position-independent code for shared libraries
$env:RUSTFLAGS = "-C relocation-model=pic -C target-feature=+crt-static"
Write-Host "  RUSTFLAGS: $env:RUSTFLAGS" -ForegroundColor Gray

# Build from inside the crate directory using cargo rustc with explicit crate types
# This matches the official libdatadog build (windows/build-artifacts.ps1)
Push-Location libdatadog/libdd-profiling-ffi

# Release cdylib (DLL + import library)
Write-Host "  Building release cdylib..." -ForegroundColor Gray
$cmd = "cargo rustc --features `"$featureFlags`" $cargoTargetArg --release --crate-type cdylib"
Write-Host "  Running: $cmd" -ForegroundColor DarkGray
Invoke-Expression $cmd
if ($LASTEXITCODE -ne 0) { Write-Host "Error: Release cdylib build failed" -ForegroundColor Red; Pop-Location; exit 1 }

# Release staticlib
Write-Host "  Building release staticlib..." -ForegroundColor Gray
$cmd = "cargo rustc --features `"$featureFlags`" $cargoTargetArg --release --crate-type staticlib"
Write-Host "  Running: $cmd" -ForegroundColor DarkGray
Invoke-Expression $cmd
if ($LASTEXITCODE -ne 0) { Write-Host "Error: Release staticlib build failed" -ForegroundColor Red; Pop-Location; exit 1 }

# Debug cdylib
Write-Host "  Building debug cdylib..." -ForegroundColor Gray
$cmd = "cargo rustc --features `"$featureFlags`" $cargoTargetArg --crate-type cdylib"
Write-Host "  Running: $cmd" -ForegroundColor DarkGray
Invoke-Expression $cmd
if ($LASTEXITCODE -ne 0) { Write-Host "Error: Debug cdylib build failed" -ForegroundColor Red; Pop-Location; exit 1 }

# Debug staticlib
Write-Host "  Building debug staticlib..." -ForegroundColor Gray
$cmd = "cargo rustc --features `"$featureFlags`" $cargoTargetArg --crate-type staticlib"
Write-Host "  Running: $cmd" -ForegroundColor DarkGray
Invoke-Expression $cmd
if ($LASTEXITCODE -ne 0) { Write-Host "Error: Debug staticlib build failed" -ForegroundColor Red; Pop-Location; exit 1 }

Pop-Location

# Verify build outputs exist (with target subdirectory if cross-compiling)
$ReleaseDir = "libdatadog/target/${targetSubdir}release"
$DebugDir = "libdatadog/target/${targetSubdir}debug"

if (-not (Test-Path "$ReleaseDir/datadog_profiling_ffi.dll")) {
    Write-Host "Error: Release build did not produce expected DLL" -ForegroundColor Red
    Write-Host "  Expected: $ReleaseDir/datadog_profiling_ffi.dll" -ForegroundColor Red
    exit 1
}

# Package the binaries
Write-Host "Packaging binaries..." -ForegroundColor Yellow

$PackageDir = Join-Path $OutputDir "libdatadog-$Platform"
New-Item -ItemType Directory -Force -Path $PackageDir | Out-Null
$PackageDir = (Resolve-Path $PackageDir).Path

# Create directory structure
$Dirs = @(
    "include/datadog",
    "release/dynamic",
    "release/static",
    "debug/dynamic",
    "debug/static"
)
foreach ($Dir in $Dirs) {
    New-Item -ItemType Directory -Force -Path (Join-Path $PackageDir $Dir) | Out-Null
}

# Copy release artifacts
Write-Host "  Copying release artifacts..." -ForegroundColor Gray

# Dynamic build (DLL + import library)
Copy-Item "$ReleaseDir/datadog_profiling_ffi.dll" -Destination "$PackageDir/release/dynamic/" -ErrorAction Stop
Copy-Item "$ReleaseDir/datadog_profiling_ffi.pdb" -Destination "$PackageDir/release/dynamic/" -ErrorAction SilentlyContinue

# Copy import library (.dll.lib) and rename to .lib for dynamic linking
if (Test-Path "$ReleaseDir/datadog_profiling_ffi.dll.lib") {
    Copy-Item "$ReleaseDir/datadog_profiling_ffi.dll.lib" -Destination "$PackageDir/release/dynamic/datadog_profiling_ffi.lib" -ErrorAction Stop
} else {
    Write-Host "  Warning: Release import library (.dll.lib) not found" -ForegroundColor Yellow
}

# Static build (static library only)
if (Test-Path "$ReleaseDir/datadog_profiling_ffi.lib") {
    Copy-Item "$ReleaseDir/datadog_profiling_ffi.lib" -Destination "$PackageDir/release/static/" -ErrorAction Stop
} else {
    Write-Host "  Warning: Release static library (.lib) not found" -ForegroundColor Yellow
}

# Copy debug artifacts
Write-Host "  Copying debug artifacts..." -ForegroundColor Gray

# Dynamic build (DLL + import library)
Copy-Item "$DebugDir/datadog_profiling_ffi.dll" -Destination "$PackageDir/debug/dynamic/" -ErrorAction Stop
Copy-Item "$DebugDir/datadog_profiling_ffi.pdb" -Destination "$PackageDir/debug/dynamic/" -ErrorAction SilentlyContinue

# Copy import library (.dll.lib) and rename to .lib for dynamic linking
if (Test-Path "$DebugDir/datadog_profiling_ffi.dll.lib") {
    Copy-Item "$DebugDir/datadog_profiling_ffi.dll.lib" -Destination "$PackageDir/debug/dynamic/datadog_profiling_ffi.lib" -ErrorAction Stop
} else {
    Write-Host "  Warning: Debug import library (.dll.lib) not found" -ForegroundColor Yellow
}

# Static build (static library only)
if (Test-Path "$DebugDir/datadog_profiling_ffi.lib") {
    Copy-Item "$DebugDir/datadog_profiling_ffi.lib" -Destination "$PackageDir/debug/static/" -ErrorAction Stop
} else {
    Write-Host "  Warning: Debug static library (.lib) not found" -ForegroundColor Yellow
}

# Generate headers using external cbindgen (matches official libdatadog build)
Write-Host "  Generating headers with cbindgen..." -ForegroundColor Yellow

# Ensure cbindgen is installed
try {
    $null = Get-Command cbindgen -ErrorAction Stop
    Write-Host "    cbindgen found" -ForegroundColor Gray
} catch {
    Write-Host "    Installing cbindgen..." -ForegroundColor Gray
    cargo install cbindgen
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Error: Failed to install cbindgen" -ForegroundColor Red
        exit 1
    }
}

# Build dedup_headers tool (build for host, not target)
Write-Host "    Building dedup_headers tool..." -ForegroundColor Gray
$savedTarget = $env:CARGO_BUILD_TARGET
$env:CARGO_BUILD_TARGET = $null
Push-Location libdatadog\tools
cargo build --release --bin dedup_headers
$buildResult = $LASTEXITCODE
Pop-Location
$env:CARGO_BUILD_TARGET = $savedTarget

if ($buildResult -ne 0) {
    Write-Host "  Error: Failed to build dedup_headers tool" -ForegroundColor Red
    exit 1
}
$dedupTool = "libdatadog\target\release\dedup_headers.exe"

# Generate headers per FFI crate using cbindgen (matching official libdatadog windows/build-artifacts.ps1)
$headerDir = "$PackageDir\include\datadog"
Push-Location libdatadog

# Always generate: common, profiling, crashtracker, data-pipeline, library-config
Write-Host "    Generating common.h..." -ForegroundColor Gray
cbindgen --crate libdd-common-ffi --config libdd-common-ffi/cbindgen.toml --output "$headerDir\common.h"
if ($LASTEXITCODE -ne 0) { Write-Host "Error: cbindgen failed for common" -ForegroundColor Red; Pop-Location; exit 1 }

Write-Host "    Generating profiling.h..." -ForegroundColor Gray
cbindgen --crate libdd-profiling-ffi --config libdd-profiling-ffi/cbindgen.toml --output "$headerDir\profiling.h"
if ($LASTEXITCODE -ne 0) { Write-Host "Error: cbindgen failed for profiling" -ForegroundColor Red; Pop-Location; exit 1 }

Write-Host "    Generating crashtracker.h..." -ForegroundColor Gray
cbindgen --crate libdd-crashtracker-ffi --config libdd-crashtracker-ffi/cbindgen.toml --output "$headerDir\crashtracker.h"
if ($LASTEXITCODE -ne 0) { Write-Host "Error: cbindgen failed for crashtracker" -ForegroundColor Red; Pop-Location; exit 1 }

Write-Host "    Generating data-pipeline.h..." -ForegroundColor Gray
cbindgen --crate libdd-data-pipeline-ffi --config libdd-data-pipeline-ffi/cbindgen.toml --output "$headerDir\data-pipeline.h"
if ($LASTEXITCODE -ne 0) { Write-Host "Error: cbindgen failed for data-pipeline" -ForegroundColor Red; Pop-Location; exit 1 }

Write-Host "    Generating library-config.h..." -ForegroundColor Gray
cbindgen --crate libdd-library-config-ffi --config libdd-library-config-ffi/cbindgen.toml --output "$headerDir\library-config.h"
if ($LASTEXITCODE -ne 0) { Write-Host "Error: cbindgen failed for library-config" -ForegroundColor Red; Pop-Location; exit 1 }

# Conditionally generate telemetry.h (only for standard preset)
$headersForDedup = @("$headerDir\common.h", "$headerDir\profiling.h", "$headerDir\crashtracker.h", "$headerDir\data-pipeline.h", "$headerDir\library-config.h")

if ($Features -eq "standard") {
    Write-Host "    Generating telemetry.h..." -ForegroundColor Gray
    cbindgen --crate libdd-telemetry-ffi --config libdd-telemetry-ffi/cbindgen.toml --output "$headerDir\telemetry.h"
    if ($LASTEXITCODE -ne 0) { Write-Host "Error: cbindgen failed for telemetry" -ForegroundColor Red; Pop-Location; exit 1 }
    $headersForDedup += "$headerDir\telemetry.h"
}

# Copy blazesym.h (static header from symbolizer-ffi, not generated by cbindgen)
if (Test-Path "symbolizer-ffi/src/blazesym.h") {
    Write-Host "    Copying blazesym.h..." -ForegroundColor Gray
    Copy-Item "symbolizer-ffi/src/blazesym.h" -Destination "$headerDir\blazesym.h" -ErrorAction Stop
}

Pop-Location

# Deduplicate headers (moves shared type definitions into common.h)
Write-Host "    Running dedup_headers..." -ForegroundColor Gray
& ".\$dedupTool" $headersForDedup
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Warning: dedup_headers failed. Headers may contain duplicate definitions." -ForegroundColor Yellow
}

# Verify critical headers exist
if (-not (Test-Path "$PackageDir\include\datadog\common.h")) {
    Write-Host "  Error: common.h not generated" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path "$PackageDir\include\datadog\profiling.h")) {
    Write-Host "  Error: profiling.h not generated" -ForegroundColor Red
    exit 1
}

Write-Host "  Headers generated successfully" -ForegroundColor Gray

# Copy license files
Write-Host "  Copying license files..." -ForegroundColor Gray
# Copy LICENSE from libdatadog (Apache 2.0)
Copy-Item "libdatadog/LICENSE" -Destination "$PackageDir/" -ErrorAction SilentlyContinue
# Copy NOTICE from libdatadog
if (Test-Path "libdatadog/NOTICE") {
    Copy-Item "libdatadog/NOTICE" -Destination "$PackageDir/" -ErrorAction SilentlyContinue
}
# Copy LICENSE-3rdparty.csv from libdatadog-dotnet root (summary of components)
if (Test-Path "LICENSE-3rdparty.csv") {
    Copy-Item "LICENSE-3rdparty.csv" -Destination "$PackageDir/" -ErrorAction SilentlyContinue
}
# Copy LICENSE-3rdparty.yml from libdatadog (full license texts)
if (Test-Path "libdatadog/LICENSE-3rdparty.yml") {
    Copy-Item "libdatadog/LICENSE-3rdparty.yml" -Destination "$PackageDir/" -ErrorAction SilentlyContinue
}

Write-Host "Build complete!" -ForegroundColor Green
Write-Host "  Package directory: $PackageDir" -ForegroundColor Gray

# Display package contents
Write-Host ""
Write-Host "Package contents:" -ForegroundColor Cyan
Get-ChildItem -Path $PackageDir -Recurse -File | ForEach-Object {
    $relativePath = $_.FullName.Substring($PackageDir.Length + 1)
    $size = "{0:N2} KB" -f ($_.Length / 1KB)
    Write-Host "  $relativePath ($size)" -ForegroundColor Gray
}
