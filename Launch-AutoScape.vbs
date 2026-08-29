' Launch-AutoScape.vbs
' Silently launches Bing-Wallpaper-UI.ps1 via the trusted powershell.exe host.
' No compiled binary involved, so Smart App Control has nothing unrecognized to block.

Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path = fso.BuildPath(scriptDir, "Bing-Wallpaper-UI.ps1")

Set shell = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1Path & """"

' 0 = hidden window, False = don't wait for it to finish
shell.Run cmd, 0, False