param(
  [Parameter(Position = 0)]
  [ValidateSet("help", "start", "demo", "smoke", "status", "health", "logs", "ui", "stop")]
  [string]$Action = "help",

  [string]$Service = "",

  [string]$Since = "10m"
)

$ErrorActionPreference = "Stop"

Set-Location $PSScriptRoot

$InfraCompose = Join-Path $PSScriptRoot "docker-compose.infra.yml"
$EdcCompose = Join-Path $PSScriptRoot "docker-compose.edc.yml"
$StartScript = Join-Path $PSScriptRoot "start-edc-three-providers.ps1"
$DemoScript = Join-Path $PSScriptRoot "start-edc-and-smoke-three-providers.ps1"
$SmokeScript = Join-Path $PSScriptRoot "smoke-test-three-providers.ps1"
$UiApp = Join-Path $PSScriptRoot "ui\app.py"

function Write-Section {
  param([string]$Text)
  Write-Host ""
  Write-Host "== $Text =="
}

function Invoke-ProjectScript {
  param([string]$Path)
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path
}

function Start-Infra {
  Write-Section "Starting base infrastructure"
  docker compose -f $InfraCompose up -d
}

function Show-Help {
  @"
Puerto Dataspace EDC service facade

Usage:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 start
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 demo
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 smoke
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 status
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 health
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 logs -Service NAME
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 ui
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 stop

Examples:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 demo
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 logs -Service consumer-controlplane -Since 20m
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 health
"@
}

switch ($Action) {
  "help" {
    Show-Help
  }

  "start" {
    Start-Infra
    Write-Section "Starting and provisioning EDC services"
    Invoke-ProjectScript $StartScript
  }

  "demo" {
    Start-Infra
    Write-Section "Starting full service demo"
    Invoke-ProjectScript $DemoScript
  }

  "smoke" {
    Write-Section "Running smoke test"
    Invoke-ProjectScript $SmokeScript
  }

  "status" {
    Write-Section "Infrastructure"
    docker compose -f $InfraCompose ps
    Write-Section "EDC services"
    docker compose -f $EdcCompose ps
  }

  "health" {
    $checks = @(
      @{ Name = "Keycloak realm"; Url = "http://localhost:8080/realms/logistics-dataspace" },
      @{ Name = "Vault"; Url = "http://localhost:8200/v1/sys/health" },
      @{ Name = "Mock API"; Url = "http://localhost:8081/health" },
      @{ Name = "Consumer Identity Hub"; Url = "http://localhost:7280/api/check/readiness" },
      @{ Name = "Issuer Service"; Url = "http://localhost:10010/api/check/readiness" }
    )

    foreach ($check in $checks) {
      try {
        Invoke-WebRequest -UseBasicParsing -Method Get -Uri $check.Url -TimeoutSec 5 | Out-Null
        Write-Host ("OK   {0} - {1}" -f $check.Name, $check.Url)
      }
      catch {
        Write-Host ("FAIL {0} - {1}" -f $check.Name, $check.Url)
      }
    }
  }

  "logs" {
    if ([string]::IsNullOrWhiteSpace($Service)) {
      throw "Use -Service with the container name, for example: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\service.ps1 logs -Service consumer-controlplane"
    }
    docker logs $Service --since $Since
  }

  "ui" {
    Write-Section "Starting Streamlit dashboard"
    python -m streamlit run $UiApp
  }

  "stop" {
    Write-Section "Stopping service, preserving volumes"
    docker compose -f $InfraCompose -f $EdcCompose down
  }
}
