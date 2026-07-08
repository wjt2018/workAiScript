<#
  collect-slack.ps1
  Return a text digest of the messages YOU sent in Slack on a given day,
  using a User OAuth Token (xoxp-...) and the search.messages API
  (query: from:@me on:<date>). Captures channels, DMs and thread replies.

  Dot-source, then:  Get-SlackDigest -DateStr "2026-07-06" -Root $Root -Logger $log
  Returns "" when Slack isn't configured or nothing was found.
#>

function Get-SlackDigest {
  param(
    [Parameter(Mandatory = $true)][string]$DateStr,
    [Parameter(Mandatory = $true)][string]$Root,
    [scriptblock]$Logger = $null
  )
  function _log($m) { if ($Logger) { & $Logger $m } }

  . (Join-Path $Root "lib-secrets.ps1")
  $sec = Get-Secrets $Root
  $token = $null
  if ($sec.slack) { $token = $sec.slack.userToken }
  if ([string]::IsNullOrWhiteSpace($token)) {
    _log "slack: not configured (run setup-slack.ps1), skipped"
    return ""
  }

  $headers = @{ Authorization = "Bearer $token" }
  # Slack search syntax: "from:me" (no @) means the token's own user; "@me" matches nothing.
  $query = "from:me on:$DateStr"
  $matches = @()
  $page = 1
  do {
    $body = @{ query = $query; count = 100; page = $page; sort = "timestamp"; sort_dir = "asc" }
    try {
      $resp = Invoke-RestMethod -Uri "https://slack.com/api/search.messages" -Method Post -Headers $headers -Body $body -TimeoutSec 20
    } catch {
      _log ("slack: request failed ({0})" -f $_.Exception.Message)
      return ""
    }
    if (-not $resp.ok) {
      _log ("slack: api error '{0}' (token scope needs search:read)" -f $resp.error)
      return ""
    }
    $matches += $resp.messages.matches
    $pageInfo = $resp.messages.paging
    $page++
  } while ($pageInfo -and $page -le $pageInfo.pages -and $page -le 5)

  if (-not $matches -or $matches.Count -eq 0) {
    _log "slack: 0 messages today"
    return ""
  }

  # light markup cleanup: <url|label> -> label, <url> -> url, collapse whitespace
  function _clean($t) {
    if (-not $t) { return "" }
    $t = [regex]::Replace($t, "<https?://[^|>]+\|([^>]+)>", '$1')
    $t = [regex]::Replace($t, "<(https?://[^>]+)>", '$1')
    $t = [regex]::Replace($t, "<@[A-Z0-9]+\|([^>]+)>", '@$1')  # <@ID|Name> -> @Name
    $t = [regex]::Replace($t, "<#[A-Z0-9]+\|([^>]+)>", '#$1')  # <#ID|chan> -> #chan
    $t = [regex]::Replace($t, "<@[A-Z0-9]+>", "@user")          # bare <@ID>
    $t = $t -replace "\s+", " "
    return $t.Trim()
  }

  $sb = New-Object System.Text.StringBuilder
  $kept = 0
  foreach ($m in $matches) {
    $c = $m.channel
    # scope: keep public/private channels and group DMs; drop 1:1 IMs (personal/noisy).
    if ($c -and $c.is_im) { continue }
    $label = if ($c -and $c.is_mpim) { "group" }
             elseif ($c -and $c.name) { "#" + $c.name }
             else { "channel" }
    $txt = _clean $m.text
    if ([string]::IsNullOrWhiteSpace($txt)) { continue }
    if ($txt.Length -gt 200) { $txt = $txt.Substring(0, 200) + "..." }
    [void]$sb.AppendLine(("- [{0}] {1}" -f $label, $txt))
    $kept++
  }
  _log ("slack: {0} messages collected (of {1}, excluding 1:1 DMs)" -f $kept, $matches.Count)
  return $sb.ToString().TrimEnd()
}
