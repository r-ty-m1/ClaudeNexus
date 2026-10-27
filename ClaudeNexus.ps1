# Claude Nexus — 英雄聯盟風格的 Claude 用量浮動小工具
# 讀取本機 Claude Code 資料（對話紀錄、執行中工作階段、帳號方案），即時顯示花費、額度與任務狀態。
# MIT License
param(
  [switch]$Test,              # 只輸出解析結果，不開視窗
  [string]$Snapshot,          # 除錯：把主視窗畫面存成 PNG 後結束
  [string]$SnapshotSettings,  # 除錯：把設定視窗畫面存成 PNG 後結束
  [string]$SnapshotCalibrate  # 除錯：把校正視窗畫面存成 PNG 後結束
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, Microsoft.VisualBasic

$Debugging = $Test -or $Snapshot -or $SnapshotSettings -or $SnapshotCalibrate
$mutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeNexusWidget')
if (-not $Debugging -and -not $mutex.WaitOne(0)) { exit }

# ================================================================ 設定
$AppDir      = Join-Path $env:APPDATA 'ClaudeNexus'
$ConfigPath  = Join-Path $AppDir 'config.json'
$ClaudeDir   = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$ClaudeJson  = if ($env:CLAUDE_CONFIG_DIR) { Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json' } else { Join-Path $env:USERPROFILE '.claude.json' }
$ProjectsDir = Join-Path $ClaudeDir 'projects'
$SessionsDir = Join-Path $ClaudeDir 'sessions'
$ScriptPath  = $MyInvocation.MyCommand.Path

$PlanNames = 'Pro', 'Max 5x', 'Max 20x', 'Team', 'Team Premium', 'Enterprise', 'API'
$Config = [ordered]@{
  plan                 = 'auto'     # auto 或上面任一方案
  # 各方案「100% 額度 ≈ 多少等值 API 花費 (USD)」，0 = 不限 / 按量計費。
  # Pro 為實測值，其他方案依官方倍數推算；同一視窗內校正兩次會自動修正
  limits               = [ordered]@{
    'Pro'          = @{ block = 26;    weekly = 118 }
    'Max 5x'       = @{ block = 130;   weekly = 590 }
    'Max 20x'      = @{ block = 520;   weekly = 2360 }
    'Team'         = @{ block = 32.5;  weekly = 147.5 }
    'Team Premium' = @{ block = 162.5; weekly = 737.5 }
    'Enterprise'   = @{ block = 0;     weekly = 0 }
    'API'          = @{ block = 0;     weekly = 0 }
  }
  # 校正基準點：官方顯示的已用 % 與當下的本機花費，之後只把新增花費換算成 % 往上加
  calib                = $null
  weeklyResetDay       = 'Wednesday'
  weeklyResetHour      = 19         # 本地時間
  weeklyResetMinute    = 0
  configVersion        = 2
  refreshSeconds       = 2
  activeMinutes        = 10         # 沒有工作階段資訊時，幾分鐘內有活動視為進行中
  maxTasks             = 4
  showTasks            = $true
  showStats            = $true
  showTools            = $true
  notifyDone           = $true
  notifyMinTaskSeconds = 15         # 執行超過幾秒的任務完成才通知
  notifyWaiting        = $true
  notifyQuota          = $true
  quotaWarnPct         = 20
  notifySound          = $true
  notifySeconds        = 6
  opacity              = 0.96
  mode                 = 'full'     # full / compact / mini
  left                 = -1
  top                  = -1
}

# JSON 裡的時間可能是 UTC（/Date(...)/ 或 ISO 字串）；DateTime 比較不看時區，一律轉成本地時間
function To-LocalTime($v) {
  $d = if ($v -is [datetime]) { $v } else { [datetime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
  if ($d.Kind -eq [DateTimeKind]::Utc) { $d.ToLocalTime() } else { $d }
}function Load-Config {
  if (-not (Test-Path $ConfigPath)) { return }
  try { $j = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
  # 第 1 版的校正把其他裝置的用量也算進本機，上限會偏低，升級時改回預設值
  $current = [int]$j.configVersion -ge 2
  foreach ($p in $j.PSObject.Properties) {
    if ($p.Name -eq 'limits') {
      if ($current) { foreach ($q in $p.Value.PSObject.Properties) { $Config.limits[$q.Name] = @{ block = [double]$q.Value.block; weekly = [double]$q.Value.weekly } } }
    } elseif ($p.Name -eq 'calib') {
      if ($current -and $p.Value) {
        $c = @{}
        if ($p.Value.block)  { $c.block  = @{ pct = [double]$p.Value.block.pct;  cost = [double]$p.Value.block.cost;  resetAt = (To-LocalTime $p.Value.block.resetAt) } }
        if ($p.Value.weekly) { $c.weekly = @{ pct = [double]$p.Value.weekly.pct; cost = [double]$p.Value.weekly.cost; start = (To-LocalTime $p.Value.weekly.start) } }
        $Config.calib = $c
      }
    } elseif ($p.Name -eq 'configVersion') {
    } elseif ($Config.Contains($p.Name)) { $Config[$p.Name] = $p.Value }
  }
  if ($null -ne $j.blockLimitUSD) { $Config.plan = 'auto' }   # 舊版單一方案設定
}
function Save-Config {
  if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory $AppDir | Out-Null }
  ($Config | ConvertTo-Json -Depth 5) | Set-Content $ConfigPath -Encoding UTF8
}
Load-Config
if (-not $Debugging) { Save-Config }

# ================================================================ 方案偵測（讀取 Claude Code 的帳號資訊）
$script:Detected = $null
$script:ClaudeJsonTime = [datetime]::MinValue
function Detect-Plan {
  if (-not (Test-Path $ClaudeJson)) { if (-not $script:Detected) { $script:Detected = 'API' }; return }
  $t = [IO.File]::GetLastWriteTimeUtc($ClaudeJson)
  if ($t -eq $script:ClaudeJsonTime) { return }
  $script:ClaudeJsonTime = $t
  try { $txt = [IO.File]::ReadAllText($ClaudeJson, [Text.Encoding]::UTF8) } catch { return }
  $get = { param($k) $m = [regex]::Match($txt, '"' + $k + '":\s*"([^"]*)"'); if ($m.Success) { $m.Groups[1].Value } else { '' } }
  $type = & $get 'organizationType'; $tier = & $get 'organizationRateLimitTier'; $seat = & $get 'seatTier'
  $plan = switch -Regex ($type) {
    'max'        { if ($tier -match '20x') { 'Max 20x' } else { 'Max 5x' }; break }
    'pro'        { 'Pro'; break }
    'team'       { if ($seat -match 'premium') { 'Team Premium' } else { 'Team' }; break }
    'enterprise' { 'Enterprise'; break }
    default      { 'API' }
  }
  $script:Detected = $plan
}
function Get-Plan { if ($Config.plan -ne 'auto' -and $PlanNames -contains $Config.plan) { $Config.plan } else { $script:Detected } }
function Get-Limits([string]$plan) {
  $l = $Config.limits[$plan]
  if (-not $l) { $l = @{ block = 0; weekly = 0 } }
  @{ block = [double]$l.block; weekly = [double]$l.weekly }
}

# ================================================================ 價格 ($ / 百萬 tokens: 輸入, 輸出, 快取讀取)
# 快取寫入：5 分鐘 = 輸入 ×1.25，1 小時 = 輸入 ×2；fast 模式 ×2
$Pricing = @(
  @('claude-fable-5-1', 10, 50, 0.25), @('claude-mythos', 10, 50, 0.25), @('claude-fable-5', 10, 50, 1.0),
  @('claude-opus-5-5', 4, 20, 0.20),   @('claude-opus-5', 5, 25, 0.5),
  @('claude-opus-4-8', 5, 25, 0.5),    @('claude-opus-4-7', 5, 25, 0.5), @('claude-opus-4-6', 5, 25, 0.5),
  @('claude-opus-4-5', 5, 25, 0.5),    @('claude-opus-4', 15, 75, 1.5),
  @('claude-sonnet-5', 2, 10, 0.2),    @('claude-sonnet-4', 3, 15, 0.3), @('claude-3-7-sonnet', 3, 15, 0.3),
  @('claude-haiku-5', 0.1, 0.5, 0.01), @('claude-haiku-4', 1, 5, 0.1),   @('claude-3-5-haiku', 0.8, 4, 0.08)
)
function Get-Price([string]$model) {
  foreach ($p in $Pricing) { if ($model.StartsWith($p[0])) { return $p } }
  return @('?', 3, 15, 0.3)
}

# ================================================================ 對話紀錄解析
$Entries    = @{}   # 每次 API 請求
$Sessions   = @{}   # sessionId -> @{ Title; Cwd }
$FileState  = @{}   # 檔案 -> 已讀取位移
$ToolEvents = @{}   # tool_use id -> 工具呼叫
$Pending    = @{}   # sessionId -> @{ tool id -> 尚未回傳結果的工具 }
$Resolved   = @{}   # 已有結果的 tool id
$script:Dirty  = $true
$script:Sorted = @()

$rx = @{
  Model   = [regex]'"model":"([^"]+)"'
  Id      = [regex]'"id":"(msg_[^"]+)"'
  Req     = [regex]'"requestId":"([^"]+)"'
  Ts      = [regex]'"timestamp":"(\d{4}-[^"]+)"'
  Sid     = [regex]'"sessionId":"([^"]+)"'
  Cwd     = [regex]'"cwd":"((?:[^"\\]|\\.)*)"'
  Title   = [regex]'"customTitle":"((?:[^"\\]|\\.)*)"'
  ToolUse = [regex]'"type":"tool_use","id":"([^"]+)","name":"([^"]+)"'
  ToolRes = [regex]'"tool_use_id":"([^"]+)"'
  Skill   = [regex]'"skill":"([^"]+)"'
  SubType = [regex]'"subagent_type":"([^"]+)"'
}
function Get-Num([string]$s, [string]$name) {
  $m = [regex]::Match($s, '"' + $name + '":(\d+)')
  if ($m.Success) { [double]$m.Groups[1].Value } else { 0 }
}
function Unescape-Json([string]$s) { try { [regex]::Unescape($s) } catch { $s } }

# 把工具名稱分類成 MCP / Skill / 子代理 / 內建工具
function Classify-Tool([string]$name, [string]$seg) {
  if ($name.StartsWith('mcp__')) {
    $parts = $name.Split(@('__'), [StringSplitOptions]::None)
    $server = if ($parts.Count -gt 1) { $parts[1] } else { 'mcp' }
    $tool = if ($parts.Count -gt 2) { $parts[2] } else { '' }
    # Claude 桌面版內部使用的 ccd_* 伺服器不算進 MCP 統計
    if ($server.StartsWith('ccd_')) { return @{ Kind = 'tool'; Label = $tool; Key = $tool } }
    # claude.ai 連接器的伺服器名稱是 GUID，改用工具名稱比較好認
    $label = if ($server -match '^[0-9a-f]{8}-') { $tool } else { "$server · $tool" }
    $key = if ($server -match '^[0-9a-f]{8}-') { ($tool -split '[-_]')[0] } else { $server }
    return @{ Kind = 'mcp'; Label = 'MCP ' + $label; Key = $key }
  }
  if ($name -eq 'Skill') {
    $m = $rx.Skill.Match($seg); $s = if ($m.Success) { $m.Groups[1].Value } else { '?' }
    return @{ Kind = 'skill'; Label = 'Skill ' + $s; Key = $s }
  }
  if ($name -eq 'Agent' -or $name -eq 'Task') {
    $m = $rx.SubType.Match($seg); $s = if ($m.Success) { $m.Groups[1].Value } else { 'agent' }
    return @{ Kind = 'agent'; Label = '子代理 ' + $s; Key = $s }
  }
  return @{ Kind = 'tool'; Label = $name; Key = $name }
}

function Parse-Line([string]$line) {
  $sidM = $rx.Sid.Match($line)
  if (-not $sidM.Success) { return }
  $sid = $sidM.Groups[1].Value
  if (-not $Sessions.ContainsKey($sid)) { $Sessions[$sid] = @{ Title = $null; Cwd = $null } }
  $s = $Sessions[$sid]
  if (-not $s.Cwd) { $m = $rx.Cwd.Match($line); if ($m.Success) { $s.Cwd = Unescape-Json $m.Groups[1].Value } }
  if ($line.Contains('"type":"custom-title"')) { $m = $rx.Title.Match($line); if ($m.Success) { $s.Title = Unescape-Json $m.Groups[1].Value } }

  if ($line.Contains('"tool_use_id"')) {
    foreach ($m in $rx.ToolRes.Matches($line)) {
      $id = $m.Groups[1].Value
      $Resolved[$id] = 1
      if ($Pending.ContainsKey($sid)) { $Pending[$sid].Remove($id) }
    }
  }
  if (-not $line.Contains('"type":"assistant"')) { return }

  $tsM = $rx.Ts.Matches($line)
  if ($tsM.Count -eq 0) { return }
  $ts = [DateTime]::Parse($tsM[$tsM.Count - 1].Groups[1].Value, $null, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()

  $tu = $rx.ToolUse.Matches($line)
  if ($tu.Count -gt 0) {
    $side = $line.Contains('"isSidechain":true')
    foreach ($m in $tu) {
      $id = $m.Groups[1].Value
      if ($ToolEvents.ContainsKey($id)) { continue }
      $seg = $line.Substring($m.Index, [math]::Min(800, $line.Length - $m.Index))
      $c = Classify-Tool $m.Groups[2].Value $seg
      if ($side -and $c.Kind -ne 'agent') { $c.Label = '子代理 ▸ ' + $c.Label }
      $ev = [pscustomobject]@{ Ts = $ts; Sid = $sid; Kind = $c.Kind; Label = $c.Label; Key = $c.Key }
      $ToolEvents[$id] = $ev
      if (-not $Resolved.ContainsKey($id)) {
        if (-not $Pending.ContainsKey($sid)) { $Pending[$sid] = @{} }
        $Pending[$sid][$id] = $ev
      }
    }
  }

  $ui = $line.LastIndexOf('"usage":{')
  if ($ui -lt 0) { return }
  $model = $rx.Model.Match($line).Groups[1].Value
  if (-not $model -or $model -eq '<synthetic>') { return }
  $u   = $line.Substring($ui)
  $in  = Get-Num $u 'input_tokens'
  $out = Get-Num $u 'output_tokens'
  $cr  = Get-Num $u 'cache_read_input_tokens'
  $cc  = Get-Num $u 'cache_creation_input_tokens'
  $c5  = Get-Num $u 'ephemeral_5m_input_tokens'
  $c1  = Get-Num $u 'ephemeral_1h_input_tokens'
  if ($c5 + $c1 -eq 0) { $c5 = $cc }
  $p = Get-Price $model
  $cost = ($in * $p[1] + $out * $p[2] + $cr * $p[3] + $c5 * $p[1] * 1.25 + $c1 * $p[1] * 2) / 1e6
  if ($u.Contains('"speed":"fast"')) { $cost *= 2 }
  $key = $rx.Id.Match($line).Groups[1].Value + '|' + $rx.Req.Match($line).Groups[1].Value
  # 串流時同一則訊息會寫入多行，保留最後一筆
  $Entries[$key] = [pscustomobject]@{
    Ts = $ts; Sid = $sid; Model = $model; Cost = $cost
    Tok = $in + $out + $cr + $cc; Ctx = $in + $cr + $cc
  }
  $script:Dirty = $true
}

function Scan-Files {
  if (-not (Test-Path $ProjectsDir)) { return }
  $cutoff = (Get-Date).ToUniversalTime().AddDays(-9)
  foreach ($f in [IO.Directory]::EnumerateFiles($ProjectsDir, '*.jsonl', [IO.SearchOption]::AllDirectories)) {
    $fi = New-Object IO.FileInfo $f
    if (-not $FileState.ContainsKey($f)) {
      if ($fi.LastWriteTimeUtc -lt $cutoff) { $FileState[$f] = $fi.Length; continue }
      $FileState[$f] = 0L
    }
    $off = [long]$FileState[$f]
    if ($fi.Length -lt $off) { $off = 0L }
    if ($fi.Length -eq $off) { continue }
    $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite, Delete')
    try {
      [void]$fs.Seek($off, 'Begin')
      $len = [int]($fs.Length - $off)
      $buf = New-Object byte[] $len
      $read = 0
      while ($read -lt $len) { $n = $fs.Read($buf, $read, $len - $read); if ($n -le 0) { break }; $read += $n }
    } finally { $fs.Dispose() }
    $last = $read - 1
    while ($last -ge 0 -and $buf[$last] -ne 10) { $last-- }
    if ($last -lt 0) { continue }   # 還沒有完整的一行
    $text = [Text.Encoding]::UTF8.GetString($buf, 0, $last + 1)
    foreach ($line in $text.Split("`n")) { if ($line.Length -gt 2) { Parse-Line $line } }
    $FileState[$f] = $off + $last + 1
  }
}

# ================================================================ 執行中的工作階段（Claude Code 寫在 ~/.claude/sessions/<pid>.json）
function Get-LiveSessions {
  $list = @()
  if (-not (Test-Path $SessionsDir)) { return , $list }
  $pids = @{}
  foreach ($p in [Diagnostics.Process]::GetProcesses()) { $pids[$p.Id] = 1 }
  foreach ($f in [IO.Directory]::EnumerateFiles($SessionsDir, '*.json')) {
    try { $j = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
    if (-not $j.sessionId -or -not $j.pid -or -not $pids.ContainsKey([int]$j.pid)) { continue }
    $since = if ($j.statusUpdatedAt) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$j.statusUpdatedAt).LocalDateTime } else { Get-Date }
    $list += [pscustomobject]@{
      Sid = [string]$j.sessionId; Name = [string]$j.name; Status = [string]$j.status
      WaitingFor = [string]$j.waitingFor; Since = $since
    }
  }
  return , $list
}

# ================================================================ 統計
function Fmt-Money([double]$v) { if ($v -ge 100) { '$' + $v.ToString('0') } else { '$' + $v.ToString('0.00') } }
function Fmt-Tok([double]$v) {
  if ($v -ge 1e9) { ($v / 1e9).ToString('0.0') + 'B' }
  elseif ($v -ge 1e6) { ($v / 1e6).ToString('0.0') + 'M' }
  elseif ($v -ge 1e3) { ($v / 1e3).ToString('0') + 'K' }
  else { $v.ToString('0') }
}
function Fmt-Span([TimeSpan]$t) {
  if ($t.TotalDays -ge 1) { '{0}d {1}h' -f [int][math]::Floor($t.TotalDays), $t.Hours }
  elseif ($t.TotalHours -ge 1) { '{0}h {1:00}m' -f [int][math]::Floor($t.TotalHours), $t.Minutes }
  else { '{0}m {1:00}s' -f $t.Minutes, $t.Seconds }
}
function Get-Title([string]$sid, [string]$fallback) {
  # 優先使用 Claude 介面上顯示的名稱，其次是對話標題
  if ($fallback) { return $fallback }
  $meta = $Sessions[$sid]
  if ($meta -and $meta.Title) { return $meta.Title }
  if ($meta -and $meta.Cwd) { return (Split-Path $meta.Cwd -Leaf) }
  return $sid.Substring(0, [math]::Min(8, $sid.Length))
}
function Get-CurrentTool([string]$sid) {
  if (-not $Pending.ContainsKey($sid) -or $Pending[$sid].Count -eq 0) { return $null }
  ($Pending[$sid].Values | Sort-Object Ts | Select-Object -Last 1)
}

function Get-CostBetween([datetime]$from, [datetime]$to) {
  $sum = 0.0
  foreach ($e in $script:Sorted) { if ($e.Ts -ge $from -and $e.Ts -lt $to) { $sum += $e.Cost } }
  $sum
}
function Get-WeekStart([datetime]$now) {
  $dow = [int][DayOfWeek]$Config.weeklyResetDay
  $wr = $now.Date.AddHours([double]$Config.weeklyResetHour).AddMinutes([double]$Config.weeklyResetMinute)
  $wr = $wr.AddDays( - (([int]$wr.DayOfWeek - $dow + 7) % 7))
  if ($wr -gt $now) { $wr = $wr.AddDays(-7) }
  $wr
}
# 已用 %：有基準點時 = 官方 % + 之後新增的花費換算；沒有時 = 花費 ÷ 上限。上限 0 (不限) 回傳 $null
function Get-UsedPct([double]$cost, [double]$limit, $base) {
  if ($limit -le 0) { return $null }
  $u = if ($base) { $base.pct + 100 * ($cost - $base.cost) / $limit } else { 100 * $cost / $limit }
  [math]::Max(0.0, [math]::Min(100.0, $u))
}

# 官方用量：statusline.ps1 把 Claude Code 交給狀態列的 rate_limits 存在 ratelimits.json
$OfficialPath = Join-Path $AppDir 'ratelimits.json'
$script:OfficialTime = [datetime]::MinValue
$script:OfficialRaw = $null
function Get-Official([datetime]$now) {
  if (-not (Test-Path $OfficialPath)) { return $null }
  $t = [IO.File]::GetLastWriteTimeUtc($OfficialPath)
  if ($t -ne $script:OfficialTime) {
    $script:OfficialTime = $t
    try { $script:OfficialRaw = [IO.File]::ReadAllText($OfficialPath, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $script:OfficialRaw = $null }
  }
  $j = $script:OfficialRaw
  if (-not $j -or -not $j.rate_limits) { return $null }
  $toLocal = { param($s) [DateTimeOffset]::FromUnixTimeSeconds([long]$s).LocalDateTime }
  $r = @{ At = (& $toLocal $j.observedAt); Block = $null; Week = $null }
  $fh = $j.rate_limits.five_hour; $sd = $j.rate_limits.seven_day
  if ($fh -and $fh.resets_at -and (& $toLocal $fh.resets_at) -gt $now) { $r.Block = @{ Pct = [double]$fh.used_percentage; ResetAt = (& $toLocal $fh.resets_at) } }
  if ($sd -and $sd.resets_at -and (& $toLocal $sd.resets_at) -gt $now) { $r.Week = @{ Pct = [double]$sd.used_percentage; ResetAt = (& $toLocal $sd.resets_at) } }
  if (-not $r.Block -and -not $r.Week) { return $null }
  $r
}

function Get-Stats {
  $now = Get-Date
  if ($script:Dirty) {
    $old = $now.AddDays(-9)
    foreach ($k in @($Entries.Keys)) { if ($Entries[$k].Ts -lt $old) { $Entries.Remove($k) } }
    foreach ($k in @($ToolEvents.Keys)) { if ($ToolEvents[$k].Ts -lt $old) { $ToolEvents.Remove($k); $Resolved.Remove($k) } }
    $script:Sorted = @($Entries.Values | Sort-Object Ts)
    $script:Dirty = $false
  }
  $all = $script:Sorted
  $st = @{ Now = $now; Plan = (Get-Plan) }
  $st.Limits = Get-Limits $st.Plan

  # 每個對話的花費
  $sCost = @{}; $sTok = @{}; $sReq = @{}; $sFirst = @{}; $sLast = @{}
  foreach ($e in $all) {
    $sCost[$e.Sid] += $e.Cost; $sTok[$e.Sid] += $e.Tok; $sReq[$e.Sid] += 1
    if (-not $sFirst.ContainsKey($e.Sid)) { $sFirst[$e.Sid] = $e }
    $sLast[$e.Sid] = $e
  }
  $st.SessCost = $sCost

  # 任務清單：優先使用 Claude Code 的工作階段狀態，否則以最近活動判斷
  $live = Get-LiveSessions
  $tasks = @()
  if ($live.Count -gt 0) {
    foreach ($l in $live) {
      $tasks += [pscustomobject]@{
        Sid = $l.Sid; Title = (Get-Title $l.Sid $l.Name); Status = $l.Status; WaitingFor = $l.WaitingFor; Since = $l.Since
        Cost = [double]$sCost[$l.Sid]; Tool = $(if ($l.Status -eq 'idle') { $null } else { Get-CurrentTool $l.Sid })
      }
    }
  } else {
    foreach ($sid in $sLast.Keys) {
      $idle = $now - $sLast[$sid].Ts
      if ($idle.TotalMinutes -ge [double]$Config.activeMinutes) { continue }
      $tool = Get-CurrentTool $sid
      $tasks += [pscustomobject]@{
        Sid = $sid; Title = (Get-Title $sid $null); Status = $(if ($idle.TotalSeconds -lt 90) { 'busy' } else { 'idle' })
        WaitingFor = ''; Since = $sLast[$sid].Ts; Cost = [double]$sCost[$sid]; Tool = $tool
      }
    }
  }
  $rank = @{ waiting = 0; busy = 1; idle = 2 }
  $st.Tasks = @($tasks | Sort-Object @{ e = { $r = $rank[$_.Status]; if ($null -eq $r) { 3 } else { $r } } }, @{ e = { $_.Since }; Descending = $true })

  # 主要對話：正在跑（或等待確認）的任務，否則最近有紀錄的對話
  $heroSid = $null
  $busyTask = $st.Tasks | Where-Object { $_.Status -ne 'idle' } | Select-Object -First 1
  if ($busyTask) { $heroSid = $busyTask.Sid } elseif ($all.Count) { $heroSid = $all[$all.Count - 1].Sid }
  $st.Session = $null
  if ($heroSid -and $sLast.ContainsKey($heroSid)) {
    $le = $sLast[$heroSid]; $task = $st.Tasks | Where-Object { $_.Sid -eq $heroSid } | Select-Object -First 1
    $status = if ($task) { $task.Status } elseif (($now - $le.Ts).TotalMinutes -lt [double]$Config.activeMinutes) { 'busy' } else { 'idle' }
    $st.Session = @{
      Title = $(if ($task) { $task.Title } else { Get-Title $heroSid $null })
      Cost = $sCost[$heroSid]; Tok = $sTok[$heroSid]; Req = $sReq[$heroSid]; Model = $le.Model; Ctx = $le.Ctx
      Status = $status; Dur = $le.Ts - $sFirst[$heroSid].Ts; Idle = $now - $le.Ts
    }
  }
  $st.Busy = @($st.Tasks | Where-Object { $_.Status -eq 'busy' }).Count
  $st.Waiting = @($st.Tasks | Where-Object { $_.Status -eq 'waiting' })

  # 額度來源優先順序：官方數字（狀態列橋接）> 手動校正 > 純估算
  $off = Get-Official $now

  # 5 小時視窗：有官方 / 校正就對齊官方重置時間；否則（或視窗已結束後）從第一則訊息起算 5 小時
  $calB = if ($Config.calib) { $Config.calib.block } else { $null }
  $bStart = $null; $bEnd = $null; $baseB = $null; $srcB = 'estimate'
  if ($off -and $off.Block) {
    $bEnd = $off.Block.ResetAt; $bStart = $bEnd.AddHours(-5); $srcB = 'official'
    $baseB = @{ pct = $off.Block.Pct; cost = (Get-CostBetween $bStart $off.At) }
  } elseif ($calB -and $now -lt $calB.resetAt) { $bStart = $calB.resetAt.AddHours(-5); $bEnd = $calB.resetAt; $baseB = $calB; $srcB = 'manual' }
  else {
    $from = if ($calB) { $calB.resetAt } else { $now.AddHours(-24) }
    foreach ($e in $all) {
      if ($e.Ts -lt $from) { continue }
      if (-not $bEnd -or $e.Ts -ge $bEnd) { $bStart = $e.Ts; $bEnd = $e.Ts.AddHours(5) }
    }
  }
  $active = $bEnd -and $now -lt $bEnd
  $bCost = if ($active) { Get-CostBetween $bStart $bEnd } else { 0 }
  $st.Block = @{
    Cost = $bCost; Active = $active; Start = $bStart; Source = $srcB; Calibrated = ($srcB -ne 'estimate')
    Reset = $(if ($active) { $bEnd - $now } else { $null })
    Used = (Get-UsedPct $bCost $st.Limits.block $baseB)
  }

  # 每週：官方重置時間；同一週內有官方數字或校正基準點就從基準點往上加
  $srcW = 'estimate'
  if ($off -and $off.Week) {
    $wr = $off.Week.ResetAt.AddDays(-7); $srcW = 'official'
    $baseW = @{ pct = $off.Week.Pct; cost = (Get-CostBetween $wr $off.At) }
  } else {
    $wr = Get-WeekStart $now
    $calW = if ($Config.calib) { $Config.calib.weekly } else { $null }
    $baseW = if ($calW -and [math]::Abs(($calW.start - $wr).TotalMinutes) -lt 1) { $srcW = 'manual'; $calW } else { $null }
  }
  $wCost = Get-CostBetween $wr $now.AddDays(1)
  $st.Week = @{
    Cost = $wCost; Reset = $wr.AddDays(7) - $now; Start = $wr; Source = $srcW; Calibrated = ($srcW -ne 'estimate')
    Used = (Get-UsedPct $wCost $st.Limits.weekly $baseW)
  }
  $st.Official = $off

  # 今日 + 近 7 日
  $today = $now.Date
  $days = New-Object double[] 7
  $tCost = 0; $tReq = 0; $tTok = 0; $tSess = @{}
  foreach ($e in $all) {
    $d = [int]($today - $e.Ts.Date).TotalDays
    if ($d -ge 0 -and $d -lt 7) { $days[6 - $d] += $e.Cost }
    if ($d -eq 0) { $tCost += $e.Cost; $tReq++; $tTok += $e.Tok; $tSess[$e.Sid] = 1 }
  }
  $st.Today = @{ Cost = $tCost; Req = $tReq; Tok = $tTok; Sess = $tSess.Count }
  $st.Days = $days

  # 今日工具使用
  $tools = @{ Total = 0; mcp = 0; skill = 0; agent = 0; McpBy = @{}; SkillBy = @{}; AgentBy = @{} }
  foreach ($t in $ToolEvents.Values) {
    if ($t.Ts.Date -ne $today) { continue }
    $tools.Total++
    switch ($t.Kind) {
      'mcp'   { $tools.mcp++;   $tools.McpBy[$t.Key] += 1 }
      'skill' { $tools.skill++; $tools.SkillBy[$t.Key] += 1 }
      'agent' { $tools.agent++; $tools.AgentBy[$t.Key] += 1 }
    }
  }
  $st.Tools = $tools
  return $st
}

if ($Test) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  Detect-Plan; Scan-Files
  $s = Get-Stats
  "scan+stats: {0} ms, entries: {1}, sessions: {2}, tool calls: {3}" -f $sw.ElapsedMilliseconds, $Entries.Count, $Sessions.Count, $ToolEvents.Count
  "plan: detected={0} effective={1} limits={2}/{3}" -f $script:Detected, $s.Plan, $s.Limits.block, $s.Limits.weekly
  if ($s.Session) { "hero: {0} | {1} | req {2} | ctx {3} | {4} | {5}" -f $s.Session.Title, (Fmt-Money $s.Session.Cost), $s.Session.Req, (Fmt-Tok $s.Session.Ctx), $s.Session.Model, $s.Session.Status }
  foreach ($t in $s.Tasks) { "task: [{0}] {1} | {2} | tool={3} | wait={4}" -f $t.Status, $t.Title, (Fmt-Money $t.Cost), $t.Tool.Label, $t.WaitingFor }
  "block: cost {0} used {1:0.0}% calibrated {2} reset {3}" -f (Fmt-Money $s.Block.Cost), $s.Block.Used, $s.Block.Calibrated, $s.Block.Reset
  "week: cost {0} used {1:0.0}% calibrated {2} reset {3}" -f (Fmt-Money $s.Week.Cost), $s.Week.Used, $s.Week.Calibrated, (Fmt-Span $s.Week.Reset)
  "today: {0} req {1} sess {2}" -f (Fmt-Money $s.Today.Cost), $s.Today.Req, $s.Today.Sess
  "tools today: total {0} mcp {1} skill {2} agent {3} | skills: {4} | mcp: {5}" -f $s.Tools.Total, $s.Tools.mcp, $s.Tools.skill, $s.Tools.agent, (($s.Tools.SkillBy.Keys) -join ','), (($s.Tools.McpBy.Keys) -join ',')
  return
}

# ================================================================ 主視窗 (海克斯科技風)
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Nexus" SizeToContent="WidthAndHeight"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="Gold" Color="#C8AA6E"/>
    <SolidColorBrush x:Key="GoldLight" Color="#F0E6D2"/>
    <SolidColorBrush x:Key="GoldDark" Color="#785A28"/>
    <SolidColorBrush x:Key="Grey" Color="#A09B8C"/>
    <Style x:Key="Sec" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Microsoft JhengHei UI"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="{StaticResource Gold}"/>
    </Style>
    <Style x:Key="Lbl" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Microsoft JhengHei UI"/>
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="Foreground" Value="{StaticResource Grey}"/>
    </Style>
    <Style x:Key="Val" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Georgia"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="{StaticResource GoldLight}"/>
    </Style>
    <Style x:Key="Btn" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="{StaticResource GoldDark}"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Foreground" Value="{StaticResource GoldLight}"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="ContextMenu">
      <Setter Property="Background" Value="#0A1428"/>
      <Setter Property="Foreground" Value="#F0E6D2"/>
      <Setter Property="BorderBrush" Value="#785A28"/>
      <Setter Property="FontFamily" Value="Microsoft JhengHei UI"/>
    </Style>
    <LinearGradientBrush x:Key="Rule" StartPoint="0,0" EndPoint="1,0">
      <GradientStop Color="#00785A28" Offset="0"/><GradientStop Color="#785A28" Offset="0.5"/><GradientStop Color="#00785A28" Offset="1"/>
    </LinearGradientBrush>
  </Window.Resources>

  <Grid>
  <Grid x:Name="FullRoot" Width="296">
  <Grid Margin="8">
    <Border x:Name="Frame" BorderThickness="1.5" Padding="2" CornerRadius="1">
      <Border.BorderBrush>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
          <GradientStop Color="#C8AA6E" Offset="0"/>
          <GradientStop Color="#785A28" Offset="0.5"/>
          <GradientStop Color="#C8AA6E" Offset="1"/>
        </LinearGradientBrush>
      </Border.BorderBrush>
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
          <GradientStop Color="#F50A1E2D" Offset="0"/>
          <GradientStop Color="#F5091428" Offset="0.35"/>
          <GradientStop Color="#F5010A13" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <Border.Effect>
        <DropShadowEffect Color="#000000" BlurRadius="14" ShadowDepth="0" Opacity="0.8"/>
      </Border.Effect>

      <Border BorderBrush="#3C2E14" BorderThickness="1" Padding="11,8,11,9">
        <StackPanel>
          <!-- 標題列 -->
          <Grid x:Name="Header" Background="Transparent">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Rectangle Width="9" Height="9" Margin="1,0,9,0" Stroke="#C8AA6E" StrokeThickness="1" VerticalAlignment="Center">
              <Rectangle.RenderTransform><RotateTransform Angle="45" CenterX="4.5" CenterY="4.5"/></Rectangle.RenderTransform>
              <Rectangle.Fill>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                  <GradientStop Color="#CDFAFA" Offset="0"/><GradientStop Color="#0AC8B9" Offset="0.5"/><GradientStop Color="#005A82" Offset="1"/>
                </LinearGradientBrush>
              </Rectangle.Fill>
              <Rectangle.Effect><DropShadowEffect x:Name="Gem" Color="#0AC8B9" BlurRadius="10" ShadowDepth="0" Opacity="0.9"/></Rectangle.Effect>
            </Rectangle>
            <TextBlock Grid.Column="1" Text="CLAUDE  NEXUS" FontFamily="Georgia" FontWeight="Bold" FontSize="13"
                       Foreground="#F0E6D2" VerticalAlignment="Center">
              <TextBlock.Effect><DropShadowEffect Color="#C8AA6E" BlurRadius="6" ShadowDepth="0" Opacity="0.5"/></TextBlock.Effect>
            </TextBlock>
            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
              <TextBlock x:Name="BtnSettings" Text="⚙" Style="{StaticResource Btn}" ToolTip="設定"/>
              <TextBlock x:Name="BtnCompact" Text="◇" Style="{StaticResource Btn}" ToolTip="切換：完整 → 精簡 → 血條"/>
              <TextBlock x:Name="BtnClose" Text="✕" Style="{StaticResource Btn}" ToolTip="關閉"/>
            </StackPanel>
          </Grid>

          <Grid Margin="0,7,0,6" Height="7">
            <Rectangle Height="1" VerticalAlignment="Center">
              <Rectangle.Fill>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                  <GradientStop Color="#00785A28" Offset="0"/><GradientStop Color="#C8AA6E" Offset="0.5"/><GradientStop Color="#00785A28" Offset="1"/>
                </LinearGradientBrush>
              </Rectangle.Fill>
            </Rectangle>
            <Rectangle Width="5" Height="5" Fill="#010A13" Stroke="#C8AA6E" StrokeThickness="1" HorizontalAlignment="Center">
              <Rectangle.RenderTransform><RotateTransform Angle="45" CenterX="2.5" CenterY="2.5"/></Rectangle.RenderTransform>
            </Rectangle>
          </Grid>

          <!-- 主要對話 -->
          <StackPanel x:Name="SecSession">
            <Grid>
              <TextBlock Text="進行中對話" Style="{StaticResource Sec}"/>
              <TextBlock x:Name="SessState" HorizontalAlignment="Right" FontSize="10" FontFamily="Microsoft JhengHei UI" Foreground="#0AC8B9" Text="—"/>
            </Grid>
            <TextBlock x:Name="SessTitle" Margin="0,3,0,0" FontFamily="Microsoft JhengHei UI" FontSize="11.5" Foreground="#F0E6D2"
                       TextTrimming="CharacterEllipsis" Text="—"/>
            <Grid Margin="0,4,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock x:Name="SessCost" Text="$0.00" FontFamily="Georgia" FontSize="24" FontWeight="Bold" Foreground="#F0E6D2">
                  <TextBlock.Effect><DropShadowEffect Color="#C8AA6E" BlurRadius="8" ShadowDepth="0" Opacity="0.45"/></TextBlock.Effect>
                </TextBlock>
                <TextBlock Text="等值 API 花費" Style="{StaticResource Lbl}" FontSize="9.5"/>
              </StackPanel>
              <StackPanel Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center">
                <TextBlock x:Name="SessModel" Style="{StaticResource Lbl}" HorizontalAlignment="Right" Foreground="#0AC8B9" Text="—"/>
                <TextBlock x:Name="SessTok" Style="{StaticResource Lbl}" HorizontalAlignment="Right" Text="—"/>
                <TextBlock x:Name="SessCtx" Style="{StaticResource Lbl}" HorizontalAlignment="Right" Text="—"/>
              </StackPanel>
            </Grid>
          </StackPanel>

          <!-- 多任務 -->
          <Rectangle x:Name="OrnT" Height="1" Margin="0,8,0,6" Fill="{StaticResource Rule}"/>
          <StackPanel x:Name="SecTasks">
            <Grid>
              <TextBlock Text="任務" Style="{StaticResource Sec}"/>
              <TextBlock x:Name="TaskSummary" HorizontalAlignment="Right" Style="{StaticResource Lbl}" FontSize="10" Text="—"/>
            </Grid>
            <StackPanel x:Name="TaskList" Margin="0,3,0,0"/>
          </StackPanel>

          <Rectangle x:Name="Orn1" Height="1" Margin="0,8,0,6" Fill="{StaticResource Rule}"/>

          <!-- 剩餘額度 -->
          <StackPanel>
            <TextBlock x:Name="QuotaTitle" Text="剩餘額度" Style="{StaticResource Sec}"/>
            <Grid Margin="0,4,0,2">
              <TextBlock Text="5 小時視窗" Style="{StaticResource Lbl}"/>
              <TextBlock x:Name="BlockPct" HorizontalAlignment="Right" FontFamily="Georgia" FontWeight="Bold" FontSize="12" Foreground="#F0E6D2" Text="—"/>
            </Grid>
            <Border Height="8" BorderBrush="#463714" BorderThickness="1" Background="#0A1A24">
              <Grid x:Name="BlockBar">
                <Grid.ColumnDefinitions><ColumnDefinition Width="0*"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions>
                <Border x:Name="BlockFill"><Border.Effect><DropShadowEffect x:Name="BlockGlow" Color="#0AC8B9" BlurRadius="8" ShadowDepth="0" Opacity="0.8"/></Border.Effect></Border>
              </Grid>
            </Border>
            <TextBlock x:Name="BlockInfo" Margin="0,3,0,0" Style="{StaticResource Lbl}" FontSize="10" Text="—"/>

            <Grid Margin="0,7,0,2">
              <TextBlock Text="本週" Style="{StaticResource Lbl}"/>
              <TextBlock x:Name="WeekPct" HorizontalAlignment="Right" FontFamily="Georgia" FontWeight="Bold" FontSize="12" Foreground="#F0E6D2" Text="—"/>
            </Grid>
            <Border Height="8" BorderBrush="#463714" BorderThickness="1" Background="#0A1A24">
              <Grid x:Name="WeekBar">
                <Grid.ColumnDefinitions><ColumnDefinition Width="0*"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions>
                <Border x:Name="WeekFill"><Border.Effect><DropShadowEffect x:Name="WeekGlow" Color="#0AC8B9" BlurRadius="8" ShadowDepth="0" Opacity="0.8"/></Border.Effect></Border>
              </Grid>
            </Border>
            <TextBlock x:Name="WeekInfo" Margin="0,3,0,0" Style="{StaticResource Lbl}" FontSize="10" Text="—"/>
          </StackPanel>

          <Rectangle x:Name="Orn2" Height="1" Margin="0,8,0,6" Fill="{StaticResource Rule}"/>

          <!-- 活動統計 -->
          <StackPanel x:Name="SecStats">
            <TextBlock Text="活動統計" Style="{StaticResource Sec}"/>
            <UniformGrid Columns="3" Margin="0,5,0,0">
              <StackPanel><TextBlock x:Name="TodayCost" Style="{StaticResource Val}" Text="—"/><TextBlock Text="今日花費" Style="{StaticResource Lbl}" FontSize="9.5"/></StackPanel>
              <StackPanel HorizontalAlignment="Center"><TextBlock x:Name="TodayReq" Style="{StaticResource Val}" HorizontalAlignment="Center" Text="—"/><TextBlock Text="今日請求" Style="{StaticResource Lbl}" FontSize="9.5" HorizontalAlignment="Center"/></StackPanel>
              <StackPanel HorizontalAlignment="Right"><TextBlock x:Name="TodaySess" Style="{StaticResource Val}" HorizontalAlignment="Right" Text="—"/><TextBlock Text="今日對話" Style="{StaticResource Lbl}" FontSize="9.5" HorizontalAlignment="Right"/></StackPanel>
            </UniformGrid>
            <UniformGrid x:Name="ToolGrid" Columns="4" Margin="0,8,0,0">
              <StackPanel><TextBlock x:Name="ToolTotal" Style="{StaticResource Val}" FontSize="12.5" Text="—"/><TextBlock Text="工具呼叫" Style="{StaticResource Lbl}" FontSize="9"/></StackPanel>
              <StackPanel x:Name="ToolMcpBox" HorizontalAlignment="Center"><TextBlock x:Name="ToolMcp" Style="{StaticResource Val}" FontSize="12.5" Foreground="#0AC8B9" HorizontalAlignment="Center" Text="—"/><TextBlock Text="MCP" Style="{StaticResource Lbl}" FontSize="9" HorizontalAlignment="Center"/></StackPanel>
              <StackPanel x:Name="ToolSkillBox" HorizontalAlignment="Center"><TextBlock x:Name="ToolSkill" Style="{StaticResource Val}" FontSize="12.5" Foreground="#C8AA6E" HorizontalAlignment="Center" Text="—"/><TextBlock Text="Skills" Style="{StaticResource Lbl}" FontSize="9" HorizontalAlignment="Center"/></StackPanel>
              <StackPanel x:Name="ToolAgentBox" HorizontalAlignment="Right"><TextBlock x:Name="ToolAgent" Style="{StaticResource Val}" FontSize="12.5" Foreground="#CDBE91" HorizontalAlignment="Right" Text="—"/><TextBlock Text="子代理" Style="{StaticResource Lbl}" FontSize="9" HorizontalAlignment="Right"/></StackPanel>
            </UniformGrid>
            <Grid x:Name="Bars" Height="30" Margin="0,8,0,0"/>
            <Grid x:Name="BarLabels" Margin="0,2,0,0"/>
          </StackPanel>

          <TextBlock x:Name="Footer" Margin="0,7,0,0" FontSize="9" Foreground="#5B5A56" FontFamily="Microsoft JhengHei UI" Text="讀取中…"/>
        </StackPanel>
      </Border>
    </Border>

    <!-- 角落鑽石 -->
    <Rectangle Width="6" Height="6" Fill="#C8AA6E" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="-2,-2,0,0">
      <Rectangle.RenderTransform><RotateTransform Angle="45" CenterX="3" CenterY="3"/></Rectangle.RenderTransform></Rectangle>
    <Rectangle Width="6" Height="6" Fill="#C8AA6E" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-2,-2,0">
      <Rectangle.RenderTransform><RotateTransform Angle="45" CenterX="3" CenterY="3"/></Rectangle.RenderTransform></Rectangle>
    <Rectangle Width="6" Height="6" Fill="#C8AA6E" HorizontalAlignment="Left" VerticalAlignment="Bottom" Margin="-2,0,0,-2">
      <Rectangle.RenderTransform><RotateTransform Angle="45" CenterX="3" CenterY="3"/></Rectangle.RenderTransform></Rectangle>
    <Rectangle Width="6" Height="6" Fill="#C8AA6E" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,-2,-2">
      <Rectangle.RenderTransform><RotateTransform Angle="45" CenterX="3" CenterY="3"/></Rectangle.RenderTransform></Rectangle>
  </Grid>
  </Grid>

  <!-- 血條模式：生命 = 5 小時額度，魔力 = 每週額度，等級框 = 重置倒數 -->
  <Grid x:Name="MiniRoot" Margin="6" Visibility="Collapsed" Background="#01000000" ToolTipService.InitialShowDelay="250">
    <StackPanel>
      <TextBlock x:Name="MiniName" Text="Claude" HorizontalAlignment="Center" MaxWidth="190" Margin="0,0,0,1"
                 FontFamily="Microsoft JhengHei UI" FontSize="11" FontWeight="Bold" Foreground="#F0E6D2" TextTrimming="CharacterEllipsis">
        <TextBlock.Effect><DropShadowEffect Color="#000000" BlurRadius="3" ShadowDepth="1" Opacity="1"/></TextBlock.Effect>
      </TextBlock>
      <Border Background="#F0010A13" BorderBrush="#000000" BorderThickness="1" Padding="1">
        <Border.Effect><DropShadowEffect Color="#000000" BlurRadius="6" ShadowDepth="1" Opacity="0.8"/></Border.Effect>
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <Border x:Name="MiniLevelBox" Width="22" Height="21" Margin="0,0,1,0" BorderBrush="#C8AA6E" BorderThickness="1">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                <GradientStop Color="#1E2328" Offset="0"/><GradientStop Color="#010A13" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <TextBlock x:Name="MiniLevel" Text="—" HorizontalAlignment="Center" VerticalAlignment="Center"
                       FontFamily="Georgia" FontWeight="Bold" FontSize="9.5" Foreground="#F0E6D2"/>
          </Border>
          <StackPanel Grid.Column="1" VerticalAlignment="Center">
            <Grid x:Name="HpBox" Width="164" Height="14" Background="#141414" ClipToBounds="True">
              <Border x:Name="HpTrail" HorizontalAlignment="Left" Width="0" Background="#E8D9A0"/>
              <Border x:Name="HpFill" HorizontalAlignment="Left" Width="0"/>
              <Canvas x:Name="HpTicks"/>
              <Rectangle Height="5" VerticalAlignment="Top" Fill="#FFFFFF" Opacity="0.16"/>
              <TextBlock x:Name="HpText" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-1,0,0"
                         FontFamily="Arial" FontWeight="Bold" FontSize="9.5" Foreground="#FFFFFF" Text="—">
                <TextBlock.Effect><DropShadowEffect Color="#000000" BlurRadius="2" ShadowDepth="0.8" Opacity="1"/></TextBlock.Effect>
              </TextBlock>
            </Grid>
            <Grid Width="164" Height="5" Margin="0,1,0,0" Background="#141414" ClipToBounds="True">
              <Border x:Name="MpFill" HorizontalAlignment="Left" Width="0">
                <Border.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                    <GradientStop Color="#7CC4FF" Offset="0"/><GradientStop Color="#2F7FE0" Offset="0.5"/><GradientStop Color="#1A4C9C" Offset="1"/>
                  </LinearGradientBrush>
                </Border.Background>
              </Border>
            </Grid>
          </StackPanel>
        </Grid>
      </Border>
    </StackPanel>
  </Grid>
  </Grid>
</Window>
'@

function Load-Xaml([xml]$x) {
  $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
  $names = @{}
  $x.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
    $n = $_.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1
    $names[$n.Value] = $w.FindName($n.Value)
  }
  return @($w, $names)
}
$win, $ui = Load-Xaml $xaml

function New-Brush([string]$c) { $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($c)); $b.Freeze(); $b }
function New-Grad([string]$a, [string]$b) {
  $g = New-Object Windows.Media.LinearGradientBrush ([Windows.Media.ColorConverter]::ConvertFromString($a)), ([Windows.Media.ColorConverter]::ConvertFromString($b)), 0
  $g.Freeze(); $g
}
function New-VGrad([string[]]$c) {
  $g = New-Object Windows.Media.LinearGradientBrush
  $g.StartPoint = '0,0'; $g.EndPoint = '0,1'
  for ($i = 0; $i -lt $c.Count; $i++) { $g.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.ColorConverter]::ConvertFromString($c[$i])), ($i / ($c.Count - 1)))) }
  $g.Freeze(); $g
}
$GradBlue = New-Grad '#005A82' '#0AC8B9'
$GradGold = New-Grad '#785A28' '#F0E6D2'
$GradRed  = New-Grad '#7A1E28' '#E84057'
$C = @{
  Blue = New-Brush '#0AC8B9'; Orange = New-Brush '#F0A030'; Dim = New-Brush '#5B5A56'; Grey = New-Brush '#A09B8C'
  Light = New-Brush '#F0E6D2'; Ice = New-Brush '#CDFAFA'; GoldDark = New-Brush '#785A28'
}

