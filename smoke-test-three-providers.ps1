$ErrorActionPreference = "Stop"

$CONSUMER_MGMT = "http://localhost:29193/management"
$CONSUMER_KEY = "consumer-api-key"

$RESOURCES = Join-Path $PSScriptRoot "resources"
$GENERATED = Join-Path $RESOURCES "generated"
New-Item -ItemType Directory -Path $GENERATED -Force | Out-Null

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

  curl.exe -s -X POST "$CONSUMER_MGMT/v3/catalog/request" `
    -H "X-API-Key: $CONSUMER_KEY" `
    -H "Content-Type: application/json" `
    --data-binary "@$($p.CatalogRequest)" `
    -o $catalogResponse

  $catalog = Get-Content -LiteralPath $catalogResponse -Raw | ConvertFrom-Json
  $dataset = @($catalog.'dcat:dataset') | Where-Object { $_.'@id' -eq $p.AssetId } | Select-Object -First 1

  if (-not $dataset) {
    throw "Asset no encontrado en catálogo de $($p.Name): $($p.AssetId)"
  }

  $offerId = $dataset.'odrl:hasPolicy'.'@id'
  if (-not $offerId) {
    throw "Offer ID vacío en $($p.Name)"
  }

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
    throw "Negociación no finalizada en $($p.Name)"
  }

  $agreementId = $neg.contractAgreementId
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
    throw "Transfer terminada con error en $($p.Name)"
  }

  if ($tp.state -notin @("STARTED", "COMPLETED")) {
    $tp | ConvertTo-Json -Depth 20
    throw "Transfer no iniciada en $($p.Name)"
  }

  Write-Host "Transfer: $transferId"
  Write-Host "State: $($tp.state)"

  $edr = $null
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
        throw
      }
      Start-Sleep -Seconds 2
    }
  }

  $edrPath = Join-Path $GENERATED "edr-$($p.Name)-response.json"
  $edr | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $edrPath -Encoding utf8

  $endpoint = $edr.endpoint.Replace($p.InternalPublicBase, $p.LocalPublicBase)
  $endpoint = $endpoint.Replace("http://consumer-dataplane:29291", "http://localhost:29291")

  $token = $edr.authorization
  if (-not $token) { $token = $edr.authCode }
  if (-not $token) { throw "No se encontró token EDR en $($p.Name)" }

  curl.exe -f -s -X GET "$endpoint" `
    -H "Authorization: $token" `
    -o $p.Output

  if ($LASTEXITCODE -ne 0) {
    throw "Falló la descarga en $($p.Name)"
  }

  Write-Host "Downloaded: $($p.Output)"

  return Get-Content -LiteralPath $p.Output -Raw | ConvertFrom-Json
}

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

Write-Host "`n=== RESULTADO AGREGADO ==="
Get-Content -LiteralPath $aggregatePath

Write-Host "`nOK: flujo multi-provider validado"
