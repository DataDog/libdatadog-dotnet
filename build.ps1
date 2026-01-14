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
Push-Location libdatadog

# Build release version
# Note: The Cargo.toml already has optimized release profile:
#   - opt-level = "s" (optimize for size)
#   - lto = true (link-time optimization)
#   - codegen-units = 1 (better optimization)
#   - debug = "line-tables-only" (minimal debug info)
Write-Host "  Building release configuration..." -ForegroundColor Gray
cargo build --release -p libdd-profiling-ffi
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Release build failed" -ForegroundColor Red
    Pop-Location
    exit 1
}

# Build debug version
Write-Host "  Building debug configuration..." -ForegroundColor Gray
cargo build -p libdd-profiling-ffi
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Debug build failed" -ForegroundColor Red
    Pop-Location
    exit 1
}

Pop-Location

# Verify build outputs exist
$ReleaseDir = "libdatadog/target/release"
$DebugDir = "libdatadog/target/debug"

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
    "include",
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

# Copy or generate headers
Write-Host "  Copying headers..." -ForegroundColor Gray

# Check common locations for generated headers
$headerLocations = @(
    "libdatadog/target/include/datadog/profiling.h",
    "libdatadog/libdd-profiling-ffi/datadog/profiling.h",
    "libdatadog/include/datadog/profiling.h"
)

$headerFound = $false
foreach ($headerPath in $headerLocations) {
    if (Test-Path $headerPath) {
        Write-Host "  Found header at: $headerPath" -ForegroundColor Gray
        $headerDir = Split-Path $headerPath -Parent
        Copy-Item $headerPath -Destination "$PackageDir/include/" -ErrorAction Stop
        $headerFound = $true
        break
    }
}

if (-not $headerFound) {
    Write-Host "  Warning: Header file not found in common locations. Attempting to generate..." -ForegroundColor Yellow
    Push-Location libdatadog/libdd-profiling-ffi
    
    # Try to generate headers with cbindgen if available
    try {
        $null = Get-Command cbindgen -ErrorAction Stop
        cbindgen --output "$PackageDir/include/profiling.h"
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Generated header with cbindgen" -ForegroundColor Gray
            $headerFound = $true
        }
    } catch {
        Write-Host "  Warning: cbindgen not found. Header files will be missing." -ForegroundColor Yellow
        Write-Host "  Install cbindgen with: cargo install cbindgen" -ForegroundColor Yellow
    }
    
    Pop-Location
}

# Copy license
Write-Host "  Copying license..." -ForegroundColor Gray
Copy-Item "libdatadog/LICENSE" -Destination "$PackageDir/" -ErrorAction SilentlyContinue
Copy-Item "libdatadog/LICENSE-3rdparty.csv" -Destination "$PackageDir/" -ErrorAction SilentlyContinue
Copy-Item "libdatadog/NOTICE" -Destination "$PackageDir/" -ErrorAction SilentlyContinue

# Create zip archive
Write-Host "Creating zip archive..." -ForegroundColor Yellow
$ZipPath = Join-Path $OutputDir "libdatadog-$Platform.zip"
if (Test-Path $ZipPath) { Remove-Item $ZipPath }

# Compress with wrapper folder to match original libdatadog structure
# This creates: libdatadog-x64-windows.zip containing libdatadog-x64-windows/ folder
$itemsToCompress = Get-ChildItem -Path $PackageDir -Force | ForEach-Object { $_.FullName }

if ($itemsToCompress.Count -eq 0) {
    Write-Host "Error: No items found in $PackageDir to compress" -ForegroundColor Red
    exit 1
}

# Compress from the parent directory to include the wrapper folder
Push-Location $OutputDir
try {
    $folderName = Split-Path $PackageDir -Leaf
    Write-Host "  Compressing folder: $folderName" -ForegroundColor Gray
    Compress-Archive -Path $folderName -DestinationPath $ZipPath -CompressionLevel Optimal
} finally {
    Pop-Location
}

# Verify zip contents
Write-Host "  Verifying zip structure..." -ForegroundColor Gray
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
$rootEntries = $zip.Entries | Select-Object -First 10 | ForEach-Object { $_.FullName }
Write-Host "  First 10 entries in zip: $($rootEntries -join ', ')" -ForegroundColor Gray
$hasWrapperFolder = $zip.Entries[0].FullName.StartsWith("libdatadog-$Platform/")
if ($hasWrapperFolder) {
    Write-Host "  ✓ Wrapper folder present: libdatadog-$Platform/" -ForegroundColor Green
} else {
    Write-Host "  ✗ WARNING: Wrapper folder missing!" -ForegroundColor Red
}
$zip.Dispose()

Write-Host "Build complete!" -ForegroundColor Green
Write-Host "  Package: $ZipPath" -ForegroundColor Gray

# Calculate and display SHA512
Write-Host "Calculating SHA512 hash..." -ForegroundColor Yellow
$Hash = (Get-FileHash -Path $ZipPath -Algorithm SHA512).Hash.ToLower()
Write-Host "  SHA512: $Hash" -ForegroundColor Gray

# Display package contents
Write-Host ""
Write-Host "Package contents:" -ForegroundColor Cyan
Get-ChildItem -Path $PackageDir -Recurse -File | ForEach-Object {
    $relativePath = $_.FullName.Substring($PackageDir.Length + 1)
    $size = "{0:N2} KB" -f ($_.Length / 1KB)
    Write-Host "  $relativePath ($size)" -ForegroundColor Gray
}
