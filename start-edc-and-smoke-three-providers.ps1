$ErrorActionPreference = "Stop"

Set-Location $PSScriptRoot

$RESOURCES = Join-Path $PSScriptRoot "resources"
$POLICY_ALLOW_USE = Join-Path $RESOURCES "policies\policy-allow-use.json"
$POLICY_TRANSPORT_COMPANY_VALID_ORDER = Join-Path $RESOURCES "policies\policy-transport-company-valid-order.json"
$CONSUMER_MEMBERSHIP_REQUEST = Join-Path $RESOURCES "identity\consumer-membership-request.json"
$CONSUMER_PARTICIPANT = Join-Path $RESOURCES "identity\consumer-participant-recreate.json"
$ISSUER_PARTICIPANT = Join-Path $RESOURCES "identity\issuer-participant.json"
$SMOKE_TEST = Join-Path $PSScriptRoot "smoke-test-three-providers.ps1"

$providers = @(
  @{
    Name = "Customs"
    IdentityReadiness = "http://localhost:7180/api/check/readiness"
    IdentityApi = "http://localhost:7181/api/identity"
    ParticipantContextId = "regulatory-clearance-provider"
    Participant = Join-Path $RESOURCES "identity\provider-participant.json"
    Database = "provider-identityhub-postgres"
    MembershipRequest = Join-Path $RESOURCES "identity\provider-membership-request.json"
    ManagementApi = "http://localhost:19193/management"
    ControlPlane = "provider-controlplane"
    DataPlane = "provider-dataplane"
    Asset = Join-Path $RESOURCES "assets\asset-clearance-mscu7654321.json"
    Contract = Join-Path $RESOURCES "contracts\contract-clearance-mscu7654321.json"
  },
  @{
    Name = "Health"
    IdentityReadiness = "http://localhost:7380/api/check/readiness"
    IdentityApi = "http://localhost:7381/api/identity"
    ParticipantContextId = "health"
    Participant = Join-Path $RESOURCES "identity\health-participant.json"
    Database = "health-identityhub-postgres"
    MembershipRequest = Join-Path $RESOURCES "identity\health-membership-request.json"
    ManagementApi = "http://localhost:21193/management"
    ControlPlane = "health-controlplane"
    DataPlane = "health-dataplane"
    Asset = Join-Path $RESOURCES "assets\asset-health-clearance-mscu7654321.json"
    Contract = Join-Path $RESOURCES "contracts\contract-health-clearance-mscu7654321.json"
  },
  @{
    Name = "CivilGuard"
    IdentityReadiness = "http://localhost:7480/api/check/readiness"
    IdentityApi = "http://localhost:7481/api/identity"
    ParticipantContextId = "civilguard"
    Participant = Join-Path $RESOURCES "identity\civilguard-participant.json"
    Database = "civilguard-identityhub-postgres"
    MembershipRequest = Join-Path $RESOURCES "identity\civilguard-membership-request.json"
    ManagementApi = "http://localhost:22193/management"
    ControlPlane = "civilguard-controlplane"
    DataPlane = "civilguard-dataplane"
    Asset = Join-Path $RESOURCES "assets\asset-civilguard-clearance-mscu7654321.json"
    Contract = Join-Path $RESOURCES "contracts\contract-civilguard-clearance-mscu7654321.json"
  }
)

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

function Wait-PostgresReady($container, $user = "identityhub", $database = "identityhub", $attempts = 30) {
  for ($i = 1; $i -le $attempts; $i++) {
    docker exec $container pg_isready -U $user -d $database | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Write-Host "$container disponible"
      return
    }

    Start-Sleep -Seconds 2
  }

  throw "$container no esta disponible despues de $attempts intentos"
}

