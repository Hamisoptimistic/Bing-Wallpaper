Add-Type -AssemblyName PresentationFramework
$win = New-Object System.Windows.Window
$tb = New-Object System.Windows.Controls.TextBlock
$tb.Text = "Hello"
$tb.Text = ""
$tb.Inlines.Add((New-Object System.Windows.Documents.Run("Part1 ")))
$tb.Inlines.Add((New-Object System.Windows.Documents.Run("Part2")))
Write-Host "Resulting text: $($tb.Text)"
