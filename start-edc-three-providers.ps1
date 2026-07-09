$ErrorActionPreference = "Stop"

Set-Location $PSScriptRoot

$RESOURCES = Join-Path $PSScriptRoot "resources"
$POLICY_ALLOW_USE = Join-Path $RESOURCES "policies\policy-allow-use.json"
$POLICY_TRANSPORT_COMPANY_VALID_ORDER = Join-Path $RESOURCES "policies\policy-transport-company-valid-order.json"
$CONSUMER_MEMBERSHIP_REQUEST = Join-Path $RESOURCES "identity\consumer-membership-request.json"
$CONSUMER_TRANSPORT_COMPANY_REQUEST = Join-Path $RESOURCES "identity\consumer-transportcompany-request.json"
$TRANSPORT_COMPANY_CREDENTIAL_DEFINITION = Join-Path $RESOURCES "identity\transport-company-credential-definition.json"
$TRANSPORT_COMPANY_ATTESTATION = Join-Path $RESOURCES "identity\transport-company-attestation.json"
$CONSUMER_PARTICIPANT = Join-Path $RESOURCES "identity\consumer-participant-recreate.json"
$ISSUER_PARTICIPANT = Join-Path $RESOURCES "identity\issuer-participant.json"
$GENERATED = Join-Path $RESOURCES "generated"
New-Item -ItemType Directory -Path $GENERATED -Force | Out-Null

function Write-UiEvent {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Step,

    [Parameter(Mandatory = $true)]
    [ValidateSet("PENDING", "RUNNING", "SUCCESS", "ERROR", "SKIPPED")]
    [string]$Status,

    [Parameter(Mandatory = $true)]
    [string]$Message,

    [string]$Provider = "",

    [hashtable]$Data = @{}
  )

  $generatedDir = Join-Path (Get-Location) "resources\generated"
  if (-not (Test-Path $generatedDir)) {
    New-Item -ItemType Directory -Force -Path $generatedDir | Out-Null
  }

  $eventPath = Join-Path $generatedDir "ui-events.jsonl"

  $event = [ordered]@{
    timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    step = $Step
    status = $Status
    provider = $Provider
    message = $Message
    data = $Data
  }

  $event | ConvertTo-Json -Depth 20 -Compress | Add-Content -Encoding UTF8 $eventPath
}

$uiEventsPath = Join-Path $GENERATED "ui-events.jsonl"
if (Test-Path $uiEventsPath) {
  Remove-Item $uiEventsPath -Force
}
Write-UiEvent -Step "script_started" -Status "RUNNING" -Message "Arrancando entorno multi-provider"

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

function Wait-ContainerHttpReady($container, $url, $name, $attempts = 45) {
  for ($i = 1; $i -le $attempts; $i++) {
    docker exec $container wget -qO- $url | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Write-Host "$name disponible"
      return
    }

    Start-Sleep -Seconds 2
  }

  throw "$name no esta disponible despues de $attempts intentos: $url"
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

