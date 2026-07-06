#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Build script for MissionPlanner (terminal and VS Code entry point).

.PARAMETER Configuration
    Debug or Release. Default: Debug.

.PARAMETER Target
    Build, Rebuild or Clean. Default: Build.

.PARAMETER Solution
    Solution file to build. Default: MissionPlanner.sln.

.PARAMETER Project
    MSBuild project target to scope the build to (builds just this project and
    its actual dependency graph). Default: MissionPlanner. The solution also
    contains a number of libraries that multi-target netstandard2.0 for an
    in-progress Mono/Linux port; building the raw .sln builds every one of
    those extra configurations too, several of which don't compile yet and
    are unrelated to the Windows app. Pass -Project '' to build the whole
    solution anyway (e.g. to check on that Mono-port work).

.PARAMETER NoRestore
    Skip NuGet restore.

.PARAMETER NoSign
    Skip signing the built exe. By default, after a successful Build/Rebuild,
    the output exe is Authenticode-signed with a local dev certificate
    (subject "CN=MissionPlanner Dev Build, O=Local Dev", auto-created and
    trusted on first use). Every rebuild produces a fresh unsigned binary,
    and this machine has Windows Smart App Control enabled, which blocks
    unsigned/unrecognized executables from running at all — signing on
    every build is what keeps `MissionPlanner.exe` launchable without
    re-running Set-AuthenticodeSignature by hand each time.

.EXAMPLE
    ./build.ps1
    ./build.ps1 -Configuration Release
    ./build.ps1 -Target Rebuild
    ./build.ps1 -Target Clean
    ./build.ps1 -Project '' -Solution MissionPlannerLib.sln -Configuration Release
#>
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',

    [ValidateSet('Build', 'Rebuild', 'Clean')]
    [string]$Target = 'Build',

    [string]$Solution = 'MissionPlanner.sln',

    [string]$Project = 'MissionPlanner',

    [switch]$NoRestore,

    [switch]$NoSign
)

$SigningCertSubject = 'CN=MissionPlanner Dev Build, O=Local Dev'

# Signs with the dev certificate created and trusted earlier (one-time,
# manual setup - see README/session notes). Never creates or trusts a new
# certificate on its own: if it's missing, this just warns and skips
# signing so the build itself still succeeds.
function Sign-Output([string]$exePath) {
    if (-not (Test-Path $exePath)) { return }

    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $SigningCertSubject } | Select-Object -First 1
    if (-not $cert) {
        Write-Host "No local dev signing certificate found (subject '$SigningCertSubject') - skipping signing. Windows Smart App Control may block running the exe." -ForegroundColor Yellow
        return
    }

    $result = Set-AuthenticodeSignature -FilePath $exePath -Certificate $cert -HashAlgorithm SHA256
    if ($result.Status -eq 'Valid') {
        Write-Host "Signed: $exePath" -ForegroundColor Green
    } else {
        Write-Host "Signing did not validate ($($result.Status)): $($result.StatusMessage)" -ForegroundColor Yellow
    }
}

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Find-MSBuild {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $installPath = & $vswhere -latest -prerelease -products * `
            -requires Microsoft.Component.MSBuild -property installationPath
        if ($installPath) {
            $candidate = Join-Path $installPath 'MSBuild\Current\Bin\MSBuild.exe'
            if (Test-Path $candidate) { return $candidate }
        }
    }

    # Fallback: known install locations (older VS versions)
    $fallbacks = @(
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2017\Community\MSBuild\15.0\Bin\MSBuild.exe"
    )
    foreach ($path in $fallbacks) {
        if (Test-Path $path) { return $path }
    }

    throw "MSBuild.exe not found. Install Visual Studio (with the '.NET desktop development' workload) or Build Tools for Visual Studio."
}

$msbuild = Find-MSBuild
Write-Host "Using MSBuild: $msbuild"

function Get-TargetSpec([string]$verb) {
    if (-not $Project) { return $verb }
    # MSBuild's per-project solution target has no suffix for the default Build verb.
    if ($verb -eq 'Build') { return $Project }
    return "$Project`:$verb"
}

function Invoke-MSBuild([string]$verb, [switch]$Restore) {
    $args = @(
        $Solution,
        "/t:$(Get-TargetSpec $verb)",
        "/p:Configuration=$Configuration",
        '/m',
        '/nologo',
        '/verbosity:minimal',
        '/consoleloggerparameters:Summary'
    )
    if ($Restore -and -not $NoRestore) { $args += '/restore' }
    # Route MSBuild's own console output straight to the host instead of the
    # success stream: otherwise it merges with this function's `return` value
    # when the call is captured (e.g. `$x = Invoke-MSBuild ...`), corrupting
    # the exit code with the build log text.
    & $msbuild @args | Out-Host
    return $LASTEXITCODE
}

# Rebuild is run as two separate MSBuild invocations (Clean, then a fresh
# Build+restore) rather than MSBuild's built-in Rebuild verb. Some NuGet
# packages (e.g. GDAL) generate source files from restore-time content
# transforms into obj\; MSBuild's combined Rebuild target can clean that
# generated output *after* restore has already produced it in the same
# invocation, leaving the compile step short a file it needs. Two
# invocations avoids that race.
if ($Target -eq 'Rebuild') {
    Write-Host "Clean ($Configuration) -> $Solution [$(Get-TargetSpec 'Clean')]"
    Invoke-MSBuild -verb 'Clean' | Out-Null
    Write-Host "Build ($Configuration) -> $Solution [$(Get-TargetSpec 'Build')]"
    $exitCode = Invoke-MSBuild -verb 'Build' -Restore
} else {
    Write-Host "$Target ($Configuration) -> $Solution [$(Get-TargetSpec $Target)]"
    $exitCode = Invoke-MSBuild -verb $Target -Restore:($Target -ne 'Clean')
}

if ($exitCode -eq 0) {
    Write-Host "Build succeeded." -ForegroundColor Green
    if ($Target -ne 'Clean') {
        $outputExe = "bin\$Configuration\net461\MissionPlanner.exe"
        Write-Host "Output: $outputExe"
        if (-not $NoSign) {
            Sign-Output (Join-Path $PSScriptRoot $outputExe)
        }
    }
} else {
    Write-Host "Build failed with exit code $exitCode." -ForegroundColor Red
}

exit $exitCode