# 7 日長條圖
$BarFills = @()
$dayNames = '日', '一', '二', '三', '四', '五', '六'
for ($i = 0; $i -lt 7; $i++) {
  $ui.Bars.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
  $ui.BarLabels.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
  $b = New-Object Windows.Controls.Border
  $b.VerticalAlignment = 'Bottom'; $b.Margin = '4,0,4,0'; $b.Height = 1
  [Windows.Controls.Grid]::SetColumn($b, $i); [void]$ui.Bars.Children.Add($b)
  $BarFills += $b
  $t = New-Object Windows.Controls.TextBlock
  $t.HorizontalAlignment = 'Center'; $t.FontSize = 9; $t.Foreground = $C.Dim
  $t.FontFamily = 'Microsoft JhengHei UI'
  [Windows.Controls.Grid]::SetColumn($t, $i); [void]$ui.BarLabels.Children.Add($t)
}

function Set-Bar($bar, $fill, $glow, [double]$pct) {
  $p = [math]::Max(0.0, [math]::Min(1.0, $pct))
  $bar.ColumnDefinitions[0].Width = New-Object Windows.GridLength($p, 'Star')
  $bar.ColumnDefinitions[1].Width = New-Object Windows.GridLength((1 - $p), 'Star')
  if ($p -ge 0.9) { $fill.Background = $GradRed; $glow.Color = '#E84057' }
  elseif ($p -ge 0.7) { $fill.Background = $GradGold; $glow.Color = '#C8AA6E' }
  else { $fill.Background = $GradBlue; $glow.Color = '#0AC8B9' }
}

