#!/usr/bin/env pwsh
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

# Define feature sets
$featureSets = @{
    "minimal" = "ddcommon-ffi,cbindgen"  # Core profiling only (~4MB) - fastest build
    "standard" = "ddcommon-ffi,crashtracker-ffi,crashtracker-collector,demangler,ddtelemetry-ffi,cbindgen"  # Most common features (~5-6MB)
    "full" = "ddcommon-ffi,crashtracker-ffi,crashtracker-collector,crashtracker-receiver,demangler,ddtelemetry-ffi,data-pipeline-ffi,symbolizer,ddsketch-ffi,datadog-log-ffi,datadog-library-config-ffi,datadog-ffe-ffi,cbindgen"  # All features (~6.5MB) - matches original libdatadog
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
    Write-Host "Using existing libdatadog clone" -ForegroundColor Gray
    Push-Location libdatadog
    $currentTag = git describe --tags --exact-match 2>$null
    if ($currentTag -ne $LibdatadogVersion) {
        Write-Host "  Warning: Existing clone is at $currentTag, not $LibdatadogVersion" -ForegroundColor Yellow
        Write-Host "  Use -Clean to clone the correct version" -ForegroundColor Yellow
    }
    Pop-Location
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

# Copy all headers from libdatadog
Write-Host "  Copying headers..." -ForegroundColor Gray

# Headers are generated during build with cbindgen feature to:
# target/{architecture}/{profile}/include/datadog/
# We check both release and debug locations

$headerDirFound = $false

# Check release build location
$releaseHeaderPath = "$ReleaseDir/include/datadog"
Write-Host "  Checking for headers in: $releaseHeaderPath" -ForegroundColor DarkGray
if (Test-Path $releaseHeaderPath) {
    Write-Host "  Found headers in $releaseHeaderPath" -ForegroundColor Gray
    Get-ChildItem $releaseHeaderPath -File | ForEach-Object { Write-Host "    - $($_.Name)" -ForegroundColor DarkGray }
    Copy-Item "$releaseHeaderPath/*" -Destination "$PackageDir/include/datadog/" -Recurse -Force -ErrorAction SilentlyContinue
    $headerDirFound = $true
} else {
    Write-Host "  Headers NOT found in $releaseHeaderPath" -ForegroundColor Yellow
}

# Check debug build location
$debugHeaderPath = "$DebugDir/include/datadog"
Write-Host "  Checking for headers in: $debugHeaderPath" -ForegroundColor DarkGray
if (Test-Path $debugHeaderPath) {
    Write-Host "  Found headers in $debugHeaderPath" -ForegroundColor Gray
    Get-ChildItem $debugHeaderPath -File | ForEach-Object { Write-Host "    - $($_.Name)" -ForegroundColor DarkGray }
    Copy-Item "$debugHeaderPath/*" -Destination "$PackageDir/include/datadog/" -Recurse -Force -ErrorAction SilentlyContinue
    $headerDirFound = $true
} else {
    Write-Host "  Headers NOT found in $debugHeaderPath" -ForegroundColor Yellow
}

# Verify profiling.h exists (critical)
if (-not (Test-Path "$PackageDir/include/datadog/profiling.h")) {
    Write-Host "  Error: profiling.h not found after build. Headers were not generated." -ForegroundColor Red
    Write-Host "  This usually means the cbindgen feature wasn't enabled during build." -ForegroundColor Red
    Write-Host "  Checked locations:" -ForegroundColor Red
    Write-Host "    - $releaseHeaderPath" -ForegroundColor Red
    Write-Host "    - $debugHeaderPath" -ForegroundColor Red
}

# Copy license
Write-Host "  Copying license..." -ForegroundColor Gray
Copy-Item "libdatadog/LICENSE" -Destination "$PackageDir/" -ErrorAction SilentlyContinue
Copy-Item "libdatadog/LICENSE-3rdparty.csv" -Destination "$PackageDir/" -ErrorAction SilentlyContinue
Copy-Item "libdatadog/NOTICE" -Destination "$PackageDir/" -ErrorAction SilentlyContinue

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
