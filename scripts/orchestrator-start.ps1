param(
  [switch]$Background
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if (-not (Test-Path ".env") -and (Test-Path ".env.example")) {
  Copy-Item ".env.example" ".env"
  Write-Host "Creado .env desde .env.example"
}

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

if (-not $env:ORCHESTRATOR_HOST) {
  $env:ORCHESTRATOR_HOST = "0.0.0.0"
}
if (-not $env:ORCHESTRATOR_PORT) {
  $env:ORCHESTRATOR_PORT = "8765"
}

$portInUse = Get-NetTCPConnection -LocalPort ([int]$env:ORCHESTRATOR_PORT) -State Listen -ErrorAction SilentlyContinue
if ($portInUse) {
  $healthUrl = "http://localhost:$env:ORCHESTRATOR_PORT/health"
  try {
    $health = Invoke-RestMethod -Uri $healthUrl -Method Get -TimeoutSec 3
    if ($health.status -eq "UP") {
      Write-Host "El orquestador ya parece estar arrancado en http://localhost:$env:ORCHESTRATOR_PORT"
      Write-Host "No es necesario arrancarlo otra vez."
      exit 0
    }
  }
  catch {
    Write-Host ""
    Write-Host "ERROR: El puerto $env:ORCHESTRATOR_PORT ya esta ocupado, pero /health no responde." -ForegroundColor Red
    Write-Host ""
    Write-Host "Para identificar el PID:" -ForegroundColor Yellow
    Write-Host "  netstat -ano | findstr :$env:ORCHESTRATOR_PORT"
    Write-Host ""
    Write-Host "Para detener el proceso que ocupa el puerto:" -ForegroundColor Yellow
    Write-Host "  Stop-Process -Id <PID> -Force"
    Write-Host ""
    exit 1
  }
}

New-Item -ItemType Directory -Force -Path "resources\generated\orchestrator-runs" | Out-Null

$venvPython = Join-Path $RepoRoot ".venv-orchestrator\Scripts\python.exe"
if (-not (Test-Path $venvPython)) {
  python -m venv ".venv-orchestrator"
}

& $venvPython -m pip install -r "orchestrator_api\requirements.txt"

$arguments = @(
  "-m",
  "uvicorn",
  "orchestrator_api.main:app",
  "--host",
  $env:ORCHESTRATOR_HOST,
  "--port",
  $env:ORCHESTRATOR_PORT
)

if ($Background) {
  $process = Start-Process -FilePath $venvPython -ArgumentList $arguments -WorkingDirectory $RepoRoot -PassThru -WindowStyle Hidden
  $process.Id | Set-Content -Encoding ASCII "resources\generated\orchestrator.pid"
  Write-Host "Orchestrator API arrancada en segundo plano. PID: $($process.Id)"
  Write-Host "URL: http://localhost:$env:ORCHESTRATOR_PORT"
}
else {
  Write-Host "Orchestrator API arrancando en primer plano."
  Write-Host "URL: http://localhost:$env:ORCHESTRATOR_PORT"
  & $venvPython @arguments
}
