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
    [ValidateSet("minimal", "full")]
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
    "minimal" = "ddcommon-ffi,crashtracker-ffi,crashtracker-collector,demangler,symbolizer,datadog-library-config-ffi,cbindgen"  # Core features needed by dd-trace-dotnet
    "full" = "ddcommon-ffi,crashtracker-ffi,crashtracker-collector,crashtracker-receiver,demangler,ddtelemetry-ffi,data-pipeline-ffi,symbolizer,ddsketch-ffi,datadog-log-ffi,datadog-library-config-ffi,datadog-ffe-ffi,cbindgen"  # All features - matches original libdatadog
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

Push-Location libdatadog

# Build release version
# Note: The Cargo.toml already has optimized release profile:
#   - opt-level = "s" (optimize for size)
#   - lto = true (link-time optimization)
#   - codegen-units = 1 (better optimization)
#   - debug = "line-tables-only" (minimal debug info)
Write-Host "  Building release configuration..." -ForegroundColor Gray
$releaseCmd = "cargo build --release -p libdd-profiling-ffi --features `"$featureFlags`" $cargoTargetArg"
Write-Host "  Running: $releaseCmd" -ForegroundColor DarkGray
Invoke-Expression $releaseCmd
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Release build failed" -ForegroundColor Red
    Pop-Location
    exit 1
}

# Build debug version
Write-Host "  Building debug configuration..." -ForegroundColor Gray
$debugCmd = "cargo build -p libdd-profiling-ffi --features `"$featureFlags`" $cargoTargetArg"
Write-Host "  Running: $debugCmd" -ForegroundColor DarkGray
Invoke-Expression $debugCmd
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Debug build failed" -ForegroundColor Red
    Pop-Location
    exit 1
}

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

# Copy headers generated during cargo build
Write-Host "  Copying headers from build output..." -ForegroundColor Gray

# Headers are generated during cargo build (with cbindgen feature) to target/include/datadog/
$SourceHeaderDir = "libdatadog\target\include\datadog"

# Verify source headers exist
if (-not (Test-Path $SourceHeaderDir)) {
    Write-Host "  Error: Header directory not found at $SourceHeaderDir" -ForegroundColor Red
    Write-Host "  Headers should be generated during cargo build with cbindgen feature" -ForegroundColor Red
    exit 1
}

# Copy common.h
Write-Host "    Copying common.h..." -ForegroundColor Gray
if (Test-Path "$SourceHeaderDir\common.h") {
    Copy-Item "$SourceHeaderDir\common.h" -Destination "$PackageDir\include\datadog\" -ErrorAction Stop
} else {
    Write-Host "  Error: common.h not found in build output" -ForegroundColor Red
    exit 1
}

# Determine which headers to copy based on feature preset
$headersToCopy = @("profiling")

switch ($Features) {
    "minimal" {
        $headersToCopy += @("crashtracker", "blazesym", "library-config")
    }
    "full" {
        $headersToCopy += @("crashtracker", "telemetry", "data-pipeline", "library-config", "log", "ddsketch", "ffe", "blazesym")
    }
}

# Copy each header that exists
$copiedHeaders = @()
foreach ($headerName in $headersToCopy) {
    $sourceHeader = "$SourceHeaderDir\$headerName.h"
    if (Test-Path $sourceHeader) {
        Write-Host "    Copying $headerName.h..." -ForegroundColor Gray
        Copy-Item $sourceHeader -Destination "$PackageDir\include\datadog\" -ErrorAction Stop
        $copiedHeaders += "$PackageDir\include\datadog\$headerName.h"
    } else {
        Write-Host "    Warning: $headerName.h not found in build output, skipping..." -ForegroundColor Yellow
    }
}

# Deduplicate headers - move type definitions from child headers to common.h
if ($copiedHeaders.Count -gt 0) {
    Write-Host "  Deduplicating headers..." -ForegroundColor Gray

    # Build the dedup_headers tool from libdatadog/tools if needed
    # When CARGO_BUILD_TARGET is set, binaries go to target/$env:CARGO_BUILD_TARGET/release/
    $toolPath = $null

    # Determine the target directory based on CARGO_BUILD_TARGET
    if ($env:CARGO_BUILD_TARGET) {
        $targetDir = "libdatadog\target\$env:CARGO_BUILD_TARGET"
    } else {
        $targetDir = "libdatadog\target"
    }

    # Check for the tool in the target-specific directory first, then fallback to default
    if (Test-Path "$targetDir\release\dedup_headers.exe") {
        $toolPath = "$targetDir\release\dedup_headers.exe"
    } elseif (Test-Path "$targetDir\debug\dedup_headers.exe") {
        $toolPath = "$targetDir\debug\dedup_headers.exe"
    } elseif (Test-Path "libdatadog\target\release\dedup_headers.exe") {
        $toolPath = "libdatadog\target\release\dedup_headers.exe"
    } elseif (Test-Path "libdatadog\target\debug\dedup_headers.exe") {
        $toolPath = "libdatadog\target\debug\dedup_headers.exe"
    }

    if (-not $toolPath) {
        Write-Host "    Building dedup_headers tool..." -ForegroundColor Gray
        Push-Location libdatadog\tools
        # Build for the host architecture, not the target (unset CARGO_BUILD_TARGET)
        # We need to run this tool on the build machine, not on the target
        $savedTarget = $env:CARGO_BUILD_TARGET
        $env:CARGO_BUILD_TARGET = $null
        cargo build --release --bin dedup_headers
        $buildResult = $LASTEXITCODE
        $env:CARGO_BUILD_TARGET = $savedTarget

        if ($buildResult -eq 0) {
            Pop-Location
            # Tool is built for host, so it's in libdatadog\target\release\
            if (Test-Path "libdatadog\target\release\dedup_headers.exe") {
                $toolPath = "libdatadog\target\release\dedup_headers.exe"
                Write-Host "    Found at: $toolPath" -ForegroundColor Gray
            } else {
                Write-Host "    Warning: dedup_headers binary not found at libdatadog\target\release\dedup_headers.exe" -ForegroundColor Yellow
            }
        } else {
            Pop-Location
            Write-Host "    Warning: Failed to build dedup_headers tool. Headers may contain duplicate definitions." -ForegroundColor Yellow
        }
    }

    # Filter out blazesym.h from deduplication (it's a third-party header)
    $headersToDedup = $copiedHeaders | Where-Object { $_ -notlike "*blazesym.h" }

    # Use the dedup_headers tool
    if ($toolPath -and $headersToDedup.Count -gt 0) {
        Write-Host "    Running dedup_headers on $($headersToDedup.Count) header(s)..." -ForegroundColor Gray
        $headerArgs = @("$PackageDir\include\datadog\common.h") + $headersToDedup
        & ".\$toolPath" $headerArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    Warning: dedup_headers failed. Headers may contain duplicate definitions." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Warning: dedup_headers tool not found. Headers may contain duplicate definitions." -ForegroundColor Yellow
    }
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
