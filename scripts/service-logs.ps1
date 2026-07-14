param(
  [string]$Service = "ui"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

docker compose `
  -f .\docker-compose.infra.yml `
  -f .\docker-compose.edc.yml `
  -f .\docker-compose.service.yml `
  logs -f --tail=200 $Service
