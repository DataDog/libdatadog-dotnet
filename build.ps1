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
#   release/dynamic/datadog_profiling_ffi.{dll,lib,pdb}   (DLL + import lib, from datadog-dotnet-ffi)
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
#
# The DLL itself is the datadog-dotnet-ffi library (see Cargo.toml): libdatadog's
# profiling FFI plus the .NET specific FFI.  It is renamed to datadog_profiling_ffi.dll,
# with an import library generated for that name.

param(
    [string]$Platform = "x64-windows",
    [string]$OutputDir = "output",
    [string]$Features = "profiling,crashtracker,symbolizer,library-config",
    [switch]$Clean,
    # Build from a local libdatadog checkout instead of the tag in LIBDATADOG_VERSION
    [string]$LibdatadogPath = ""
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

# The libdatadog sources the builder is installed from: either a checkout of the release
# tag, or a junction to a local checkout.
$LibdatadogDir = Join-Path $PWD "libdatadog"
$LibdatadogItem = Get-Item $LibdatadogDir -ErrorAction SilentlyContinue
$IsLink = $LibdatadogItem -and $LibdatadogItem.LinkType
if ($LibdatadogPath) {
    if ($LibdatadogItem -and -not $IsLink) {
        Write-Host "Error: $LibdatadogDir exists and is not a link, remove it to use -LibdatadogPath" -ForegroundColor Red
        exit 1
    }
    if ($IsLink) { $LibdatadogItem.Delete() }
    New-Item -ItemType Junction -Path $LibdatadogDir -Target (Resolve-Path $LibdatadogPath).Path | Out-Null
} elseif ($IsLink) {
    Write-Host "Error: $LibdatadogDir links to a local checkout, pass -LibdatadogPath or remove it" -ForegroundColor Red
    exit 1
} elseif (-not $LibdatadogItem) {
    git clone --quiet --depth 1 --branch "v${Version}" https://github.com/DataDog/libdatadog $LibdatadogDir
    if ($LASTEXITCODE -ne 0) { Write-Host "Error: git clone failed" -ForegroundColor Red; exit 1 }
} elseif ((git -C $LibdatadogDir describe --tags --exact-match 2>$null) -ne "v${Version}") {
    Write-Host "Error: $LibdatadogDir is not a checkout of v${Version}, remove it to check out the right version" -ForegroundColor Red
    exit 1
}

# Install the builder binary once.  Each subsequent profile run reuses it.
# Clear CARGO_BUILD_TARGET so `cargo install` compiles the builder for the
# host (x86_64).  The workflow sets CARGO_BUILD_TARGET=i686-pc-windows-msvc
# for the x86-windows matrix entry, which would otherwise produce a 32-bit
# release.exe that can't load on the x86_64 runner — STATUS_ENTRYPOINT_NOT_FOUND
# (exit code -1073741511).  The builder accepts --target as a CLI arg and
# handles the target cross-compile internally.
$savedTarget = $env:CARGO_BUILD_TARGET
$env:CARGO_BUILD_TARGET = $null
cargo install `
    --path libdatadog/builder `
    --bin release `
    --root .builder `
    --no-default-features `
    --features $Features `
    --locked `
    --force `
    builder
$env:CARGO_BUILD_TARGET = $savedTarget

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

    # Use Start-Process with explicit file redirects rather than the
    # pipeline — PowerShell's $ErrorActionPreference=Stop + native-command
    # stderr handling is unreliable enough that even `2>&1 | Out-Host` can
    # eat panic messages, leaving a silent exit-code-1 failure with zero
    # diagnostic output.  Writing both streams to disk then dumping them
    # is bulletproof.
    $stdoutFile = Join-Path $OutputDir "_builder-$BuildProfile.stdout.log"
    $stderrFile = Join-Path $OutputDir "_builder-$BuildProfile.stderr.log"
    $proc = Start-Process -FilePath ".\.builder\bin\release.exe" `
        -ArgumentList "--out", "$BuilderOut", "--target", "$Target" `
        -NoNewWindow -PassThru -Wait `
        -RedirectStandardOutput $stdoutFile `
        -RedirectStandardError $stderrFile
    if (Test-Path $stdoutFile) { Get-Content $stdoutFile | Write-Host }
    if (Test-Path $stderrFile) { Get-Content $stderrFile | Write-Host -ForegroundColor Yellow }
    if ($proc.ExitCode -ne 0) {
        Write-Host "Builder failed for profile $BuildProfile (exit code $($proc.ExitCode))" -ForegroundColor Red
        exit 1
    }
    return $BuilderOut
}

