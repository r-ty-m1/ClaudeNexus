' Launch Claude Nexus without a console window
Set sh = CreateObject("WScript.Shell")
dir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -STA -WindowStyle Hidden -File """ & dir & "\ClaudeNexus.ps1""", 0, False
