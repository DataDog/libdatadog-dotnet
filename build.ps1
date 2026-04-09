#!/usr/bin/env pwsh
# SPDX-License-Identifier: Apache-2.0
#
# Unless explicitly stated otherwise all files in this repository are licensed
# under the Apache License Version 2.0.
# This product includes software developed at Datadog (https://www.datadoghq.com/).
# Copyright 2025-present Datadog, Inc.

# Build script for libdatadog-dotnet on Windows.
# The libdatadog version is controlled by the LIBDATADOG_VERSION file.

param(
    [string]$Platform = "x64-windows",
    [string]$OutputDir = "output",
    [string]$Profile = "release",
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

# Builder crate features compiled into the release binary.
# These control which FFI modules are included in the output library.
# Feature names map to flags in builder/src/bin/release.rs in libdatadog.
$Features = "profiling,crashtracker,data-pipeline,symbolizer,library-config,log"

Write-Host "Building libdatadog-dotnet" -ForegroundColor Cyan
Write-Host "  Platform : $Platform" -ForegroundColor Gray
Write-Host "  Target   : $Target" -ForegroundColor Gray
Write-Host "  Profile  : $Profile" -ForegroundColor Gray
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

# Install the builder binary
cargo install `
    --git https://github.com/DataDog/libdatadog `
    --tag "v${Version}" `
    --bin release `
    --root .builder `
    --no-default-features `
    --features $Features `
    --force `
    builder

if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: cargo install failed" -ForegroundColor Red
    exit 1
}

# Determine host triple
$HostTriple = (rustc -vV 2>&1 | Where-Object { $_ -match "^host:" }) -replace "^host:\s*", ""

$env:PROFILE = $Profile
$env:TARGET = $HostTriple
$env:CARGO_PKG_VERSION = $Version
$env:CARGO_TARGET_DIR = Join-Path $PWD "target"

.\.builder\bin\release.exe --out "$PackageDir" --target "$Target"

if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed" -ForegroundColor Red
    exit 1
}

Write-Host "Build complete!" -ForegroundColor Green
Write-Host "  Package directory: $PackageDir" -ForegroundColor Gray
