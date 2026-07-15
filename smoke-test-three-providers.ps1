$ErrorActionPreference = "Stop"
$Embedded = $args -contains "-Embedded"

$CONSUMER_MGMT = "http://localhost:29193/management"
$CONSUMER_KEY = "consumer-api-key"

$RESOURCES = Join-Path $PSScriptRoot "resources"
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

  $line = ($event | ConvertTo-Json -Depth 20 -Compress) + [Environment]::NewLine
  $encoding = New-Object System.Text.UTF8Encoding $false

  for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
      $stream = [System.IO.File]::Open($eventPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
      try {
        $bytes = $encoding.GetBytes($line)
        $stream.Write($bytes, 0, $bytes.Length)
      }
      finally {
        $stream.Dispose()
      }
      return
    }
    catch {
      if ($attempt -eq 5) { throw }
      Start-Sleep -Milliseconds 100
    }
  }
}

$providers = @(
  @{
    Name = "customs"
    Did = "did:web:provider-identityhub%3A8183:provider"
    Address = "http://provider-controlplane:19292/protocol"
    CatalogRequest = Join-Path $RESOURCES "catalog\catalog-request.json"
    AssetId = "asset-clearance-mscu7654321"
    InternalPublicBase = "http://provider-dataplane:19294"
    LocalPublicBase = "http://localhost:19294"
    Output = Join-Path $GENERATED "downloaded-customs-clearance.json"
  },
  @{
    Name = "health"
    Did = "did:web:health-identityhub%3A8183:health"
    Address = "http://health-controlplane:19292/protocol"
    CatalogRequest = Join-Path $RESOURCES "catalog\catalog-request-health.json"
    AssetId = "asset-health-clearance-mscu7654321"
    InternalPublicBase = "http://health-dataplane:19294"
    LocalPublicBase = "http://localhost:21294"
    Output = Join-Path $GENERATED "downloaded-health-clearance.json"
  },
  @{
    Name = "civilguard"
    Did = "did:web:civilguard-identityhub%3A8183:civilguard"
    Address = "http://civilguard-controlplane:19292/protocol"
    CatalogRequest = Join-Path $RESOURCES "catalog\catalog-request-civilguard.json"
    AssetId = "asset-civilguard-clearance-mscu7654321"
    InternalPublicBase = "http://civilguard-dataplane:19294"
    LocalPublicBase = "http://localhost:22294"
    Output = Join-Path $GENERATED "downloaded-civilguard-clearance.json"
  }
)

