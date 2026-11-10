# 由 ClaudeNexus-Setup.exe 解壓縮後執行：安裝並顯示結果
Add-Type -AssemblyName PresentationFramework
try {
  & (Join-Path $PSScriptRoot 'install.ps1') | Out-Null
  [Windows.MessageBox]::Show("Claude Nexus 已安裝，小工具會出現在螢幕右下角。`n桌面與開始功能表都有「Claude Nexus」捷徑。`n`n注意：此安裝檔不會自動讀取 Claude 官方額度，百分比為本機估算。`n要與官方一致，請在小工具上按右鍵 → 校正額度，或改用 zip 版的 install-official-quota.bat。", 'Claude Nexus', 'OK', 'Information') | Out-Null
} catch {
  [Windows.MessageBox]::Show("安裝失敗：`n" + $_.Exception.Message, 'Claude Nexus', 'OK', 'Error') | Out-Null
}
