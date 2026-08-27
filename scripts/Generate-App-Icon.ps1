<#
.SYNOPSIS
    Generates a transparent multi-resolution Windows icon (assets\app.ico)
    from the master vector PeakView_logo_vector.svg.
#>

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

$rootFolder = if (Test-Path (Join-Path $scriptDir 'Bing-Wallpaper-UI.ps1')) {
    $scriptDir
}
else {
    Split-Path -Parent $scriptDir
}

$assetsFolder = Join-Path $rootFolder 'assets'
$svgPath = Join-Path $assetsFolder 'PeakView_logo_vector.svg'
$icoPath = Join-Path $assetsFolder 'app.ico'

if (-not (Test-Path $svgPath)) {
    throw "Master SVG not found at: $svgPath"
}

Write-Output "--> Rendering PeakView master vector to high-res transparent surface..."
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing

$vectorXaml = @'
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1024" Height="1024" Background="Transparent">
    <Canvas.Resources>
        <LinearGradientBrush x:Key="b1" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#174BCB" Offset="0"/>
            <GradientStop Color="#0B3AA5" Offset="1"/>
        </LinearGradientBrush>
        <LinearGradientBrush x:Key="b2" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#1470D5" Offset="0"/>
            <GradientStop Color="#0758BD" Offset="1"/>
        </LinearGradientBrush>
        <LinearGradientBrush x:Key="sky" StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#54A8F4" Offset="0"/>
            <GradientStop Color="#8BC8F6" Offset="1"/>
        </LinearGradientBrush>
        <LinearGradientBrush x:Key="m1" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#08459F" Offset="0"/>
            <GradientStop Color="#0A62C2" Offset="1"/>
        </LinearGradientBrush>
        <LinearGradientBrush x:Key="m2" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#2C72CB" Offset="0"/>
            <GradientStop Color="#5E9FDF" Offset="1"/>
        </LinearGradientBrush>
        <LinearGradientBrush x:Key="m3" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#79B5EA" Offset="0"/>
            <GradientStop Color="#9CCDF0" Offset="1"/>
        </LinearGradientBrush>
        <LinearGradientBrush x:Key="snow" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#E5EEFF" Offset="0"/>
            <GradientStop Color="#FFFFFF" Offset="1"/>
        </LinearGradientBrush>
        <RectangleGeometry x:Key="clip" Rect="173,263,678,539" RadiusX="36" RadiusY="36"/>
    </Canvas.Resources>

    <!-- Top back rounded rect -->
    <Rectangle Canvas.Left="245" Canvas.Top="147" Width="534" Height="151" RadiusX="34" RadiusY="34" Fill="{StaticResource b1}">
        <Rectangle.Effect>
            <DropShadowEffect BlurRadius="24" Direction="270" ShadowDepth="10" Opacity="0.18" Color="Black"/>
        </Rectangle.Effect>
    </Rectangle>

    <!-- Middle back rounded rect -->
    <Rectangle Canvas.Left="209" Canvas.Top="205" Width="606" Height="168" RadiusX="36" RadiusY="36" Fill="{StaticResource b2}"/>

    <!-- Main rounded rect sky -->
    <Rectangle Canvas.Left="173" Canvas.Top="263" Width="678" Height="539" RadiusX="36" RadiusY="36" Fill="{StaticResource sky}">
        <Rectangle.Effect>
            <DropShadowEffect BlurRadius="24" Direction="270" ShadowDepth="10" Opacity="0.18" Color="Black"/>
        </Rectangle.Effect>
    </Rectangle>

    <!-- Mountain & sun content clipped to main rounded rect -->
    <Canvas Clip="{StaticResource clip}">
        <Ellipse Canvas.Left="80" Canvas.Top="175" Width="820" Height="380" Fill="#B9DEFA" Opacity="0.18"/>
        <Ellipse Canvas.Left="642" Canvas.Top="295" Width="110" Height="110" Fill="#FFE995"/>
        <Path Data="M235 625L360 510L425 558L495 424L570 505L635 450L810 616L880 690V830H205V830Z" Fill="{StaticResource m3}"/>
        <Path Data="M360 510L495 424L570 505L532 485L500 535L468 501L430 552L403 531Z" Fill="{StaticResource snow}"/>
        <Path Data="M175 657L302 544L376 600L458 516L553 625L610 561L720 671L858 760V830H175Z" Fill="{StaticResource m2}"/>
        <Path Data="M302 544L376 600L346 584L325 608L302 590L275 613Z" Fill="#BBDCF5" Opacity="0.9"/>
        <Path Data="M458 516L553 625L514 601L486 630L458 602L432 625Z" Fill="#CDE5FA" Opacity="0.85"/>
        <Path Data="M150 671L268 590L337 632L420 695L505 751L590 793L655 838H150Z" Fill="{StaticResource m1}"/>
        <Path Data="M268 590L337 632L420 695L505 751L590 793L458 741L382 699L320 653Z" Fill="#165DB8" Opacity="0.82"/>
        <Path Data="M515 830L590 760L675 700L760 747L880 683L900 830Z" Fill="#3984D4" Opacity="0.78"/>
        <Path Data="M675 700L760 747L720 735L690 759L654 730Z" Fill="#79B6E9" Opacity="0.62"/>
    </Canvas>
