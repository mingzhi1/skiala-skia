param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("skiala-0.153.3-cpu", "slint-0.99.0-opengl")]
    [string]$Profile,

    [string]$Target = "x86_64-pc-windows-msvc"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$workRoot = Join-Path $repositoryRoot "_work\$Profile"
$sourceRoot = Join-Path $workRoot "rust-skia"
$stagingRoot = Join-Path $workRoot "staging"
$outputRoot = Join-Path $repositoryRoot "artifacts\$Profile"

switch ($Profile) {
    "skiala-0.153.3-cpu" {
        $version = "0.153.3"
        $cargoFeatures = "binary-cache,embed-icudtl,textlayout"
        $noDefaultFeatures = $true
        $expectedKey = "b7f043e0b1e2a850e702-$Target-textlayout-static"
        $consumer = "Skiala/minimal CPU raster with SkParagraph"
    }
    "slint-0.99.0-opengl" {
        $version = "0.99.0"
        $cargoFeatures = "d3d,gl,textlayout"
        $noDefaultFeatures = $false
        $expectedKey = "a25a0fdb7d90429aa2d1-$Target-d3d-gl-jpegd-jpege-pdf-textlayout-static"
        $consumer = "Slint 1.17.1 Skia OpenGL startup reference"
    }
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

function Get-CommandText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    return ((& $FilePath @ArgumentList 2>&1) | Out-String).Trim()
}

Remove-Item $workRoot, $outputRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $workRoot, $stagingRoot, $outputRoot | Out-Null

Invoke-Checked git @(
    "clone",
    "--branch", $version,
    "--depth", "1",
    "--recurse-submodules",
    "https://github.com/rust-skia/rust-skia.git",
    $sourceRoot
)

$buildArguments = @(
    "build",
    "-p", "skia-safe",
    "--release",
    "--locked",
    "--target", $Target,
    "--features", $cargoFeatures
)
if ($noDefaultFeatures) {
    $buildArguments += "--no-default-features"
}

Push-Location $sourceRoot
try {
    $env:RUSTFLAGS = "-C target-feature=+crt-static"
    $env:FORCE_SKIA_BUILD = "1"
    $env:BUILD_ARTIFACTSTAGINGDIRECTORY = $stagingRoot
    Remove-Item Env:SKIA_BINARIES_URL -ErrorAction SilentlyContinue
    Remove-Item Env:FORCE_SKIA_BINARIES_DOWNLOAD -ErrorAction SilentlyContinue

    Invoke-Checked cargo $buildArguments

    $cacheDirectory = Join-Path $stagingRoot "skia-binaries"
    $keyPath = Join-Path $cacheDirectory "key.txt"
    $tagPath = Join-Path $cacheDirectory "tag.txt"
    if (-not (Test-Path $keyPath) -or -not (Test-Path $tagPath)) {
        throw "skia-bindings did not export a binary cache into $cacheDirectory"
    }

    $actualKey = (Get-Content $keyPath -Raw).Trim()
    $actualTag = (Get-Content $tagPath -Raw).Trim()
    if ($actualKey -ne $expectedKey) {
        throw "Unexpected cache key. Expected '$expectedKey', got '$actualKey'"
    }
    if ($actualTag -ne $version) {
        throw "Unexpected cache tag. Expected '$version', got '$actualTag'"
    }

    $bindingsLibrary = Join-Path $cacheDirectory "skia-bindings.lib"
    if (-not (Test-Path $bindingsLibrary)) {
        throw "Missing skia-bindings.lib in exported cache"
    }
    $directives = Get-CommandText dumpbin @("/directives", $bindingsLibrary)
    if ($directives -notmatch "(?i)DEFAULTLIB:LIBCMT") {
        throw "skia-bindings.lib does not declare the static MSVC runtime LIBCMT"
    }
    if ($directives -match "(?i)DEFAULTLIB:MSVCRT") {
        throw "skia-bindings.lib unexpectedly declares the dynamic MSVC runtime MSVCRT"
    }

    $archiveName = "skia-binaries-$actualKey.tar.gz"
    $archivePath = Join-Path $outputRoot $archiveName
    Invoke-Checked tar.exe @("-czf", $archivePath, "-C", $stagingRoot, "skia-binaries")

    $archiveEntries = Get-CommandText tar.exe @("-tzf", $archivePath)
    foreach ($requiredEntry in @(
        "skia-binaries/key.txt",
        "skia-binaries/tag.txt",
        "skia-binaries/LICENSE_SKIA",
        "skia-binaries/bindings.rs",
        "skia-binaries/skia.lib",
        "skia-binaries/skia-bindings.lib"
    )) {
        if ($archiveEntries -notmatch "(?m)^$([regex]::Escape($requiredEntry))\r?$") {
            throw "Archive is missing $requiredEntry"
        }
    }

    # Validate the same import path consumers use, rather than trusting archive creation alone.
    Remove-Item Env:FORCE_SKIA_BUILD -ErrorAction SilentlyContinue
    Remove-Item Env:BUILD_ARTIFACTSTAGINGDIRECTORY -ErrorAction SilentlyContinue
    $env:FORCE_SKIA_BINARIES_DOWNLOAD = "1"
    $env:SKIA_BINARIES_URL = ([System.Uri]$archivePath).AbsoluteUri
    Invoke-Checked cargo @("clean", "-p", "skia-bindings", "--target", $Target)
    Invoke-Checked cargo $buildArguments

    $archiveHash = (Get-FileHash -Algorithm SHA256 $archivePath).Hash.ToLowerInvariant()
    $sourceCommit = (Get-CommandText git @("rev-parse", "HEAD")).Trim()
    $metadata = [ordered]@{
        schema = 1
        profile = $Profile
        consumer = $consumer
        rustSkiaVersion = $version
        rustSkiaCommit = $sourceCommit
        target = $Target
        cargoFeatures = $cargoFeatures.Split(",")
        noDefaultFeatures = $noDefaultFeatures
        crt = "static (/MT)"
        cacheKey = $actualKey
        archive = $archiveName
        archiveSha256 = $archiveHash
        archiveBytes = (Get-Item $archivePath).Length
        validatedByReimport = $true
        generatedAtUtc = [DateTime]::UtcNow.ToString("o")
        toolchain = [ordered]@{
            rustc = Get-CommandText rustc @("-Vv")
            cargo = Get-CommandText cargo @("-V")
            clang = Get-CommandText clang @("--version")
            msvcDeveloperCommandVersion = $env:VSCMD_VER
            runnerImage = $env:ImageOS
        }
    }

    $metadataPath = Join-Path $outputRoot "$archiveName.metadata.json"
    $checksumPath = Join-Path $outputRoot "$archiveName.sha256"
    $metadata | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 $metadataPath
    "$archiveHash  $archiveName" | Set-Content -Encoding ascii $checksumPath

    Write-Host "SKIA_CACHE $($metadata | ConvertTo-Json -Compress -Depth 6)"
}
finally {
    Pop-Location
}