# 血條：每 10% 一條短刻度、50% 一條長刻度，生命值依剩餘量變色
$HpWidth = 164.0
for ($i = 1; $i -lt 10; $i++) {
  $r = New-Object Windows.Shapes.Rectangle
  $r.Width = 1; $r.Height = if ($i -eq 5) { 14 } else { 6 }
  $r.Fill = New-Brush '#B0000000'
  [Windows.Controls.Canvas]::SetLeft($r, [math]::Round($HpWidth * $i / 10))
  [void]$ui.HpTicks.Children.Add($r)
}
$HpGreen  = New-VGrad '#7BEA5E', '#3FB82B', '#1E6E14'
$HpYellow = New-VGrad '#F5E27A', '#D9B82E', '#7A6414'
$HpRed    = New-VGrad '#FF7A7A', '#D8323F', '#6E1218'
$script:HpLast = -1.0

function Set-Hp([double]$remain) {
  $remain = [math]::Max(0.0, [math]::Min(1.0, $remain))
  $w = [math]::Round($HpWidth * $remain, 1)
  $ui.HpFill.Background = if ($remain -gt 0.5) { $HpGreen } elseif ($remain -gt 0.25) { $HpYellow } else { $HpRed }
  $ui.HpFill.Width = $w
  if ($script:HpLast -ge 0 -and $w -lt $script:HpLast) {
    # 扣血時保留淡黃色殘影，稍後才縮回（遊戲中受傷的效果）
    $ui.HpTrail.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $null)
    $ui.HpTrail.Width = [math]::Max($ui.HpTrail.Width, $script:HpLast)
    $a = New-Object Windows.Media.Animation.DoubleAnimation $w, ([Windows.Duration][TimeSpan]::FromMilliseconds(600))
    $a.BeginTime = [TimeSpan]::FromMilliseconds(500)
    $ui.HpTrail.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $a)
  } elseif ($w -ne $script:HpLast) {
    $ui.HpTrail.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $null)
    $ui.HpTrail.Width = $w
  }
  $script:HpLast = $w
}

