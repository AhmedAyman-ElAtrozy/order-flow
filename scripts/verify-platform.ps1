<#
.SYNOPSIS
  Verify the OrderFlow platform. Prints PASS/FAIL per check; exit code 1 on any FAIL.

.DESCRIPTION
  Checks:
    * postgres, kafka, redis containers are healthy
    * dev ports are published on 127.0.0.1 only (when the dev override is used)
    * the 4 schemas exist, each owned by its service role
    * the 4 service roles exist, can log in, are not superusers
    * each role, logging in with its own password, can create a table in its
      own schema and has USAGE on NO other schema (including public)
    * the 4 real topics exist with 3 partitions (read-only: nothing is written)
    * produce/consume round trip on a TEMPORARY topic orderflow.platform-probe-<random>,
      which is deleted afterwards. The real orders topic is never written to by
      this script, so no consumer ever sees a non-contract message.
    * Redis answers PING with the password and rejects unauthenticated clients
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'   # native stderr must not throw in PS 5.1
$Bootstrap = 'kafka:19092'
$KafkaBin  = '/opt/kafka/bin'
$script:Failures = 0
$script:Passes = 0

function Write-Result {
    param([bool]$Ok, [string]$Name, [string]$Detail = '')
    if ($Ok) {
        $script:Passes++
        Write-Host ("[PASS] {0}" -f $Name) -ForegroundColor Green
    } else {
        $script:Failures++
        Write-Host ("[FAIL] {0}" -f $Name) -ForegroundColor Red
        if ($Detail) { Write-Host ("       {0}" -f ($Detail -replace "`n", "`n       ")) -ForegroundColor DarkGray }
    }
}

# Run a native command, capture stdout+stderr as one string, return exit code too.
function Invoke-Native {
    param([string[]]$Cmd, [string]$InputText = $null)
    $exe = $Cmd[0]
    $rest = @()
    if ($Cmd.Length -gt 1) { $rest = $Cmd[1..($Cmd.Length - 1)] }
    if ($null -ne $InputText) {
        $out = $InputText | & $exe @rest 2>&1 | ForEach-Object { "$_" }
    } else {
        $out = & $exe @rest 2>&1 | ForEach-Object { "$_" }
    }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (($out -join "`n").Trim()) }
}

function Invoke-AdminSql {
    param([string]$Sql)
    # Admin connects over the local socket inside the container.
    Invoke-Native @('docker', 'compose', 'exec', '-T', 'postgres', 'sh', '-c',
        'psql -U $POSTGRES_USER -d orderflow -qtA -v ON_ERROR_STOP=1') -InputText $Sql
}

function Get-DotEnv {
    $vars = @{}
    Get-Content (Join-Path $PSScriptRoot '..\.env') | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') { $vars[$Matches[1]] = $Matches[2].Trim() }
    }
    return $vars
}

function Invoke-ServiceSql {
    param([string]$Role, [string]$Password, [string]$Sql)
    # Connect from a SEPARATE throwaway container on orderflow-net, exactly like a
    # real service would. Do NOT use "exec postgres psql -h 127.0.0.1": the
    # official image trusts loopback inside its own container, so a wrong
    # password would still log in and the check would prove nothing.
    # "-e PGPASSWORD" (name only) copies the value from this process's env, so
    # the password never appears on a command line.
    $env:PGPASSWORD = $Password
    try {
        Invoke-Native @('docker', 'run', '--rm', '-i', '--network', 'orderflow-net', '-e', 'PGPASSWORD',
            $script:PgImage, 'psql', '-h', 'postgres', '-U', $Role, '-d', 'orderflow', '-qtA', '-v', 'ON_ERROR_STOP=1') -InputText $Sql
    }
    finally {
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    }
}

function Invoke-KafkaTool {
    param([string]$Tool, [string[]]$ToolArgs, [string]$InputText = $null)
    Invoke-Native (@('docker', 'compose', 'exec', '-T', 'kafka', "$KafkaBin/$Tool", '--bootstrap-server', $Bootstrap) + $ToolArgs) -InputText $InputText
}

