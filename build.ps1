#!/usr/bin/env pwsh
# Build script for libdatadog-dotnet
# This script builds custom libdatadog binaries for the .NET SDK

param(
    [string]$LibdatadogVersion = "v25.0.0",
    [string]$OutputDir = "output",
    [string]$Platform = "x64-windows",
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

Write-Host "Building libdatadog-dotnet" -ForegroundColor Cyan
Write-Host "  Libdatadog version: $LibdatadogVersion" -ForegroundColor Gray
Write-Host "  Platform: $Platform" -ForegroundColor Gray
Write-Host "  Output directory: $OutputDir" -ForegroundColor Gray

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
    git clone https://github.com/DataDog/libdatadog.git
    Push-Location libdatadog
    git checkout $LibdatadogVersion
    Pop-Location
} else {
    Write-Host "Using existing libdatadog clone" -ForegroundColor Gray
}

# Build libdatadog profiling FFI
Write-Host "Building libdatadog profiling FFI..." -ForegroundColor Yellow
Push-Location libdatadog

# Build release version
Write-Host "  Building release configuration..." -ForegroundColor Gray
cargo build --release -p datadog-profiling-ffi

# Build debug version  
Write-Host "  Building debug configuration..." -ForegroundColor Gray
cargo build -p datadog-profiling-ffi

Pop-Location

# Package the binaries
Write-Host "Packaging binaries..." -ForegroundColor Yellow

$PackageDir = Join-Path $OutputDir "libdatadog-$Platform"
New-Item -ItemType Directory -Force -Path $PackageDir | Out-Null

# Create directory structure
$Dirs = @(
    "include",
    "release/dynamic",
    "debug/dynamic"
)
foreach ($Dir in $Dirs) {
    New-Item -ItemType Directory -Force -Path (Join-Path $PackageDir $Dir) | Out-Null
}

# Copy release artifacts
Write-Host "  Copying release artifacts..." -ForegroundColor Gray
$ReleaseDir = "libdatadog/target/release"
Copy-Item "$ReleaseDir/datadog_profiling_ffi.dll" -Destination "$PackageDir/release/dynamic/"
Copy-Item "$ReleaseDir/datadog_profiling_ffi.pdb" -Destination "$PackageDir/release/dynamic/" -ErrorAction SilentlyContinue
Copy-Item "$ReleaseDir/datadog_profiling_ffi.dll.lib" -Destination "$PackageDir/release/dynamic/datadog_profiling_ffi.lib" -ErrorAction SilentlyContinue

# Copy debug artifacts
Write-Host "  Copying debug artifacts..." -ForegroundColor Gray
$DebugDir = "libdatadog/target/debug"
Copy-Item "$DebugDir/datadog_profiling_ffi.dll" -Destination "$PackageDir/debug/dynamic/"
Copy-Item "$DebugDir/datadog_profiling_ffi.pdb" -Destination "$PackageDir/debug/dynamic/" -ErrorAction SilentlyContinue
Copy-Item "$DebugDir/datadog_profiling_ffi.dll.lib" -Destination "$PackageDir/debug/dynamic/datadog_profiling_ffi.lib" -ErrorAction SilentlyContinue

# Copy headers
Write-Host "  Copying headers..." -ForegroundColor Gray
if (Test-Path "libdatadog/profiling-ffi/*.h") {
    Copy-Item "libdatadog/profiling-ffi/*.h" -Destination "$PackageDir/include/"
}

# Copy license
Write-Host "  Copying license..." -ForegroundColor Gray
Copy-Item "libdatadog/LICENSE" -Destination "$PackageDir/" -ErrorAction SilentlyContinue
Copy-Item "libdatadog/LICENSE-3rdparty.csv" -Destination "$PackageDir/" -ErrorAction SilentlyContinue

# Create zip archive
Write-Host "Creating zip archive..." -ForegroundColor Yellow
$ZipPath = Join-Path $OutputDir "libdatadog-$Platform.zip"
if (Test-Path $ZipPath) { Remove-Item $ZipPath }
Compress-Archive -Path $PackageDir -DestinationPath $ZipPath -CompressionLevel Optimal

Write-Host "Build complete!" -ForegroundColor Green
Write-Host "  Package: $ZipPath" -ForegroundColor Gray

# Calculate and display SHA512
Write-Host "Calculating SHA512 hash..." -ForegroundColor Yellow
$Hash = (Get-FileHash -Path $ZipPath -Algorithm SHA512).Hash.ToLower()
Write-Host "  SHA512: $Hash" -ForegroundColor Gray
