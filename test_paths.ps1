Write-Host "PSCommandPath: $PSCommandPath"
Write-Host "PSScriptRoot: $PSScriptRoot"
Write-Host "MyInvocation.MyCommand.Path: $($MyInvocation.MyCommand.Path)"
Write-Host "Process.MainModule.FileName: $([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)"
Start-Sleep -Seconds 3
