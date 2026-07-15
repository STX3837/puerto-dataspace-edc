param()

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

$Generated = Join-Path $RepoRoot "resources\generated"
New-Item -ItemType Directory -Force -Path $Generated | Out-Null

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

  $eventPath = Join-Path $Generated "ui-events.jsonl"
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

Write-UiEvent -Step "edc_start" -Status "RUNNING" -Message "Arrancando infraestructura y servicios EDC"

try {
  docker compose `
    -f .\docker-compose.infra.yml `
    -f .\docker-compose.edc.yml `
    up -d --build

  Write-UiEvent -Step "edc_start" -Status "SUCCESS" -Message "Infraestructura y servicios EDC arrancados"
}
catch {
  Write-UiEvent -Step "edc_start" -Status "ERROR" -Message $_.Exception.Message
  throw
}
