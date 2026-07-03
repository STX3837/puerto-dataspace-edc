$ErrorActionPreference = "Stop"

Set-Location $PSScriptRoot

$RESOURCES = Join-Path $PSScriptRoot "resources"
$ASSET_DEMO = Join-Path $RESOURCES "assets\asset-clearance-mscu7654321.json"
$POLICY_ALLOW_USE = Join-Path $RESOURCES "policies\policy-allow-use.json"
$CONTRACT_DEMO = Join-Path $RESOURCES "contracts\contract-clearance-mscu7654321.json"
$SMOKE_TEST = Join-Path $PSScriptRoot "smoke-test-edc.ps1"

function Post-Json-Accept409($url, $apiKey, $file) {
  try {
    $r = Invoke-WebRequest `
      -UseBasicParsing `
      -Method Post `
      -Uri $url `
      -Headers @{ "X-API-Key" = $apiKey } `
      -ContentType "application/json" `
      -InFile $file

    Write-Host "OK $url -> $($r.StatusCode)"
  }
  catch {
    $status = $_.Exception.Response.StatusCode.value__
    if ($status -eq 409) {
      Write-Host "YA EXISTE $url -> 409"
    }
    else {
      throw
    }
  }
}

Write-Host "1) Arrancando infraestructura EDC..."

docker compose -f docker-compose.edc.yml up -d `
  consumer-identityhub-postgres provider-identityhub-postgres issuer-postgres `
  consumer-identityhub provider-identityhub issuer-service

Start-Sleep -Seconds 20

Write-Host "2) Arrancando ControlPlanes y DataPlanes..."

docker compose -f docker-compose.edc.yml up -d --force-recreate `
  consumer-controlplane provider-controlplane `
  consumer-dataplane provider-dataplane

Start-Sleep -Seconds 15

Write-Host "3) Verificando VCs activas..."

$consumerVc = docker exec consumer-identityhub-postgres psql -U identityhub -d identityhub -t -A -c "select count(*) from credential_resource where vc_state=300;"
$providerVc = docker exec provider-identityhub-postgres psql -U identityhub -d identityhub -t -A -c "select count(*) from credential_resource where vc_state=300;"

if ($consumerVc.Trim() -ne "1") { throw "Consumer VC activa incorrecta: $consumerVc" }
if ($providerVc.Trim() -ne "1") { throw "Provider VC activa incorrecta: $providerVc" }

Write-Host "VCs OK"

Write-Host "4) Recargando asset, policy y contract definition..."

Post-Json-Accept409 "http://localhost:19193/management/v3/assets" "provider-api-key" $ASSET_DEMO
Post-Json-Accept409 "http://localhost:19193/management/v3/policydefinitions" "provider-api-key" $POLICY_ALLOW_USE
Post-Json-Accept409 "http://localhost:19193/management/v3/contractdefinitions" "provider-api-key" $CONTRACT_DEMO

Write-Host "Provider artifacts OK"

Write-Host "5) Verificando DataPlane Provider..."

$dp = docker exec provider-dataplane wget -qO- http://provider-controlplane:19194/control/v1/dataplanes

if ($dp -notmatch "AVAILABLE") {
  throw "Provider DataPlane no está AVAILABLE"
}

Write-Host "DataPlane OK"

Write-Host "6) Ejecutando smoke test extremo a extremo..."

powershell.exe -ExecutionPolicy Bypass -File $SMOKE_TEST

Write-Host "`nENTORNO VALIDADO"
