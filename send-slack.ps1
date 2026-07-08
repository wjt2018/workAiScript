<#
  send-slack.ps1
  Send the finished report to yourself as a Slack DM, using the bot token
  (xoxb-...) stored by setup-slack-send.ps1.

  The report text is converted into Slack Block Kit "rich_text_list" blocks so
  it renders as a NATIVE bulleted (unordered) list with nesting, instead of a
  literal "-" prefix. The plain text is still sent as the notification fallback.

  Dot-source, then:  Send-SlackReport -Text $report -Root $Root -Logger $log
  Returns $true on success, $false if not configured or the API refused.
#>

# one bulleted list group (all items at the same indent level)
function _RtList($indent, $items) {
  return @{ type = "rich_text_list"; style = "bullet"; indent = $indent; elements = @($items) }
}
function _RtSection($text, $bold) {
  $t = @{ type = "text"; text = $text }
  if ($bold) { $t.style = @{ bold = $true } }
  return @{ type = "rich_text_section"; elements = @($t) }
}

# Turn the report text into a single rich_text block (list-aware).
function Convert-ReportToBlocks {
  param([string]$Text)
  $lines = $Text -split "`r?`n"
  $elements = New-Object System.Collections.ArrayList   # ordered pieces of the rich_text block
  $curIndent = -1
  $curItems  = New-Object System.Collections.ArrayList

  foreach ($ln in $lines) {
    if ([string]::IsNullOrWhiteSpace($ln)) { continue }

    $m = [regex]::Match($ln, '^(\s*)[-*]\s+(.*)$')
    if ($m.Success) {
      $indent = if ($m.Groups[1].Value.Length -ge 2) { 1 } else { 0 }
      $txt    = $m.Groups[2].Value.TrimEnd()
      if ($curItems.Count -gt 0 -and $indent -ne $curIndent) {
        [void]$elements.Add((_RtList $curIndent $curItems))
        $curItems = New-Object System.Collections.ArrayList
      }
      $curIndent = $indent
      [void]$curItems.Add((_RtSection $txt $false))
      continue
    }

    # non-list line (e.g. the "Today:" header): flush list, add a text section
    if ($curItems.Count -gt 0) {
      [void]$elements.Add((_RtList $curIndent $curItems))
      $curItems = New-Object System.Collections.ArrayList
      $curIndent = -1
    }
    [void]$elements.Add((_RtSection ($ln.Trim()) $true))
  }
  if ($curItems.Count -gt 0) { [void]$elements.Add((_RtList $curIndent $curItems)) }

  return @( @{ type = "rich_text"; elements = @($elements) } )
}

function Send-SlackReport {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$Root,
    [scriptblock]$Logger = $null
  )
  function _log($m) { if ($Logger) { & $Logger $m } }

  . (Join-Path $Root "lib-secrets.ps1")
  $sec = Get-Secrets $Root
  $bot = $null; $uid = $null
  if ($sec.slack) { $bot = $sec.slack.botToken; $uid = $sec.slack.userId }
  if ([string]::IsNullOrWhiteSpace($bot)) {
    _log "slack send: no botToken (run setup-slack-send.ps1), skipped"
    return $false
  }
  if ([string]::IsNullOrWhiteSpace($uid)) {
    _log "slack send: no userId in secrets, skipped"
    return $false
  }

  $headers = @{ Authorization = "Bearer $bot" }
  # send a raw JSON string (PS 5.1 ConvertTo-Json unwraps single-item arrays,
  # which corrupts "blocks", so we assemble that array by hand below).
  function _postRaw($url, $json) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    return Invoke-RestMethod -Uri $url -Method Post -Headers $headers `
      -ContentType "application/json; charset=utf-8" -Body $bytes -TimeoutSec 20
  }

  # 1) open (or fetch) the DM channel with the user
  $channel = $uid
  try {
    $open = _postRaw "https://slack.com/api/conversations.open" (@{ users = $uid } | ConvertTo-Json)
    if ($open.ok -and $open.channel -and $open.channel.id) { $channel = $open.channel.id }
    else { _log ("slack send: conversations.open said '{0}', trying direct post" -f $open.error) }
  } catch {
    _log ("slack send: conversations.open failed ({0}), trying direct post" -f $_.Exception.Message)
  }

  # 2) post as a rich_text bulleted list (text kept as notification fallback)
  $blocksArr  = Convert-ReportToBlocks -Text $Text
  $parts      = foreach ($b in $blocksArr) { $b | ConvertTo-Json -Depth 20 -Compress }
  $blocksJson = "[" + ($parts -join ",") + "]"
  $payload    = "{""channel"":" + ($channel | ConvertTo-Json) + ",""text"":" + ($Text | ConvertTo-Json) + ",""blocks"":" + $blocksJson + "}"
  try {
    $post = _postRaw "https://slack.com/api/chat.postMessage" $payload
  } catch {
    _log ("slack send: chat.postMessage failed ({0})" -f $_.Exception.Message)
    return $false
  }
  if (-not $post.ok) {
    _log ("slack send: api error '{0}' (bot needs chat:write, and im:write to DM you)" -f $post.error)
    return $false
  }
  _log "slack send: report delivered as DM"
  return $true
}