# ================================================================ 小通知（英雄聯盟風格的 toast）
$script:Toasts = New-Object System.Collections.ArrayList
function Show-Toast([string]$kind, [string]$title, [string]$msg) {
  if ($Debugging) { return }
  $accent = switch ($kind) { 'done' { '#0AC8B9' } 'wait' { '#F0A030' } 'quota' { '#E84057' } default { '#C8AA6E' } }
  $icon   = switch ($kind) { 'done' { '✔' } 'wait' { '!' } 'quota' { '♥' } default { '◆' } }
  [xml]$tx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="272" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize" Opacity="0" Cursor="Hand">
  <Border Margin="6" BorderThickness="1.5" Background="#F5091428">
    <Border.BorderBrush>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#C8AA6E" Offset="0"/><GradientStop Color="#785A28" Offset="1"/></LinearGradientBrush>
    </Border.BorderBrush>
    <Border.Effect><DropShadowEffect Color="#000000" BlurRadius="12" ShadowDepth="0" Opacity="0.8"/></Border.Effect>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="3"/><ColumnDefinition Width="34"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Rectangle Fill="$accent"/>
      <Grid Grid.Column="1" Width="20" Height="20" VerticalAlignment="Center">
        <Rectangle Width="14" Height="14" Stroke="$accent" StrokeThickness="1.5" Fill="#010A13">
          <Rectangle.RenderTransform><RotateTransform Angle="45" CenterX="7" CenterY="7"/></Rectangle.RenderTransform>
          <Rectangle.Effect><DropShadowEffect Color="$accent" BlurRadius="8" ShadowDepth="0" Opacity="0.9"/></Rectangle.Effect>
        </Rectangle>
        <TextBlock Text="$icon" Foreground="$accent" FontWeight="Bold" FontSize="10" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Grid>
      <StackPanel Grid.Column="2" Margin="2,8,10,9">
        <TextBlock x:Name="T" FontFamily="Microsoft JhengHei UI" FontWeight="Bold" FontSize="12" Foreground="#F0E6D2"/>
        <TextBlock x:Name="M" FontFamily="Microsoft JhengHei UI" FontSize="10.5" Foreground="#A09B8C" TextWrapping="Wrap" Margin="0,2,0,0" MaxHeight="44"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
"@
  $t, $n = Load-Xaml $tx
  $n.T.Text = $title; $n.M.Text = $msg
  $t.Add_MouseLeftButtonUp({ param($sd) $sd.Close() })
  $t.Add_Closed({ param($sd) $script:Toasts.Remove($sd); Restack-Toasts })
  $t.Show()
  $t.UpdateLayout()
  [void]$script:Toasts.Add($t)
  Restack-Toasts
  $t.BeginAnimation([Windows.Window]::OpacityProperty, (New-Object Windows.Media.Animation.DoubleAnimation 0.0, 1.0, ([Windows.Duration][TimeSpan]::FromMilliseconds(220))))
  $timer = New-Object Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromSeconds([math]::Max(2.0, [double]$Config.notifySeconds))
  $timer.Tag = $t
  $timer.Add_Tick({ param($sd) $sd.Stop(); $sd.Tag.Close() })
  $timer.Start()
  if ($Config.notifySound) {
    if ($kind -eq 'done') { [System.Media.SystemSounds]::Asterisk.Play() } else { [System.Media.SystemSounds]::Exclamation.Play() }
  }
}
# 通知疊在小工具上方（空間不夠時放下方），右側對齊
function Restack-Toasts {
  $off = 0.0
  for ($i = $script:Toasts.Count - 1; $i -ge 0; $i--) {
    $t = $script:Toasts[$i]
    $h = $t.ActualHeight
    $left = [math]::Min($win.Left + $win.ActualWidth - $t.ActualWidth, $wa.Right - $t.ActualWidth)
    $above = $win.Top - $off - $h
    $t.Left = [math]::Max($wa.Left, $left)
    $t.Top = if ($above -ge $wa.Top) { $above } else { $win.Top + $win.ActualHeight + $off }
    $off += $h
  }
}

