Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Test" Width="400" Height="300">
    <StackPanel Margin="20" Orientation="Horizontal">
        <ComboBox Name="Box1" Width="100" Margin="5">
            <ComboBoxItem>Item 1</ComboBoxItem>
            <ComboBoxItem>Item 2</ComboBoxItem>
        </ComboBox>
        <ComboBox Name="Box2" Width="100" Margin="5">
            <ComboBoxItem>Option A</ComboBoxItem>
            <ComboBoxItem>Option B</ComboBoxItem>
        </ComboBox>
        <ComboBox Name="Box3" Width="100" Margin="5">
            <ComboBoxItem>Choice X</ComboBoxItem>
            <ComboBoxItem>Choice Y</ComboBoxItem>
        </ComboBox>
    </StackPanel>
</Window>
'@

$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
$window = [System.Windows.Markup.XamlReader]::Load($reader)
$box1 = $window.FindName("Box1")
$box2 = $window.FindName("Box2")
$box3 = $window.FindName("Box3")

$allBoxes = @($box1, $box2, $box3)

# In WPF, when ComboBox popup is open, Window.PreviewMouseDown or Mouse.PreviewMouseDown can be used.
# Let's see: on ComboBox.DropDownOpened:
# When any ComboBox opens its dropdown, how can we capture clicks on other ComboBoxes?
# Method: Win32 WH_MOUSE / Global mouse hook, OR Window.PreviewMouseDown, OR Popup.PreviewMouseDownOutsideCapturedElement.
# Let's inspect Popup in visual tree of ComboBox!
$window.Add_ContentRendered({
    foreach ($cb in $allBoxes) {
        $popup = $cb.Template.FindName("PART_Popup", $cb)
        if (-not $popup) {
            # Find popup in template
            $popup = $cb.FindName("PART_Popup")
        }
        Write-Host "$($cb.Name) popup: $popup"
    }
})

Write-Host "Initialized"