</Canvas>
'@

$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($vectorXaml))
$canvas = [System.Windows.Markup.XamlReader]::Load($reader)
$canvas.Measure([System.Windows.Size]::new(1024, 1024))
$canvas.Arrange([System.Windows.Rect]::new(0, 0, 1024, 1024))
$canvas.UpdateLayout()

$rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(1024, 1024, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
$rtb.Render($canvas)

$tempPng = [System.IO.Path]::GetTempFileName() + ".png"
$enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
$enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
$outStream = [System.IO.File]::Create($tempPng)
$enc.Save($outStream)
$outStream.Close()

Write-Output "--> Generating multi-resolution frames (16, 24, 32, 48, 64, 128, 256px) into $icoPath..."

$pyScript = @"
import sys
from PIL import Image

temp_png = sys.argv[1]
ico_path = sys.argv[2]

img = Image.open(temp_png)
sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
imgs = [img.resize(s, Image.Resampling.LANCZOS) for s in sizes]

# Save as Windows multi-resolution ICO with PNG/BMP frame encoding
imgs[-1].save(ico_path, format='ICO', sizes=sizes, append_images=imgs[:-1])
print(f'Successfully generated multi-res ICO with sizes: {sizes}')
"@

$pyTemp = [System.IO.Path]::GetTempFileName() + ".py"
Set-Content -Path $pyTemp -Value $pyScript -Encoding UTF8

$proc = Start-Process -FilePath "python.exe" -ArgumentList "`"$pyTemp`" `"$tempPng`" `"$icoPath`"" -NoNewWindow -Wait -PassThru

Remove-Item -Path $tempPng -Force -ErrorAction SilentlyContinue
Remove-Item -Path $pyTemp -Force -ErrorAction SilentlyContinue

if ($proc.ExitCode -ne 0 -or -not (Test-Path $icoPath)) {
    throw "Failed to generate $icoPath (Exit code: $($proc.ExitCode))"
}

# Verify generated ICO
$decoder = [System.Windows.Media.Imaging.IconBitmapDecoder]::new([System.Uri]::new((Resolve-Path -LiteralPath $icoPath).Path), [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::Default)
Write-Output "--> Verified assets\app.ico: $($decoder.Frames.Count) frames embedded:"
foreach ($f in $decoder.Frames) {
    Write-Output "    - $($f.PixelWidth)x$($f.PixelHeight) ($($f.Format))"
}
Remove-Item -Path $tempPng -Force -ErrorAction SilentlyContinue
Remove-Item -Path $pyTemp -Force -ErrorAction SilentlyContinue

if ($proc.ExitCode -ne 0 -or -not (Test-Path $icoPath)) {
    throw "Failed to generate $icoPath (Exit code: $($proc.ExitCode))"
}

# Verify generated ICO
$decoder = [System.Windows.Media.Imaging.IconBitmapDecoder]::new([System.Uri]::new((Resolve-Path -LiteralPath $icoPath).Path), [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::Default)
Write-Output "--> Verified assets\app.ico: $($decoder.Frames.Count) frames embedded:"
foreach ($f in $decoder.Frames) {
    Write-Output "    - $($f.PixelWidth)x$($f.PixelHeight) ($($f.Format))"
}
$proc = Start-Process -FilePath "python.exe" -ArgumentList "`"$pyTemp`" `"$tempPng`" `"$icoPath`"" -NoNewWindow -Wait -PassThru

Remove-Item -Path $tempPng -Force -ErrorAction SilentlyContinue
Remove-Item -Path $pyTemp -Force -ErrorAction SilentlyContinue

if ($proc.ExitCode -ne 0 -or -not (Test-Path $icoPath)) {
    throw "Failed to generate $icoPath (Exit code: $($proc.ExitCode))"
}

# Verify generated ICO
$decoder = [System.Windows.Media.Imaging.IconBitmapDecoder]::new([System.Uri]::new((Resolve-Path -LiteralPath $icoPath).Path), [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::Default)
Write-Output "--> Verified assets\app.ico: $($decoder.Frames.Count) frames embedded:"
foreach ($f in $decoder.Frames) {
    Write-Output "    - $($f.PixelWidth)x$($f.PixelHeight) ($($f.Format))"
}
