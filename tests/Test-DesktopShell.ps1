param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $Root 'src\DesktopShell.ps1')
$outDir=Join-Path $Root 'work\desktop-shell-render'
[void](New-Item -ItemType Directory -Path $outDir -Force)
$shell=New-DesktopShell
$checks=New-Object Collections.Generic.List[string]
function Assert-Ui($Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $checks.Add($Message) }
function Render-Element($Element,[int]$Width,[int]$Height,[string]$Name,[string]$Background='') {
    $Element.Measure((New-Object Windows.Size($Width,$Height)))
    $Element.Arrange((New-Object Windows.Rect(0,0,$Width,$Height)))
    $Element.UpdateLayout()
    $render=New-Object Windows.Media.Imaging.RenderTargetBitmap($Width,$Height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $render.Render($Element)
    if ($Background) {
        $visual=New-Object Windows.Media.DrawingVisual
        $drawing=$visual.RenderOpen()
        $brush=[Windows.Media.BrushConverter]::new().ConvertFromString($Background)
        $bounds=New-Object Windows.Rect(0,0,$Width,$Height)
        $drawing.DrawRectangle($brush,$null,$bounds)
        $drawing.DrawImage($render,$bounds)
        $drawing.Close()
        $composite=New-Object Windows.Media.Imaging.RenderTargetBitmap($Width,$Height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
        $composite.Render($visual)
        $render=$composite
    }
    $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($render))
    $stream=[IO.File]::Create((Join-Path $outDir ($Name+'.png')))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    return $render
}
try {
    foreach($controlName in @('SettingsNavigation','SettingsPageTitle','ConnectionPage','SoundPage','AppearancePage','BargeInToggle','EchoStatusLabel','WakePhraseBox','WakeHintLabel','SaveWakePhraseButton','ResetWakePhraseButton','PauseResumeButton','MenuPauseResume','CenterPlaybackButton','CenterStopButton','CenterPlaybackGroup')){Assert-Ui ($shell.Controls.ContainsKey($controlName)) ('control '+$controlName)}
    Assert-Ui (-not $shell.Controls.WakePhraseBox.IsReadOnly) 'wake phrase is editable'
    Assert-Ui ($shell.Controls.WakeHintLabel.TextWrapping -eq 'Wrap') 'wake validation status can wrap'
    Assert-Ui ($shell.Controls.PauseResumeButton.Content -eq '暂停朗读' -and $shell.Controls.MenuPauseResume.Header -eq '暂停朗读') 'pause and resume entries start with pause label'
    Assert-Ui ($shell.Menu.Items.IndexOf($shell.Controls.MenuPauseResume) -eq ($shell.Menu.Items.IndexOf($shell.Controls.MenuStop)-1)) 'pause entry immediately precedes stop'
    foreach ($name in @('TaskLabel','StatusLabel','AnswerBox','InputBox','SpeakButton','SendButton','StopButton','PinToggle','HandsFreeToggle','FooterHint','AnswerStateLabel','DirectoryCombo','TaskCombo','RefreshTasksButton','BindTaskButton','OpenTaskButton','VoiceCombo','RateCombo','AutoReadToggle','AutoSendToggle','StyleCombo','SizeSlider','CaptionToggle','ResetPositionButton','MenuPin','MenuSettings','MenuCaptions','MenuStop','MenuVisibility','CaptionText','CaptionTask','CaptionStatus','TaskDirectoryLabel','PreviewVoiceButton','ReplayButton','CaptionExpandButton','CaptionCloseButton')) {
        Assert-Ui ($shell.Controls.ContainsKey($name) -and $null -ne $shell.Controls[$name]) ('control '+$name)
    }
    foreach ($style in @('rays','halo','particles','minimal','bars','flow')) {
        $wave=New-Object ShengBan.Desktop.WaveformView
        $height=if($style -in @('bars','flow')){104}else{260}
        $wave.SetFrame($style,.65,'listen',1.25)
        $bitmap=Render-Element $wave 260 $height ('wave-'+$style)
        $bytes=New-Object byte[] (260*$height*4)
        $bitmap.CopyPixels($bytes,260*4,0)
        Assert-Ui ($bytes[3] -eq 0) ($style+' outside alpha is zero')
        Assert-Ui (-not $wave.IsInteractivePoint((New-Object Windows.Point(0,0)))) ($style+' outside rejects hit')
        $visibleCount=0
        for($i=3;$i -lt $bytes.Length;$i+=4){if($bytes[$i] -gt 0){$visibleCount++}}
        Assert-Ui ($visibleCount -gt 100) ($style+' has drawn pixels')
        if($style -notin @('bars','flow')) {
            Assert-Ui ($bytes[(130*260+130)*4+3] -eq 0) ($style+' center alpha is zero')
            Assert-Ui (-not $wave.IsInteractivePoint((New-Object Windows.Point(130,130)))) ($style+' center rejects hit')
            Assert-Ui ($wave.IsInteractivePoint((New-Object Windows.Point(215,130)))) ($style+' annulus accepts hit')
            $centerPixels=0
            for($y=80;$y -le 180;$y++){for($x=80;$x -le 180;$x++){if(($x-130)*($x-130)+($y-130)*($y-130) -le 2500){$centerPixels += $bytes[($y*260+$x)*4+3]}}}
            Assert-Ui ($centerPixels -eq 0) ($style+' 100px central disk is completely transparent')
        } else {
            $point=if($style -eq 'bars'){New-Object Windows.Point((23*260/280),52)}else{New-Object Windows.Point((14*260/280),52)}
            Assert-Ui ($wave.IsInteractivePoint($point)) ($style+' mark accepts hit')
        }
    }
    $shell.Controls.TaskLabel.Text='让声伴成为桌面上的语音搭档'
    $shell.Controls.StatusLabel.Text='待机 · 语音唤醒已就绪'
    $shell.Controls.TaskDirectoryLabel.Text='C:\Projects\语音助手'
    foreach($entry in @(@('DirectoryCombo','C:\Projects\语音助手'),@('TaskCombo','让声伴成为桌面上的语音搭档'),@('VoiceCombo','台湾女声 · 晓臻'),@('RateCombo','1.0× · 正常'),@('StyleCombo','流光环'))){[void]$shell.Controls[$entry[0]].Items.Add($entry[1]);$shell.Controls[$entry[0]].SelectedIndex=0}
    $shell.Controls.HandsFreeToggle.IsChecked=$true
    $shell.Controls.CaptionTask.Text=$shell.Controls.TaskLabel.Text
    $shell.Controls.CaptionText.Text="可以。平常桌面上只保留一圈声波，你叫我，我就开始听。`r`n`r`n需要检查文字时再打开字幕；回答会完整保留，也可以重读。你继续在当前 Codex 任务里工作就好。"
    $shell.Controls.InputBox.Text='把它做得再轻一点，放在桌面右边。'
    $shell.Controls.CaptionStatus.Text='正在朗读 · 台湾女声'
    $shell.Controls.AnswerStateLabel.Text='文字 · 语音'
    $shell.Controls.BargeInToggle.IsChecked=$true
    $shell.Controls.EchoStatusLabel.Text='回声消除已就绪，朗读中可喊“你好，声伴”。'
    [void](Render-Element $shell.SettingsWindow.Content 714 600 'settings' '#F5F5F7')
    [void](Render-Element $shell.SettingsWindow.Content 484 540 'settings-narrow' '#F5F5F7')
    $pageKeys=@('ConnectionPage','SoundPage','AppearancePage');$pageNames=@('connection','sound','appearance');$pageTitles=@('连接','声音','外观')
    for($pageIndex=0;$pageIndex -lt 3;$pageIndex++){
        $shell.Controls.SettingsNavigation.SelectedIndex=$pageIndex
        Assert-Ui ($shell.SettingsPage -eq $pageIndex -and $shell.Controls.SettingsPageTitle.Text -eq $pageTitles[$pageIndex]) ('navigation selects '+$pageNames[$pageIndex])
        for($other=0;$other -lt 3;$other++){Assert-Ui (($shell.Controls[$pageKeys[$other]].Visibility -eq 'Visible') -eq ($other -eq $pageIndex)) ('page visibility '+$pageNames[$pageIndex]+'/'+$pageNames[$other])}
        [void](Render-Element $shell.SettingsWindow.Content 714 600 ('settings-'+$pageNames[$pageIndex]) '#F5F5F7')
        if($pageIndex -eq 1){
            # v0.6.17 adds the opt-in follow-up row; the scrollable page must
            # keep the last option reachable instead of assuming zero scroll.
            Assert-Ui ($shell.Controls.SoundPage.ExtentWidth -le ($shell.Controls.SoundPage.ViewportWidth+1)) 'default sound page has no horizontal overflow'
            Assert-Ui ([Windows.Controls.Grid]::GetRow($shell.Controls.WakePhraseActions) -eq 0) 'default wake actions remain beside the editor'
            Assert-Ui ($shell.Controls.WakePhraseBox.ActualWidth -ge 140) 'default wake editor retains readable width'
            $shell.Controls.SoundPage.ScrollToEnd();$shell.Controls.SoundPage.UpdateLayout()
            $lastOption=$shell.Controls.AutoSendToggle.TransformToAncestor($shell.Controls.SoundPage).Transform((New-Object Windows.Point(0,$shell.Controls.AutoSendToggle.ActualHeight)))
            Assert-Ui ($lastOption.Y -gt $shell.Controls.AutoSendToggle.ActualHeight -and $lastOption.Y -le ($shell.Controls.SoundPage.ActualHeight+1)) 'last sound option is fully reachable by scrolling'
            [void](Render-Element $shell.SettingsWindow.Content 714 600 'settings-sound-bottom' '#F5F5F7')
            $shell.Controls.SoundPage.ScrollToTop();$shell.Controls.SoundPage.UpdateLayout()
        }
        [void](Render-Element $shell.SettingsWindow.Content 484 540 ('settings-'+$pageNames[$pageIndex]+'-narrow') '#F5F5F7')
        if($pageIndex -eq 0){Assert-Ui ($shell.Controls.ConnectionPage.ExtentWidth -le ($shell.Controls.ConnectionPage.ViewportWidth+1)) 'keyword guidance fits the narrow connection page without horizontal overflow'}
    }
    Set-DesktopSettingsPage $shell 1
    [void](Render-Element $shell.SettingsWindow.Content 484 400 'settings-sound-minimum' '#F5F5F7')
    Assert-Ui ([Windows.Controls.Grid]::GetRow($shell.Controls.WakePhraseActions) -eq 1 -and $shell.Controls.WakePhraseBox.ActualWidth -ge 120) 'minimum-width wake controls wrap without squeezing the editor'
    Assert-Ui ($shell.Controls.SoundPage.ScrollableHeight -gt 0 -and $shell.Controls.SoundPage.ExtentWidth -le ($shell.Controls.SoundPage.ViewportWidth+1)) 'minimum sound page scrolls vertically without horizontal overflow'
    $originalHint=$shell.Controls.WakeHintLabel.Text
    $shell.Controls.WakeHintLabel.Text='唤醒词尚未保存，请输入 2—16 个汉字。建议使用 4—6 个字，听到“在”后开始说话。'
    $shell.Controls.SoundPage.ScrollToEnd();$shell.Controls.SoundPage.UpdateLayout()
    [void](Render-Element $shell.SettingsWindow.Content 484 400 'settings-sound-lower-narrow' '#F5F5F7')
    Assert-Ui ($shell.Controls.WakeHintLabel.ActualHeight -gt 22) 'long wake validation notice wraps on the minimum sound page'
    $shell.Controls.WakeHintLabel.Text=$originalHint
    Set-DesktopSettingsPage $shell 0
    [void](Render-Element $shell.CaptionWindow.Content 480 200 'captions-compact')
    $shell.Controls.CaptionInputPanel.Visibility='Visible';$shell.Controls.CaptionActions.Visibility='Visible';$shell.Controls.CaptionExpandButton.Content='收起'
    [void](Render-Element $shell.CaptionWindow.Content 480 380 'captions')
    [void](Render-Element $shell.CaptionWindow.Content 360 300 'captions-narrow')
    $shell.SettingsWindow.Close()
    Assert-Ui (-not $shell.SettingsWindow.IsVisible) 'settings Close hides window'
    Assert-Ui ($shell.SettingsWindow.IsLoaded -eq $false -or $shell.SettingsWindow.Content -ne $null) 'settings content retained after Close'
    Set-DesktopShellSize $shell 300 'bars'
    Assert-Ui ($shell.Window.Width -eq 300 -and $shell.Window.Height -eq 120) 'bar size uses 0.4 aspect'
    Set-DesktopShellPosition $shell -99999 -99999
    $area=Get-DesktopShellWorkArea $shell
    Assert-Ui ($shell.Window.Left -ge $area.Left -and $shell.Window.Top -ge $area.Top) 'position constrained to work area'
    $shell.Waveform.SetFrame('invalid',[double]::NaN,'invalid',[double]::NaN)
    Assert-Ui ($shell.Waveform.StyleName -eq 'rays' -and $shell.Waveform.Level -eq 0 -and $shell.Waveform.Mode -eq 'idle') 'invalid frame inputs normalized'
    $gallery=New-Object Windows.Controls.Grid
    $gallery.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#F5F5F7')
    for($i=0;$i -lt 3;$i++){[void]$gallery.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))}
    for($i=0;$i -lt 2;$i++){[void]$gallery.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))}
    $styleTitles=@{rays='流光环';halo='柔光环';particles='微粒环';minimal='细线环';bars='律动音柱';flow='流动声线'}
    $index=0
    foreach($style in @('rays','halo','particles','minimal','bars','flow')){
        $tile=New-Object Windows.Controls.Grid
        $drawingRow=New-Object Windows.Controls.RowDefinition;$drawingRow.Height='*';[void]$tile.RowDefinitions.Add($drawingRow)
        $titleRow=New-Object Windows.Controls.RowDefinition;$titleRow.Height=34;[void]$tile.RowDefinitions.Add($titleRow)
        $wave=New-Object ShengBan.Desktop.WaveformView;$wave.Width=260;$wave.Height=if($style -in @('bars','flow')){104}else{260};$wave.VerticalAlignment='Center';$wave.HorizontalAlignment='Center';$wave.SetFrame($style,.65,'listen',1.25)
        [void]$tile.Children.Add($wave)
        $title=New-Object Windows.Controls.TextBlock;$title.Text=$styleTitles[$style];$title.FontFamily='Microsoft YaHei UI';$title.FontSize=14;$title.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#64646A');$title.HorizontalAlignment='Center'
        [Windows.Controls.Grid]::SetRow($title,1);[void]$tile.Children.Add($title)
        [Windows.Controls.Grid]::SetColumn($tile,($index%3));[Windows.Controls.Grid]::SetRow($tile,[int][Math]::Floor($index/3));[void]$gallery.Children.Add($tile);$index++
    }
    [void](Render-Element $gallery 900 620 'wave-gallery')
    [pscustomobject]@{passed=$checks.Count;checks=$checks;renderDirectory=$outDir;externalClickThrough='Not tested; PNG alpha and WPF geometry hit tests only'} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $outDir 'result.json') -Encoding UTF8
    'Passed '+$checks.Count+' checks. Renders: '+$outDir
} finally { Close-DesktopShell $shell }
