$ErrorActionPreference = "Stop"

Set-Location $PSScriptRoot

$RESOURCES = Join-Path $PSScriptRoot "resources"
$ASSET_DEMO = Join-Path $RESOURCES "assets\asset-clearance-mscu7654321.json"
$POLICY_ALLOW_USE = Join-Path $RESOURCES "policies\policy-allow-use.json"
$POLICY_TRANSPORT_COMPANY_VALID_ORDER = Join-Path $RESOURCES "policies\policy-transport-company-valid-order.json"
$CONTRACT_DEMO = Join-Path $RESOURCES "contracts\contract-clearance-mscu7654321.json"
$CONSUMER_MEMBERSHIP_REQUEST = Join-Path $RESOURCES "identity\consumer-membership-request.json"
$PROVIDER_MEMBERSHIP_REQUEST = Join-Path $RESOURCES "identity\provider-membership-request.json"
$SMOKE_TEST = Join-Path $PSScriptRoot "smoke-test-edc.ps1"

function Wait-HttpReady($url, $name, $attempts = 30) {
  for ($i = 1; $i -le $attempts; $i++) {
    try {
      $response = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 3
      if ($response.StatusCode -eq 200) {
        Write-Host "$name disponible"
        return
      }
    }
    catch {
      if ($i -eq $attempts) {
        throw "$name no está disponible después de $attempts intentos: $url"
      }
    }

    Start-Sleep -Seconds 2
  }
}

function Set-ParticipantActive($identityApi, $participantContextId, $token) {
  Invoke-WebRequest `
    -UseBasicParsing `
    -Method Post `
    -Uri "$identityApi/v1beta/participants/$participantContextId/state?isActive=true" `
    -Headers @{ Authorization = "Bearer $token" } `
    -ContentType "application/json" | Out-Null
}

function Get-IssuedCredentialCount($databaseContainer) {
  $result = docker exec $databaseContainer psql `
    -U identityhub `
    -d identityhub `
    -t `
    -A `
    -c "select count(*) from credential_resource where vc_state=500;"

  if ($LASTEXITCODE -ne 0) {
    throw "No se pudo consultar credential_resource en $databaseContainer"
  }

  return [int]$result.Trim()
}

function Ensure-MembershipCredential(
  $name,
  $identityApi,
  $participantContextId,
  $databaseContainer,
  $requestTemplate,
  $token
) {
  if ((Get-IssuedCredentialCount $databaseContainer) -gt 0) {
    Write-Host "${name}: MembershipCredential ya emitida"
    return
  }

  $request = Get-Content -LiteralPath $requestTemplate -Raw | ConvertFrom-Json
  $request.holderPid = "$participantContextId-membership-$([guid]::NewGuid())"
  $payload = $request | ConvertTo-Json -Depth 20

  Invoke-WebRequest `
    -UseBasicParsing `
    -Method Post `
    -Uri "$identityApi/v1beta/participants/$participantContextId/credentials/request" `
    -Headers @{ Authorization = "Bearer $token" } `
    -ContentType "application/json" `
    -Body $payload | Out-Null

  for ($i = 1; $i -le 30; $i++) {
    if ((Get-IssuedCredentialCount $databaseContainer) -gt 0) {
      Write-Host "${name}: MembershipCredential emitida"
      return
    }

    Start-Sleep -Seconds 2
  }

  throw "${name}: la MembershipCredential no llegó al estado ISSUED (vc_state=500)"
}

