param()

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if (Test-Path ".env") {
  Get-Content ".env" | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith("#") -or -not $line.Contains("=")) {
      return
    }
    $parts = $line.Split("=", 2)
    [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim(), "Process")
  }
}

$port = if ($env:ORCHESTRATOR_PORT) { $env:ORCHESTRATOR_PORT } else { "8765" }
$baseUrl = "http://localhost:$port"
$headers = @{}
if ($env:ORCHESTRATOR_TOKEN) {
  $headers["X-Orchestrator-Token"] = $env:ORCHESTRATOR_TOKEN
}

try {
  $health = Invoke-RestMethod -Uri "$baseUrl/health" -Method Get -TimeoutSec 5
  Write-Host "Orchestrator API: $($health.status) ($baseUrl)"
}
catch {
  Write-Host "Orchestrator API no disponible en $baseUrl"
  exit 1
}

try {
  $runs = Invoke-RestMethod -Uri "$baseUrl/runs" -Method Get -Headers $headers -TimeoutSec 5
  if (-not $runs) {
    Write-Host "Runs: ninguno"
  }
  else {
    $runs | Select-Object run_id, command_name, status, pid, started_at, finished_at | Format-Table
  }
}
catch {
  Write-Host "No se pudieron consultar runs: $($_.Exception.Message)"
}
