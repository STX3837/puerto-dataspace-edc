$ErrorActionPreference = "Stop"

$CONSUMER_MGMT = "http://localhost:29193/management"
$CONSUMER_KEY = "consumer-api-key"
$PROVIDER_DID = "did:web:provider-identityhub%3A8183:provider"
$ASSET_ID_EXPECTED = "asset-clearance-mscu7654321"

Write-Host "1) Catalog..."
curl.exe -s -X POST "$CONSUMER_MGMT/v3/catalog/request" `
  -H "X-API-Key: $CONSUMER_KEY" `
  -H "Content-Type: application/json" `
  --data-binary "@catalog-request.json" `
  -o catalog-response.json

$catalog = Get-Content .\catalog-response.json -Raw | ConvertFrom-Json
$dataset = @($catalog.'dcat:dataset') | Where-Object { $_.'@id' -eq $ASSET_ID_EXPECTED } | Select-Object -First 1

if (-not $dataset) { throw "Asset no encontrado en catálogo" }

$OFFER_ID = $dataset.'odrl:hasPolicy'.'@id'
$ASSET_ID = $dataset.'@id'

if (-not $OFFER_ID) { throw "Offer ID vacío" }

Write-Host "Asset: $ASSET_ID"
Write-Host "Offer: $OFFER_ID"

Write-Host "2) Contract negotiation..."

@"
{
  "@context": {
    "@vocab": "https://w3id.org/edc/v0.0.1/ns/",
    "odrl": "http://www.w3.org/ns/odrl/2/"
  },
  "@type": "ContractRequest",
  "counterPartyId": "$PROVIDER_DID",
  "counterPartyAddress": "http://provider-controlplane:19292/protocol",
  "protocol": "dataspace-protocol-http",
  "policy": {
    "@id": "$OFFER_ID",
    "@type": "odrl:Offer",
    "odrl:assigner": {
      "@id": "$PROVIDER_DID"
    },
    "odrl:target": {
      "@id": "$ASSET_ID"
    },
    "odrl:permission": [
      {
        "odrl:action": {
          "@id": "use"
        },
        "odrl:target": {
          "@id": "$ASSET_ID"
        }
      }
    ],
    "odrl:prohibition": [],
    "odrl:obligation": []
  }
}
"@ | Set-Content .\contract-negotiation-request.json -Encoding utf8

$response = Invoke-WebRequest `
  -UseBasicParsing `
  -Method Post `
  -Uri "$CONSUMER_MGMT/v3/contractnegotiations" `
  -Headers @{ "X-API-Key" = $CONSUMER_KEY } `
  -ContentType "application/json" `
  -InFile ".\contract-negotiation-request.json"

$NEGOTIATION_ID = ($response.Content | ConvertFrom-Json).'@id'

for ($i = 0; $i -lt 30; $i++) {
  $neg = Invoke-RestMethod `
    -Method Get `
    -Uri "$CONSUMER_MGMT/v3/contractnegotiations/$NEGOTIATION_ID" `
    -Headers @{ "X-API-Key" = $CONSUMER_KEY }

  if ($neg.state -in @("FINALIZED", "TERMINATED")) { break }
  Start-Sleep -Seconds 2
}

if ($neg.state -ne "FINALIZED") {
  $neg | ConvertTo-Json -Depth 20
  throw "Negociación no finalizada"
}

$AGREEMENT_ID = $neg.contractAgreementId
Write-Host "Agreement: $AGREEMENT_ID"

Write-Host "3) Transfer..."

@"
{
  "@context": {
    "@vocab": "https://w3id.org/edc/v0.0.1/ns/"
  },
  "@type": "TransferRequest",
  "counterPartyId": "$PROVIDER_DID",
  "counterPartyAddress": "http://provider-controlplane:19292/protocol",
  "protocol": "dataspace-protocol-http",
  "assetId": "$ASSET_ID",
  "contractId": "$AGREEMENT_ID",
  "transferType": "HttpData-PULL",
  "dataDestination": {
    "type": "HttpProxy"
  }
}
"@ | Set-Content .\transfer-request.json -Encoding utf8

$response = Invoke-WebRequest `
  -UseBasicParsing `
  -Method Post `
  -Uri "$CONSUMER_MGMT/v3/transferprocesses" `
  -Headers @{ "X-API-Key" = $CONSUMER_KEY } `
  -ContentType "application/json" `
  -InFile ".\transfer-request.json"

$TRANSFER_ID = ($response.Content | ConvertFrom-Json).'@id'

for ($i = 0; $i -lt 30; $i++) {
  $tp = Invoke-RestMethod `
    -Method Get `
    -Uri "$CONSUMER_MGMT/v3/transferprocesses/$TRANSFER_ID" `
    -Headers @{ "X-API-Key" = $CONSUMER_KEY }

  if ($tp.state -in @("STARTED", "COMPLETED", "TERMINATED")) { break }
  Start-Sleep -Seconds 2
}

if ($tp.state -eq "TERMINATED") {
  $tp | ConvertTo-Json -Depth 20
  throw "Transfer terminada con error"
}

Write-Host "Transfer: $TRANSFER_ID"
Write-Host "State: $($tp.state)"

Write-Host "4) EDR..."

$edr = Invoke-RestMethod `
  -Method Get `
  -Uri "$CONSUMER_MGMT/v3/edrs/$TRANSFER_ID/dataaddress" `
  -Headers @{ "X-API-Key" = $CONSUMER_KEY }

$edr | ConvertTo-Json -Depth 20 | Set-Content .\edr-response.json -Encoding utf8

$endpoint = $edr.endpoint `
  -replace "http://provider-dataplane:19294", "http://localhost:19294" `
  -replace "http://consumer-dataplane:29291", "http://localhost:29291"

$token = $edr.authorization
if (-not $token) {
  $token = $edr.authCode
}

if (-not $token) {
  throw "No se encontró token en el EDR"
}

Write-Host "Endpoint: $endpoint"

Write-Host "5) Access asset..."

curl.exe -f -i -X GET "$endpoint" `
  -H "Authorization: $token"

if ($LASTEXITCODE -ne 0) {
  throw "Falló el acceso al asset"
}

Write-Host "`nOK: flujo completo validado"