# ================================================================ 顯示模式
function Apply-Mode {
  if ($Config.mode -notin 'full', 'compact', 'mini') { $Config.mode = 'full' }
  # 若視窗靠在螢幕右側 / 下方，切換大小時固定右下角，不會跑出畫面
  $right = $win.Left + $win.ActualWidth; $bottom = $win.Top + $win.ActualHeight
  $anchorR = $win.IsLoaded -and ($win.Left + $win.ActualWidth / 2) -gt ($wa.Left + $wa.Width / 2)
  $anchorB = $win.IsLoaded -and ($win.Top + $win.ActualHeight / 2) -gt ($wa.Top + $wa.Height / 2)

  $mini = $Config.mode -eq 'mini'; $full = $Config.mode -eq 'full'
  $ui.FullRoot.Visibility = if ($mini) { 'Collapsed' } else { 'Visible' }
  $ui.MiniRoot.Visibility = if ($mini) { 'Visible' } else { 'Collapsed' }
  $vis = { param($on) if ($on) { 'Visible' } else { 'Collapsed' } }
  $ui.SecSession.Visibility = & $vis $full
  $ui.OrnT.Visibility = & $vis ($full -and $Config.showTasks)
  $ui.SecTasks.Visibility = & $vis ($full -and $Config.showTasks)
  $ui.Orn1.Visibility = & $vis $full
  $ui.Orn2.Visibility = & $vis ($full -and $Config.showStats)
  $ui.SecStats.Visibility = & $vis ($full -and $Config.showStats)
  $ui.ToolGrid.Visibility = & $vis $Config.showTools
  $ui.BtnCompact.Text = if ($Config.mode -eq 'compact') { '◆' } else { '◇' }

  if ($win.IsLoaded) {
    $win.UpdateLayout()
    if ($anchorR) { $win.Left = $right - $win.ActualWidth }
    if ($anchorB) { $win.Top = $bottom - $win.ActualHeight }
    $Config.left = [math]::Round($win.Left); $Config.top = [math]::Round($win.Top)
  }
  foreach ($m in $ModeItems) { $m.IsChecked = ($m.Tag -eq $Config.mode) }
  if (-not $Debugging) { Save-Config }
}
function Set-Mode([string]$m) { $Config.mode = $m; Apply-Mode }

# ================================================================ 任務列
function New-TaskRow($t) {
  $g = New-Object Windows.Controls.Grid
  $g.Margin = '0,2,0,2'
  foreach ($w in 'Auto', '*', 'Auto') {
    $cd = New-Object Windows.Controls.ColumnDefinition
    $cd.Width = if ($w -eq '*') { New-Object Windows.GridLength(1, 'Star') } else { [Windows.GridLength]::Auto }
    $g.ColumnDefinitions.Add($cd)
  }
  $dot = New-Object Windows.Controls.TextBlock
  $dot.FontSize = 10; $dot.Margin = '0,1,6,0'; $dot.VerticalAlignment = 'Top'
  switch ($t.Status) {
    'waiting' { $dot.Text = '◆'; $dot.Foreground = $C.Orange }
    'busy'    { $dot.Text = '●'; $dot.Foreground = $C.Blue }
    default   { $dot.Text = '○'; $dot.Foreground = $C.Dim }
  }
  [void]$g.Children.Add($dot)

  $sp = New-Object Windows.Controls.StackPanel
  [Windows.Controls.Grid]::SetColumn($sp, 1)
  $name = New-Object Windows.Controls.TextBlock
  $name.Text = $t.Title; $name.FontSize = 11; $name.FontFamily = 'Microsoft JhengHei UI'
  $name.Foreground = if ($t.Status -eq 'idle') { $C.Grey } else { $C.Light }
  $name.TextTrimming = 'CharacterEllipsis'; $name.ToolTip = $t.Title
  $sub = New-Object Windows.Controls.TextBlock
  $sub.FontSize = 9.5; $sub.FontFamily = 'Microsoft JhengHei UI'; $sub.TextTrimming = 'CharacterEllipsis'
  $now = Get-Date
  switch ($t.Status) {
    'waiting' { $sub.Text = '等待你確認' + $(if ($t.WaitingFor) { '：' + $t.WaitingFor } else { '' }); $sub.Foreground = $C.Orange }
    'busy'    {
      $sub.Text = if ($t.Tool) { '▸ ' + $t.Tool.Label } else { '▸ 思考中…' }
      $sub.Text += ' · ' + (Fmt-Span ($now - $t.Since))
      $sub.Foreground = $(if ($t.Tool -and $t.Tool.Kind -eq 'mcp') { $C.Blue } elseif ($t.Tool -and $t.Tool.Kind -eq 'skill') { New-Brush '#C8AA6E' } else { $C.Ice })
    }
    default   { $sub.Text = '閒置 ' + (Fmt-Span ($now - $t.Since)); $sub.Foreground = $C.Dim }
  }
  $sub.ToolTip = $sub.Text
  [void]$sp.Children.Add($name); [void]$sp.Children.Add($sub)
  [void]$g.Children.Add($sp)

  $cost = New-Object Windows.Controls.TextBlock
  $cost.Text = Fmt-Money $t.Cost; $cost.FontFamily = 'Georgia'; $cost.FontSize = 11; $cost.FontWeight = 'Bold'
  $cost.Foreground = $C.Light; $cost.Margin = '6,0,0,0'; $cost.VerticalAlignment = 'Top'
  [Windows.Controls.Grid]::SetColumn($cost, 2)
  [void]$g.Children.Add($cost)
  return $g
}

# ================================================================ 通知判斷
$PrevStatus = @{}; $BusySince = @{}
$script:Primed = $false
$script:QuotaWarned = $null
$script:LastPlan = $null
function Check-Notifications($s) {
  foreach ($t in $s.Tasks) {
    $prev = $PrevStatus[$t.Sid]
    $working = $t.Status -in 'busy', 'waiting'
    if ($working -and $prev -notin 'busy', 'waiting') { $BusySince[$t.Sid] = Get-Date }
    if ($script:Primed) {
      if ($t.Status -eq 'idle' -and $prev -in 'busy', 'waiting' -and $Config.notifyDone) {
        $dur = if ($BusySince[$t.Sid]) { (Get-Date) - $BusySince[$t.Sid] } else { [TimeSpan]::Zero }
        if ($dur.TotalSeconds -ge [double]$Config.notifyMinTaskSeconds) {
          Show-Toast 'done' '任務完成' ('{0}{1}歷時 {2} · 累計 {3}' -f $t.Title, "`n", (Fmt-Span $dur), (Fmt-Money $t.Cost))
        }
      }
      if ($t.Status -eq 'waiting' -and $prev -ne 'waiting' -and $Config.notifyWaiting) {
        Show-Toast 'wait' '需要你的確認' ($t.Title + $(if ($t.WaitingFor) { "`n" + $t.WaitingFor } else { "`n請回到 Claude 同意或回覆" }))
      }
    }
    $PrevStatus[$t.Sid] = $t.Status
  }

  if ($Config.notifyQuota -and $null -ne $s.Block.Used -and $s.Block.Active) {
    $remain = 100 - $s.Block.Used
    if ($remain -le [double]$Config.quotaWarnPct -and $script:QuotaWarned -ne $s.Block.Start) {
      $script:QuotaWarned = $s.Block.Start
      if ($script:Primed) { Show-Toast 'quota' '5 小時額度偏低' ('剩約 {0:0}% · {1} 後重置' -f [math]::Max(0.0, $remain), (Fmt-Span $s.Block.Reset)) }
    }
  }

  if ($script:Primed -and $script:LastPlan -and $s.Plan -ne $script:LastPlan) {
    Show-Toast 'info' '方案已切換' ("偵測到 {0}，已套用對應額度" -f $s.Plan)
  }
  $script:LastPlan = $s.Plan
  $script:Primed = $true
}

