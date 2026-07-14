param()

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

Write-Host "Deteniendo servicios sin borrar volumenes. No se ejecutara down -v."

docker compose `
  -f .\docker-compose.infra.yml `
  -f .\docker-compose.edc.yml `
  -f .\docker-compose.service.yml `
  down
