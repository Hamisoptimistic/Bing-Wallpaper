$ps = [powershell]::Create()
$ps.AddScript({
    New-Item -ItemType File -Path "test_success.txt" -Force
}) | Out-Null
$ps.Invoke()
if ($ps.Streams.Error.Count -gt 0) {
    Write-Host "Error in runspace: $($ps.Streams.Error[0].Exception.Message)"
} else {
    Write-Host "Success"
}