$ReleaseOut = Invoke-Builder -BuildProfile "release"
$DebugOut   = Invoke-Builder -BuildProfile "debug"

# Build datadog-dotnet-ffi, which replaces the profiling DLL.  The PDB path embedded in the
# DLL already gets the final name.  Uses the dependency versions libdatadog is tested with.
Copy-Item -Path (Join-Path $LibdatadogDir "Cargo.lock") -Destination (Join-Path $PWD "Cargo.lock") -Force
$env:CARGO_TARGET_DIR = $CargoTargetDir
$env:RUSTFLAGS = "-C relocation-model=pic -C target-feature=+crt-static -C link-arg=/PDBALTPATH:datadog_profiling_ffi.pdb"
foreach ($p in @("release", "debug")) {
    $cargoProfile = if ($p -eq "debug") { "dev" } else { $p }
    cargo build -p datadog-dotnet-ffi --target $Target --profile $cargoProfile
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: building datadog-dotnet-ffi ($p) failed" -ForegroundColor Red
        exit 1
    }
}
$env:RUSTFLAGS = $null

# Creates an import library for $Dll under the name $DllName.
function New-ImportLibrary {
    param([string]$Dll, [string]$DllName, [string]$OutLib)

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    $toolsBin = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -find "VC\Tools\MSVC\**\bin\Hostx64\x64" | Select-Object -First 1
    if (-not $toolsBin) {
        Write-Host "Error: MSVC tools not found" -ForegroundColor Red
        exit 1
    }
    $machine = if ($Target -like "i686-*") { "X86" } else { "X64" }

    # Lines like "          1    0 000A1B20 ddog_Error_drop"
    $exports = & (Join-Path $toolsBin "dumpbin.exe") /nologo /exports $Dll | ForEach-Object {
        if ($_ -match '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]{8}\s+(\S+)') { $Matches[1] }
    }
    $def = [IO.Path]::ChangeExtension($OutLib, ".def")
    @("LIBRARY $DllName", "EXPORTS") + ($exports | ForEach-Object { "    $_" }) | Set-Content -Encoding ascii $def
    & (Join-Path $toolsBin "lib.exe") /nologo "/def:$def" "/machine:$machine" "/out:$OutLib"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: creating the import library failed" -ForegroundColor Red
        exit 1
    }
    Remove-Item $def
    Remove-Item ([IO.Path]::ChangeExtension($OutLib, ".exp")) -ErrorAction SilentlyContinue
}

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
foreach ($f in @("LICENSE", "NOTICE", "LICENSE-3rdparty.csv")) {
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
# The static slot gets that staticlib.  The dynamic slot gets the datadog-dotnet-ffi
# DLL and PDB instead, renamed, with a generated datadog_profiling_ffi.lib import library
# (the import library cargo produces refers to datadog_dotnet_ffi.dll).
foreach ($p in @("release", "debug")) {
    $cargoOut  = Join-Path $CargoTargetDir "$Target/$p"
    $dynDir    = Join-Path $PackageDir "$p/dynamic"
    $staticDir = Join-Path $PackageDir "$p/static"
    New-Item -ItemType Directory -Force -Path $dynDir, $staticDir | Out-Null

    Copy-Item -Path (Join-Path $cargoOut "datadog_dotnet_ffi.dll")        -Destination (Join-Path $dynDir "datadog_profiling_ffi.dll")
    Copy-Item -Path (Join-Path $cargoOut "datadog_dotnet_ffi.pdb")        -Destination (Join-Path $dynDir "datadog_profiling_ffi.pdb")
    New-ImportLibrary -Dll (Join-Path $dynDir "datadog_profiling_ffi.dll") -DllName "datadog_profiling_ffi.dll" `
        -OutLib (Join-Path $dynDir "datadog_profiling_ffi.lib")
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