function Get-IssuedCredentialObjectCount($databaseContainer, $credentialObjectId) {
  $result = docker exec $databaseContainer psql `
    -U identityhub `
    -d identityhub `
    -t `
    -A `
    -c "select count(*) from credential_resource where vc_state=500 and metadata->>'credentialObjectId'='$credentialObjectId';"

  if ($LASTEXITCODE -ne 0) {
    throw "No se pudo consultar credential_resource en $databaseContainer"
  }

  return [int]$result.Trim()
}

function Remove-StaleCredentialObjects($databaseContainer, $credentialObjectId) {
  docker exec $databaseContainer psql `
    -U identityhub `
    -d identityhub `
    -c "with keep as (select id from credential_resource where vc_state=500 and metadata->>'credentialObjectId'='$credentialObjectId' order by create_timestamp desc limit 1) delete from credential_resource where metadata->>'credentialObjectId'='$credentialObjectId' and id not in (select id from keep);" | Out-Null

  if ($LASTEXITCODE -ne 0) {
    throw "No se pudieron limpiar credenciales antiguas en $databaseContainer"
  }
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

function Ensure-TransportCompanyCredentialDefinition($token) {
  $definitionId = "transport-company-credential-def"
  $definitionUrl = "http://localhost:10013/api/admin/v1beta/participants/issuer/credentialdefinitions/$definitionId"

  try {
    Invoke-WebRequest `
      -UseBasicParsing `
      -Method Post `
      -Uri "http://localhost:10013/api/admin/v1beta/participants/issuer/attestations" `
      -Headers @{ Authorization = "Bearer $token" } `
      -ContentType "application/json" `
      -InFile $TRANSPORT_COMPANY_ATTESTATION | Out-Null
  }
  catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) {
      throw
    }
  }

  $holderPayload = @{
    holderId = "did:web:consumer-identityhub%3A7083:consumer"
    did = "did:web:consumer-identityhub%3A7083:consumer"
    holderName = "transport-company-a"
    properties = @{
      id = "did:web:consumer-identityhub%3A7083:consumer"
      role = "TransportCompany"
      companyId = "TC-A"
    }
  } | ConvertTo-Json -Depth 8

  try {
    Invoke-WebRequest `
      -UseBasicParsing `
      -Method Post `
      -Uri "http://localhost:10013/api/admin/v1beta/participants/issuer/holders" `
      -Headers @{ Authorization = "Bearer $token" } `
      -ContentType "application/json" `
      -Body $holderPayload | Out-Null
  }
  catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) {
      throw
    }
  }

  try {
    Invoke-WebRequest `
      -UseBasicParsing `
      -Method Post `
      -Uri "http://localhost:10013/api/admin/v1beta/participants/issuer/credentialdefinitions" `
      -Headers @{ Authorization = "Bearer $token" } `
      -ContentType "application/json" `
      -InFile $TRANSPORT_COMPANY_CREDENTIAL_DEFINITION | Out-Null
  }
  catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 409) {
      throw
    }
  }

  Write-Host "TransportCompanyCredential definition registrada"
}

