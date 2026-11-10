# 用 Windows 內建的 IExpress 打包成 ClaudeNexus-Setup.exe
# 用法：powershell -File release\build-exe.ps1 -Out dist\ClaudeNexus-Setup.exe
param([Parameter(Mandatory)][string]$Out)
$ErrorActionPreference = 'Stop'
$root  = Split-Path $PSScriptRoot
$stage = Join-Path ([IO.Path]::GetTempPath()) ('nexus-exe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $stage | Out-Null
foreach ($f in 'ClaudeNexus.ps1', 'ClaudeNexus.vbs', 'install.ps1', 'statusline.ps1') { Copy-Item (Join-Path $root $f) $stage }
Copy-Item (Join-Path $PSScriptRoot 'setup.ps1') $stage
$files = Get-ChildItem $stage -File | Select-Object -ExpandProperty Name
$outFull = [IO.Path]::GetFullPath($Out)
New-Item -ItemType Directory -Force (Split-Path $outFull) | Out-Null
if (Test-Path $outFull) { Remove-Item $outFull }

$src = ($files | ForEach-Object -Begin { $i = 0 } -Process { "FILE$i=`"$_`""; $i++ }) -join "`r`n"
$lst = ($files | ForEach-Object -Begin { $i = 0 } -Process { "%FILE$i%="; $i++ }) -join "`r`n"
$sed = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=1
UseLongFileName=1
InsertPrompt=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=
DisplayLicense=
FinishMessage=
TargetName=$outFull
FriendlyName=Claude Nexus Setup
AppLaunched=powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File setup.ps1
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
SourceFiles=SourceFiles
[Strings]
$src
[SourceFiles]
SourceFiles0=$stage\
[SourceFiles0]
$lst
"@
$sedPath = Join-Path $stage 'build.sed'
[IO.File]::WriteAllText($sedPath, $sed, [Text.Encoding]::ASCII)
$p = Start-Process iexpress.exe -ArgumentList '/N', '/Q', $sedPath -Wait -PassThru -NoNewWindow
if (-not (Test-Path $outFull)) { throw "IExpress 沒有產生輸出（exit $($p.ExitCode)）" }
Remove-Item $stage -Recurse -Force
Write-Host ("OK {0} ({1:N0} bytes)" -f $outFull, (Get-Item $outFull).Length)