Push-Location (Join-Path $PSScriptRoot '..')
try {
    Write-Host '== Containers'
    foreach ($svc in @('postgres', 'kafka', 'redis')) {
        $id = (Invoke-Native @('docker', 'compose', 'ps', '-q', $svc)).Output
        if (-not $id) { Write-Result $false "$svc container running" 'not running'; continue }
        $h = Invoke-Native @('docker', 'inspect', '--format', '{{.State.Health.Status}}', $id)
        Write-Result ($h.Output -eq 'healthy') "$svc healthy" "status: $($h.Output)"
    }

    Write-Host '== Dev ports (loopback only)'
    foreach ($p in @(@('postgres', '5432'), @('kafka', '9092'), @('redis', '6379'))) {
        $r = Invoke-Native @('docker', 'compose', 'port', $p[0], $p[1])
        $ok = ($r.ExitCode -eq 0) -and ($r.Output -match '^127\.0\.0\.1:\d+$')
        Write-Result $ok "$($p[0]):$($p[1]) published on loopback only -> $($r.Output)" "docker compose port: '$($r.Output)'"
    }

    Write-Host '== PostgreSQL'
    $envVars = Get-DotEnv
    # Use the exact image the running postgres container uses (no second pin to drift).
    $pgId = (Invoke-Native @('docker', 'compose', 'ps', '-q', 'postgres')).Output
    $script:PgImage = (Invoke-Native @('docker', 'inspect', '--format', '{{.Config.Image}}', $pgId)).Output
    $expectedOwners = @('identity:identity_svc', 'inventory:inventory_svc', 'orders:orders_svc', 'payments:payments_svc')
    $r = Invoke-AdminSql "SELECT nspname || ':' || pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname IN ('identity','orders','inventory','payments') ORDER BY nspname;"
    $got = @($r.Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Write-Result (($r.ExitCode -eq 0) -and (($got -join ',') -eq ($expectedOwners -join ','))) '4 schemas exist, each owned by its service role' "got: $($got -join ', ')`n$($r.Output)"

    $expectedRoles = @('identity_svc:t:f', 'inventory_svc:t:f', 'orders_svc:t:f', 'payments_svc:t:f')
    $r = Invoke-AdminSql "SELECT rolname || ':' || CASE WHEN rolcanlogin THEN 't' ELSE 'f' END || ':' || CASE WHEN rolsuper THEN 't' ELSE 'f' END FROM pg_roles WHERE rolname IN ('identity_svc','orders_svc','inventory_svc','payments_svc') ORDER BY rolname;"
    $got = @($r.Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Write-Result (($r.ExitCode -eq 0) -and (($got -join ',') -eq ($expectedRoles -join ','))) '4 service roles exist (LOGIN, not superuser)' "got: $($got -join ', ')`n$($r.Output)"

    $services = @(
        @{ Role = 'identity_svc';  Schema = 'identity';  Var = 'IDENTITY_DB_PASSWORD' },
        @{ Role = 'orders_svc';    Schema = 'orders';    Var = 'ORDERS_DB_PASSWORD' },
        @{ Role = 'inventory_svc'; Schema = 'inventory'; Var = 'INVENTORY_DB_PASSWORD' },
        @{ Role = 'payments_svc';  Schema = 'payments';  Var = 'PAYMENTS_DB_PASSWORD' }
    )
    foreach ($s in $services) {
        # Create a table unqualified (lands in search_path = own schema), then list
        # every schema this role has USAGE on. Rolled back: leaves nothing behind.
        $sql = @"
BEGIN;
CREATE TABLE verify_probe (id int);
SELECT current_schema() || '|' || (SELECT n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relname = 'verify_probe') || '|' || coalesce((SELECT string_agg(x, ',' ORDER BY x) FROM unnest(ARRAY['identity','orders','inventory','payments','public']) AS x WHERE has_schema_privilege(x, 'USAGE')), '');
ROLLBACK;
"@
        $r = Invoke-ServiceSql $s.Role $envVars[$s.Var] $sql
        $want = "$($s.Schema)|$($s.Schema)|$($s.Schema)"
        Write-Result (($r.ExitCode -eq 0) -and ($r.Output -eq $want)) "$($s.Role): password login over network, writes only to '$($s.Schema)', no access to other schemas" "expected '$want' (search_path|table schema|schemas with USAGE), got '$($r.Output)'"
    }

    # Negative checks: these must FAIL to connect / read, or the checks above prove nothing.
    $r = Invoke-ServiceSql 'orders_svc' 'definitely-wrong-password' 'SELECT 1;'
    Write-Result (($r.ExitCode -ne 0) -and ($r.Output -match 'password authentication failed')) 'wrong password is rejected (scram-sha-256 enforced on the network)' $r.Output

    $r = Invoke-ServiceSql 'inventory_svc' $envVars['INVENTORY_DB_PASSWORD'] 'SELECT 1 FROM orders.anything;'
    Write-Result (($r.ExitCode -ne 0) -and ($r.Output -match 'permission denied for schema orders')) 'inventory_svc reading orders.* is denied' $r.Output

    Write-Host '== Kafka topics'
    $r = Invoke-KafkaTool 'kafka-topics.sh' @('--describe')
    foreach ($t in @('orderflow.orders.v1', 'orderflow.inventory.v1', 'orderflow.orders.v1.dlq', 'orderflow.inventory.v1.dlq')) {
        $pattern = 'Topic:\s*' + [regex]::Escape($t) + '\s+TopicId:\s*\S+\s+PartitionCount:\s*(\d+)\s+ReplicationFactor:\s*(\d+)'
        if (($r.ExitCode -eq 0) -and ($r.Output -match $pattern)) {
            $pc = [int]$Matches[1]; $rf = [int]$Matches[2]
            Write-Result (($pc -eq 3) -and ($rf -eq 1)) "$t exists (partitions=$pc, rf=$rf)" 'expected partitions=3, rf=1'
        } else {
            Write-Result $false "$t exists" 'topic not found (run .\scripts\create-topics.ps1)'
        }
    }

    Write-Host '== Kafka round trip (temporary topic)'
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $probeTopic = "orderflow.platform-probe-$suffix"
    $nonce = [guid]::NewGuid().ToString()
    $probeKey = "probe-$suffix"
    try {
        $c = Invoke-KafkaTool 'kafka-topics.sh' @('--create', '--topic', $probeTopic, '--partitions', '3', '--replication-factor', '1')
        Write-Result ($c.ExitCode -eq 0) "create temp topic $probeTopic" $c.Output

        if ($c.ExitCode -eq 0) {
            $payload = '{"probe":"' + $nonce + '"}'
            $p = Invoke-KafkaTool 'kafka-console-producer.sh' @('--topic', $probeTopic,
                '--property', 'parse.key=true', '--property', 'key.separator=|',
                '--producer-property', 'acks=all') -InputText "$probeKey|$payload"
            Write-Result ($p.ExitCode -eq 0) "produce keyed message (key=$probeKey)" $p.Output

            # No committed offsets: the throwaway consumer group leaves nothing to clean up.
            $k = Invoke-KafkaTool 'kafka-console-consumer.sh' @('--topic', $probeTopic, '--from-beginning',
                '--max-messages', '1', '--timeout-ms', '20000',
                '--property', 'print.key=true', '--property', 'key.separator=|',
                '--consumer-property', 'enable.auto.commit=false')
            $line = ($k.Output -split "`n" | Where-Object { $_ -like "$probeKey|*" } | Select-Object -First 1)
            Write-Result ([bool]$line -and ($line -eq "$probeKey|$payload")) 'consume same message back (key + payload match)' "consumer output:`n$($k.Output)"
        }
    }
    finally {
        $d = Invoke-KafkaTool 'kafka-topics.sh' @('--delete', '--topic', $probeTopic)
        $gone = $false
        for ($i = 0; $i -lt 10 -and -not $gone; $i++) {
            $l = Invoke-KafkaTool 'kafka-topics.sh' @('--list')
            $gone = ($l.ExitCode -eq 0) -and -not (($l.Output -split "`n") -contains $probeTopic)
            if (-not $gone) { Start-Sleep -Seconds 1 }
        }
        Write-Result $gone "delete temp topic $probeTopic" $d.Output
    }

    Write-Host '== Redis'
    $r = Invoke-Native @('docker', 'compose', 'exec', '-T', 'redis', 'redis-cli', 'ping')
    Write-Result ($r.Output -eq 'PONG') 'Redis PING with password -> PONG' $r.Output
    $r = Invoke-Native @('docker', 'compose', 'exec', '-T', 'redis', 'sh', '-c', 'unset REDISCLI_AUTH; redis-cli ping')
    Write-Result ($r.Output -match 'NOAUTH') 'Redis rejects unauthenticated PING' $r.Output

    Write-Host ''
    if ($script:Failures -eq 0) {
        Write-Host ("RESULT: PASS ({0} checks)" -f $script:Passes) -ForegroundColor Green
        exit 0
    } else {
        Write-Host ("RESULT: FAIL ({0} failed, {1} passed)" -f $script:Failures, $script:Passes) -ForegroundColor Red
        exit 1
    }
}
finally {
    Pop-Location
}
