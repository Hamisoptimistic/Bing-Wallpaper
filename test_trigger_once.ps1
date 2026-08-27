try {
    $action = New-ScheduledTaskAction -Execute "wscript.exe"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date)
    Register-ScheduledTask -TaskName "BingWallpaperSpotlight_Test" -Action $action -Trigger $trigger -Force
    Write-Host "Success"
} catch {
    Write-Host "Error: $_"
}
