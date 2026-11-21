<#
.SYNOPSIS
  Create the OrderFlow Kafka topics. Idempotent: safe to run any number of times.

.DESCRIPTION
  Creates orderflow.orders.v1, orderflow.inventory.v1 and their .dlq topics with
  3 partitions and replication factor 1 (single dev broker).

  --if-not-exists makes a re-run a no-op. After creating, every topic is
  described and its partition count checked. If an existing topic has a
  DIFFERENT partition count the script fails and does NOT alter it: adding
  partitions changes which partition a key (orderId) hashes to, which would
  break per-order ordering for in-flight orders (rule 8).

  Requires the kafka container to be running (.\scripts\dev.ps1 up).
#>
[CmdletBinding()]
param(
    [int]$Partitions = 3,
    [int]$ReplicationFactor = 1
)

$ErrorActionPreference = 'Continue'   # native stderr must not throw in PS 5.1
$Bootstrap = 'kafka:19092'
$KafkaBin  = '/opt/kafka/bin'
$Topics = @(
    'orderflow.orders.v1',
    'orderflow.inventory.v1',
    'orderflow.orders.v1.dlq',
    'orderflow.inventory.v1.dlq'
)

function Invoke-KafkaTopics {
    param([string[]]$KafkaArgs)
    $out = & docker compose exec -T kafka "$KafkaBin/kafka-topics.sh" --bootstrap-server $Bootstrap @KafkaArgs 2>&1 |
        ForEach-Object { "$_" }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
}

Push-Location (Join-Path $PSScriptRoot '..')
try {
    $failed = $false
    foreach ($t in $Topics) {
        $r = Invoke-KafkaTopics @('--create', '--if-not-exists', '--topic', $t,
            '--partitions', "$Partitions", '--replication-factor', "$ReplicationFactor")
        if ($r.ExitCode -ne 0) {
            Write-Host "[FAIL] create $t`n$($r.Output)" -ForegroundColor Red
            $failed = $true
            continue
        }

        $d = Invoke-KafkaTopics @('--describe', '--topic', $t)
        if ($d.ExitCode -ne 0 -or $d.Output -notmatch 'PartitionCount:\s*(\d+)') {
            Write-Host "[FAIL] describe $t`n$($d.Output)" -ForegroundColor Red
            $failed = $true
            continue
        }
        $actual = [int]$Matches[1]
        if ($actual -ne $Partitions) {
            Write-Host "[FAIL] $t has $actual partitions, expected $Partitions. Not altering it (would remap orderId keys). Use dev.ps1 reset in dev." -ForegroundColor Red
            $failed = $true
        } else {
            Write-Host "[OK]   $t (partitions=$actual)" -ForegroundColor Green
        }
    }
    if ($failed) { exit 1 }
    exit 0
}
finally {
    Pop-Location
}