function Ensure-TransferProxyKeys {
  $vaultHeaders = @{ "X-Vault-Token" = "root" }
  $keysExist = $true

  foreach ($key in @("private-key", "public-key")) {
    try {
      $secret = Invoke-RestMethod `
        -Uri "http://localhost:8200/v1/secret/data/$key" `
        -Headers $vaultHeaders

      if (-not $secret.data.data.content) {
        $keysExist = $false
      }
    }
    catch {
      $keysExist = $false
    }
  }

  if ($keysExist) {
    Write-Host "Claves del Transfer Proxy ya provisionadas"
    return
  }

  $privateKey = (& docker exec provider-dataplane sh -c `
      "openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null") -join "`n"

  if ($LASTEXITCODE -ne 0 -or -not $privateKey.Contains("BEGIN PRIVATE KEY")) {
    throw "No se pudo generar la clave privada del Transfer Proxy"
  }

  $publicKey = ($privateKey | docker exec -i provider-dataplane openssl pkey -pubout 2>$null) -join "`n"

  if ($LASTEXITCODE -ne 0 -or -not $publicKey.Contains("BEGIN PUBLIC KEY")) {
    throw "No se pudo generar la clave pública del Transfer Proxy"
  }

  foreach ($entry in @(
      @("private-key", $privateKey),
      @("public-key", $publicKey)
    )) {
    $payload = @{
      data = @{
        content = $entry[1]
      }
    } | ConvertTo-Json -Depth 3

    Invoke-RestMethod `
      -Method Post `
      -Uri "http://localhost:8200/v1/secret/data/$($entry[0])" `
      -Headers $vaultHeaders `
      -ContentType "application/json" `
      -Body $payload | Out-Null
  }

  Write-Host "Claves del Transfer Proxy provisionadas en Vault"
}

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

if ($LASTEXITCODE -ne 0) {
  throw "No se pudo arrancar la infraestructura EDC"
}

docker compose -f docker-compose.edc.yml up -d --build --force-recreate mock-api

if ($LASTEXITCODE -ne 0) {
  throw "No se pudo construir o arrancar la Mock API"
}

Wait-HttpReady "http://localhost:7280/api/check/readiness" "Consumer Identity Hub"
Wait-HttpReady "http://localhost:7180/api/check/readiness" "Provider Identity Hub"
Wait-HttpReady "http://localhost:10010/api/check/readiness" "Issuer Service"

Write-Host "2) Activando participantes y provisionando MembershipCredentials..."

$tokenResponse = Invoke-RestMethod `
  -Method Post `
  -Uri "http://localhost:8080/realms/logistics-dataspace/protocol/openid-connect/token" `
  -ContentType "application/x-www-form-urlencoded" `
  -Body @{
    grant_type    = "client_credentials"
    client_id     = "ih-provisioner"
    client_secret = "ih-provisioner-secret"
  }

$identityToken = $tokenResponse.access_token
if (-not $identityToken) {
  throw "Keycloak no devolvió el token de ih-provisioner"
}

Set-ParticipantActive "http://localhost:10015/api/identity" "issuer" $identityToken
Set-ParticipantActive "http://localhost:7281/api/identity" "transport-company-a" $identityToken
Set-ParticipantActive "http://localhost:7181/api/identity" "regulatory-clearance-provider" $identityToken

Ensure-MembershipCredential `
  "Consumer" `
  "http://localhost:7281/api/identity" `
  "transport-company-a" `
  "consumer-identityhub-postgres" `
  $CONSUMER_MEMBERSHIP_REQUEST `
  $identityToken

Ensure-MembershipCredential `
  "Provider" `
  "http://localhost:7181/api/identity" `
  "regulatory-clearance-provider" `
  "provider-identityhub-postgres" `
  $PROVIDER_MEMBERSHIP_REQUEST `
  $identityToken

Write-Host "MembershipCredentials OK"

Write-Host "3) Arrancando ControlPlanes y DataPlanes..."

docker compose -f docker-compose.edc.yml up -d --force-recreate `
  consumer-controlplane provider-controlplane `
  consumer-dataplane provider-dataplane

Start-Sleep -Seconds 15
Ensure-TransferProxyKeys

Write-Host "4) Recargando asset, policy y contract definition..."

Post-Json-Accept409 "http://localhost:19193/management/v3/assets" "provider-api-key" $ASSET_DEMO
Post-Json-Accept409 "http://localhost:19193/management/v3/policydefinitions" "provider-api-key" $POLICY_ALLOW_USE
Post-Json-Accept409 "http://localhost:19193/management/v3/policydefinitions" "provider-api-key" $POLICY_TRANSPORT_COMPANY_VALID_ORDER
Post-Json-Accept409 "http://localhost:19193/management/v3/contractdefinitions" "provider-api-key" $CONTRACT_DEMO

Write-Host "Provider artifacts OK"

Write-Host "5) Verificando DataPlane Provider..."

$dp = docker exec provider-dataplane wget -qO- http://provider-controlplane:19194/control/v1/dataplanes

if ($dp -notmatch "AVAILABLE") {
  throw "Provider DataPlane no está AVAILABLE"
}

Write-Host "DataPlane OK"

Write-Host "6) Ejecutando smoke test extremo a extremo..."

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SMOKE_TEST

if ($LASTEXITCODE -ne 0) {
  throw "El smoke test EDC falló con código $LASTEXITCODE"
}

Write-Host "`nENTORNO VALIDADO"
