$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$localDir = Join-Path $repoRoot '.local'
$envPath = Join-Path $localDir 'dev.env'

if (Test-Path -LiteralPath $envPath) {
    Write-Host 'Existing development credentials preserved.'
    exit 0
}

New-Item -ItemType Directory -Force -Path $localDir | Out-Null

$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

try {
    $adminBytes = New-Object byte[] 32
    $appBytes = New-Object byte[] 32

    $rng.GetBytes($adminBytes)
    $rng.GetBytes($appBytes)

    $adminPassword = [Convert]::ToBase64String($adminBytes)
    $appPassword = [Convert]::ToBase64String($appBytes)

    $content = "POSTGRES_PASSWORD=$adminPassword`nDB_APP_PASSWORD=$appPassword`n"

    [System.IO.File]::WriteAllText(
        $envPath,
        $content,
        [System.Text.Encoding]::ASCII
    )

    Write-Host 'Development credentials created without displaying them.'
} finally {
    $rng.Dispose()
    $adminPassword = $null
    $appPassword = $null
    $content = $null
}
