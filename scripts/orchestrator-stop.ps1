param()

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

$pidFile = "resources\generated\orchestrator.pid"
if (-not (Test-Path $pidFile)) {
  Write-Host "No existe $pidFile. No hay orquestador en segundo plano registrado."
  exit 0
}

$orchestratorPid = Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $orchestratorPid) {
  Write-Host "El fichero de PID esta vacio."
  Remove-Item $pidFile -Force
  exit 0
}

$process = Get-Process -Id ([int]$orchestratorPid) -ErrorAction SilentlyContinue
if ($process) {
  Stop-Process -Id $process.Id -Force
  Write-Host "Orchestrator API parada. PID: $orchestratorPid"
}
else {
  Write-Host "No hay proceso activo con PID $orchestratorPid."
}

Remove-Item $pidFile -Force
