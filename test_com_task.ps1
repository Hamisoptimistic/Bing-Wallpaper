$service = New-Object -ComObject 'Schedule.Service'
$service.Connect()
$folder = $service.GetFolder('\')
$task = $service.NewTask(0)
$task.RegistrationInfo.Description = 'Test'
$action = $task.Actions.Create(0)
$action.Path = 'wscript.exe'
$trigger = $task.Triggers.Create(9)
try {
    $folder.RegisterTaskDefinition('BingWallpaperSpotlight_Test', $task, 6, $null, $null, 3) | Out-Null
    Write-Host 'Success'
} catch {
    Write-Host "Error: $_"
}
