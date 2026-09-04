$script:activeGuideDialog = $null
$script:isClosingGuideDialog = $false

function Close-UserGuideDialog {
    if ($script:isClosingGuideDialog) { return }
    if ($script:activeModalControl -and $script:activeModalKind -eq 'Guide') {
        $script:isClosingGuideDialog = $true
        Close-InWindowModal
        $script:isClosingGuideDialog = $false
    }
}

function Show-UserGuideDialog {
    if ($script:activeModalControl -and $script:activeModalKind -eq 'Guide' -and -not $script:activeModalClosing) {
        Close-UserGuideDialog
        return
    }
    $cleanTitle = "AutoScape"
    $cleanDate = "Today's Wallpaper"
    $thumbPath = $null

    try {
        if ($script:loadedImages -and $script:loadedImages.Count -gt 0) {
            $latest = $script:loadedImages[0]
            $cleanTitle = [System.Security.SecurityElement]::Escape((Get-CleanImageTitle $latest))
            try {
                $cleanDate = ([DateTime]::ParseExact($latest.enddate.ToString(), 'yyyyMMdd', $null)).ToString('ddd, MMM d')
            }
            catch {
                $cleanDate = if ($latest.copyright) { [System.Security.SecurityElement]::Escape($latest.copyright) } else { "Today's Wallpaper" }
            }
            $safeName = $latest.urlbase -replace '[^a-zA-Z0-9]', ''
            $tPath = Join-Path $env:LOCALAPPDATA "AutoScape\cache\Thumbnails\${safeName}_thumb.jpg"
            if (-not (Test-Path -LiteralPath $tPath)) {
                $legacyTPath = Join-Path $env:LOCALAPPDATA "BingWallpaper\Cache\Thumbnails\${safeName}_thumb.jpg"
                if (Test-Path -LiteralPath $legacyTPath) { $tPath = $legacyTPath }
            }
            if (Test-Path -LiteralPath $tPath) {
                $thumbPath = (Resolve-Path -LiteralPath $tPath).Path
            }
        }
        elseif (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'AutoScape\cache\current_wallpaper.jpg')) {
            $thumbPath = (Resolve-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'AutoScape\cache\current_wallpaper.jpg')).Path
        }
        elseif (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'BingWallpaper\Cache\current_wallpaper.jpg')) {
            $thumbPath = (Resolve-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'BingWallpaper\Cache\current_wallpaper.jpg')).Path
        }
    }
    catch {}

    $screenWidth = [System.Windows.SystemParameters]::PrimaryScreenWidth
    $screenHeight = [System.Windows.SystemParameters]::PrimaryScreenHeight
    if ($window -and $window.ActualWidth -gt 600) {
        $screenWidth = $window.ActualWidth
        $screenHeight = $window.ActualHeight
    }
    $maxModalWidth = [Math]::Max(320, [int]$screenWidth - 48)
    $maxModalHeight = [Math]::Max(320, [int]$screenHeight - 48)
    $modalWidth = [Math]::Min($maxModalWidth, [Math]::Max(700, [int]($screenWidth * 0.72)))
    $modalHeight = [Math]::Min($maxModalHeight, [Math]::Max(520, [int]($screenHeight * 0.72)))

    $dialogXaml = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="$modalWidth" Height="$modalHeight"
        Background="Transparent" Foreground="#F0F0F0" FontFamily="Segoe UI">
    <UserControl.Resources>
        <Style TargetType="ToolTip">
            <Setter Property="Background" Value="#2E2E2E"/>
            <Setter Property="Foreground" Value="#F5F5F5"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="HasDropShadow" Value="False"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToolTip">
                        <Border Background="{TemplateBinding Background}" BorderBrush="#454545" BorderThickness="1.5" CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <Border.Effect>
                                <DropShadowEffect BlurRadius="14" ShadowDepth="3" Opacity="0.4" Color="Black"/>
                            </Border.Effect>
                            <ContentPresenter/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </UserControl.Resources>
    <Border Name="DialogRoot" Padding="28,24,28,22" Background="#1a1a1a" BorderBrush="#2E2E2E" BorderThickness="1.5" CornerRadius="12" Opacity="1">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Close Button -->
            <Button Name="GuideCloseButton" Width="32" Height="32"
                    HorizontalAlignment="Right" VerticalAlignment="Top" Background="#262626" Foreground="#E8E8E8"
                    BorderThickness="0" Cursor="Hand" ToolTip="Close" Panel.ZIndex="100">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border Name="CloseBorder" Background="{TemplateBinding Background}" CornerRadius="7">
                            <Canvas Width="20" Height="20">
                                <Path Data="M 5,5 L 15,15 M 15,5 L 5,15"
                                      Stroke="{TemplateBinding Foreground}" StrokeThickness="2.6"
                                      StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                            </Canvas>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="CloseBorder" Property="Background" Value="#E81123"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="CloseBorder" Property="Background" Value="#C50F1F"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>

            <!-- Header -->
            <Grid Grid.Row="0" Margin="0,0,0,24" HorizontalAlignment="Center">
                <StackPanel Orientation="Horizontal">
                    <Viewbox Width="36" Height="36" Margin="0,0,14,0">
                        <Canvas Width="760" Height="720">
                            <Canvas Canvas.Left="-135" Canvas.Top="-135" Width="1024" Height="1024">
                                <Rectangle Canvas.Left="245" Canvas.Top="147" Width="534" Height="151" RadiusX="34" RadiusY="34">
                                    <Rectangle.Fill>
                                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                            <GradientStop Color="#174BCB" Offset="0"/>
                                            <GradientStop Color="#0B3AA5" Offset="1"/>
                                        </LinearGradientBrush>
                                    </Rectangle.Fill>
                                    <Rectangle.Effect>
                                        <DropShadowEffect BlurRadius="24" Direction="270" ShadowDepth="10" Opacity="0.18" Color="Black"/>
                                    </Rectangle.Effect>
                                </Rectangle>

                                <Rectangle Canvas.Left="209" Canvas.Top="205" Width="606" Height="168" RadiusX="36" RadiusY="36">
                                    <Rectangle.Fill>
                                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                            <GradientStop Color="#1470D5" Offset="0"/>
                                            <GradientStop Color="#0758BD" Offset="1"/>
                                        </LinearGradientBrush>
                                    </Rectangle.Fill>
                                </Rectangle>

                                <Rectangle Canvas.Left="173" Canvas.Top="263" Width="678" Height="539" RadiusX="36" RadiusY="36">
                                    <Rectangle.Fill>
                                        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                                            <GradientStop Color="#54A8F4" Offset="0"/>
                                            <GradientStop Color="#8BC8F6" Offset="1"/>
                                        </LinearGradientBrush>
                                    </Rectangle.Fill>
                                    <Rectangle.Effect>
                                        <DropShadowEffect BlurRadius="24" Direction="270" ShadowDepth="10" Opacity="0.18" Color="Black"/>
                                    </Rectangle.Effect>
                                </Rectangle>

                                <Canvas>
                                    <Canvas.Clip>
                                        <RectangleGeometry Rect="173,263,678,539" RadiusX="36" RadiusY="36"/>
                                    </Canvas.Clip>
                                    <Ellipse Canvas.Left="80" Canvas.Top="175" Width="820" Height="380" Fill="#B9DEFA" Opacity="0.18"/>
                                    <Ellipse Canvas.Left="642" Canvas.Top="295" Width="110" Height="110" Fill="#FFE995"/>
                                    <Path Data="M235 625L360 510L425 558L495 424L570 505L635 450L810 616L880 690V830H205V830Z">
                                        <Path.Fill>
                                            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                                <GradientStop Color="#79B5EA" Offset="0"/>
                                                <GradientStop Color="#9CCDF0" Offset="1"/>
                                            </LinearGradientBrush>
                                        </Path.Fill>
                                    </Path>
                                    <Path Data="M360 510L495 424L570 505L532 485L500 535L468 501L430 552L403 531Z">
                                        <Path.Fill>
                                            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                                <GradientStop Color="#E5EEFF" Offset="0"/>
                                                <GradientStop Color="#FFFFFF" Offset="1"/>
                                            </LinearGradientBrush>
                                        </Path.Fill>
                                    </Path>
                                    <Path Data="M175 657L302 544L376 600L458 516L553 625L610 561L720 671L858 760V830H175Z">
                                        <Path.Fill>
                                            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                                <GradientStop Color="#2C72CB" Offset="0"/>
                                                <GradientStop Color="#5E9FDF" Offset="1"/>
                                            </LinearGradientBrush>
                                        </Path.Fill>
                                    </Path>
                                    <Path Data="M302 544L376 600L346 584L325 608L302 590L275 613Z" Fill="#BBDCF5" Opacity="0.9"/>
                                    <Path Data="M458 516L553 625L514 601L486 630L458 602L432 625Z" Fill="#CDE5FA" Opacity="0.85"/>
                                    <Path Data="M150 671L268 590L337 632L420 695L505 751L590 793L655 838H150Z">
                                        <Path.Fill>
                                            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                                <GradientStop Color="#08459F" Offset="0"/>
                                                <GradientStop Color="#0A62C2" Offset="1"/>
                                            </LinearGradientBrush>
                                        </Path.Fill>
                                    </Path>
                                    <Path Data="M268 590L337 632L420 695L505 751L590 793L458 741L382 699L320 653Z" Fill="#165DB8" Opacity="0.82"/>
                                    <Path Data="M515 830L590 760L675 700L760 747L880 683L900 830Z" Fill="#3984D4" Opacity="0.78"/>
                                    <Path Data="M675 700L760 747L720 735L690 759L654 730Z" Fill="#79B6E9" Opacity="0.62"/>
                                </Canvas>
                            </Canvas>
                        </Canvas>
                    </Viewbox>
                    <StackPanel VerticalAlignment="Center">
                        <TextBlock Text="AutoScape" FontSize="26" FontWeight="SemiBold" Foreground="#FFFFFF" Margin="0,0,0,2"/>
                        <TextBlock Text="Bing wallpapers, delivered daily" FontSize="13" Foreground="#9E9E9E" FontWeight="Normal" Margin="0,0,0,0"/>
                    </StackPanel>
                </StackPanel>
            </Grid>

            <ScrollViewer Grid.Row="1" Margin="0,0,0,18" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="1.35*" MinWidth="260" MaxWidth="380"/>
                    <ColumnDefinition Width="24"/>
                    <ColumnDefinition Width="2*" MinWidth="320"/>
                </Grid.ColumnDefinitions>

                <Grid Grid.Column="0">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <Grid Grid.Row="0" Margin="0,0,0,16">
                        <Border Name="GuidePreviewShadow" Background="#212121" CornerRadius="12" BorderThickness="0" IsHitTestVisible="False">
                            <Border.Effect>
                                <DropShadowEffect Color="#000000" BlurRadius="10" ShadowDepth="2" Opacity="0.3" Direction="270"/>
                            </Border.Effect>
                        </Border>
                        <Border Name="GuidePreviewCard" Background="#212121" CornerRadius="12" BorderThickness="0" ClipToBounds="True" Cursor="Hand">
                            <Grid>
                                <StackPanel IsHitTestVisible="False">
                                    <Border Height="185" CornerRadius="12,12,0,0" ClipToBounds="True" Background="#141414">
                                        <Image Name="GuideLatestImage" Stretch="UniformToFill"/>
                                    </Border>
                                    <StackPanel Margin="14,12,14,14">
                                        <TextBlock Name="GuideLatestTitle" Text="$cleanTitle" FontSize="15" FontWeight="SemiBold" Foreground="#FFFFFF" TextTrimming="CharacterEllipsis" Margin="0,0,0,4"/>
                                        <TextBlock Name="GuideLatestDate" Text="$cleanDate" FontSize="13" Foreground="#A0A0A0" TextTrimming="CharacterEllipsis"/>
                                    </StackPanel>
                                </StackPanel>
                                <Rectangle Name="GuideRevealRect" RadiusX="12" RadiusY="12" Opacity="0" IsHitTestVisible="False"/>
                                <Border Name="GuideRevealBorder" CornerRadius="12" BorderThickness="1.5" IsHitTestVisible="False"/>
                            </Grid>
                        </Border>
                    </Grid>

                    <Border Grid.Row="1" Name="GuideDefaultCard" Background="#212121" BorderBrush="#2E2E2E" BorderThickness="1" CornerRadius="12" Padding="20,18" VerticalAlignment="Top">
                        <StackPanel VerticalAlignment="Top">
                            <TextBlock Text="Default Behavior" FontSize="18" FontWeight="Bold" Foreground="#0078D4" Margin="0,0,0,16"/>
                            <TextBlock Text="4K resolution is used by default" FontSize="13.5" Foreground="#FFFFFF" TextWrapping="Wrap" LineHeight="20" Margin="0,0,0,12"/>
                            <TextBlock Text="Everyday wallpaper changes automatically at 12am" FontSize="13.5" Foreground="#FFFFFF" TextWrapping="Wrap" LineHeight="20" Margin="0,0,0,12"/>
                            <TextBlock Text="Fit is the default wallpaper style" FontSize="13.5" Foreground="#FFFFFF" TextWrapping="Wrap" LineHeight="20" Margin="0,0,0,12"/>
                            <TextBlock Text="Default region is selected based on your location" FontSize="13.5" Foreground="#FFFFFF" TextWrapping="Wrap" LineHeight="20" Margin="0,0,0,12"/>
                            <TextBlock Text="Wallpapers change hourly by default" FontSize="13.5" Foreground="#FFFFFF" TextWrapping="Wrap" LineHeight="20"/>
                        </StackPanel>
                    </Border>
                </Grid>

                <Border Grid.Column="2" Name="GuideFeaturesPanel" Background="#212121" BorderBrush="#2E2E2E" BorderThickness="1" CornerRadius="12" Padding="20,18" VerticalAlignment="Top">
                    <StackPanel>
                        <TextBlock Text="Essential Features" FontSize="18" FontWeight="Bold" Foreground="#0078D4" Margin="0,0,0,16"/>

                        <Border Background="#1A1A1A" CornerRadius="8" Padding="16,12" Margin="0,0,0,10">
                            <Grid VerticalAlignment="Center">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="36"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="&#xE896;" FontFamily="Segoe MDL2 Assets" FontSize="19" Foreground="#0078D4" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="16,0,0,0">
                                    <TextBlock Text="Download" FontSize="14.5" FontWeight="SemiBold" Foreground="#FAFAFA"/>
                                    <TextBlock Text="Save original 4K Ultra HD images directly to your device without any watermarks" FontSize="13" Foreground="#A0A0A0" TextWrapping="Wrap" LineHeight="18" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Grid>
                        </Border>

                        <Border Background="#1A1A1A" CornerRadius="8" Padding="16,12" Margin="0,0,0,10">
                            <Grid VerticalAlignment="Center">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="36"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="&#xE8B9;" FontFamily="Segoe MDL2 Assets" FontSize="19" Foreground="#00CACC" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="16,0,0,0">
                                    <TextBlock Text="Browse" FontSize="14.5" FontWeight="SemiBold" Foreground="#FAFAFA"/>
                                    <TextBlock Text="Explore recent days of Bing imagery. Single click to inspect, double-click to apply" FontSize="13" Foreground="#A0A0A0" TextWrapping="Wrap" LineHeight="18" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Grid>
                        </Border>

                        <Border Background="#1A1A1A" CornerRadius="8" Padding="16,12" Margin="0,0,0,10">
                            <Grid VerticalAlignment="Center">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="36"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="&#xE771;" FontFamily="Segoe MDL2 Assets" FontSize="19" Foreground="#60CDFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="16,0,0,0">
                                    <TextBlock Text="Apply Wallpaper" FontSize="14.5" FontWeight="SemiBold" Foreground="#FAFAFA"/>
                                    <TextBlock Text="Set image for Desktop, Lock Screen, or Both with customized sizing (Fit, Fill, Stretch, Center, Span)" FontSize="13" Foreground="#A0A0A0" TextWrapping="Wrap" LineHeight="18" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Grid>
                        </Border>

                        <Border Background="#1A1A1A" CornerRadius="8" Padding="16,12" Margin="0,0,0,10">
                            <Grid VerticalAlignment="Center">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="36"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="&#xE774;" FontFamily="Segoe MDL2 Assets" FontSize="19" Foreground="#A78BFA" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="16,0,0,0">
                                    <TextBlock Text="Customize Region" FontSize="14.5" FontWeight="SemiBold" Foreground="#FAFAFA"/>
                                    <TextBlock Text="Switch between global regions (US, UK, Japan, Germany, etc.) for localized photography" FontSize="13" Foreground="#A0A0A0" TextWrapping="Wrap" LineHeight="18" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Grid>
                        </Border>

                        <Border Background="#1A1A1A" CornerRadius="8" Padding="16,12" Margin="0,0,0,10">
                            <Grid VerticalAlignment="Center">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="36"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="&#xE72C;" FontFamily="Segoe MDL2 Assets" FontSize="19" Foreground="#34D399" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="16,0,0,0">
                                    <TextBlock Text="Automatic Changes" FontSize="14.5" FontWeight="SemiBold" Foreground="#FAFAFA"/>
                                    <TextBlock Text="Enable Auto switch to cycle wallpapers at custom intervals (1 min, Hourly, Daily, on Login)" FontSize="13" Foreground="#A0A0A0" TextWrapping="Wrap" LineHeight="18" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Grid>
                        </Border>

                        <Border Background="#1A1A1A" CornerRadius="8" Padding="16,12">
                            <Grid VerticalAlignment="Center">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="36"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="&#xE838;" FontFamily="Segoe MDL2 Assets" FontSize="19" Foreground="#FBBF24" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="16,0,0,0">
                                    <TextBlock Text="Download Location" FontSize="14.5" FontWeight="SemiBold" Foreground="#FAFAFA"/>
                                    <TextBlock Text="Click the folder path at any time to choose where your saved wallpapers are stored" FontSize="13" Foreground="#A0A0A0" TextWrapping="Wrap" LineHeight="18" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Grid>
                        </Border>
                    </StackPanel>
                </Border>
            </Grid>
            </ScrollViewer>

            <StackPanel Grid.Row="2" Margin="0,12,0,0" HorizontalAlignment="Center">
                <Border Background="#1E1E1E" BorderBrush="#2E2E2E" BorderThickness="1" CornerRadius="24" Padding="6">
                    <StackPanel Orientation="Horizontal">
                        <Button Name="GuideGithubRepoBtn" Height="36" Padding="12,0" Background="Transparent" Foreground="#D8D8D8" BorderThickness="0" Cursor="Hand" ToolTip="Open GitHub Repository" ToolTipService.InitialShowDelay="600" ToolTipService.BetweenShowDelay="600">
                            <Button.Template>
                                <ControlTemplate TargetType="Button">
                                    <Border Name="PillBg" Background="{TemplateBinding Background}" CornerRadius="18" Padding="{TemplateBinding Padding}">
                                        <Viewbox Width="18" Height="18" HorizontalAlignment="Center" VerticalAlignment="Center">
                                            <Canvas Width="24" Height="24">
                                                <Path Data="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0 0 24 12c0-6.63-5.37-12-12-12z" Fill="#A371F7"/>
                                            </Canvas>
                                        </Viewbox>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="PillBg" Property="Background" Value="#2A2A2A"/>
                                            <Setter Property="Foreground" Value="#FFFFFF"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Button.Template>
                        </Button>

                        <Border Width="1" Height="20" Background="#333333" VerticalAlignment="Center" Margin="4,0"/>

                        <Button Name="GuideShortcutsBtn" Height="36" Padding="14,0" Background="Transparent" Foreground="#D8D8D8" BorderThickness="0" Cursor="Hand">
                            <Button.Template>
                                <ControlTemplate TargetType="Button">
                                    <Border Name="PillBg" Background="{TemplateBinding Background}" CornerRadius="18" Padding="{TemplateBinding Padding}">
                                        <StackPanel Orientation="Horizontal">
                                            <TextBlock Text="&#xE765;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="#FB7185" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                            <TextBlock Text="Keyboard Shortcuts" FontSize="13" FontWeight="SemiBold" Foreground="{TemplateBinding Foreground}" VerticalAlignment="Center"/>
                                        </StackPanel>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="PillBg" Property="Background" Value="#2A2A2A"/>
                                            <Setter Property="Foreground" Value="#FFFFFF"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Button.Template>
                        </Button>

                        <Border Width="1" Height="20" Background="#333333" VerticalAlignment="Center" Margin="4,0"/>

                        <Button Name="GuideCheckUpdateBtn" Height="36" Padding="14,0" Background="Transparent" Foreground="#D8D8D8" BorderThickness="0" Cursor="Hand">
                            <Button.Template>
                                <ControlTemplate TargetType="Button">
                                    <Border Name="PillBg" Background="{TemplateBinding Background}" CornerRadius="18" Padding="{TemplateBinding Padding}">
                                        <StackPanel Orientation="Horizontal">
                                            <TextBlock Text="&#xE896;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="#0078D4" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                            <TextBlock Text="Check for Updates" FontSize="13" FontWeight="SemiBold" Foreground="{TemplateBinding Foreground}" VerticalAlignment="Center"/>
                                        </StackPanel>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="PillBg" Property="Background" Value="#2A2A2A"/>
                                            <Setter Property="Foreground" Value="#FFFFFF"/>
                                        </Trigger>
                                        <Trigger Property="IsEnabled" Value="False">
                                            <Setter TargetName="PillBg" Property="Opacity" Value="0.5"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Button.Template>
                        </Button>
                    </StackPanel>
                </Border>

                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,12,0,0">
                    <TextBlock Text="Crafted with " FontSize="13" Foreground="#7A7A7A" VerticalAlignment="Center"/>
                    <TextBlock Name="GuideHeartIcon" Text="&#xEB52;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="#FF334B" VerticalAlignment="Center" Margin="3,2,3,0"/>
                    <TextBlock Text=" by HamB" FontSize="13" Foreground="#7A7A7A" VerticalAlignment="Center"/>
                </StackPanel>
            </StackPanel>
        </Grid>
    </Border>
