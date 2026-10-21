param([switch]$RecreateDatabase)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $repoRoot '.local/dev.env'
$baseUrl = 'http://127.0.0.1:8080'

function Invoke-Compose {
    param([string[]]$Arguments)
    & docker compose --env-file $envPath @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'Docker Compose verification command failed.' }
}

function Assert-Check {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    Write-Host "PASS: $Message"
}

function Wait-Ready {
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $ready = Invoke-RestMethod "$baseUrl/readyz" -TimeoutSec 5
            if ($ready.status -eq 'ready') { return }
        } catch { }
        Start-Sleep -Seconds 2
    }
    throw 'Readiness did not recover through Nginx.'
}

Push-Location $repoRoot
try {
    Invoke-Compose -Arguments @('config', '--quiet')
    Wait-Ready
    Assert-Check ((Invoke-RestMethod "$baseUrl/healthz").status -eq 'ok') 'HTTP health through Nginx'

    $appId = (Invoke-Compose -Arguments @('ps', '-q', 'app')).Trim()
    $uid = Invoke-Compose -Arguments @('exec', '-T', 'app', 'id', '-u')
    Assert-Check ($uid.Trim() -eq '10001') 'Running API uses UID 10001'
    foreach ($service in @('app', 'db', 'nginx')) {
        $containerId = (Invoke-Compose -Arguments @('ps', '-q', $service)).Trim()
        $bindingJson = & docker inspect --format '{{json .HostConfig.PortBindings}}' $containerId
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect port bindings.' }
        $bindings = $bindingJson | ConvertFrom-Json
        if ($service -eq 'nginx') {
            Assert-Check ($bindings.'80/tcp'[0].HostIp -eq '127.0.0.1' -and $bindings.'80/tcp'[0].HostPort -eq '8080') 'Nginx is published on loopback port 8080'
        } else {
            Assert-Check ($null -eq $bindings -or @($bindings.PSObject.Properties).Count -eq 0) "$service has no published host port"
        }
    }

    # Run from the API container: this exercises the actual network and credentials.
    $databaseCheck = @'
import os
import psycopg
from app.config import Settings
from app.db import Database

settings = Settings.from_env()
with Database(settings).connect() as conn:
    role = conn.execute("SELECT current_user AS name, rolsuper, rolcreatedb, rolcreaterole FROM pg_roles WHERE rolname = current_user").fetchone()
    assert role['name'] == 'notes_app'
    assert not any(role[k] for k in ('rolsuper', 'rolcreatedb', 'rolcreaterole'))
    assert not conn.execute("SELECT has_schema_privilege(current_user, 'public', 'CREATE') AS allowed").fetchone()['allowed']
try:
    psycopg.connect(host=os.environ['DB_HOST'], port=os.environ['DB_PORT'], dbname=os.environ['DB_NAME'], user=os.environ['DB_USER'], password='deliberately-incorrect-verification-password', connect_timeout=3)
except psycopg.OperationalError as exc:
    if 'password authentication failed' not in str(exc):
        raise AssertionError('Wrong-password check failed for a reason other than authentication') from None
else:
    raise AssertionError('Incorrect database password was accepted')
assert 'POSTGRES_PASSWORD' not in os.environ
assert 'PIP_CERT' not in os.environ
assert not os.path.exists('/run/secrets/build_ca')
assert not os.path.exists('/tmp/pip-ca.pem')
print('PASS: restricted DB login, wrong-password rejection, and no retained build CA/admin password in API')
'@
    $databaseCheck | & docker compose --env-file $envPath exec -T app python -
    if ($LASTEXITCODE -ne 0) { throw 'Database privilege/build-secret verification failed.' }

    $payload = @{ title = "Container verification $([guid]::NewGuid().ToString('N'))"; content = 'Persist this record across container recreation.' } | ConvertTo-Json
    $response = Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/api/notes" -Method Post -ContentType 'application/json' -Body $payload
    Assert-Check ($response.StatusCode -eq 201) 'HTTP POST returns 201'
    $note = $response.Content | ConvertFrom-Json
    $stored = Invoke-RestMethod "$baseUrl/api/notes/$($note.id)"
    Assert-Check ($stored.title -ceq $note.title -and $stored.content -ceq $note.content) 'HTTP GET returns the committed note'

    $sql = "SELECT count(*) FROM public.notes WHERE id = $([long]$note.id);"
    $rowCount = $sql | & docker compose --env-file $envPath exec -T db psql -X -v ON_ERROR_STOP=1 -U postgres -d notes -tA
    if ($LASTEXITCODE -ne 0) { throw 'Independent database query failed.' }
    Assert-Check ($rowCount.Trim() -eq '1') 'Independent SQL connection sees the committed row'

    if ($RecreateDatabase) {
        $before = (Invoke-Compose -Arguments @('ps', '-q', 'db')).Trim()
        Invoke-Compose -Arguments @('up', '--detach', '--no-deps', '--force-recreate', '--wait', '--wait-timeout', '120', 'db')
        $after = (Invoke-Compose -Arguments @('ps', '-q', 'db')).Trim()
        Assert-Check ($before -ne $after) 'Database container was replaced'
        Wait-Ready
        $recovered = Invoke-RestMethod "$baseUrl/api/notes/$($note.id)"
        Assert-Check ($recovered.id -eq $note.id -and $recovered.title -ceq $note.title -and $recovered.content -ceq $note.content -and $recovered.created_at -eq $note.created_at) 'Same note and timestamp survive database recreation'
        Assert-Check ((Invoke-Compose -Arguments @('ps', '-q', 'app')).Trim() -eq $appId) 'API recovered without replacing its container'
    }

    $updatedPayload = @{ title = $note.title; content = 'Updated through Nginx.' } | ConvertTo-Json
    $updated = Invoke-RestMethod "$baseUrl/api/notes/$($note.id)" -Method Put -ContentType 'application/json' -Body $updatedPayload
    Assert-Check ($updated.content -eq 'Updated through Nginx.') 'HTTP PUT updates the note'
    $deleted = Invoke-WebRequest -UseBasicParsing "$baseUrl/api/notes/$($note.id)" -Method Delete
    Assert-Check ($deleted.StatusCode -eq 204) 'HTTP DELETE removes only the verification note'
    $status = 0
    try { $null = Invoke-WebRequest -UseBasicParsing "$baseUrl/api/notes/$($note.id)" } catch {
        if ($null -ne $_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    }
    Assert-Check ($status -eq 404) 'Deleted verification note returns 404'
    Write-Host 'Local container verification completed. Existing notes were preserved.'
} finally {
    Pop-Location
}
