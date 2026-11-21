<#
.SYNOPSIS
  OrderFlow dev entry point (replaces a Makefile on Windows).

.EXAMPLE
  .\scripts\dev.ps1 up              # start platform (dev ports on 127.0.0.1), wait healthy, create topics
  .\scripts\dev.ps1 verify          # run platform checks (PASS/FAIL)
  .\scripts\dev.ps1 logs kafka      # follow logs (all services if omitted)
  .\scripts\dev.ps1 down            # stop, KEEP data
  .\scripts\dev.ps1 reset           # stop, DELETE volumes (asks first; -Force skips), start again

  If script execution is blocked:
  powershell -ExecutionPolicy Bypass -File .\scripts\dev.ps1 up
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('up', 'down', 'logs', 'reset', 'verify')]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Service,

    [switch]$Force
)

$ErrorActionPreference = 'Continue'   # native stderr must not throw in PS 5.1
$Root = Resolve-Path (Join-Path $PSScriptRoot '..')
# The dev override publishes Kafka/Postgres/Redis on 127.0.0.1 only. A plain
# "docker compose up" (base file alone) publishes nothing (rule 17).
$ComposeFiles = @('-f', 'docker-compose.yml', '-f', 'docker-compose.dev.yml')

function Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

function Ensure-Env {
    if (-not (Test-Path (Join-Path $Root '.env'))) {
        Copy-Item (Join-Path $Root '.env.example') (Join-Path $Root '.env')
        Write-Host '    created .env from .env.example (dev defaults)' -ForegroundColor Yellow
    }
}

function Ensure-Keys {
    if (Get-Command node -ErrorAction SilentlyContinue) {
        & node (Join-Path $PSScriptRoot 'gen-keys.mjs')
    } else {
        Write-Host '    node not found: skipping key generation (run: node scripts/gen-keys.mjs)' -ForegroundColor Yellow
    }
}

function Invoke-Up {
    Step 'Checking .env'
    Ensure-Env
    Step 'Ensuring dev RS256 keys in ./keys'
    Ensure-Keys
    Step 'Starting kafka, postgres, redis (waiting for healthchecks)'
    & docker compose @ComposeFiles up -d --quiet-pull --wait --wait-timeout 180
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'compose up failed or a service is unhealthy. See: .\scripts\dev.ps1 logs' -ForegroundColor Red
        exit 1
    }
    Step 'Creating Kafka topics (idempotent)'
    & (Join-Path $PSScriptRoot 'create-topics.ps1')
    if ($LASTEXITCODE -ne 0) { exit 1 }
    & docker compose @ComposeFiles ps
    Step 'Platform is up. Next: .\scripts\dev.ps1 verify'
}

Push-Location $Root
try {
    switch ($Command) {
        'up' { Invoke-Up }
        'down' {
            Step 'Stopping (data volumes kept)'
            & docker compose @ComposeFiles down
            exit $LASTEXITCODE
        }
        'logs' {
            $svcArgs = @()
            if ($Service) { $svcArgs = @($Service) }
            & docker compose @ComposeFiles logs -f --tail 200 @svcArgs
        }
        'reset' {
            if (-not $Force) {
                $answer = Read-Host 'This DELETES all local Postgres, Kafka and Redis data. Type "reset" to continue'
                if ($answer -ne 'reset') { Write-Host 'Aborted.'; exit 1 }
            }
            Step 'Removing containers and volumes'
            & docker compose @ComposeFiles down -v
            if ($LASTEXITCODE -ne 0) { exit 1 }
            Invoke-Up
        }
        'verify' {
            & (Join-Path $PSScriptRoot 'verify-platform.ps1')
            exit $LASTEXITCODE
        }
    }
}
finally {
    Pop-Location
}