function Ensure-TransportCompanyCredential($databaseContainer, $requestTemplate, $token) {
  Remove-StaleCredentialObjects $databaseContainer "transport-company-credential-def"

  if ((Get-IssuedCredentialObjectCount $databaseContainer "transport-company-credential-def") -gt 0) {
    Write-Host "Consumer: TransportCompanyCredential ya emitida"
    return
  }

  $request = Get-Content -LiteralPath $requestTemplate -Raw | ConvertFrom-Json
  $request.holderPid = "transport-company-a-transportcompany-$([guid]::NewGuid())"
  $payload = $request | ConvertTo-Json -Depth 20

  Invoke-WebRequest `
    -UseBasicParsing `
    -Method Post `
    -Uri "http://localhost:7281/api/identity/v1beta/participants/transport-company-a/credentials/request" `
    -Headers @{ Authorization = "Bearer $token" } `
    -ContentType "application/json" `
    -Body $payload | Out-Null

  for ($i = 1; $i -le 30; $i++) {
    if ((Get-IssuedCredentialObjectCount $databaseContainer "transport-company-credential-def") -gt 0) {
      Write-Host "Consumer: TransportCompanyCredential emitida"
      return
    }

    Start-Sleep -Seconds 2
  }

  throw "Consumer: la TransportCompanyCredential no llego al estado ISSUED (vc_state=500)"
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
  Remove-StaleCredentialObjects $databaseContainer "membership-credential-def"

  if ((Get-IssuedCredentialObjectCount $databaseContainer "membership-credential-def") -gt 0) {
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
    Remove-StaleCredentialObjects $databaseContainer "membership-credential-def"
    if ((Get-IssuedCredentialObjectCount $databaseContainer "membership-credential-def") -gt 0) {
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
  for ($i = 1; $i -le 30; $i++) {
    try {
      $response = Invoke-WebRequest `
        -UseBasicParsing `
        -Method Post `
        -Uri $url `
        -Headers @{ "X-API-Key" = $apiKey } `
        -ContentType "application/json" `
        -InFile $file

      Write-Host "OK $url -> $($response.StatusCode)"
      return
    }
    catch {
      $status = $null
      if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
        $status = $_.Exception.Response.StatusCode.value__
      }

      if ($status -eq 409) {
        Write-Host "YA EXISTE $url -> 409"
        return
      }

      if (($null -eq $status -or $status -in @(404, 405, 429, 500, 502, 503, 504)) -and $i -lt 30) {
        Write-Host "Esperando Management API $url -> $status (intento $i/30)"
        Start-Sleep -Seconds 2
        continue
      }

      throw
    }
  }
}

function Wait-ProviderDataPlaneAvailable($provider, $attempts = 45) {
  for ($i = 1; $i -le $attempts; $i++) {
    $dataPlanes = docker exec $provider.DataPlane `
      wget -qO- "http://$($provider.ControlPlane):19194/control/v1/dataplanes"

    if ($LASTEXITCODE -eq 0 -and $dataPlanes -match "AVAILABLE") {
      Write-Host "$($provider.Name) DataPlane OK"
      return
    }

    Write-Host "Esperando $($provider.Name) DataPlane AVAILABLE (intento $i/$attempts)"
    Start-Sleep -Seconds 2
  }

  throw "$($provider.Name) DataPlane no está AVAILABLE"
}

try {
Write-Host "1) Arrancando infraestructura EDC..."
Write-UiEvent -Step "infra_check" -Status "RUNNING" -Message "Comprobando infraestructura base"

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
Write-UiEvent -Step "infra_check" -Status "SUCCESS" -Message "Infraestructura base disponible"

docker compose -f docker-compose.edc.yml up -d `
  consumer-identityhub provider-identityhub health-identityhub civilguard-identityhub `
  issuer-service

if ($LASTEXITCODE -ne 0) {
  throw "No se pudo arrancar la infraestructura EDC"
}

Write-UiEvent -Step "identityhubs_ready" -Status "RUNNING" -Message "Esperando IdentityHubs"
Wait-HttpReady "http://localhost:7280/api/check/readiness" "Consumer Identity Hub"

Write-UiEvent -Step "issuer_ready" -Status "RUNNING" -Message "Esperando IssuerService"
Wait-HttpReady "http://localhost:10010/api/check/readiness" "Issuer Service"
Write-UiEvent -Step "issuer_ready" -Status "SUCCESS" -Message "IssuerService disponible"

foreach ($provider in $providers) {
  Wait-HttpReady $provider.IdentityReadiness "$($provider.Name) Identity Hub"
}
Write-UiEvent -Step "identityhubs_ready" -Status "SUCCESS" -Message "IdentityHubs disponibles"

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

$issuerAdminTokenResponse = Invoke-RestMethod `
  -Method Post `
  -Uri "http://localhost:8080/realms/logistics-dataspace/protocol/openid-connect/token" `
  -ContentType "application/x-www-form-urlencoded" `
  -Body @{
    grant_type = "client_credentials"
    client_id = "issuer"
    client_secret = "issuer-secret"
  }

$issuerAdminToken = $issuerAdminTokenResponse.access_token
if (-not $issuerAdminToken) {
  throw "Keycloak no devolvio el token de issuer"
}

Write-UiEvent -Step "vault_provisioning" -Status "RUNNING" -Message "Provisionando claves en Vault"
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
Write-UiEvent -Step "vault_provisioning" -Status "SUCCESS" -Message "Vault provisionado"

Write-UiEvent -Step "participants_activation" -Status "RUNNING" -Message "Activando participantes"
Set-ParticipantActive "http://localhost:10015/api/identity" "issuer" $identityToken
Set-ParticipantActive "http://localhost:7281/api/identity" "transport-company-a" $identityToken

foreach ($provider in $providers) {
  Set-ParticipantActive `
    $provider.IdentityApi `
    $provider.ParticipantContextId `
    $identityToken
}
Write-UiEvent -Step "participants_activation" -Status "SUCCESS" -Message "Participantes activados"

Write-UiEvent -Step "membership_credentials" -Status "RUNNING" -Message "Comprobando/emitiendo MembershipCredential"
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
Write-UiEvent -Step "membership_credentials" -Status "SUCCESS" -Message "MembershipCredential disponibles"

Write-Host "2.1) Provisionando TransportCompanyCredential del consumer..."
Write-UiEvent -Step "transport_company_credential" -Status "RUNNING" -Message "Comprobando/emitiendo TransportCompanyCredential del Consumer"

Ensure-TransportCompanyCredentialDefinition $issuerAdminToken
Ensure-TransportCompanyCredential `
  "consumer-identityhub-postgres" `
  $CONSUMER_TRANSPORT_COMPANY_REQUEST `
  $identityToken

Write-Host "TransportCompanyCredential OK"
Write-UiEvent -Step "transport_company_credential" -Status "SUCCESS" -Message "TransportCompanyCredential disponible para el Consumer"

Write-Host "3) Construyendo imagen ControlPlane..."

& .\gradlew.bat :runtimes:controlplane:dockerize --no-daemon

if ($LASTEXITCODE -ne 0) {
  throw "No se pudo construir la imagen puerto-edc-controlplane:latest"
}

Write-Host "4) Arrancando ControlPlanes y DataPlanes..."
Write-UiEvent -Step "controlplanes_dataplanes" -Status "RUNNING" -Message "Arrancando Control Planes y Data Planes"

docker compose -f docker-compose.edc.yml up -d --force-recreate `
  consumer-controlplane consumer-dataplane `
  provider-controlplane provider-dataplane `
  health-controlplane health-dataplane `
  civilguard-controlplane civilguard-dataplane

if ($LASTEXITCODE -ne 0) {
  throw "No se pudieron arrancar los Control Planes y Data Planes"
}

Wait-ContainerHttpReady "consumer-controlplane" "http://localhost:29191/api/check/readiness" "Consumer Control Plane"
Wait-ContainerHttpReady "consumer-dataplane" "http://localhost:29291/api/check/readiness" "Consumer Data Plane"

foreach ($provider in $providers) {
  Wait-ContainerHttpReady $provider.ControlPlane "http://localhost:19191/api/check/readiness" "$($provider.Name) Control Plane"
  Wait-ContainerHttpReady $provider.DataPlane "http://localhost:19291/api/check/readiness" "$($provider.Name) Data Plane"
}

Ensure-TransferProxyKeys
Write-UiEvent -Step "controlplanes_dataplanes" -Status "SUCCESS" -Message "Control Planes y Data Planes arrancados"

Write-Host "5) Recargando assets, policies y contract definitions..."
Write-UiEvent -Step "assets_policies_contracts" -Status "RUNNING" -Message "Registrando assets, policies y contract definitions"

foreach ($provider in $providers) {
  Write-Host "Provisionando artefactos de $($provider.Name)..."
  Post-Json-Accept409 "$($provider.ManagementApi)/v3/assets" "provider-api-key" $provider.Asset
  Post-Json-Accept409 "$($provider.ManagementApi)/v3/policydefinitions" "provider-api-key" $POLICY_ALLOW_USE
  Post-Json-Accept409 "$($provider.ManagementApi)/v3/policydefinitions" "provider-api-key" $POLICY_TRANSPORT_COMPANY_VALID_ORDER
  Post-Json-Accept409 "$($provider.ManagementApi)/v3/contractdefinitions" "provider-api-key" $provider.Contract
}

Write-Host "Provider artifacts OK"
Write-UiEvent -Step "assets_policies_contracts" -Status "SUCCESS" -Message "Assets, policies y contract definitions registrados"

Write-Host "6) Verificando Data Planes..."
Write-UiEvent -Step "dataplanes_available" -Status "RUNNING" -Message "Comprobando disponibilidad de Data Planes"

foreach ($provider in $providers) {
  Wait-ProviderDataPlaneAvailable $provider
}
Write-UiEvent -Step "dataplanes_available" -Status "SUCCESS" -Message "Data Planes disponibles"

Write-UiEvent -Step "script_finished" -Status "SUCCESS" -Message "Entorno multi-provider arrancado correctamente"
Write-Host "`nENTORNO MULTI-PROVIDER ARRANCADO"
}
catch {
  Write-UiEvent -Step "script_finished" -Status "ERROR" -Message $_.Exception.Message
  throw
}
