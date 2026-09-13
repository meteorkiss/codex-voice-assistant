# Presentation only: business events and persistence are owned by Assistant.ps1.
$script:DesktopShellSourceRoot = $PSScriptRoot

function Import-DesktopShellTypes {
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
    if (-not ('ShengBan.Desktop.WaveformView' -as [type])) {
        Add-Type -Path (Join-Path $script:DesktopShellSourceRoot 'WaveformView.cs') -ReferencedAssemblies @('PresentationFramework','PresentationCore','WindowsBase','System.Xaml')
    }
}

function Read-DesktopShellWindow {
    param([string]$Path, [hashtable]$Controls)
    [xml]$document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $reader = New-Object Xml.XmlNodeReader $document
    try { $view = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    foreach ($element in $document.SelectNodes('//*[@Name]')) {
        $name = $element.GetAttribute('Name')
        $control = $view.FindName($name)
        if ($control) { $Controls[$name] = $control }
    }
    return $view
}

function Get-DesktopShellWorkArea {
    param([hashtable]$Shell)
    return [ShengBan.Desktop.DesktopPlacement]::GetWorkArea($Shell.Window)
}

function Set-DesktopShellPosition {
    param([hashtable]$Shell, [double]$Left, [double]$Top)
    $window = $Shell.Window
    if ([double]::IsNaN($Left) -or [double]::IsInfinity($Left) -or [double]::IsNaN($Top) -or [double]::IsInfinity($Top)) { Reset-DesktopShellPosition $Shell; return }
    # Assign first so MonitorFromWindow chooses the restored monitor, then clamp.
    $window.Left = $Left; $window.Top = $Top
    $area = Get-DesktopShellWorkArea $Shell
    $window.Left = [Math]::Max($area.Left, [Math]::Min($Left, $area.Right - $window.Width))
    $window.Top = [Math]::Max($area.Top, [Math]::Min($Top, $area.Bottom - $window.Height))
    Update-DesktopCaptionPosition $Shell
}

function Set-DesktopShellSize {
    param([hashtable]$Shell, [double]$Size = 260, [string]$Style = '')
    if ([double]::IsNaN($Size) -or [double]::IsInfinity($Size)) { $Size = 260 }
    $Size = [Math]::Max(180, [Math]::Min(360, $Size))
    if (-not $Style) { $Style = $Shell.Waveform.StyleName }
    $window = $Shell.Window
    $centerX = $window.Left + $window.Width / 2; $centerY = $window.Top + $window.Height / 2
    $window.Width = $Size; $window.Height = if ($Style -in @('bars','flow')) { $Size * 0.4 } else { $Size }
    $Shell.Size = $Size
    $Shell.Controls.SizeValueLabel.Text = [string][int]$Size
    Set-DesktopCenterControlsSize $Shell $Size
    Set-DesktopShellPosition $Shell ($centerX - $window.Width / 2) ($centerY - $window.Height / 2)
}

function Set-DesktopCenterControlsSize {
    param([hashtable]$Shell,[double]$Size)
    $diameter=[Math]::Max(26,[Math]::Min(36,[Math]::Round($Size*34/260)))
    $gap=[Math]::Max(4,[Math]::Min(8,[Math]::Round($Size*6/260)))
    foreach($name in @('CenterPlaybackButton','CenterStopButton')){
        $button=$Shell.Controls[$name]
        if($button){
            $button.Width=$diameter;$button.Height=$diameter
            $button.Clip=New-Object Windows.Media.EllipseGeometry((New-Object Windows.Point(($diameter/2),($diameter/2))),($diameter/2),($diameter/2))
        }
    }
    if($Shell.Controls.CenterStopButton){$Shell.Controls.CenterStopButton.Margin=New-Object Windows.Thickness($gap,0,0,0)}
}

function Update-DesktopCaptionPosition {
    param([hashtable]$Shell)
    if ($Shell.FollowCaption -eq $false) { return }
    $window = $Shell.Window; $caption = $Shell.CaptionWindow
    $area = Get-DesktopShellWorkArea $Shell
    $left = $window.Left + ($window.Width - $caption.Width) / 2
    $top = $window.Top + $window.Height + 10
    if ($top + $caption.Height -gt $area.Bottom) { $top = $window.Top - $caption.Height - 10 }
    $caption.Left = [Math]::Max($area.Left, [Math]::Min($left, $area.Right - $caption.Width))
    $caption.Top = [Math]::Max($area.Top, [Math]::Min($top, $area.Bottom - $caption.Height))
}

function Reset-DesktopShellPosition {
    param([hashtable]$Shell)
    $Shell.FollowCaption = $true
    $area = Get-DesktopShellWorkArea $Shell
    Set-DesktopShellPosition $Shell ($area.Right - $Shell.Window.Width - 45) ($area.Top + 70)
}

function Show-DesktopSettings {
    param([hashtable]$Shell)
    $settings = $Shell.SettingsWindow
    if (-not $settings.IsVisible) {
        $area = Get-DesktopShellWorkArea $Shell
        $settings.Height = [Math]::Min(640, [Math]::Max(440, $area.Height - 50))
        $settings.Left = $area.Left + [Math]::Max(0, ($area.Width - $settings.Width) / 2)
        $settings.Top = $area.Top + [Math]::Max(0, ($area.Height - $settings.Height) / 2)
        $settings.Show()
    }
    if ($settings.WindowState -eq 'Minimized') { $settings.WindowState = 'Normal' }
    [void]$settings.Activate()
}

function Set-DesktopSettingsPage {
    param([hashtable]$Shell, [int]$Index=0)
    $Index=[Math]::Max(0,[Math]::Min(2,$Index))
    $pages=@('ConnectionPage','SoundPage','AppearancePage')
    $titles=@('连接','声音','外观')
    for($i=0;$i -lt $pages.Count;$i++) { $Shell.Controls[$pages[$i]].Visibility=if($i -eq $Index){'Visible'}else{'Collapsed'} }
    $Shell.Controls.SettingsPageTitle.Text=$titles[$Index]
    if($Shell.Controls.SettingsNavigation.SelectedIndex -ne $Index){$Shell.Controls.SettingsNavigation.SelectedIndex=$Index}
    $Shell.SettingsPage=$Index
}

function Set-DesktopCaptionsVisible {
    param([hashtable]$Shell, [bool]$Visible)
    if ($Visible) { Update-DesktopCaptionPosition $Shell; $Shell.CaptionWindow.Show() }
    else { $Shell.CaptionWindow.Hide() }
}

function Update-DesktopWakePhraseLayout {
    param([hashtable]$Shell)
    $narrow=$Shell.Controls.WakePhraseRow.ActualWidth -lt 380
    $actions=$Shell.Controls.WakePhraseActions
    [Windows.Controls.Grid]::SetRow($actions, $(if($narrow){1}else{0}))
    [Windows.Controls.Grid]::SetColumn($actions, $(if($narrow){1}else{2}))
    [Windows.Controls.Grid]::SetColumnSpan($actions, $(if($narrow){2}else{1}))
    [Windows.Controls.Grid]::SetColumnSpan($Shell.Controls.WakePhraseBox, $(if($narrow){2}else{1}))
    $actions.Margin=if($narrow){'0,6,0,0'}else{'8,0,0,0'}
}

function Close-DesktopShell {
    param([hashtable]$Shell)
    $Shell.AllowClose = $true
    foreach ($view in @($Shell.SettingsWindow,$Shell.CaptionWindow,$Shell.Window)) {
        if (-not $Shell.ClosedWindows.ContainsKey($view.Name)) { $view.Close() }
    }
}

function New-DesktopCenterPlaybackButton {
    # The clip is also used by WPF hit testing: the transparent square corners
    # are not part of this native button's interactive area.
    [xml]$markup=@'
<Button xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Name="CenterPlaybackButton" Width="44" Height="44" HorizontalAlignment="Center" VerticalAlignment="Center"
        Tag="play" ToolTip="播放回答" AutomationProperties.Name="播放或暂停回答" Cursor="Hand" FocusVisualStyle="{x:Null}"
        Background="{x:Null}" BorderThickness="0" ContextMenuService.ShowOnDisabled="True" ToolTipService.ShowOnDisabled="True">
  <Button.Clip><EllipseGeometry Center="22,22" RadiusX="22" RadiusY="22"/></Button.Clip>
  <Button.Style><Style TargetType="Button">
    <Setter Property="Opacity" Value="0.30"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Viewbox Stretch="Uniform"><Grid Width="44" Height="44" Background="{x:Null}">
        <Ellipse Fill="#D9EFF1F5" Stroke="#99929AA7" StrokeThickness="0.8" Margin="0.6"/>
        <Path Name="PlayGlyph" Data="M 18,14.5 L 29,22 L 18,29.5 Z" Fill="#FF343D4A" StrokeLineJoin="Round"/>
        <Path Name="PauseGlyph" Visibility="Collapsed" Data="M 17.5,15 L 17.5,29 M 26.5,15 L 26.5,29" Stroke="#FF343D4A" StrokeThickness="3" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
        <Rectangle Name="StopGlyph" Visibility="Collapsed" Width="13" Height="13" RadiusX="1.5" RadiusY="1.5" Fill="#FF343D4A" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Grid></Viewbox>
      <ControlTemplate.Triggers><Trigger Property="Tag" Value="pause"><Setter TargetName="PlayGlyph" Property="Visibility" Value="Collapsed"/><Setter TargetName="PauseGlyph" Property="Visibility" Value="Visible"/></Trigger><Trigger Property="Tag" Value="stop"><Setter TargetName="PlayGlyph" Property="Visibility" Value="Collapsed"/><Setter TargetName="StopGlyph" Property="Visibility" Value="Visible"/></Trigger></ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Opacity" Value="0.60"/></Trigger>
      <Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="Opacity" Value="0.60"/></Trigger>
      <Trigger Property="IsPressed" Value="True"><Setter Property="Opacity" Value="0.70"/></Trigger>
      <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.15"/></Trigger>
    </Style.Triggers>
  </Style></Button.Style>
</Button>
'@
    $reader=New-Object Xml.XmlNodeReader $markup
    try { return [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
}

function New-DesktopShell {
    Import-DesktopShellTypes
    $controls = @{}
    $settings = Read-DesktopShellWindow (Join-Path $script:DesktopShellSourceRoot 'SettingsWindow.xaml') $controls
    $caption = Read-DesktopShellWindow (Join-Path $script:DesktopShellSourceRoot 'CaptionWindow.xaml') $controls
    $controls.CaptionText = $controls.AnswerBox
    $controls.CaptionTask = $controls.CaptionTaskLabel
    $controls.TaskDirectoryLabel = $controls.BoundDirectoryLabel
    $window = New-Object Windows.Window
    $window.Name = 'MainWindow'; $window.Title = '声伴'; $window.Width = 260; $window.Height = 260
    $window.WindowStyle = 'None'; $window.AllowsTransparency = $true; $window.Background = $null
    $window.ResizeMode = 'NoResize'; $window.ShowInTaskbar = $false; $window.ShowActivated = $false
    $window.Topmost = $true; $window.Left = 0; $window.Top = 0
    $wave = New-Object ShengBan.Desktop.WaveformView
    $overlay = New-Object Windows.Controls.Grid
    $overlay.Background = $null
    [void]$overlay.Children.Add($wave)
    $centerPlayback = New-DesktopCenterPlaybackButton
    $centerStop = New-DesktopCenterPlaybackButton
    $centerStop.Name='CenterStopButton';$centerStop.Tag='stop';$centerStop.ToolTip='停止朗读'
    [Windows.Automation.AutomationProperties]::SetName($centerStop,'停止朗读')
    $centerGroup=New-Object Windows.Controls.StackPanel
    $centerGroup.Name='CenterPlaybackGroup';$centerGroup.Orientation='Horizontal';$centerGroup.HorizontalAlignment='Center';$centerGroup.VerticalAlignment='Center';$centerGroup.Background=$null
    [void]$centerGroup.Children.Add($centerPlayback);[void]$centerGroup.Children.Add($centerStop)
    [void]$overlay.Children.Add($centerGroup)
    $controls.CenterPlaybackButton = $centerPlayback
    $controls.CenterStopButton = $centerStop
    $controls.CenterPlaybackGroup = $centerGroup
    $window.Content = $overlay
    $menu = New-Object Windows.Controls.ContextMenu
    $menu.FontFamily = 'Microsoft YaHei UI'; $menu.FontSize = 13; $menu.Padding = '5'
    foreach ($entry in @(
        @('MenuPin','始终置顶',$true), @('MenuSettings','打开设置',$false),
        @('MenuCaptions','显示字幕与输入',$true), @('MenuPauseResume','暂停朗读',$false), @('MenuStop','停止朗读',$false),
        @('MenuFollowUpEnd','结束连续接话',$false),
        @('MenuVisibility','隐藏悬浮声波',$false)
    )) {
        if ($entry[0] -eq 'MenuVisibility') { [void]$menu.Items.Add((New-Object Windows.Controls.Separator)) }
        $item = New-Object Windows.Controls.MenuItem
        $item.Name = $entry[0]; $item.Header = $entry[1]; $item.IsCheckable = [bool]$entry[2]
        if ($entry[0] -eq 'MenuPin') { $item.IsChecked = $true }
        [void]$menu.Items.Add($item); $controls[$entry[0]] = $item
    }
    $wave.ContextMenu = $menu
    $centerPlayback.ContextMenu = $menu
    $centerStop.ContextMenu = $menu
    $shell = @{ Window=$window; SettingsWindow=$settings; CaptionWindow=$caption; Controls=$controls; Waveform=$wave; Menu=$menu; Size=260; FollowCaption=$true; AllowClose=$false; ClosedWindows=@{} }
    foreach ($view in @($window,$settings,$caption,$wave,$controls.CaptionDragHandle)) { $view.Tag=$shell }
    $controls.SettingsNavigation.Tag=$shell
    $controls.WakePhraseRow.Tag=$shell
    $controls.WakePhraseRow.Add_SizeChanged({ param($sender,$eventArgs) Update-DesktopWakePhraseLayout $sender.Tag })
    $controls.SettingsNavigation.Add_SelectionChanged({ param($sender,$eventArgs) if($eventArgs.Source -eq $sender -and $sender.SelectedIndex -ge 0){Set-DesktopSettingsPage $sender.Tag $sender.SelectedIndex} })
    # Keep handlers in the caller's script session; GetNewClosure creates a dynamic
    # module whose delayed callbacks cannot reliably resolve the module functions.
    $wave.Add_MouseLeftButtonDown({ param($sender,$eventArgs) $ui=$sender.Tag; if ($eventArgs.ButtonState -eq 'Pressed') { try { $ui.Window.DragMove(); Set-DesktopShellPosition $ui $ui.Window.Left $ui.Window.Top } catch {} $eventArgs.Handled=$true } })
    $window.Add_LocationChanged({ param($sender,$eventArgs) Update-DesktopCaptionPosition $sender.Tag })
    $window.Add_SizeChanged({ param($sender,$eventArgs) Update-DesktopCaptionPosition $sender.Tag })
    $caption.Add_SizeChanged({ param($sender,$eventArgs) Update-DesktopCaptionPosition $sender.Tag })
    $controls.CaptionDragHandle.Add_MouseLeftButtonDown({
        param($sender,$eventArgs)
        $node=$eventArgs.OriginalSource
        while ($node -and $node -ne $sender) { if ($node -is [Windows.Controls.Primitives.ButtonBase]) { return }; $node=[Windows.Media.VisualTreeHelper]::GetParent($node) }
        $ui=$sender.Tag; $ui.FollowCaption=$false
        try {
            $ui.CaptionWindow.DragMove()
            $area=[ShengBan.Desktop.DesktopPlacement]::GetWorkArea($ui.CaptionWindow)
            $ui.CaptionWindow.Left=[Math]::Max($area.Left,[Math]::Min($ui.CaptionWindow.Left,$area.Right-$ui.CaptionWindow.Width))
            $ui.CaptionWindow.Top=[Math]::Max($area.Top,[Math]::Min($ui.CaptionWindow.Top,$area.Bottom-$ui.CaptionWindow.Height))
        } catch {}
    })
    $settings.Add_Closing({ param($sender,$eventArgs) if (-not $sender.Tag.AllowClose) { $eventArgs.Cancel=$true; $sender.Hide() } })
    $caption.Add_Closing({ param($sender,$eventArgs) if (-not $sender.Tag.AllowClose) { $eventArgs.Cancel=$true; $sender.Hide() } })
    foreach ($view in @($window,$settings,$caption)) { $view.Add_Closed({ param($sender,$eventArgs) $sender.Tag.ClosedWindows[$sender.Name]=$true }) }
    # Settings must not inherit the floating window's native topmost band.
    $window.Add_SourceInitialized({ param($sender,$eventArgs) $ui=$sender.Tag; $ui.CaptionWindow.Owner=$sender; Set-DesktopShellPosition $ui $sender.Left $sender.Top })
    [void](New-Object Windows.Interop.WindowInteropHelper($window)).EnsureHandle()
    $wave.SetFrame('rays',0,'idle',0)
    Set-DesktopCenterControlsSize $shell 260
    Set-DesktopSettingsPage $shell 0
    Reset-DesktopShellPosition $shell
    return $shell
}
