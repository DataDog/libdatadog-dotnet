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
    [ValidateSet("minimal", "standard", "full")]
    [string]$Features = "minimal",
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

Write-Host "Building libdatadog-dotnet" -ForegroundColor Cyan
Write-Host "  Libdatadog version: $LibdatadogVersion" -ForegroundColor Gray
Write-Host "  Platform: $Platform" -ForegroundColor Gray
Write-Host "  Feature preset: $Features" -ForegroundColor Gray
Write-Host "  Output directory: $OutputDir" -ForegroundColor Gray

# Map feature presets to builder features
# The builder crate has its own feature flags that control which FFI modules are included
$builderFeatures = @{
    "minimal" = "profiling"  # Core profiling only (~4MB) - fastest build
    "standard" = "profiling,crashtracker,telemetry"  # Most common features (~5-6MB)
    "full" = ""  # All features (~6.5MB) - uses default features which include everything
}

$featureArg = $builderFeatures[$Features]
if ($featureArg -eq "") {
    Write-Host "  Using default features (full)" -ForegroundColor Gray
    $cargoFeatures = ""
} else {
    Write-Host "  Builder features: $featureArg" -ForegroundColor Gray
    $cargoFeatures = "--no-default-features --features $featureArg"
}

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
    Write-Host "Using existing libdatadog clone" -ForegroundColor Gray
    Push-Location libdatadog
    $currentTag = git describe --tags --exact-match 2>$null
    if ($currentTag -ne $LibdatadogVersion) {
        Write-Host "  Warning: Existing clone is at $currentTag, not $LibdatadogVersion" -ForegroundColor Yellow
        Write-Host "  Use -Clean to clone the correct version" -ForegroundColor Yellow
    }
    Pop-Location
}

# Build using libdatadog builder crate
Write-Host "Building libdatadog using builder crate..." -ForegroundColor Yellow

# Create temporary build output directory
$TempBuildDir = Join-Path $OutputDir "temp-build"
New-Item -ItemType Directory -Force -Path $TempBuildDir | Out-Null

Push-Location libdatadog

# Prepare builder command
$builderCmd = "cargo run --release --bin release $cargoFeatures --"

# Add output directory
$builderCmd += " --out `"$TempBuildDir`""

# Add target if cross-compiling
if ($env:CARGO_BUILD_TARGET) {
    Write-Host "  Target architecture: $env:CARGO_BUILD_TARGET" -ForegroundColor Cyan
    $builderCmd += " --target $env:CARGO_BUILD_TARGET"
}

Write-Host "  Running builder..." -ForegroundColor Gray
Write-Host "  Command: $builderCmd" -ForegroundColor DarkGray
Invoke-Expression $builderCmd
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Builder failed" -ForegroundColor Red
    Pop-Location
    exit 1
}

Pop-Location

# The builder creates output directly in the temp-build directory
Write-Host "  Builder output: $TempBuildDir" -ForegroundColor Gray

# Package the binaries
Write-Host "Packaging binaries..." -ForegroundColor Yellow

# Copy builder output to final package directory
$PackageDir = Join-Path $OutputDir "libdatadog-$Platform"
Write-Host "  Copying builder output to package directory..." -ForegroundColor Gray
Copy-Item -Path $TempBuildDir -Destination $PackageDir -Recurse -Force

# Add our LICENSE-3rdparty.csv (summary) alongside the full yml from libdatadog
Write-Host "  Adding LICENSE-3rdparty.csv..." -ForegroundColor Gray
if (Test-Path "LICENSE-3rdparty.csv") {
    Copy-Item "LICENSE-3rdparty.csv" -Destination "$PackageDir/" -Force -ErrorAction SilentlyContinue
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
