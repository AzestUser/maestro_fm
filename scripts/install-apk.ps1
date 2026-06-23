param(
    [Parameter(Mandatory = $true)]
    [string]$ApkPath,

    [switch]$Replace
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ApkPath)) {
    throw "APK not found: $ApkPath"
}

$adb = Get-Command adb -ErrorAction SilentlyContinue
if (-not $adb) {
    throw "adb not found in PATH. Install Android SDK platform-tools."
}

$installArgs = @("install")
if ($Replace) {
    $installArgs += "-r"
}
$installArgs += $ApkPath

& adb @installArgs
if ($LASTEXITCODE -ne 0) {
    throw "adb install failed with exit code $LASTEXITCODE"
}

Write-Host "Installed: $ApkPath"
