# Builds the PYLO release APK with the Supabase anon/public key injected at
# build time via --dart-define-from-file, so the release APK can never be
# produced with cloud sync accidentally disabled.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\build_release_apk.ps1
#   powershell -ExecutionPolicy Bypass -File .\build_release_apk.ps1 -Arm64Only
#   powershell -ExecutionPolicy Bypass -File .\build_release_apk.ps1 -DartDefineFile C:\path\to\.env.local
#
# The define file defaults to dart_defines\.env.local (see the tracked
# .env.local.example template). The key value is never printed.

[CmdletBinding()]
param(
    [string]$DartDefineFile = (Join-Path $PSScriptRoot 'dart_defines\.env.local'),
    [switch]$Arm64Only
)

$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Read-AnonKey([string]$Path) {
    $value = $null
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*SUPABASE_ANON_KEY\s*=\s*(.*?)\s*$') {
            $value = $Matches[1]
        }
    }
    return $value
}

if (-not (Test-Path -LiteralPath $DartDefineFile)) {
    Fail "Missing dart-define file '$DartDefineFile'. Copy 'dart_defines\.env.local.example' to 'dart_defines\.env.local' and set SUPABASE_ANON_KEY, then re-run."
}

$anonKey = Read-AnonKey $DartDefineFile
if ([string]::IsNullOrEmpty($anonKey)) {
    Fail "SUPABASE_ANON_KEY is empty in '$DartDefineFile'. A release APK built without it would ship with cloud sync disabled. Set the anon/public key (never a service_role key), or pass '-DartDefineFile <path>'."
}

Write-Host "Using dart-define file: $DartDefineFile (anon key present)." -ForegroundColor Green

$flutterArgs = @('build', 'apk', '--release', "--dart-define-from-file=$DartDefineFile")
if ($Arm64Only) {
    $flutterArgs += @('--target-platform', 'android-arm64')
}

& flutter @flutterArgs
exit $LASTEXITCODE