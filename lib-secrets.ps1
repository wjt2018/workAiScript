<#
  lib-secrets.ps1
  Tiny helper to read/write secrets.json (tokens live here, NEVER in git).
  Structure:
    {
      "slack":  { "userToken": "xoxp-...", "userId": "U..." },
      "google": { "clientId": "...", "clientSecret": "...", "refreshToken": "..." }
    }
  Dot-source, then use Get-Secrets / Save-SecretSection.
#>

function Get-SecretsPath { param([string]$Root) Join-Path $Root "secrets.json" }

function Get-Secrets {
  param([string]$Root)
  $p = Get-SecretsPath $Root
  if (-not (Test-Path $p)) { return [pscustomobject]@{} }
  try { return (Get-Content $p -Raw -Encoding utf8 | ConvertFrom-Json) }
  catch { return [pscustomobject]@{} }
}

function Save-SecretSection {
  param([string]$Root, [string]$Section, $Value)
  $p = Get-SecretsPath $Root
  $all = Get-Secrets $Root
  # ConvertFrom-Json objects are PSCustomObject; add/replace the section
  if ($all.PSObject.Properties.Name -contains $Section) {
    $all.$Section = $Value
  } else {
    $all | Add-Member -NotePropertyName $Section -NotePropertyValue $Value -Force
  }
  ($all | ConvertTo-Json -Depth 10) | Set-Content -Path $p -Encoding utf8
  return $p
}