# ================================================================ 畫面更新
$script:LastStats = $null
function Refresh-UI {
  try {
    Detect-Plan
    Scan-Files
    $s = Get-Stats
    $script:LastStats = $s

    if ($s.Session) {
      $x = $s.Session
      $ui.SessTitle.Text = $x.Title; $ui.SessTitle.ToolTip = $x.Title
      $ui.SessCost.Text = Fmt-Money $x.Cost
      $ui.SessModel.Text = $x.Model -replace '^claude-', ''
      $ui.SessTok.Text = '{0} 請求 · {1} tokens' -f $x.Req, (Fmt-Tok $x.Tok)
      $ui.SessCtx.Text = '上下文 {0} · 歷時 {1}' -f (Fmt-Tok $x.Ctx), (Fmt-Span $x.Dur)
      switch ($x.Status) {
        'busy'    { $ui.SessState.Text = '● 進行中'; $ui.SessState.Foreground = $C.Blue; $ui.Gem.Opacity = 0.95 }
        'waiting' { $ui.SessState.Text = '◆ 等待確認'; $ui.SessState.Foreground = $C.Orange; $ui.Gem.Opacity = 0.95 }
        default   { $ui.SessState.Text = '○ 閒置 ' + (Fmt-Span $x.Idle); $ui.SessState.Foreground = $C.Dim; $ui.Gem.Opacity = 0.25 }
      }
    } else { $ui.SessTitle.Text = '尚無對話紀錄' }

    # 任務清單
    $ui.TaskList.Children.Clear()
    $max = [int]$Config.maxTasks
    $shown = @($s.Tasks | Select-Object -First $max)
    foreach ($t in $shown) { [void]$ui.TaskList.Children.Add((New-TaskRow $t)) }
    if ($s.Tasks.Count -eq 0) {
      $e = New-Object Windows.Controls.TextBlock
      $e.Text = '沒有執行中的 Claude Code 工作階段'; $e.FontSize = 10; $e.Foreground = $C.Dim; $e.FontFamily = 'Microsoft JhengHei UI'
      [void]$ui.TaskList.Children.Add($e)
    } elseif ($s.Tasks.Count -gt $max) {
      $e = New-Object Windows.Controls.TextBlock
      $e.Text = '還有 {0} 個…' -f ($s.Tasks.Count - $max); $e.FontSize = 9.5; $e.Foreground = $C.Dim; $e.FontFamily = 'Microsoft JhengHei UI'
      [void]$ui.TaskList.Children.Add($e)
    }
    $parts = @()
    if ($s.Busy) { $parts += "$($s.Busy) 執行中" }
    if ($s.Waiting.Count) { $parts += "$($s.Waiting.Count) 待確認" }
    $parts += "共 $($s.Tasks.Count)"
    $ui.TaskSummary.Text = $parts -join ' · '

    # 額度
    $bl = $s.Limits.block; $wl = $s.Limits.weekly
    $planLabel = $s.Plan + $(if ($Config.plan -eq 'auto') { '（自動）' } else { '' })
    $ui.QuotaTitle.Text = '剩餘額度 · ' + $planLabel
    $calTag = {
      param($src)
      switch ($src) {
        'official' { ' · 官方 ' + $(if ($s.Official) { $m = [int]((Get-Date) - $s.Official.At).TotalMinutes; if ($m -lt 1) { '剛剛' } else { "$m 分前" } } else { '' }) }
        'manual'   { ' · 已校正' }
        default    { ' · 估算' }
      }
    }
    if ($bl -gt 0) {
      $bp = $s.Block.Used / 100
      Set-Bar $ui.BlockBar $ui.BlockFill $ui.BlockGlow $bp
      $ui.BlockPct.Text = '剩 {0:0}%' -f (100 - $s.Block.Used)
      $ui.BlockInfo.Text = if ($s.Block.Active) { '本機 {0} · {1} 後重置{2}' -f (Fmt-Money $s.Block.Cost), (Fmt-Span $s.Block.Reset), (& $calTag $s.Block.Source) } else { '視窗未啟動 · 下則訊息開始計時' }
    } else {
      $bp = 0; Set-Bar $ui.BlockBar $ui.BlockFill $ui.BlockGlow 0
      $ui.BlockPct.Text = Fmt-Money $s.Block.Cost
      $ui.BlockInfo.Text = '不限額度 / 按用量計費'
    }
    if ($wl -gt 0) {
      $wp = $s.Week.Used / 100
      Set-Bar $ui.WeekBar $ui.WeekFill $ui.WeekGlow $wp
      $ui.WeekPct.Text = '剩 {0:0}%' -f (100 - $s.Week.Used)
      $ui.WeekInfo.Text = '本機 {0} · {1} 後重置{2}' -f (Fmt-Money $s.Week.Cost), (Fmt-Span $s.Week.Reset), (& $calTag $s.Week.Source)
    } else {
      $wp = 0; Set-Bar $ui.WeekBar $ui.WeekFill $ui.WeekGlow 0
      $ui.WeekPct.Text = Fmt-Money $s.Week.Cost
      $ui.WeekInfo.Text = '本週花費'
    }

    # 統計
    $ui.TodayCost.Text = Fmt-Money $s.Today.Cost
    $ui.TodayReq.Text = $s.Today.Req
    $ui.TodaySess.Text = $s.Today.Sess
    $tl = $s.Tools
    $ui.ToolTotal.Text = $tl.Total; $ui.ToolMcp.Text = $tl.mcp; $ui.ToolSkill.Text = $tl.skill; $ui.ToolAgent.Text = $tl.agent
    $top = { param($h) if ($h.Count -eq 0) { '今日尚未使用' } else { ($h.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 6 | ForEach-Object { '{0} × {1}' -f $_.Key, $_.Value }) -join "`n" } }
    $ui.ToolMcpBox.ToolTip = & $top $tl.McpBy
    $ui.ToolSkillBox.ToolTip = & $top $tl.SkillBy
    $ui.ToolAgentBox.ToolTip = & $top $tl.AgentBy
    $mx = ($s.Days | Measure-Object -Maximum).Maximum
    for ($i = 0; $i -lt 7; $i++) {
      $BarFills[$i].Height = if ($mx -gt 0) { [math]::Max(1.0, 30.0 * $s.Days[$i] / $mx) } else { 1 }
      $BarFills[$i].ToolTip = Fmt-Money $s.Days[$i]
      $BarFills[$i].Background = if ($i -eq 6) { $GradBlue } else { $C.GoldDark }
      $ui.BarLabels.Children[$i].Text = $dayNames[[int]$s.Now.AddDays($i - 6).DayOfWeek]
    }
    $ui.Footer.Text = '更新於 {0} · 本機 Claude Code 紀錄 · {1}' -f $s.Now.ToString('HH:mm:ss'), $(if ($s.Official) { '額度來自官方' } else { '額度為估算' })

    # 血條模式
    $hp = if ($bl -gt 0) { [math]::Max(0.0, 1 - $bp) } else { 1.0 }
    Set-Hp $hp
    $ui.MpFill.Width = [math]::Round($HpWidth * $(if ($wl -gt 0) { [math]::Max(0.0, [math]::Min(1.0, 1 - $wp)) } else { 1.0 }), 1)
    $ui.HpText.Text = if ($bl -gt 0) { '{0:0} / 100' -f ($hp * 100) } else { Fmt-Money $s.Block.Cost }
    if ($bl -le 0) { $ui.MiniLevel.Text = '∞' }
    elseif ($s.Block.Active) {
      $r = $s.Block.Reset
      $ui.MiniLevel.Text = if ($r.TotalHours -ge 1) { '{0}h' -f [int][math]::Floor($r.TotalHours) } else { '{0}m' -f [int][math]::Ceiling($r.TotalMinutes) }
    } else { $ui.MiniLevel.Text = '—' }
    if ($s.Waiting.Count) {
      $ui.MiniName.Text = '◆ 待確認 · ' + $s.Waiting[0].Title; $ui.MiniName.Foreground = $C.Orange
      $ui.MiniLevelBox.BorderBrush = $C.Orange
    } elseif ($s.Session) {
      $ui.MiniName.Text = $s.Session.Title + $(if ($s.Busy -gt 1) { "  ⚔$($s.Busy)" } else { '' })
      $ui.MiniName.Foreground = if ($s.Session.Status -ne 'idle') { $C.Ice } else { $C.Grey }
      $ui.MiniLevelBox.BorderBrush = New-Brush '#C8AA6E'
    }
    $tip = @(
      ('{0} · {1}' -f $planLabel, $ui.SessTitle.Text)
      ('對話花費  {0}' -f $ui.SessCost.Text)
      ('5 小時   {0} · {1}' -f $ui.BlockPct.Text, $ui.BlockInfo.Text)
      ('本週     {0} · {1}' -f $ui.WeekPct.Text, $ui.WeekInfo.Text)
      ('任務     {0}' -f $ui.TaskSummary.Text)
      ('今日     {0} · {1} 請求 · MCP {2} · Skills {3}' -f (Fmt-Money $s.Today.Cost), $s.Today.Req, $tl.mcp, $tl.skill)
      '雙擊切回完整模式'
    ) -join "`n"
    $ui.MiniRoot.ToolTip = $tip

    Learn-FromOfficial $s
    Check-Notifications $s
    if ($win.IsLoaded) { $win.UpdateLayout(); Restack-Toasts }
  } catch {
    $ui.Footer.Text = '錯誤：' + $_.Exception.Message
  }
}

