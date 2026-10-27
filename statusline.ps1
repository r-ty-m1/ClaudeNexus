# Claude Nexus 的狀態列橋接：Claude Code 每次更新狀態列時會把 JSON 從 stdin 傳進來，
# 其中 rate_limits 就是官方的 5 小時 / 每週已用百分比與重置時間。這裡把它存檔給小工具讀取。
$ErrorActionPreference = 'SilentlyContinue'
$raw = [Console]::In.ReadToEnd()
$dir = Join-Path $env:APPDATA 'ClaudeNexus'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
try { $j = $raw | ConvertFrom-Json } catch { $j = $null }
if ($j -and $j.rate_limits) {
  $out = [ordered]@{ observedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); sessionId = $j.session_id; rate_limits = $j.rate_limits }
  $tmp = Join-Path $dir 'ratelimits.tmp'
  ($out | ConvertTo-Json -Depth 5 -Compress) | Set-Content $tmp -Encoding UTF8
  Move-Item $tmp (Join-Path $dir 'ratelimits.json') -Force
}
# 狀態列本身顯示的文字
$parts = @()
if ($j.model.display_name) { $parts += $j.model.display_name }
if ($j.rate_limits.five_hour) { $parts += ('5h {0:0}%' -f $j.rate_limits.five_hour.used_percentage) }
if ($j.rate_limits.seven_day) { $parts += ('週 {0:0}%' -f $j.rate_limits.seven_day.used_percentage) }
[Console]::Out.Write(($parts -join ' · '))
