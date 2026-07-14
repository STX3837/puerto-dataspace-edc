param()

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function Assert-DockerAvailable {
  try {
    docker version | Out-Null
  }
  catch {
    throw "Docker no esta disponible. Arranca Docker Desktop y vuelve a intentarlo."
  }
}

Assert-DockerAvailable

if (-not (Test-Path ".env") -and (Test-Path ".env.example")) {
  Copy-Item ".env.example" ".env"
  Write-Host "Creado .env desde .env.example"
}

New-Item -ItemType Directory -Force -Path "resources\generated" | Out-Null

docker compose `
  -f .\docker-compose.infra.yml `
  -f .\docker-compose.edc.yml `
  -f .\docker-compose.service.yml `
  up -d --build

if ($LASTEXITCODE -ne 0) {
  $exitCode = $LASTEXITCODE
  Write-Host ""
  Write-Host "ERROR: No se pudo arrancar el modo servicio." -ForegroundColor Red
  Write-Host ""
  Write-Host "Si el error menciona que el contenedor 'vault' ya existe, ejecuta:" -ForegroundColor Yellow
  Write-Host "  docker stop vault"
  Write-Host "  docker rm vault"
  Write-Host "  .\scripts\service-start.ps1"
  Write-Host ""
  Write-Host "No uses 'docker compose down -v' salvo que quieras borrar volumenes." -ForegroundColor Yellow
  exit $exitCode
}

Write-Host ""
Write-Host "Servicio demostrador local arrancado."
Write-Host "UI: http://localhost:8501"
Write-Host "Keycloak: http://localhost:8080"
Write-Host "Vault: http://localhost:8200"
Write-Host "Mock API: http://localhost:8081"
Write-Host ""
Write-Host "Para ejecutar el flujo completo:"
Write-Host "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-edc-and-smoke-three-providers.ps1"