# ================================================================ 設定視窗
function Show-Settings {
  [xml]$sx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Nexus 設定" Width="372" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ResizeMode="NoResize" WindowStartupLocation="CenterScreen"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Microsoft JhengHei UI"/><Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Foreground" Value="#A09B8C"/><Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="H" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Microsoft JhengHei UI"/><Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="12"/><Setter Property="Foreground" Value="#C8AA6E"/><Setter Property="Margin" Value="0,10,0,4"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#010A13"/><Setter Property="Foreground" Value="#F0E6D2"/>
      <Setter Property="BorderBrush" Value="#463714"/><Setter Property="CaretBrush" Value="#C8AA6E"/>
      <Setter Property="Padding" Value="4,2"/><Setter Property="Width" Value="64"/><Setter Property="Margin" Value="6,2,0,2"/>
      <Setter Property="FontFamily" Value="Georgia"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#F0E6D2"/><Setter Property="FontFamily" Value="Microsoft JhengHei UI"/>
      <Setter Property="FontSize" Value="11.5"/><Setter Property="Margin" Value="0,3,0,3"/><Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Margin" Value="6,2,0,2"/><Setter Property="FontFamily" Value="Microsoft JhengHei UI"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#F0E6D2"/><Setter Property="FontFamily" Value="Microsoft JhengHei UI"/>
      <Setter Property="FontWeight" Value="Bold"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="8,0,0,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="#1E2328" BorderBrush="#C8AA6E" BorderThickness="1" Padding="18,5">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#2A3A44"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Margin="10" BorderThickness="1.5" Background="#F7091428">
    <Border.BorderBrush>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#C8AA6E" Offset="0"/><GradientStop Color="#785A28" Offset="0.5"/><GradientStop Color="#C8AA6E" Offset="1"/></LinearGradientBrush>
    </Border.BorderBrush>
    <Border.Effect><DropShadowEffect Color="#000000" BlurRadius="16" ShadowDepth="0" Opacity="0.85"/></Border.Effect>
    <StackPanel Margin="16,12,16,14">
      <Grid x:Name="Head" Background="Transparent">
        <TextBlock Text="CLAUDE NEXUS · 設定" FontFamily="Georgia" FontWeight="Bold" FontSize="13" Foreground="#F0E6D2"/>
        <TextBlock x:Name="X" Text="✕" HorizontalAlignment="Right" Foreground="#785A28" Cursor="Hand"/>
      </Grid>
      <Rectangle Height="1" Margin="0,8,0,0">
        <Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#00785A28" Offset="0"/><GradientStop Color="#C8AA6E" Offset="0.5"/><GradientStop Color="#00785A28" Offset="1"/></LinearGradientBrush></Rectangle.Fill>
      </Rectangle>

      <TextBlock Text="方案與額度" Style="{StaticResource H}"/>
      <StackPanel Orientation="Horizontal"><TextBlock Text="方案" Width="86"/><ComboBox x:Name="Plan" Width="150"/></StackPanel>
      <TextBlock x:Name="Detected" Margin="86,0,0,2" FontSize="10" Foreground="#0AC8B9"/>
      <StackPanel Orientation="Horizontal"><TextBlock Text="100% ≈ 5 小時" Width="86"/><TextBlock Text="$"/><TextBox x:Name="Block"/><TextBlock Text="   每週 $" /><TextBox x:Name="Week"/></StackPanel>
      <TextBlock Text="100% 額度約等於多少等值 API 花費；0 = 不限額度。右鍵「校正額度」照抄官方用量頁最準。" FontSize="9.5" Foreground="#5B5A56" TextWrapping="Wrap" Margin="86,0,0,2"/>
      <StackPanel Orientation="Horizontal"><TextBlock Text="每週重置" Width="86"/><ComboBox x:Name="Day" Width="70"/><TextBox x:Name="Hour" Width="54"/><TextBlock Text="（本地時間）"/></StackPanel>

      <TextBlock Text="通知" Style="{StaticResource H}"/>
      <StackPanel Orientation="Horizontal"><CheckBox x:Name="NDone" Content="任務完成時通知，執行超過"/><TextBox x:Name="MinSec" Width="40"/><TextBlock Text=" 秒"/></StackPanel>
      <CheckBox x:Name="NWait" Content="需要同意指令 / 等待輸入時通知"/>
      <StackPanel Orientation="Horizontal"><CheckBox x:Name="NQuota" Content="5 小時額度剩餘低於"/><TextBox x:Name="QPct" Width="40"/><TextBlock Text=" % 時通知"/></StackPanel>
      <StackPanel Orientation="Horizontal"><CheckBox x:Name="NSound" Content="播放音效"/><TextBlock Text="      停留" Margin="0"/><TextBox x:Name="NSec" Width="40"/><TextBlock Text=" 秒"/></StackPanel>

      <TextBlock Text="顯示" Style="{StaticResource H}"/>
      <CheckBox x:Name="STasks" Content="多任務清單"/>
      <StackPanel Orientation="Horizontal" Margin="22,0,0,0"><TextBlock Text="最多顯示"/><TextBox x:Name="MaxT" Width="40"/><TextBlock Text=" 個任務"/></StackPanel>
      <CheckBox x:Name="SStats" Content="活動統計（今日花費、7 日圖表）"/>
      <CheckBox x:Name="STools" Content="工具 / MCP / Skills / 子代理使用次數"/>
      <StackPanel Orientation="Horizontal"><TextBlock Text="更新間隔" Width="86"/><TextBox x:Name="Refresh" Width="40"/><TextBlock Text=" 秒"/></StackPanel>
      <StackPanel Orientation="Horizontal"><TextBlock Text="透明度" Width="86"/><Slider x:Name="Op" Width="170" Minimum="0.4" Maximum="1" VerticalAlignment="Center" Margin="6,0,0,0"/></StackPanel>
      <CheckBox x:Name="Auto" Content="開機自動啟動" Margin="0,8,0,0"/>

      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
        <Button x:Name="Cancel" Content="取消"/>
        <Button x:Name="Save" Content="儲存"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
  $sw, $n = Load-Xaml $sx
  if ($win.IsLoaded) { $sw.Owner = $win }
  [void]$n.Plan.Items.Add('自動偵測'); foreach ($p in $PlanNames) { [void]$n.Plan.Items.Add($p) }
  $dayKeys = 'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'
  foreach ($d in $dayNames) { [void]$n.Day.Items.Add('週' + $d) }

  # 暫存各方案上限，切換下拉選單時顯示對應數字
  $work = @{}; foreach ($k in $Config.limits.Keys) { $work[$k] = @{ block = $Config.limits[$k].block; weekly = $Config.limits[$k].weekly } }
  $state = @{ Cur = $null }
  $planOf = { param($i) if ($i -le 0) { $script:Detected } else { $PlanNames[$i - 1] } }
  $commit = {
    if ($state.Cur) {
      $b = 0.0; $w = 0.0
      if ([double]::TryParse($n.Block.Text, [ref]$b) -and [double]::TryParse($n.Week.Text, [ref]$w)) { $work[$state.Cur] = @{ block = $b; weekly = $w } }
    }
  }
  $load = {
    $pl = & $planOf $n.Plan.SelectedIndex
    $state.Cur = $pl
    $l = $work[$pl]; if (-not $l) { $l = @{ block = 0; weekly = 0 } }
    $n.Block.Text = $l.block; $n.Week.Text = $l.weekly
  }
  $n.Detected.Text = '偵測到的方案：' + $script:Detected
  $n.Plan.SelectedIndex = if ($Config.plan -eq 'auto') { 0 } else { [array]::IndexOf($PlanNames, $Config.plan) + 1 }
  & $load
  $n.Plan.Add_SelectionChanged({ & $commit; & $load })

  $n.Day.SelectedIndex = [array]::IndexOf($dayKeys, [string]$Config.weeklyResetDay)
  $n.Hour.Text = '{0:00}:{1:00}' -f [int]$Config.weeklyResetHour, [int]$Config.weeklyResetMinute
  $n.NDone.IsChecked = [bool]$Config.notifyDone; $n.MinSec.Text = $Config.notifyMinTaskSeconds
  $n.NWait.IsChecked = [bool]$Config.notifyWaiting
  $n.NQuota.IsChecked = [bool]$Config.notifyQuota; $n.QPct.Text = $Config.quotaWarnPct
  $n.NSound.IsChecked = [bool]$Config.notifySound; $n.NSec.Text = $Config.notifySeconds
  $n.STasks.IsChecked = [bool]$Config.showTasks; $n.MaxT.Text = $Config.maxTasks
  $n.SStats.IsChecked = [bool]$Config.showStats; $n.STools.IsChecked = [bool]$Config.showTools
  $n.Refresh.Text = $Config.refreshSeconds
  $n.Op.Value = [double]$Config.opacity
  $n.Op.Add_ValueChanged({ $win.Opacity = $n.Op.Value })
  $n.Auto.IsChecked = Test-Path $StartupLnk

  $n.Head.Add_MouseLeftButtonDown({ try { $sw.DragMove() } catch {} })
  $cancel = { $win.Opacity = [double]$Config.opacity; $sw.Close() }
  $n.X.Add_MouseLeftButtonUp($cancel)
  $n.Cancel.Add_Click($cancel)
  $n.Save.Add_Click({ & $commit; $sw.Tag = 'save'; $sw.Close() })

  if ($SnapshotSettings) {
    $sw.Add_ContentRendered({ Save-Png $sw $SnapshotSettings; $sw.Close() })
  }
  [void]$sw.ShowDialog()
  if ($sw.Tag -ne 'save') { return }

  $num = { param($txt, $def) $v = 0.0; if ([double]::TryParse($txt, [ref]$v)) { $v } else { $def } }
  $Config.plan = if ($n.Plan.SelectedIndex -le 0) { 'auto' } else { $PlanNames[$n.Plan.SelectedIndex - 1] }
  foreach ($k in $work.Keys) { $Config.limits[$k] = $work[$k] }
  if ($n.Day.SelectedIndex -ge 0) { $Config.weeklyResetDay = $dayKeys[$n.Day.SelectedIndex] }
  $tm = [regex]::Match($n.Hour.Text.Trim(), '^(\d{1,2})(?::(\d{2}))?$')
  if ($tm.Success -and [int]$tm.Groups[1].Value -le 23) {
    $Config.weeklyResetHour = [int]$tm.Groups[1].Value
    $Config.weeklyResetMinute = if ($tm.Groups[2].Success) { [math]::Min(59, [int]$tm.Groups[2].Value) } else { 0 }
  }
  $Config.notifyDone = [bool]$n.NDone.IsChecked; $Config.notifyMinTaskSeconds = & $num $n.MinSec.Text 15
  $Config.notifyWaiting = [bool]$n.NWait.IsChecked
  $Config.notifyQuota = [bool]$n.NQuota.IsChecked; $Config.quotaWarnPct = & $num $n.QPct.Text 20
  $Config.notifySound = [bool]$n.NSound.IsChecked; $Config.notifySeconds = & $num $n.NSec.Text 6
  $Config.showTasks = [bool]$n.STasks.IsChecked; $Config.maxTasks = [int](& $num $n.MaxT.Text 4)
  $Config.showStats = [bool]$n.SStats.IsChecked; $Config.showTools = [bool]$n.STools.IsChecked
  $Config.refreshSeconds = [math]::Max(1.0, (& $num $n.Refresh.Text 2))
  $Config.opacity = [math]::Round($n.Op.Value, 2)
  if ([bool]$n.Auto.IsChecked -ne (Test-Path $StartupLnk)) { Set-Autostart ([bool]$n.Auto.IsChecked) }
  $auto.IsChecked = Test-Path $StartupLnk
  $timer.Interval = [TimeSpan]::FromSeconds([double]$Config.refreshSeconds)
  $win.Opacity = [double]$Config.opacity
  Save-Config; Apply-Mode; Refresh-UI
}

# ================================================================ 校正額度
# 記下「官方已用 %」與「當下本機花費」當基準點，之後只把新增花費換算成 % 往上加，
# 所以其他裝置（claude.ai 網頁、手機）先前用掉的額度不會再被算到本機頭上。
# 同一個視窗內第二次校正時，用兩次的差距推算「100% ≈ 多少花費」並存成該方案的換算值。
function Apply-Calibration($blockPct, $blockResetAt, $weekPct, [string]$weekDay, $weekHour, $weekMinute) {
  Scan-Files
  $null = Get-Stats   # 確保 $script:Sorted 是最新的
  $now = Get-Date
  $plan = Get-Plan
  $lim = Get-Limits $plan
  $msgs = @()
  if (-not $Config.calib) { $Config.calib = @{} }

  if ($null -ne $blockPct -and $blockResetAt) {
    $cost = Get-CostBetween $blockResetAt.AddHours(-5) $blockResetAt
    $prev = $Config.calib.block
    if ($prev -and [math]::Abs(($prev.resetAt - $blockResetAt).TotalMinutes) -lt 10 -and ($blockPct - $prev.pct) -ge 5 -and ($cost - $prev.cost) -gt 0.05) {
      $lim.block = [math]::Round(($cost - $prev.cost) / ($blockPct - $prev.pct) * 100, 2)
      $msgs += '5 小時：100% ≈ {0}（依兩次校正推算）' -f (Fmt-Money $lim.block)
    }
    $Config.calib.block = @{ pct = [double]$blockPct; cost = $cost; resetAt = $blockResetAt }
  }

  if ($weekDay) {
    $Config.weeklyResetDay = $weekDay; $Config.weeklyResetHour = [int]$weekHour; $Config.weeklyResetMinute = [int]$weekMinute
  }
  if ($null -ne $weekPct) {
    $ws = Get-WeekStart $now
    $cost = Get-CostBetween $ws $now.AddDays(1)
    $prev = $Config.calib.weekly
    if ($prev -and [math]::Abs(($prev.start - $ws).TotalMinutes) -lt 1 -and ($weekPct - $prev.pct) -ge 3 -and ($cost - $prev.cost) -gt 0.05) {
      $lim.weekly = [math]::Round(($cost - $prev.cost) / ($weekPct - $prev.pct) * 100, 2)
      $msgs += '每週：100% ≈ {0}（依兩次校正推算）' -f (Fmt-Money $lim.weekly)
    }
    $Config.calib.weekly = @{ pct = [double]$weekPct; cost = $cost; start = $ws }
  }
  $Config.limits[$plan] = $lim
  if (-not $Debugging) { Save-Config }
  return , $msgs
}

# 有官方數字時自動學習換算值：同一視窗內官方 % 累積上升夠多時，用「新增花費 ÷ 新增 %」更新
$script:PrevOff = $null
function Learn-FromOfficial($s) {
  $o = $s.Official
  if (-not $o) { return }
  $p = $script:PrevOff
  if (-not $p) { $script:PrevOff = $o; return }
  if ($o.At -le $p.At) { return }
  $lim = Get-Limits $s.Plan; $learned = $false; $reset = $false
  foreach ($k in @(@{ Key = 'Block'; Lim = 'block'; Hours = 5; Min = 5 }, @{ Key = 'Week'; Lim = 'weekly'; Hours = 168; Min = 3 })) {
    $a = $p[$k.Key]; $b = $o[$k.Key]
    if (-not $a -or -not $b) { continue }
    if ([math]::Abs(($a.ResetAt - $b.ResetAt).TotalMinutes) -gt 2) { $reset = $true; continue }
    $start = $b.ResetAt.AddHours(-$k.Hours)
    $dc = (Get-CostBetween $start $o.At) - (Get-CostBetween $start $p.At)
    $dp = $b.Pct - $a.Pct
    if ($dp -ge $k.Min -and $dc -gt 0.1 -and $lim[$k.Lim] -gt 0) {
      $v = $dc / $dp * 100
      if ($v -gt $lim[$k.Lim] * 0.2 -and $v -lt $lim[$k.Lim] * 5) { $lim[$k.Lim] = [math]::Round($v, 2); $learned = $true }
    }
  }
  if ($learned) { $Config.limits[$s.Plan] = $lim; if (-not $Debugging) { Save-Config } }
  if ($learned -or $reset) { $script:PrevOff = $o }
}