function Invoke-ProviderFlow($p) {
  Write-Host "`n=== $($p.Name.ToUpper()) ==="

  $catalogResponse = Join-Path $GENERATED "catalog-$($p.Name)-response.json"

  Write-UiEvent -Step "catalog" -Status "RUNNING" -Provider $p.Name -Message "Solicitando catálogo a $($p.Name)"
  curl.exe -s -X POST "$CONSUMER_MGMT/v3/catalog/request" `
    -H "X-API-Key: $CONSUMER_KEY" `
    -H "Content-Type: application/json" `
    --data-binary "@$($p.CatalogRequest)" `
    -o $catalogResponse

  $catalog = Get-Content -LiteralPath $catalogResponse -Raw | ConvertFrom-Json
  $dataset = @($catalog.'dcat:dataset') | Where-Object { $_.'@id' -eq $p.AssetId } | Select-Object -First 1

  if (-not $dataset) {
    Write-UiEvent -Step "catalog" -Status "ERROR" -Provider $p.Name -Message "Asset no encontrado en catálogo de $($p.Name)"
    throw "Asset no encontrado en catálogo de $($p.Name): $($p.AssetId)"
  }

  $offerId = $dataset.'odrl:hasPolicy'.'@id'
  if (-not $offerId) {
    Write-UiEvent -Step "catalog" -Status "ERROR" -Provider $p.Name -Message "Offer ID vacío en $($p.Name)"
    throw "Offer ID vacío en $($p.Name)"
  }

  Write-UiEvent -Step "catalog" -Status "SUCCESS" -Provider $p.Name -Message "Catálogo recibido de $($p.Name)"
  Write-Host "Asset: $($p.AssetId)"
  Write-Host "Offer: $offerId"

  $negotiationRequest = Join-Path $GENERATED "contract-negotiation-request-$($p.Name).json"
  $policy = $dataset.'odrl:hasPolicy'
  $policy | Add-Member -NotePropertyName "odrl:assigner" -NotePropertyValue @{ "@id" = $p.Did } -Force
  $policy | Add-Member -NotePropertyName "odrl:target" -NotePropertyValue @{ "@id" = $p.AssetId } -Force

  $negotiationPayload = [ordered]@{
    "@context" = @{
      "@vocab" = "https://w3id.org/edc/v0.0.1/ns/"
      "odrl" = "http://www.w3.org/ns/odrl/2/"
    }
    "@type" = "ContractRequest"
    counterPartyId = $p.Did
    counterPartyAddress = $p.Address
    protocol = "dataspace-protocol-http"
    policy = $policy
  }

  $negotiationPayload |
    ConvertTo-Json -Depth 30 |
    Set-Content -LiteralPath $negotiationRequest -Encoding utf8

  Write-UiEvent -Step "contract_negotiation" -Status "RUNNING" -Provider $p.Name -Message "Negociando contrato con $($p.Name)"
  $response = Invoke-WebRequest `
    -UseBasicParsing `
    -Method Post `
    -Uri "$CONSUMER_MGMT/v3/contractnegotiations" `
    -Headers @{ "X-API-Key" = $CONSUMER_KEY } `
    -ContentType "application/json" `
    -InFile $negotiationRequest

  $negotiationId = ($response.Content | ConvertFrom-Json).'@id'

  for ($i = 0; $i -lt 30; $i++) {
    $neg = Invoke-RestMethod `
      -Method Get `
      -Uri "$CONSUMER_MGMT/v3/contractnegotiations/$negotiationId" `
      -Headers @{ "X-API-Key" = $CONSUMER_KEY }

    if ($neg.state -in @("FINALIZED", "TERMINATED")) { break }
    Start-Sleep -Seconds 2
  }

  if ($neg.state -ne "FINALIZED") {
    $neg | ConvertTo-Json -Depth 20
    Write-UiEvent -Step "contract_negotiation" -Status "ERROR" -Provider $p.Name -Message "Negociación no finalizada en $($p.Name)"
    throw "Negociación no finalizada en $($p.Name)"
  }

  $agreementId = $neg.contractAgreementId
  Write-UiEvent -Step "contract_negotiation" -Status "SUCCESS" -Provider $p.Name -Message "Contrato finalizado con $($p.Name)" -Data @{ agreementId = $agreementId }
  Write-Host "Agreement: $agreementId"

  $transferRequest = Join-Path $GENERATED "transfer-request-$($p.Name).json"

  $transferPayload = [ordered]@{
    "@context" = @{
      "@vocab" = "https://w3id.org/edc/v0.0.1/ns/"
    }
    "@type" = "TransferRequest"
    counterPartyId = $p.Did
    counterPartyAddress = $p.Address
    protocol = "dataspace-protocol-http"
    assetId = $p.AssetId
    contractId = $agreementId
    transferType = "HttpData-PULL"
  }

  $transferPayload |
    ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $transferRequest -Encoding utf8

  Write-UiEvent -Step "transfer" -Status "RUNNING" -Provider $p.Name -Message "Iniciando transferencia con $($p.Name)"
  $response = Invoke-WebRequest `
    -UseBasicParsing `
    -Method Post `
    -Uri "$CONSUMER_MGMT/v3/transferprocesses" `
    -Headers @{ "X-API-Key" = $CONSUMER_KEY } `
    -ContentType "application/json" `
    -InFile $transferRequest

  $transferId = ($response.Content | ConvertFrom-Json).'@id'

  for ($i = 0; $i -lt 30; $i++) {
    $tp = Invoke-RestMethod `
      -Method Get `
      -Uri "$CONSUMER_MGMT/v3/transferprocesses/$transferId" `
      -Headers @{ "X-API-Key" = $CONSUMER_KEY }

    if ($tp.state -in @("STARTED", "COMPLETED", "TERMINATED")) { break }
    Start-Sleep -Seconds 2
  }

  if ($tp.state -eq "TERMINATED") {
    $tp | ConvertTo-Json -Depth 20
    Write-UiEvent -Step "transfer" -Status "ERROR" -Provider $p.Name -Message "Transfer terminada con error en $($p.Name)" -Data @{ transferId = $transferId }
    throw "Transfer terminada con error en $($p.Name)"
  }

  if ($tp.state -notin @("STARTED", "COMPLETED")) {
    $tp | ConvertTo-Json -Depth 20
    Write-UiEvent -Step "transfer" -Status "ERROR" -Provider $p.Name -Message "Transfer no iniciada en $($p.Name)" -Data @{ transferId = $transferId }
    throw "Transfer no iniciada en $($p.Name)"
  }

  Write-UiEvent -Step "transfer" -Status "SUCCESS" -Provider $p.Name -Message "Transfer STARTED con $($p.Name)" -Data @{ transferId = $transferId }
  Write-Host "Transfer: $transferId"
  Write-Host "State: $($tp.state)"

  $edr = $null
  Write-UiEvent -Step "edr" -Status "RUNNING" -Provider $p.Name -Message "Solicitando EDR de $($p.Name)"
  for ($i = 0; $i -lt 20; $i++) {
    try {
      $edr = Invoke-RestMethod `
        -Method Get `
        -Uri "$CONSUMER_MGMT/v3/edrs/$transferId/dataaddress" `
        -Headers @{ "X-API-Key" = $CONSUMER_KEY }
      break
    }
    catch {
      if ($i -eq 19) {
        Write-UiEvent -Step "edr" -Status "ERROR" -Provider $p.Name -Message "No se pudo obtener EDR de $($p.Name)"
        throw
      }
      Start-Sleep -Seconds 2
    }
  }

  $edrPath = Join-Path $GENERATED "edr-$($p.Name)-response.json"
  $edr | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $edrPath -Encoding utf8
  Write-UiEvent -Step "edr" -Status "SUCCESS" -Provider $p.Name -Message "EDR obtenido de $($p.Name)"

  $endpoint = $edr.endpoint.Replace($p.InternalPublicBase, $p.LocalPublicBase)
  $endpoint = $endpoint.Replace("http://consumer-dataplane:29291", "http://localhost:29291")

  $token = $edr.authorization
  if (-not $token) { $token = $edr.authCode }
  if (-not $token) {
    Write-UiEvent -Step "edr" -Status "ERROR" -Provider $p.Name -Message "No se encontró token EDR en $($p.Name)"
    throw "No se encontró token EDR en $($p.Name)"
  }

  Write-UiEvent -Step "download" -Status "RUNNING" -Provider $p.Name -Message "Descargando dato de $($p.Name)"
  curl.exe -f -s -X GET "$endpoint" `
    -H "Authorization: $token" `
    -o $p.Output

  if ($LASTEXITCODE -ne 0) {
    Write-UiEvent -Step "download" -Status "ERROR" -Provider $p.Name -Message "Falló la descarga en $($p.Name)"
    throw "Falló la descarga en $($p.Name)"
  }

  Write-UiEvent -Step "download" -Status "SUCCESS" -Provider $p.Name -Message "Dato descargado de $($p.Name)"
  Write-Host "Downloaded: $($p.Output)"

  return Get-Content -LiteralPath $p.Output -Raw | ConvertFrom-Json
}

if (-not $Embedded) {
Write-UiEvent -Step "script_started" -Status "RUNNING" -Message "Ejecutando solo smoke test multi-provider"
foreach ($step in @(
    "infra_check",
    "identityhubs_ready",
    "issuer_ready",
    "participants_activation",
    "membership_credentials",
    "transport_company_credential",
    "vault_provisioning",
    "controlplanes_dataplanes",
    "assets_policies_contracts",
    "dataplanes_available"
  )) {
  Write-UiEvent -Step $step -Status "SKIPPED" -Message "Paso no ejecutado en modo smoke test"
}
Write-UiEvent -Step "smoke_test" -Status "RUNNING" -Message "Ejecutando smoke test multi-provider"
}

try {
$customs = Invoke-ProviderFlow $providers[0]
$health = Invoke-ProviderFlow $providers[1]
$civilguard = Invoke-ProviderFlow $providers[2]

$blockingAuthorities = @()

if ($customs.status -ne "CLEARED") {
  $blockingAuthorities += "CUSTOMS"
}

if ($health.status -ne "CLEARED") {
  $blockingAuthorities += "HEALTH_INSPECTION"
}

if ($civilguard.status -ne "CLEARED") {
  $blockingAuthorities += "CIVIL_GUARD"
}

$overallStatus = if ($blockingAuthorities.Count -eq 0) {
  "READY_FOR_PICKUP"
} else {
  "NOT_READY_FOR_PICKUP"
}

Write-UiEvent -Step "aggregation" -Status "RUNNING" -Message "Agregando resultados de los tres Providers"
$aggregate = [ordered]@{
  containerId = "MSCU7654321"
  customsStatus = $customs.status
  healthInspectionStatus = $health.status
  civilGuardStatus = $civilguard.status
  overallStatus = $overallStatus
  blockingAuthorities = $blockingAuthorities
  lastUpdatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

$aggregatePath = Join-Path $GENERATED "aggregated-clearance-status.json"
$aggregate | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $aggregatePath -Encoding utf8
Write-UiEvent -Step "aggregation" -Status "SUCCESS" -Message "Resultado agregado generado"

if ($overallStatus -eq "READY_FOR_PICKUP") {
  Write-UiEvent -Step "result" -Status "SUCCESS" -Message "El contenedor MSCU7654321 está listo para retirada"
} else {
  Write-UiEvent -Step "result" -Status "ERROR" -Message "El contenedor MSCU7654321 no está listo para retirada"
}

Write-Host "`n=== RESULTADO AGREGADO ==="
Get-Content -LiteralPath $aggregatePath

if (-not $Embedded) {
  Write-UiEvent -Step "smoke_test" -Status "SUCCESS" -Message "Smoke test multi-provider validado"
  Write-UiEvent -Step "script_finished" -Status "SUCCESS" -Message "Smoke test validado correctamente"
}
Write-Host "`nOK: flujo multi-provider validado"
}
catch {
  if (-not $Embedded) {
    Write-UiEvent -Step "smoke_test" -Status "ERROR" -Message $_.Exception.Message
    Write-UiEvent -Step "script_finished" -Status "ERROR" -Message $_.Exception.Message
  }
  throw
}
