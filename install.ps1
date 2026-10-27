# 安裝 Claude Nexus：複製到 %LOCALAPPDATA%\ClaudeNexus 並建立桌面 / 開始選單捷徑
#   -StatusLine  另外把狀態列橋接登記到 ~/.claude/settings.json，讓小工具讀到官方用量
# 解除安裝：powershell -File install.ps1 -Uninstall（會一併移除本工具登記的狀態列）
param([switch]$Uninstall, [switch]$StatusLine)

$Target   = Join-Path $env:LOCALAPPDATA 'ClaudeNexus'
$Links    = @(
  (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude Nexus.lnk'),
  (Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude Nexus.lnk')
)
$Startup  = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Nexus.lnk'
$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$Settings = Join-Path $ClaudeDir 'settings.json'
$Bridge   = Join-Path $Target 'statusline.ps1'
$BridgeCmd = 'powershell -NoProfile -File "' + $Bridge + '"'

function Read-Settings {
  if (Test-Path $Settings) { Get-Content $Settings -Raw -Encoding UTF8 | ConvertFrom-Json } else { New-Object psobject }
}
function Write-Settings($s) {
  if (-not (Test-Path $ClaudeDir)) { New-Item -ItemType Directory $ClaudeDir | Out-Null }
  ($s | ConvertTo-Json -Depth 20) | Set-Content $Settings -Encoding UTF8
}

# 只關閉以 -File 啟動的小工具本身，避免誤關其他命令列中剛好提到檔名的 PowerShell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '-File\s+"[^"]*\\ClaudeNexus\.ps1"' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }

if ($Uninstall) {
  foreach ($l in $Links + $Startup) { if (Test-Path $l) { Remove-Item $l } }
  if (Test-Path $Settings) {
    $s = Read-Settings
    if ($s.statusLine -and $s.statusLine.command -like '*ClaudeNexus*statusline.ps1*') {
      $s.PSObject.Properties.Remove('statusLine'); Write-Settings $s
      Write-Host '已從 Claude Code 設定移除狀態列橋接。'
    }
  }
  if (Test-Path $Target) { Remove-Item $Target -Recurse }
  Write-Host 'Claude Nexus 已解除安裝。'
  return
}

New-Item -ItemType Directory -Force $Target | Out-Null
foreach ($f in 'ClaudeNexus.ps1', 'ClaudeNexus.vbs', 'statusline.ps1') { Copy-Item (Join-Path $PSScriptRoot $f) $Target -Force }

$sh = New-Object -ComObject WScript.Shell
foreach ($l in $Links) {
  $s = $sh.CreateShortcut($l)
  $s.TargetPath = 'wscript.exe'
  $s.Arguments = '"' + (Join-Path $Target 'ClaudeNexus.vbs') + '"'
  $s.WorkingDirectory = $Target
  $s.IconLocation = "$env:SystemRoot\System32\imageres.dll,76"
  $s.Description = 'Claude 用量浮動監控'
  $s.Save()
}

if ($StatusLine) {
  $s = Read-Settings
  if ($s.statusLine -and $s.statusLine.command -notlike '*ClaudeNexus*statusline.ps1*') {
    Write-Warning ("你已經有自己的狀態列設定（{0}），為避免覆蓋沒有修改。若要改用 Claude Nexus 的橋接，請把 statusLine.command 改成：`n  {1}" -f $s.statusLine.command, $BridgeCmd)
  } else {
    if (Test-Path $Settings) { Copy-Item $Settings ($Settings + '.bak-claudenexus') -Force }
    $s | Add-Member -NotePropertyName statusLine -NotePropertyValue ([ordered]@{ type = 'command'; command = $BridgeCmd; padding = 0 }) -Force
    Write-Settings $s
    Write-Host "已在 $Settings 登記狀態列橋接；Claude Code 更新狀態列時，小工具就會讀到官方用量。"
  }
}

Start-Process wscript.exe ('"' + (Join-Path $Target 'ClaudeNexus.vbs') + '"')
Write-Host "已安裝到 $Target，並建立桌面與開始選單捷徑。"
if (-not $StatusLine) { Write-Host '想讓小工具讀到官方用量，可加上 -StatusLine 參數重新執行。' }