function Show-Calibrate {
  [xml]$cx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Nexus 校正" Width="372" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ResizeMode="NoResize" WindowStartupLocation="CenterScreen"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Microsoft JhengHei UI"/><Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Foreground" Value="#A09B8C"/><Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="H" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Microsoft JhengHei UI"/><Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="12"/><Setter Property="Foreground" Value="#C8AA6E"/><Setter Property="Margin" Value="0,12,0,4"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#010A13"/><Setter Property="Foreground" Value="#F0E6D2"/>
      <Setter Property="BorderBrush" Value="#463714"/><Setter Property="CaretBrush" Value="#C8AA6E"/>
      <Setter Property="Padding" Value="4,2"/><Setter Property="Width" Value="44"/><Setter Property="Margin" Value="6,2,4,2"/>
      <Setter Property="FontFamily" Value="Georgia"/>
    </Style>
    <Style TargetType="ComboBox"><Setter Property="Margin" Value="6,2,0,2"/><Setter Property="FontFamily" Value="Microsoft JhengHei UI"/></Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#F0E6D2"/><Setter Property="FontFamily" Value="Microsoft JhengHei UI"/>
      <Setter Property="FontWeight" Value="Bold"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="8,0,0,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="#1E2328" BorderBrush="#C8AA6E" BorderThickness="1" Padding="18,5">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#2A3A44"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Margin="10" BorderThickness="1.5" Background="#F7091428">
    <Border.BorderBrush>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#C8AA6E" Offset="0"/><GradientStop Color="#785A28" Offset="0.5"/><GradientStop Color="#C8AA6E" Offset="1"/></LinearGradientBrush>
    </Border.BorderBrush>
    <Border.Effect><DropShadowEffect Color="#000000" BlurRadius="16" ShadowDepth="0" Opacity="0.85"/></Border.Effect>
    <StackPanel Margin="16,12,16,14">
      <Grid x:Name="Head" Background="Transparent">
        <TextBlock Text="CLAUDE NEXUS · 校正額度" FontFamily="Georgia" FontWeight="Bold" FontSize="13" Foreground="#F0E6D2"/>
        <TextBlock x:Name="X" Text="✕" HorizontalAlignment="Right" Foreground="#785A28" Cursor="Hand"/>
      </Grid>
      <Rectangle Height="1" Margin="0,8,0,6">
        <Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#00785A28" Offset="0"/><GradientStop Color="#C8AA6E" Offset="0.5"/><GradientStop Color="#00785A28" Offset="1"/></LinearGradientBrush></Rectangle.Fill>
      </Rectangle>
      <TextBlock TextWrapping="Wrap" FontSize="10.5">打開 Claude → 設定 → 用量，把畫面上的數字照抄下來。留空的區塊不會更新。</TextBlock>
      <TextBlock x:Name="PlanText" Margin="0,4,0,0" FontSize="10.5" Foreground="#0AC8B9"/>

      <TextBlock Text="5 小時額度" Style="{StaticResource H}"/>
      <StackPanel Orientation="Horizontal"><TextBlock Text="已使用" Width="56"/><TextBox x:Name="BPct"/><TextBlock Text="%"/></StackPanel>
      <StackPanel Orientation="Horizontal"><TextBlock Text="重置時間" Width="56"/><TextBox x:Name="BT" Width="54"/><TextBlock Text="（例如 14:50，本地時間）"/></StackPanel>

      <TextBlock Text="每週額度" Style="{StaticResource H}"/>
      <StackPanel Orientation="Horizontal"><TextBlock Text="已使用" Width="56"/><TextBox x:Name="WPct"/><TextBlock Text="%"/></StackPanel>
      <StackPanel Orientation="Horizontal"><TextBlock Text="重置於" Width="56"/><ComboBox x:Name="WDay" Width="70"/><TextBox x:Name="WTime" Width="54"/><TextBlock Text="（本地時間）"/></StackPanel>

      <TextBlock TextWrapping="Wrap" FontSize="9.5" Foreground="#5B5A56" Margin="0,12,0,0">小工具會以這次的數字為基準，之後只把新增的花費換算成 % 往上加。在同一個視窗內隔一段時間再校正一次，就能自動算出「100% 額度約等於多少花費」，之後會更準。</TextBlock>
      <TextBlock x:Name="Err" Foreground="#E84057" FontSize="10.5" Margin="0,6,0,0" TextWrapping="Wrap"/>

      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
        <Button x:Name="Cancel" Content="取消"/>
        <Button x:Name="Ok" Content="校正"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
  $cw, $n = Load-Xaml $cx
  if ($win.IsLoaded) { $cw.Owner = $win }
  $dayKeys = 'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'
  foreach ($d in $dayNames) { [void]$n.WDay.Items.Add('週' + $d) }
  $n.WDay.SelectedIndex = [array]::IndexOf($dayKeys, [string]$Config.weeklyResetDay)
  $n.WTime.Text = '{0:00}:{1:00}' -f [int]$Config.weeklyResetHour, [int]$Config.weeklyResetMinute
  $plan = Get-Plan
  $n.PlanText.Text = '目前方案：{0}　·　100% 約等於 5 小時 {1}、每週 {2}' -f $plan, (Fmt-Money (Get-Limits $plan).block), (Fmt-Money (Get-Limits $plan).weekly)
  $s = $script:LastStats
  # 只有已對齊官方時才預填倒數；本機推算的時間可能和官方差很多
  if ($s -and $s.Block.Calibrated -and $s.Block.Reset) { $n.BT.Text = ((Get-Date) + $s.Block.Reset).ToString('HH:mm') }
  if ($s -and $s.Official) { $n.Err.Foreground = New-Brush '#0AC8B9'; $n.Err.Text = '目前已在讀取官方數字（狀態列橋接），通常不需要手動校正。' }

  $n.Head.Add_MouseLeftButtonDown({ try { $cw.DragMove() } catch {} })
  $n.X.Add_MouseLeftButtonUp({ $cw.Close() })
  $n.Cancel.Add_Click({ $cw.Close() })
  $n.Ok.Add_Click({
    $pct = { param($t) $v = 0.0; if ($t.Trim() -eq '') { $null } elseif ([double]::TryParse($t, [ref]$v) -and $v -ge 0 -and $v -le 100) { $v } else { 'bad' } }
    $bp = & $pct $n.BPct.Text; $wp = & $pct $n.WPct.Text
    if ($bp -is [string] -or $wp -is [string]) { $n.Err.Text = '百分比請輸入 0–100 的數字。'; return }
    $resetAt = $null
    if ($null -ne $bp) {
      # 官方用量頁顯示的是重置時刻；取「現在之後最近的一次」，且必須在 5 小時內
      $bt = [regex]::Match($n.BT.Text.Trim(), '^(\d{1,2})[:：](\d{2})$')
      if (-not $bt.Success -or [int]$bt.Groups[1].Value -gt 23 -or [int]$bt.Groups[2].Value -gt 59) { $n.Err.Text = '請填入 5 小時額度的重置時間，例如 14:50。'; return }
      $now = Get-Date
      $resetAt = $now.Date.AddHours([int]$bt.Groups[1].Value).AddMinutes([int]$bt.Groups[2].Value)
      if ($resetAt -le $now) { $resetAt = $resetAt.AddDays(1) }
      if (($resetAt - $now).TotalHours -gt 5) { $n.Err.Text = '5 小時額度的重置時間應該在現在之後 5 小時內，請確認。'; return }
    }
    $tm = [regex]::Match($n.WTime.Text.Trim(), '^(\d{1,2})(?::(\d{2}))?$')
    if (-not $tm.Success -or [int]$tm.Groups[1].Value -gt 23) { $n.Err.Text = '每週重置時間請用 19:00 這種格式。'; return }
    $wMin = if ($tm.Groups[2].Success) { [int]$tm.Groups[2].Value } else { 0 }
    $msgs = Apply-Calibration $bp $resetAt $wp $dayKeys[$n.WDay.SelectedIndex] ([int]$tm.Groups[1].Value) $wMin
    $cw.Tag = $msgs
    $cw.Close()
  })
  if ($SnapshotCalibrate) { $cw.Add_ContentRendered({ Save-Png $cw $SnapshotCalibrate; $cw.Close() }) }
  [void]$cw.ShowDialog()
  if ($null -eq $cw.Tag) { return }
  Refresh-UI
  $note = if ($cw.Tag.Count) { $cw.Tag -join "`n" } else { '已設定基準點，之後會從這裡往上累加' }
  Show-Toast 'info' '校正完成' $note
}

function Save-Png($w, [string]$path) {
  $w.UpdateLayout()
  $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]($w.ActualWidth * 2)), ([int]($w.ActualHeight * 2)), 192, 192, ([Windows.Media.PixelFormats]::Pbgra32)
  $bmp.Render($w.Content)
  $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
  $fs = [IO.File]::Create($path); $enc.Save($fs); $fs.Dispose()
}

# ================================================================ 互動
$wa = [Windows.SystemParameters]::WorkArea
$win.Opacity = [double]$Config.opacity
$win.WindowStartupLocation = 'Manual'
$win.Left = if ([double]$Config.left -ge 0) { [double]$Config.left } else { $wa.Right - 312 }
$win.Top  = if ([double]$Config.top -ge 0) { [double]$Config.top } else { $wa.Bottom - 560 }
$ModeItems = @()

$drag = {
  param($sender, $e)
  if ($e.ClickCount -eq 2) {
    if ($Config.mode -eq 'mini') { Set-Mode 'full' }
    return
  }
  try { $win.DragMove() } catch {}
  $Config.left = [math]::Round($win.Left); $Config.top = [math]::Round($win.Top); Save-Config
  Restack-Toasts
}
$ui.Frame.Add_MouseLeftButtonDown($drag)
$ui.MiniRoot.Add_MouseLeftButtonDown($drag)
$ui.BtnClose.Add_MouseLeftButtonUp({ $win.Close() })
$ui.BtnSettings.Add_MouseLeftButtonUp({ Show-Settings })
# ◇ 依序切換：完整 → 精簡 → 血條
$ui.BtnCompact.Add_MouseLeftButtonUp({ Set-Mode $(if ($Config.mode -eq 'full') { 'compact' } else { 'mini' }) })

$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Nexus.lnk'
function Set-Autostart([bool]$on) {
  if ($on) {
    $vbs = Join-Path (Split-Path $ScriptPath) 'ClaudeNexus.vbs'
    $sh = New-Object -ComObject WScript.Shell
    $l = $sh.CreateShortcut($StartupLnk)
    $l.TargetPath = 'wscript.exe'; $l.Arguments = '"' + $vbs + '"'; $l.WorkingDirectory = Split-Path $ScriptPath
    $l.Save()
  } elseif (Test-Path $StartupLnk) { Remove-Item $StartupLnk }
}

function Add-Item($menu, [string]$text, [scriptblock]$action) {
  $m = New-Object Windows.Controls.MenuItem
  $m.Header = $text; $m.Add_Click($action); [void]$menu.Items.Add($m); $m
}
$menu = New-Object Windows.Controls.ContextMenu
[void](Add-Item $menu '設定…' { Show-Settings })
[void](Add-Item $menu '校正額度…（照抄官方用量頁）' { Show-Calibrate })
$modeMenu = Add-Item $menu '顯示模式' {}
foreach ($m in @(@('full', '完整'), @('compact', '精簡'), @('mini', '血條（迷你）'))) {
  $mi = New-Object Windows.Controls.MenuItem
  $mi.Header = $m[1]; $mi.Tag = $m[0]
  $mi.Add_Click({ param($sd) Set-Mode $sd.Tag })
  [void]$modeMenu.Items.Add($mi)
  $ModeItems += $mi
}
[void](Add-Item $menu '測試通知' { Show-Toast 'done' '任務完成' "範例對話`n歷時 2m 10s · 累計 `$0.42"; Show-Toast 'wait' '需要你的確認' "範例對話`n請回到 Claude 同意或回覆" })
[void](Add-Item $menu '立即重新整理' { Refresh-UI })
$auto = Add-Item $menu '開機自動啟動' { Set-Autostart (-not (Test-Path $StartupLnk)); $auto.IsChecked = (Test-Path $StartupLnk) }
$auto.IsChecked = (Test-Path $StartupLnk)
[void](Add-Item $menu '開啟設定檔' { Start-Process notepad.exe $ConfigPath })
[void]$menu.Items.Add((New-Object Windows.Controls.Separator))
[void](Add-Item $menu '結束' { $win.Close() })
$ui.Frame.ContextMenu = $menu
$ui.MiniRoot.ContextMenu = $menu
Apply-Mode

# 有時其他全螢幕程式會搶走置頂，定期重新宣告
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds([math]::Max(1.0, [double]$Config.refreshSeconds))
$timer.Add_Tick({ Refresh-UI; if (-not $win.IsActive) { $win.Topmost = $false; $win.Topmost = $true } })
$win.Add_ContentRendered({
  Refresh-UI; $timer.Start()
  if ($Snapshot) { Save-Png $win $Snapshot; $win.Close() }
  if ($SnapshotSettings) { Show-Settings; $win.Close() }
  if ($SnapshotCalibrate) { Show-Calibrate; $win.Close() }
})
$win.Add_Closed({ $timer.Stop(); foreach ($t in @($script:Toasts)) { $t.Close() } })

[void]$win.ShowDialog()
