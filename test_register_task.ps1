$action = New-ScheduledTaskAction -Execute "wscript.exe"
$trigger = New-ScheduledTaskTrigger -AtLogOn
try {
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
    Register-ScheduledTask -TaskName "BingWallpaperSpotlight_Test" -Action $action -Trigger $trigger -Principal $principal -Force
    Write-Host "Success"
} catch {
    Write-Host "Error: $_"
}