function Set-ParticipantActive($identityApi, $participantContextId, $token) {
  Invoke-WebRequest `
    -UseBasicParsing `
    -Method Post `
    -Uri "$identityApi/v1beta/participants/$participantContextId/state?isActive=true" `
    -Headers @{ Authorization = "Bearer $token" } `
    -ContentType "application/json" | Out-Null
}

function Reset-Participant($identityApi, $participantContextId, $participantFile, $token) {
  $participantUrl = "$identityApi/v1beta/participants/$participantContextId"

  try {
    Invoke-WebRequest `
      -UseBasicParsing `
      -Method Delete `
      -Uri $participantUrl `
      -Headers @{ Authorization = "Bearer $token" } | Out-Null
  }
  catch {
    $status = $_.Exception.Response.StatusCode.value__
    if ($status -ne 404) {
      throw
    }
  }

  Invoke-WebRequest `
    -UseBasicParsing `
    -Method Post `
    -Uri "$identityApi/v1beta/participants" `
    -Headers @{ Authorization = "Bearer $token" } `
    -ContentType "application/json" `
    -InFile $participantFile | Out-Null

  Set-ParticipantActive $identityApi $participantContextId $token
  Start-Sleep -Seconds 5
  Write-Host "$participantContextId reprovisionado"
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

function Clear-HolderCredentialState($databaseContainer) {
  docker exec $databaseContainer psql `
    -U identityhub `
    -d identityhub `
    -c "delete from credential_resource; delete from edc_holder_credentialrequest;" | Out-Null

  if ($LASTEXITCODE -ne 0) {
    throw "No se pudo limpiar el estado de credenciales en $databaseContainer"
  }
}

function Clear-IssuerCredentialState {
  docker exec issuer-postgres psql `
    -U issuer `
    -d issuerservice `
    -c "delete from credential_resource; delete from edc_issuance_process;" | Out-Null

  if ($LASTEXITCODE -ne 0) {
    throw "No se pudo limpiar el estado de credenciales en issuer-postgres"
  }
}

function Test-VaultSecretExists($secretAlias) {
  $vaultKey = [uri]::EscapeDataString($secretAlias)
  $vaultPath = [uri]::EscapeDataString($vaultKey)

  try {
    Invoke-RestMethod `
      -Uri "http://localhost:8200/v1/secret/data/$vaultPath" `
      -Headers @{ "X-Vault-Token" = "root" } | Out-Null

    return $true
  }
  catch {
    return $false
  }
}

function Get-ParticipantPrivateKeyAlias($participantFile) {
  $participant = Get-Content -LiteralPath $participantFile -Raw | ConvertFrom-Json
  return $participant.key.privateKeyAlias
}

function Ensure-ParticipantPrivateKey($name, $identityApi, $participantContextId, $participantFile, $token) {
  $privateKeyAlias = Get-ParticipantPrivateKeyAlias $participantFile

  if (Test-VaultSecretExists $privateKeyAlias) {
    Write-Host "${name}: clave privada ya existe en Vault"
    return $false
  }

  Write-Host "${name}: clave privada no existe en Vault; reprovisionando participante"
  Reset-Participant $identityApi $participantContextId $participantFile $token
  return $true
}

function Get-LatestHolderCredentialRequestError($databaseContainer) {
  $result = docker exec $databaseContainer psql `
    -U identityhub `
    -d identityhub `
    -t `
    -A `
    -c "select coalesce(error_detail, '') from edc_holder_credentialrequest order by created_at desc limit 1;"

  if ($LASTEXITCODE -ne 0) {
    return ""
  }

  return ($result -join "`n").Trim()
}

