' Launch Claude Nexus without a console window
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
script = dir & "\ClaudeNexus.ps1"
If Not fso.FileExists(script) Then
  ' Fall back to the installed copy when this launcher was moved away from its script
  script = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\ClaudeNexus\ClaudeNexus.ps1"
End If
If Not fso.FileExists(script) Then
  MsgBox "Cannot find ClaudeNexus.ps1." & vbCrLf & "Looked in: " & dir & vbCrLf & "and the install folder under %LOCALAPPDATA%\ClaudeNexus." & vbCrLf & "Keep ClaudeNexus.vbs next to ClaudeNexus.ps1, or run install.ps1.", 48, "Claude Nexus"
  WScript.Quit 1
End If
sh.CurrentDirectory = fso.GetParentFolderName(script)
sh.Run "powershell.exe -NoProfile -STA -WindowStyle Hidden -File """ & script & """", 0, False