</UserControl>
"@

    $r = New-Object System.Xml.XmlNodeReader ([xml]$dialogXaml)
    $dlg = [Windows.Markup.XamlReader]::Load($r)

    $guideRoot = $dlg.FindName('DialogRoot')
    if ($guideRoot) { $guideRoot.Opacity = 1.0 }

    $guideGithubRepoBtn = $dlg.FindName('GuideGithubRepoBtn')
    if ($guideGithubRepoBtn) {
        Enable-StrictToolTipDelay $guideGithubRepoBtn
        $guideGithubRepoBtn.Add_Click({
                try {
                    Start-Process "https://github.com/Hamisoptimistic/Bing-Wallpaper" | Out-Null
                }
                catch {}
            })
    }

    $guideShortcutsBtn = $dlg.FindName('GuideShortcutsBtn')
    if ($guideShortcutsBtn) {
        $guideShortcutsBtn.Add_Click({
                try {
                    Show-ModernDialog -Title "AutoScape" -Header "Keyboard Shortcuts" -Icon "Info" -Buttons "OK" `
                        -Message "Handy shortcuts you can use anywhere in the app:" `
                        -Details "- Ctrl+S - Download the selected wallpaper`n- Ctrl+B - Set as desktop background`n- Ctrl+L - Set as lock screen`n- F5 - Refresh the gallery`n- Esc - Close the open dialog" | Out-Null
                }
                catch {
                    Show-AppErrorDialog `
                        -Message "Show-ModernDialog (shortcuts) failed:`n`n$($_.Exception.GetType().FullName)`n$($_.Exception.Message)`n`n$($_.ScriptStackTrace)" `
                        -Title "Shortcuts dialog error"
                }
            })
    }

    # Reuses the same $CheckUpdateBtn plumbing Start-VerifiedUpdate already
    # expects (enable/disable while a check is in flight), just pointed at
    # this button instead of the old Info modal's button.
    $script:CheckUpdateBtn = $dlg.FindName('GuideCheckUpdateBtn')
    if ($script:CheckUpdateBtn) {
        $script:CheckUpdateBtn.Add_Click({ Invoke-CheckForUpdatesClick })
    }

    $imgControl = $dlg.FindName('GuideLatestImage')
    if ($imgControl -and $thumbPath) {
        try {
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit()
            $bmp.UriSource = New-Object System.Uri($thumbPath)
            $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bmp.EndInit()
            $bmp.Freeze()
            [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($imgControl, [System.Windows.Media.BitmapScalingMode]::HighQuality)
            $imgControl.Source = $bmp
        }
        catch {}
    }

    $heart = $dlg.FindName('GuideHeartIcon')
    if ($heart) {
        try {
            $scale = New-Object System.Windows.Media.ScaleTransform(1.0, 1.0)
            $heart.RenderTransform = $scale
            $heart.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)

            $glow = New-Object System.Windows.Media.Effects.DropShadowEffect
            $glow.Color = [System.Windows.Media.Color]::FromRgb(255, 51, 75)
            $glow.ShadowDepth = 0
            $glow.BlurRadius = 6
            $glow.Opacity = 0.85
            $heart.Effect = $glow

            $scaleAnim = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
            $scaleAnim.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(1200))
            $scaleAnim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever

            $scaleAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame(1.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(0))))) | Out-Null
            $scaleAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.35, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(140))))) | Out-Null
            $scaleAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.06, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(260))))) | Out-Null
            $scaleAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.25, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(380))))) | Out-Null
            $scaleAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(540))))) | Out-Null
            $scaleAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame(1.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(1200))))) | Out-Null

            $glowAnim = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
            $glowAnim.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(1200))
            $glowAnim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever

            $glowAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame(6.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(0))))) | Out-Null
            $glowAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(18.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(140))))) | Out-Null
            $glowAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(8.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(260))))) | Out-Null
            $glowAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(14.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(380))))) | Out-Null
            $glowAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(6.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(540))))) | Out-Null
            $glowAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame(6.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(1200))))) | Out-Null

            $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $scaleAnim)
            $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $scaleAnim)
            $glow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty, $glowAnim)
        }
        catch {}
    }

    $card = $dlg.FindName('GuidePreviewCard')
    $previewShadow = $dlg.FindName('GuidePreviewShadow')
    $defaultCard = $dlg.FindName('GuideDefaultCard')
    $featuresPanel = $dlg.FindName('GuideFeaturesPanel')
    $revealRect = $dlg.FindName('GuideRevealRect')
    $revealBorder = $dlg.FindName('GuideRevealBorder')

    $syncGuideColumns = {
        try {
            if (-not $defaultCard -or -not $featuresPanel -or -not $card) { return }
            $previewHeight = $card.ActualHeight + 16
            $defaultNatural = $defaultCard.DesiredSize.Height
            $featuresNatural = $featuresPanel.DesiredSize.Height
            $bodyHeight = [Math]::Max($featuresNatural, ($previewHeight + $defaultNatural))
            $defaultCard.MinHeight = [Math]::Max(0, $bodyHeight - $previewHeight)
            $featuresPanel.MinHeight = $bodyHeight
        }
        catch {}
    }

    if ($featuresPanel) { $featuresPanel.Add_SizeChanged({ & $syncGuideColumns }) }
    if ($card) {
        $card.Add_SizeChanged({ & $syncGuideColumns })
        $dlg.Add_Loaded({
                $dlg.Dispatcher.BeginInvoke([Action] { & $syncGuideColumns }, [System.Windows.Threading.DispatcherPriority]::Loaded) | Out-Null
            })
    }

    if ($card) {
        $cardClip = New-Object System.Windows.Media.RectangleGeometry
        $cardClip.RadiusX = 12
        $cardClip.RadiusY = 12
        $card.Clip = $cardClip
        $card.Add_SizeChanged({
                param($s, $e)
                $s.Clip.Rect = [System.Windows.Rect]::new(0, 0, $s.ActualWidth, $s.ActualHeight)
            })

        $revealBrush = New-Object System.Windows.Media.RadialGradientBrush
        $revealBrush.MappingMode = [System.Windows.Media.BrushMappingMode]::Absolute
        $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(28, 255, 255, 255), 0.0)))
        $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(14, 255, 255, 255), 0.4)))
        $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(4, 255, 255, 255), 0.75)))
        $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(0, 255, 255, 255), 1.0)))
        $revealBrush.RadiusX = 180
        $revealBrush.RadiusY = 180
        if ($revealRect) { $revealRect.Fill = $revealBrush }

        $revealBorderBrush = New-Object System.Windows.Media.RadialGradientBrush
        $revealBorderBrush.MappingMode = [System.Windows.Media.BrushMappingMode]::Absolute
        $revealBorderBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(90, 255, 255, 255), 0.0)))
        $revealBorderBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(0, 255, 255, 255), 1.0)))
        $revealBorderBrush.RadiusX = 160
        $revealBorderBrush.RadiusY = 160
        if ($revealBorder) { $revealBorder.BorderBrush = $revealBorderBrush }

        $cardUnselected = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 33, 33, 33))
        $cardHover = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 45, 45, 45))

        $card.Add_MouseEnter({
                $card.Background = $cardHover
                if ($previewShadow -and $previewShadow.Effect) {
                    $previewShadow.Effect.BlurRadius = 25
                    $previewShadow.Effect.ShadowDepth = 8
                }
                if ($revealRect) { $revealRect.Opacity = 1 }
            })

        $card.Add_MouseLeave({
                $card.Background = $cardUnselected
                if ($previewShadow -and $previewShadow.Effect) {
                    $previewShadow.Effect.BlurRadius = 10
                    $previewShadow.Effect.ShadowDepth = 2
                }
                if ($revealRect) { $revealRect.Opacity = 0 }
            })

        $card.Add_MouseMove({
                param($s, $e)
                try {
                    $pos = $e.GetPosition($card)
                    $revealBrush.Center = $pos
                    $revealBrush.GradientOrigin = $pos
                    $revealBorderBrush.Center = $pos
                    $revealBorderBrush.GradientOrigin = $pos
                }
                catch {}
            })
    }

    $script:activeGuideDialog = $dlg
    $closeButton = $dlg.FindName('GuideCloseButton')
    if ($closeButton) { $closeButton.Add_Click({ Close-UserGuideDialog }) }

    $dlg.Add_PreviewKeyDown({
            param($s, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Escape) { $e.Handled = $true; Close-UserGuideDialog }
        })

    Open-InWindowModal -Control $dlg -Kind 'Guide' -CloseCallback {
        $script:activeGuideDialog = $null
        $script:CheckUpdateBtn = $null
    }
}
