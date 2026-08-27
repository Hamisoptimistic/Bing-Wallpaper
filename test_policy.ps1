$ps = [powershell]::Create()
$res = $ps.AddScript({ Get-ExecutionPolicy }).Invoke()
Write-Host "Runspace Execution Policy: $res"