function Ensure-MembershipCredential(
  $name,
  $identityApi,
  $participantContextId,
  $databaseContainer,
  $requestTemplate,
  $token,
  $participantFile = $null,
  $repairAttempted = $false
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

  $latestError = Get-LatestHolderCredentialRequestError $databaseContainer
  if (-not $repairAttempted `
      -and $participantFile `
      -and $latestError -match "Private key with ID '.+' not found") {
    Write-Host "${name}: clave privada ausente en Vault; reprovisionando participante"
    Reset-Participant $identityApi $participantContextId $participantFile $token
    Clear-HolderCredentialState $databaseContainer
    Ensure-MembershipCredential `
      $name `
      $identityApi `
      $participantContextId `
      $databaseContainer `
      $requestTemplate `
      $token `
      $participantFile `
      $true
    return
  }

  if ($latestError) {
    throw "${name}: la MembershipCredential no llego al estado ISSUED (vc_state=500). Ultimo error: $latestError"
  }

  throw "${name}: la MembershipCredential no llego al estado ISSUED (vc_state=500)"
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
    $response = Invoke-WebRequest `
      -UseBasicParsing `
      -Method Post `
      -Uri $url `
      -Headers @{ "X-API-Key" = $apiKey } `
      -ContentType "application/json" `
      -InFile $file

    Write-Host "OK $url -> $($response.StatusCode)"
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
  consumer-identityhub-postgres provider-identityhub-postgres `
  health-identityhub-postgres civilguard-identityhub-postgres issuer-postgres `
  mock-api

if ($LASTEXITCODE -ne 0) {
  throw "No se pudieron arrancar las bases de datos de infraestructura EDC"
}

Wait-PostgresReady "consumer-identityhub-postgres"
Wait-PostgresReady "provider-identityhub-postgres"
Wait-PostgresReady "health-identityhub-postgres"
Wait-PostgresReady "civilguard-identityhub-postgres"
Wait-PostgresReady "issuer-postgres" "issuer" "issuerservice"

docker compose -f docker-compose.edc.yml up -d `
  consumer-identityhub provider-identityhub health-identityhub civilguard-identityhub `
  issuer-service

if ($LASTEXITCODE -ne 0) {
  throw "No se pudo arrancar la infraestructura EDC"
}

Wait-HttpReady "http://localhost:7280/api/check/readiness" "Consumer Identity Hub"
Wait-HttpReady "http://localhost:10010/api/check/readiness" "Issuer Service"

foreach ($provider in $providers) {
  Wait-HttpReady $provider.IdentityReadiness "$($provider.Name) Identity Hub"
}

Write-Host "2) Activando participantes y provisionando MembershipCredentials..."

$tokenResponse = Invoke-RestMethod `
  -Method Post `
  -Uri "http://localhost:8080/realms/logistics-dataspace/protocol/openid-connect/token" `
  -ContentType "application/x-www-form-urlencoded" `
  -Body @{
    grant_type = "client_credentials"
    client_id = "ih-provisioner"
    client_secret = "ih-provisioner-secret"
  }

$identityToken = $tokenResponse.access_token
if (-not $identityToken) {
  throw "Keycloak no devolvió el token de ih-provisioner"
}

Write-Host "Comprobando claves privadas de participantes en Vault..."
$participantsReprovisioned = $false
$issuerReprovisioned = Ensure-ParticipantPrivateKey `
  "Issuer" `
  "http://localhost:10015/api/identity" `
  "issuer" `
  $ISSUER_PARTICIPANT `
  $identityToken

if ($issuerReprovisioned) {
  $participantsReprovisioned = $true
  Clear-IssuerCredentialState
  Clear-HolderCredentialState "consumer-identityhub-postgres"
  foreach ($provider in $providers) {
    Clear-HolderCredentialState $provider.Database
  }
}

$consumerReprovisioned = Ensure-ParticipantPrivateKey `
  "Consumer" `
  "http://localhost:7281/api/identity" `
  "transport-company-a" `
  $CONSUMER_PARTICIPANT `
  $identityToken

if ($consumerReprovisioned) {
  $participantsReprovisioned = $true
  Clear-HolderCredentialState "consumer-identityhub-postgres"
}

foreach ($provider in $providers) {
  $providerReprovisioned = Ensure-ParticipantPrivateKey `
    $provider.Name `
    $provider.IdentityApi `
    $provider.ParticipantContextId `
    $provider.Participant `
    $identityToken

  if ($providerReprovisioned) {
    $participantsReprovisioned = $true
    Clear-HolderCredentialState $provider.Database
  }
}

if ($participantsReprovisioned) {
  docker compose -f docker-compose.edc.yml restart `
    issuer-service consumer-identityhub provider-identityhub health-identityhub civilguard-identityhub

  if ($LASTEXITCODE -ne 0) {
    throw "No se pudieron reiniciar los Identity Hubs tras reprovisionar participantes"
  }

  Wait-HttpReady "http://localhost:7280/api/check/readiness" "Consumer Identity Hub"
  Wait-HttpReady "http://localhost:10010/api/check/readiness" "Issuer Service"

  foreach ($provider in $providers) {
    Wait-HttpReady $provider.IdentityReadiness "$($provider.Name) Identity Hub"
  }
}

Set-ParticipantActive "http://localhost:10015/api/identity" "issuer" $identityToken
Set-ParticipantActive "http://localhost:7281/api/identity" "transport-company-a" $identityToken

foreach ($provider in $providers) {
  Set-ParticipantActive `
    $provider.IdentityApi `
    $provider.ParticipantContextId `
    $identityToken
}

Ensure-MembershipCredential `
  "Consumer" `
  "http://localhost:7281/api/identity" `
  "transport-company-a" `
  "consumer-identityhub-postgres" `
  $CONSUMER_MEMBERSHIP_REQUEST `
  $identityToken `
  $CONSUMER_PARTICIPANT

foreach ($provider in $providers) {
  Ensure-MembershipCredential `
    $provider.Name `
    $provider.IdentityApi `
    $provider.ParticipantContextId `
    $provider.Database `
    $provider.MembershipRequest `
    $identityToken `
    $provider.Participant
}

Write-Host "MembershipCredentials OK"

Write-Host "3) Arrancando ControlPlanes y DataPlanes..."

docker compose -f docker-compose.edc.yml up -d --force-recreate `
  consumer-controlplane consumer-dataplane `
  provider-controlplane provider-dataplane `
  health-controlplane health-dataplane `
  civilguard-controlplane civilguard-dataplane

if ($LASTEXITCODE -ne 0) {
  throw "No se pudieron arrancar los Control Planes y Data Planes"
}

Start-Sleep -Seconds 15
Ensure-TransferProxyKeys

Write-Host "4) Recargando assets, policies y contract definitions..."

foreach ($provider in $providers) {
  Write-Host "Provisionando artefactos de $($provider.Name)..."
  Post-Json-Accept409 "$($provider.ManagementApi)/v3/assets" "provider-api-key" $provider.Asset
  Post-Json-Accept409 "$($provider.ManagementApi)/v3/policydefinitions" "provider-api-key" $POLICY_ALLOW_USE
  Post-Json-Accept409 "$($provider.ManagementApi)/v3/policydefinitions" "provider-api-key" $POLICY_TRANSPORT_COMPANY_VALID_ORDER
  Post-Json-Accept409 "$($provider.ManagementApi)/v3/contractdefinitions" "provider-api-key" $provider.Contract
}

Write-Host "Provider artifacts OK"

Write-Host "5) Verificando Data Planes..."

foreach ($provider in $providers) {
  $dataPlanes = docker exec $provider.DataPlane `
    wget -qO- "http://$($provider.ControlPlane):19194/control/v1/dataplanes"

  if ($LASTEXITCODE -ne 0 -or $dataPlanes -notmatch "AVAILABLE") {
    throw "$($provider.Name) DataPlane no está AVAILABLE"
  }

  Write-Host "$($provider.Name) DataPlane OK"
}

Write-Host "6) Ejecutando smoke test de tres providers..."

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SMOKE_TEST

if ($LASTEXITCODE -ne 0) {
  throw "El smoke test de tres providers falló con código $LASTEXITCODE"
}

Write-Host "`nENTORNO MULTI-PROVIDER VALIDADO"
