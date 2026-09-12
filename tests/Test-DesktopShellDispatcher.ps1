param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $Root 'src\DesktopShell.ps1')
$outDir=Join-Path $Root 'work\desktop-shell-render'
[void](New-Item -ItemType Directory -Path $outDir -Force)
$script:uiErrors=New-Object Collections.Generic.List[string]
$script:uiSteps=New-Object Collections.Generic.List[string]
$script:ui=New-DesktopShell
function Send-OwnControlKey($Control,[Windows.Input.Key]$Key) {
    [void]$Control.Focus()
    $eventArgs=New-Object Windows.Input.KeyEventArgs([Windows.Input.Keyboard]::PrimaryDevice,[Windows.PresentationSource]::FromVisual($Control),[Environment]::TickCount,$Key)
    $eventArgs.RoutedEvent=[Windows.Input.Keyboard]::KeyDownEvent
    $Control.RaiseEvent($eventArgs)
}
function Click-OwnComboToggle($Combo) {
    $toggle=$Combo.Template.FindName('ComboToggle',$Combo)
    if(-not $toggle){throw 'Custom combo toggle is missing.'}
    $method=$toggle.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic')
    [void]$method.Invoke($toggle,@())
}
function Get-OwnVisualText($Control) {
    if($Control -is [Windows.Controls.TextBlock]){$Control.Text}
    for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Control);$i++){Get-OwnVisualText ([Windows.Media.VisualTreeHelper]::GetChild($Control,$i))}
}
$script:step=0
$script:uiDispatcher=$script:ui.Window.Dispatcher
$script:uiDispatcher.Add_UnhandledException({
    param($sender,$eventArgs)
    $script:uiErrors.Add($eventArgs.Exception.ToString())
    $eventArgs.Handled=$true
    $script:uiTimer.Stop()
    $script:uiDispatcher.BeginInvokeShutdown([Windows.Threading.DispatcherPriority]::Background)
})
$script:uiTimer=New-Object Windows.Threading.DispatcherTimer
$script:uiTimer.Interval=[TimeSpan]::FromMilliseconds(180)
$script:uiTimer.Add_Tick({
    $script:step++
    switch ($script:step) {
        1 { $script:ui.Window.Show(); $script:uiSteps.Add('show floating window') }
        2 { Show-DesktopSettings $script:ui; $script:uiSteps.Add('show settings') }
        3 { Set-DesktopCaptionsVisible $script:ui $true; $script:uiSteps.Add('show compact captions') }
        4 { Set-DesktopShellPosition $script:ui 900 160; Set-DesktopShellSize $script:ui 300 'bars'; $script:ui.Waveform.SetFrame('bars',.4,'listen',2); $script:uiSteps.Add('move and resize floating window') }
        5 { $script:ui.CaptionWindow.Height=420; $script:ui.Controls.CaptionInputPanel.Visibility='Visible'; $script:ui.Controls.CaptionActions.Visibility='Visible'; $script:uiSteps.Add('expand captions and follow position') }
        6 { $script:ui.SettingsWindow.Close(); $script:ui.CaptionWindow.Close(); if ($script:ui.SettingsWindow.IsVisible -or $script:ui.CaptionWindow.IsVisible) { throw 'close did not hide satellite windows' }; $script:uiSteps.Add('close settings and captions hides them') }
        7 { Show-DesktopSettings $script:ui; Set-DesktopCaptionsVisible $script:ui $true; $script:uiSteps.Add('reopen hidden satellite windows') }
        8 { $script:ui.Window.Hide(); $script:ui.Window.Show(); $script:uiSteps.Add('hide and restore floating window') }
        9 {
            Show-DesktopSettings $script:ui;Set-DesktopSettingsPage $script:ui 0
            $taskCombo=$script:ui.Controls.TaskCombo;$taskCombo.DisplayMemberPath='title'
            [void]$taskCombo.Items.Add([pscustomobject]@{title='Dispatcher Task A'});[void]$taskCombo.Items.Add([pscustomobject]@{title='Dispatcher Task B'});$taskCombo.SelectedIndex=1
            $script:ui.SettingsWindow.UpdateLayout()
            $edit=$taskCombo.Template.FindName('PART_EditableTextBox',$taskCombo)
            if(-not $edit -or $edit.Text -ne 'Dispatcher Task B' -or -not $edit.IsReadOnly){throw 'Readonly editable TaskCombo did not display its title binding.'}
            $script:uiSteps.Add('task ComboBox displays bound title in readonly editor')
        }
        10 { Send-OwnControlKey $script:ui.Controls.TaskCombo ([Windows.Input.Key]::F4);$script:uiSteps.Add('F4 opens the actual ComboBox') }
        11 {
            $taskCombo=$script:ui.Controls.TaskCombo
            if(-not $taskCombo.IsDropDownOpen -or -not $taskCombo.Template.FindName('PART_Popup',$taskCombo).IsOpen){throw 'F4 failed to open the actual ComboBox popup.'}
            Send-OwnControlKey $taskCombo ([Windows.Input.Key]::F4);$script:uiSteps.Add('F4 closes the actual ComboBox')
        }
        12 {
            if($script:ui.Controls.TaskCombo.IsDropDownOpen){throw 'F4 failed to close the dropdown.'}
            Click-OwnComboToggle $script:ui.Controls.TaskCombo;$script:uiSteps.Add('native toggle click path opens dropdown')
        }
        13 {
            if(-not $script:ui.Controls.TaskCombo.IsDropDownOpen){throw 'Native toggle click failed to open dropdown.'}
            Click-OwnComboToggle $script:ui.Controls.TaskCombo
            $script:ui.Controls.SettingsNavigation.SelectedIndex=1
            $voiceCombo=$script:ui.Controls.VoiceCombo;$voiceCombo.DisplayMemberPath='name';[void]$voiceCombo.Items.Add([pscustomobject]@{name='Dispatcher Voice A'});$voiceCombo.SelectedIndex=0
            $script:ui.SettingsWindow.UpdateLayout()
            if(@(Get-OwnVisualText $voiceCombo) -notcontains 'Dispatcher Voice A'){throw 'VoiceCombo failed to display its name binding.'}
            if($script:ui.Controls.SoundPage.Visibility -ne 'Visible'){throw 'Native navigation selection did not change the page.'}
            $script:uiSteps.Add('voice name binding and sound navigation remain functional')
        }
        14 {
            $script:ui.SettingsWindow.Width=500;$script:ui.SettingsWindow.Height=440;$script:ui.SettingsWindow.UpdateLayout()
            if([Windows.Controls.Grid]::GetRow($script:ui.Controls.WakePhraseActions) -ne 1 -or $script:ui.Controls.WakePhraseBox.ActualWidth -lt 120){throw 'Wake phrase actions failed to reflow after a real resize.'}
            if($script:ui.Controls.WakePhraseBox.IsReadOnly -or -not $script:ui.Controls.WakePhraseBox.IsTabStop -or -not $script:ui.Controls.SaveWakePhraseButton.IsTabStop -or -not $script:ui.Controls.ResetWakePhraseButton.IsTabStop){throw 'Wake phrase editor or actions cannot be reached for editing.'}
            $script:ui.Controls.WakePhraseBox.Text='小伴你好'
            $script:uiSteps.Add('wake editor stays editable and actions reflow in the minimum window')
        }
        15 {
            $script:ui.SettingsWindow.Width=730;$script:ui.SettingsWindow.Height=640;$script:ui.SettingsWindow.UpdateLayout()
            if([Windows.Controls.Grid]::GetRow($script:ui.Controls.WakePhraseActions) -ne 0){throw 'Wake phrase actions did not return to their default row.'}
            $script:ui.Controls.PauseResumeButton.Content='继续朗读';$script:ui.Controls.MenuPauseResume.Header='继续朗读'
            if($script:ui.Controls.PauseResumeButton.Content -ne '继续朗读' -or $script:ui.Controls.MenuPauseResume.Header -ne '继续朗读'){throw 'Pause and resume labels cannot be updated by the controller.'}
            $center=$script:ui.Controls.CenterPlaybackButton;$center.Tag='pause';$script:ui.Window.UpdateLayout()
            if($center.Template.FindName('PauseGlyph',$center).Visibility -ne 'Visible' -or $center.Tag -is [hashtable]){throw 'Center playback button does not retain its visual state during the dispatcher loop.'}
            $centerStop=$script:ui.Controls.CenterStopButton
            if($centerStop.Template.FindName('StopGlyph',$centerStop).Visibility -ne 'Visible' -or $centerStop.Tag -ne 'stop'){throw 'Center stop button does not retain its stop visual during the dispatcher loop.'}
            $script:uiSteps.Add('default wake row and playback labels including center glyph update correctly')
        }
        16 { $script:ui.Controls.SettingsNavigation.SelectedIndex=2;if($script:ui.Controls.AppearancePage.Visibility -ne 'Visible'){throw 'Appearance navigation failed.'};$script:ui.Controls.SettingsNavigation.SelectedIndex=0;$script:uiSteps.Add('appearance and connection navigation work after popup use') }
        17 { $script:ui.Window.Close(); $script:uiSteps.Add('close floating window permanently') }
        18 { Close-DesktopShell $script:ui; Close-DesktopShell $script:ui; $script:uiSteps.Add('idempotent cleanup'); $script:uiTimer.Stop(); $script:uiDispatcher.BeginInvokeShutdown([Windows.Threading.DispatcherPriority]::Background) }
    }
})
try {
    $script:uiTimer.Start()
    [Windows.Threading.Dispatcher]::Run()
} finally {
    $script:uiTimer.Stop()
    try { Close-DesktopShell $script:ui } catch { $script:uiErrors.Add($_.Exception.ToString()) }
}
$uiResult=[pscustomobject]@{passed=($script:uiErrors.Count -eq 0 -and $script:uiSteps.Count -eq 18);steps=$script:uiSteps;errors=$script:uiErrors}
$uiResult | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $outDir 'dispatcher-result.json') -Encoding UTF8
$uiResult | ConvertTo-Json -Depth 5
if (-not $uiResult.passed) { exit 1 }
