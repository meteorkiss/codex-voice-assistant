. (Join-Path $PSScriptRoot 'TaskBinding.ps1')
# Desktop presentation and preferences. Speech and sends stay in Assistant.ps1.
. (Join-Path $PSScriptRoot 'DesktopTopmost.ps1')
. (Join-Path $PSScriptRoot 'PreferenceActions.ps1')
. (Join-Path $PSScriptRoot 'AudioOutput.ps1')
function Show-AssistantSettings {
    Show-DesktopSettings $desktop
    if (-not $script:tasksLoaded -and -not $script:bridgeJob) { Refresh-AssistantTasks }
}
function Toggle-AnswerPlayback {
    if ($script:recMode -ne 'idle' -or $script:handsFreePhase -in @('releasing','answering-wake','acknowledging')) { return }
    $state=[CodexReader.AudioPlayer]::State
    if ($state -eq 'playing') {
        [CodexReader.AudioPlayer]::Pause()
        $script:playbackNotice='已暂停朗读，点击“继续朗读”可接着听。'
    } elseif ($state -eq 'paused') {
        if (-not (Safe-To-Play)) {
            $script:playbackNotice='麦克风或回声处理尚未就绪，请稍后继续朗读。'
            $script:notice=$script:playbackNotice
            return
        }
        [CodexReader.AudioPlayer]::Resume()
        $script:playbackNotice=''
    } else { return }
    $script:localCommandNoticeUntil=[DateTime]::MinValue
    $script:notice=if ($state -eq 'playing') { $script:playbackNotice } else { '已继续朗读。' }
}
function Test-ReadableAnswerAvailable {
    if (-not [object]::ReferenceEquals($script:playbackTextSource,$script:latest)) {
        $script:playbackTextSource=$script:latest
        $script:playbackTextReady=-not [string]::IsNullOrWhiteSpace((ConvertTo-SpokenText $script:latest))
    }
    return [bool]$script:playbackTextReady
}
function Invoke-CenterPlayback {
    if ($script:recMode -ne 'idle' -or $script:handsFreePhase -in @('releasing','answering-wake','acknowledging')) { return }
    $state=[CodexReader.AudioPlayer]::State
    if ($state -in @('playing','paused')) { Toggle-AnswerPlayback; return }
    if ($script:ttsJob -or $script:speechQueue.Count -gt 0 -or [string]::IsNullOrWhiteSpace($script:latest)) { return }
    if (-not (Test-ReadableAnswerAvailable)) { $script:notice='这条回答没有可以朗读的文字。'; return }
    Stop-Output
    Queue-AnswerSpeech $script:latest
    if ($script:speechQueue.Count -gt 0) { $script:notice='正在准备朗读上一条回答…' }
}
function Invoke-CenterStop {
    if ($script:recMode -ne 'idle' -or $script:handsFreePhase -in @('releasing','answering-wake','acknowledging')) { return }
    Stop-Output '已结束朗读。'
}
function Update-AssistantAudioLevel {
    # The AEC wake listener stays active during speech. Playback must take
    # precedence over that microphone's (echo-cancelled) residual level.
    $state=[CodexReader.AudioPlayer]::State
    $script:levelSource='silence'
    $target=0.0
    if ($script:recMode -eq 'listening') {
        $target=[double]$script:recorder.Level/100.0
        $script:levelSource='microphone'
    } elseif ($state -eq 'playing') {
        $target=[double][CodexReader.AudioPlayer]::Level
        $script:levelSource='playback'
    } elseif ($state -ne 'paused' -and $script:wakeListener -and $script:wakeListener.IsListening -and $script:wakeListener.IsReady) {
        $target=[double]$script:wakeListener.AudioLevel/100.0
        $script:levelSource='microphone'
    }
    if ([double]::IsNaN($target) -or [double]::IsInfinity($target)) { $target=0.0 }
    # WaveformView applies its own fast attack and gentle release; a second
    # smoothing filter here would hide syllables and add avoidable latency.
    $script:level=[Math]::Max(0.0,[Math]::Min(1.0,$target))
}
function Set-FloatingVisible([bool]$Visible) {
    Set-AssistantPreferences @{floatingVisible=$Visible}
}
function Set-CaptionsVisible([bool]$Visible) {
    Set-AssistantPreferences @{captionsVisible=$Visible}
}
function Set-CaptionExpanded([bool]$Expanded) {
    $script:captionExpanded=$Expanded
    $desktop.CaptionWindow.Height=if ($Expanded) { 420 } else { 200 }
    foreach ($key in @('CaptionInputPanel','CaptionActions')) {
        if ($desktop.Controls.ContainsKey($key)) { $desktop.Controls[$key].Visibility=if ($Expanded) { 'Visible' } else { 'Collapsed' } }
    }
    if ($desktop.Controls.ContainsKey('CaptionExpandButton')) { $desktop.Controls.CaptionExpandButton.Content=if ($Expanded) { '收起' } else { '展开与输入' } }
    Update-DesktopCaptionPosition $desktop
}
function Open-VoiceComposer {
    if (-not $script:floatingVisible) { Set-FloatingVisible $true }
    Set-CaptionExpanded $true
    Set-CaptionsVisible $true
    Begin-Recording
}
function Exit-Assistant {
    Reset-ManualTaskBinding
    $script:closing=$true
    Invalidate-VoiceTaskCreateBinding -Reason '声伴已退出'
    Reset-VoiceTaskSwitch
    $window.Close()
}
function Refresh-AssistantTasks {
    Reset-ManualTaskBinding '已刷新任务列表，取消上次连接。'
    Invalidate-VoiceTaskCreateBinding -Reason '已手动刷新任务列表'
    Reset-VoiceTaskSwitch
    if (Start-Bridge @{action='list'} 'list') { $script:notice='正在读取本机 Codex 任务…' }
}
function Set-TaskCandidates($Threads, [string]$Warning='') {
    $script:taskCandidates=@($Threads)
    $script:tasksLoaded=$true
    $script:syncingUi=$true
    try {
        $DirectoryCombo.Items.Clear()
        [void]$DirectoryCombo.Items.Add([pscustomobject]@{name='全部工作目录';path=''})
        foreach ($directory in @($script:taskCandidates.cwd | Where-Object { $_ } | Sort-Object -Unique)) {
            [void]$DirectoryCombo.Items.Add([pscustomobject]@{name=$directory;path=$directory})
        }
        $DirectoryCombo.SelectedIndex=0
        foreach ($entry in $DirectoryCombo.Items) { if ($entry.path -eq $script:directoryFilter) { $DirectoryCombo.SelectedItem=$entry; break } }
    } finally { $script:syncingUi=$false }
    Update-TaskSelection
    $script:notice=if ($Warning) { $Warning } elseif ($script:taskCandidates.Count) { '对话列表已更新，选中任务后自动连接。' } else { '没有可连接的本机对话，请先在 Codex 创建或打开一个对话。' }
}
function Update-TaskSelection {
    $selected=if (-not (Test-TaskBindingSelectionHealthy)) { '' } elseif ($TaskCombo.SelectedItem) { [string]$TaskCombo.SelectedItem.threadId } else { $script:threadId }
    $filter=if ($DirectoryCombo.SelectedItem) { [string]$DirectoryCombo.SelectedItem.path } else { '' }
    $script:directoryFilter=$filter
    $script:syncingUi=$true
    try {
        $TaskCombo.Items.Clear()
        foreach ($task in $script:taskCandidates) {
            if ($filter -and $task.cwd -ne $filter) { continue }
            [void]$TaskCombo.Items.Add($task)
            if ($task.threadId -eq $selected) { $TaskCombo.SelectedItem=$task }
        }
        # Never choose the first or most recent task on behalf of the user.
        if ($null -eq $TaskCombo.SelectedItem) { $TaskCombo.SelectedIndex=-1 }
    } finally { $script:syncingUi=$false }
}
function Sync-DesktopPreferences {
    if (-not $desktop) { return }
    $script:syncingUi=$true
    try {
        Set-DesktopPinned $desktop $script:pinned
        $PinToggle.IsChecked=$script:pinned
        $MenuPin.IsChecked=$script:pinned
        $CaptionToggle.IsChecked=$script:captionsVisible
        $MenuCaptions.IsChecked=$script:captionsVisible
        $HandsFreeToggle.IsChecked=$script:handsFreeEnabled
        if ($desktop.Controls.ContainsKey('BargeInToggle')) { $desktop.Controls.BargeInToggle.IsChecked=$script:bargeInEnabled }
        if ($desktop.Controls.ContainsKey('ShortFollowUpToggle')) { $desktop.Controls.ShortFollowUpToggle.IsChecked=$script:shortFollowUpEnabled }
        $AutoSendToggle.IsChecked=$script:autoSend
        $AutoReadToggle.IsChecked=$script:autoRead
        $MenuVisibility.Header=if ($script:floatingVisible) { '隐藏悬浮声波' } else { '显示悬浮声波' }
        if ($showItem) { $showItem.Text=if ($script:floatingVisible) { '隐藏悬浮声波' } else { '显示悬浮声波' } }
        if ($pinItem) { $pinItem.Checked=$script:pinned }
        if ($captionItem) { $captionItem.Checked=$script:captionsVisible }
        if ($handsFreeItem) { $handsFreeItem.Checked=$script:handsFreeEnabled }
        if ($autoItem) { $autoItem.Checked=$script:autoSend }
        foreach ($entry in $VoiceCombo.Items) { if ($entry.id -eq $script:voiceId) { $VoiceCombo.SelectedItem=$entry; break } }
        foreach ($entry in $RateCombo.Items) { if ($entry.value -eq $script:speechRate) { $RateCombo.SelectedItem=$entry; break } }
        foreach ($entry in $StyleCombo.Items) { if ($entry.id -eq $script:waveStyle) { $StyleCombo.SelectedItem=$entry; break } }
        $SizeSlider.Value=$script:waveSize
        Set-DesktopShellSize $desktop $script:waveSize $script:waveStyle
        if ($script:captionsVisible -and $script:floatingVisible) {
            Update-DesktopCaptionPosition $desktop
            if (-not $desktop.CaptionWindow.IsVisible) { $desktop.CaptionWindow.Show() }
        } else { $desktop.CaptionWindow.Hide() }
    } finally { $script:syncingUi=$false }
}
function Update-DesktopDisplay {
    $playbackState=[CodexReader.AudioPlayer]::State
    $pauseLabel=if ($playbackState -eq 'paused') { '继续朗读' } else { '暂停朗读' }
    $canPause=($script:recMode -eq 'idle' -and $playbackState -in @('playing','paused') -and $script:handsFreePhase -notin @('releasing','answering-wake','acknowledging'))
    if ($desktop.Controls.ContainsKey('MenuPauseResume')) { $desktop.Controls.MenuPauseResume.Header=$pauseLabel; $desktop.Controls.MenuPauseResume.IsEnabled=$canPause }
    if ($desktop.Controls.ContainsKey('PauseResumeButton')) { $desktop.Controls.PauseResumeButton.Content=if ($playbackState -eq 'paused') { '继续' } else { '暂停' }; $desktop.Controls.PauseResumeButton.IsEnabled=$canPause }
    if ($pauseResumeItem) { $pauseResumeItem.Text=$pauseLabel; $pauseResumeItem.Enabled=$canPause }
    if ($desktop.Controls.ContainsKey('CenterPlaybackButton')) {
        $centerButton=$desktop.Controls.CenterPlaybackButton
        $centerButton.Tag=if ($playbackState -eq 'playing') { 'pause' } else { 'play' }
        $readyToStart=($playbackState -notin @('playing','paused') -and -not $script:ttsJob -and $script:speechQueue.Count -eq 0 -and (Test-ReadableAnswerAvailable))
        $centerButton.IsEnabled=($script:recMode -eq 'idle' -and $script:handsFreePhase -notin @('releasing','answering-wake','acknowledging') -and ($canPause -or $readyToStart))
        $centerButton.ToolTip=if ($playbackState -eq 'playing') { '暂停朗读' } elseif ($playbackState -eq 'paused') { '继续朗读' } elseif ($script:ttsJob -or $script:speechQueue.Count -gt 0) { '正在准备语音' } elseif (-not $readyToStart) { '等待可朗读的回答' } else { '播放上一条回答' }
        [Windows.Automation.AutomationProperties]::SetName($centerButton,[string]$centerButton.ToolTip)
    }
    if ($desktop.Controls.ContainsKey('CenterStopButton')) {
        $desktop.Controls.CenterStopButton.IsEnabled=($script:recMode -eq 'idle' -and $script:handsFreePhase -notin @('releasing','answering-wake','acknowledging') -and ($playbackState -in @('playing','paused') -or $script:ttsJob -or $script:speechQueue.Count -gt 0))
        $desktop.Controls.CenterStopButton.ToolTip='结束朗读'
        [Windows.Automation.AutomationProperties]::SetName($desktop.Controls.CenterStopButton,'结束朗读')
    }
    $mode=if ($script:recMode -eq 'listening') { 'listen' } elseif ([CodexReader.AudioPlayer]::State -eq 'playing') { 'speak' } elseif ($script:busy) { 'busy' } else { 'idle' }
    $desktop.Waveform.SetFrame($script:waveStyle, [double]$script:level, $mode, $script:phaseClock.Elapsed.TotalSeconds)
    $desktop.Waveform.ToolTip=$StatusLabel.Text
    if ($desktop.Controls.ContainsKey('CaptionText') -and -not [object]::ReferenceEquals($desktop.Controls.CaptionText,$AnswerBox) -and $desktop.Controls.CaptionText.Text -cne $AnswerBox.Text) { $desktop.Controls.CaptionText.Text=$AnswerBox.Text }
    if ($desktop.Controls.ContainsKey('CaptionStatus')) { $desktop.Controls.CaptionStatus.Text=$StatusLabel.Text }
    if ($desktop.Controls.ContainsKey('CaptionTask')) { $desktop.Controls.CaptionTask.Text=$TaskLabel.Text }
    if ($desktop.Controls.ContainsKey('TaskDirectoryLabel')) { $desktop.Controls.TaskDirectoryLabel.Text=if ($script:boundDirectory) { $script:boundDirectory } else { '尚未绑定任务' } }
    if ($desktop.Controls.ContainsKey('EchoStatusLabel')) {
        $desktop.Controls.EchoStatusLabel.Text=if ($script:wakeListener -and $script:wakeListener.Error) { '音频设备未就绪：'+$script:wakeListener.Error } elseif (-not $script:bargeInEnabled) { '轮流听说：朗读结束后恢复语音唤醒。' } elseif (-not $script:handsFreeEnabled) { '开启语音唤醒后检查回声消除设备。' } elseif (Test-FullDuplexReady) { '回声消除已就绪，朗读中可喊“'+$script:wakePhrase+'”。' } else { '正在准备回声消除；设备不兼容时可关闭此选项。' }
    }
    if ($desktop.Controls.ContainsKey('MenuFollowUpEnd')) { $desktop.Controls.MenuFollowUpEnd.IsEnabled=[bool]($script:shortFollowUp -or $script:followUpCapture) }
    # A failed/currently unavailable target must remain selectable again, even
    # when its ID is still saved. Selecting an already selected WPF row emits
    # no SelectionChanged event, so keep unhealthy non-pending selections empty.
    if (-not $script:manualTaskBinding -and -not (Test-TaskBindingSelectionHealthy) -and $TaskCombo.SelectedItem -and $TaskCombo.SelectedItem.threadId -ceq $script:threadId) { Sync-TaskBindingSelection }
    if ($desktop.Controls.ContainsKey('TaskSelectionHint')) {
        $desktop.Controls.TaskSelectionHint.Text=if ($script:manualTaskBinding) { '正在连接所选任务，请等待确认；旧草稿不会发送到新任务。' } elseif ($script:taskSelectionMessage) { $script:taskSelectionMessage } elseif ($TaskCombo.SelectedItem -and $script:connected -and $TaskCombo.SelectedItem.threadId -ceq $script:threadId) { '已连接到所选任务；后续消息发往这里。' } elseif ($script:connected) { '当前连接保持不变；选择其它任务后自动连接。' } else { '选中任务后自动连接；旧草稿会单独保存。' }
    }
    if ($desktop.Controls.ContainsKey('BindingAvailabilityLabel')) {
        $desktop.Controls.BindingAvailabilityLabel.Text=if ($script:bindingAvailability -eq 'archived') { '原任务已归档，普通发送已停用；可唤醒后说切换任务。' } elseif ($script:bindingAvailability -eq 'missing') { '原任务不存在，请重新选择；不会自动连接其它任务。' } elseif ($script:bindingAvailability -eq 'unknown') { $script:bindingAvailabilityError } elseif ($script:connected) { '连接有效' } else { '尚未建立可发送的连接' }
    }
    if ($desktop.Controls.ContainsKey('RecoveryDraftButton')) {
        $desktop.Controls.RecoveryDraftButton.IsEnabled=($script:recoveryDraftCount -gt 0)
        $desktop.Controls.RecoveryDraftButton.Content='查看保留草稿（'+[int]$script:recoveryDraftCount+'）'
    }
    $RefreshTasksButton.IsEnabled=(-not $script:bridgeJob)
    $OpenTaskButton.IsEnabled=($script:connected -and -not $script:bridgeJob)
}
function Initialize-DesktopController {
    $script:tasksLoaded=$false
    $script:taskCandidates=@()
    $script:taskSelectionMessage=''
    $script:syncingUi=$true
    $DirectoryCombo.DisplayMemberPath='name'
    $TaskCombo.DisplayMemberPath='title'
    $VoiceCombo.DisplayMemberPath='name'
    foreach ($voice in $script:voiceCatalog) { [void]$VoiceCombo.Items.Add($voice) }
    $RateCombo.DisplayMemberPath='name'
    foreach ($entry in @(@{name='0.8× · 慢一些';value=-20},@{name='1.0× · 正常';value=0},@{name='1.2× · 快一些';value=20},@{name='1.5× · 更快';value=50})) { [void]$RateCombo.Items.Add([pscustomobject]$entry) }
    $StyleCombo.DisplayMemberPath='name'
    foreach ($entry in @(@{id='rays';name='流光环'},@{id='halo';name='柔光环'},@{id='particles';name='微粒环'},@{id='minimal';name='细线环'},@{id='bars';name='律动音柱'},@{id='flow';name='流动声线'})) { [void]$StyleCombo.Items.Add([pscustomobject]$entry) }
    $script:syncingUi=$false
    if ($desktop.Controls.ContainsKey('WakePhraseBox')) {
        $desktop.Controls.WakePhraseBox.Text=$script:wakePhrase
        $desktop.Controls.WakePhraseBox.IsReadOnly=$false
        $desktop.Controls.WakePhraseBox.Add_KeyDown({ param($sender,$eventArgs) if ($eventArgs.Key -eq [Windows.Input.Key]::Return) { [void](Set-AssistantWakePhrase $sender.Text); $eventArgs.Handled=$true } })
    }
    if ($desktop.Controls.ContainsKey('SaveWakePhraseButton')) { $desktop.Controls.SaveWakePhraseButton.Add_Click({ [void](Set-AssistantWakePhrase $desktop.Controls.WakePhraseBox.Text) }) }
    if ($desktop.Controls.ContainsKey('ResetWakePhraseButton')) { $desktop.Controls.ResetWakePhraseButton.Add_Click({ [void](Set-AssistantWakePhrase '你好，声伴') }) }
    if ($desktop.Controls.ContainsKey('AutoSendToggle')) { $AutoSendToggle.Content='手动录音停顿后自动发送' }
    $PinToggle.Add_Click({ [void](Invoke-DesktopPreference @{pinned=[bool]$PinToggle.IsChecked}) })
    $CaptionToggle.Add_Click({ [void](Invoke-DesktopPreference @{captionsVisible=[bool]$CaptionToggle.IsChecked}) })
    $HandsFreeToggle.Add_Click({ Set-HandsFree ([bool]$HandsFreeToggle.IsChecked); Sync-DesktopPreferences; Save-Settings })
    if ($desktop.Controls.ContainsKey('BargeInToggle')) {
        $desktop.Controls.BargeInToggle.Add_Click({
            $resumeWake=$script:handsFreeEnabled
            if ($resumeWake) { Set-HandsFree $false }
            $script:bargeInEnabled=[bool]$desktop.Controls.BargeInToggle.IsChecked
            if ($resumeWake) { Set-HandsFree $true }
            Sync-DesktopPreferences
            Save-Settings
        })
    }
    if ($desktop.Controls.ContainsKey('ShortFollowUpToggle')) {
        $desktop.Controls.ShortFollowUpToggle.Add_Click({
            $enabled=[bool]$desktop.Controls.ShortFollowUpToggle.IsChecked
            if (Invoke-DesktopPreference @{shortFollowUpEnabled=$enabled}) {
                if (-not $enabled -and (Get-Command Close-ShortFollowUp -ErrorAction SilentlyContinue)) { Close-ShortFollowUp '短时连续接话已关闭。' -CancelCapture }
                elseif (-not $script:handsFreeEnabled) { $script:notice='短时连续接话已开启；还需开启语音唤醒才会生效。' }
                else { $script:notice='短时连续接话已开启，下次唤醒交流后生效。' }
            }
        })
    }
    $AutoReadToggle.Add_Click({ [void](Invoke-DesktopPreference @{autoRead=[bool]$AutoReadToggle.IsChecked}) })
    $AutoSendToggle.Add_Click({ [void](Invoke-DesktopPreference @{autoSend=[bool]$AutoSendToggle.IsChecked}) })
    $VoiceCombo.Add_SelectionChanged({ if (-not $script:syncingUi -and $VoiceCombo.SelectedItem) { [void](Invoke-DesktopPreference @{voiceId=[string]$VoiceCombo.SelectedItem.id}) } })
    $RateCombo.Add_SelectionChanged({ if (-not $script:syncingUi -and $RateCombo.SelectedItem) { [void](Invoke-DesktopPreference @{speechRate=[int]$RateCombo.SelectedItem.value}) } })
    $StyleCombo.Add_SelectionChanged({ if (-not $script:syncingUi -and $StyleCombo.SelectedItem) { [void](Invoke-DesktopPreference @{waveStyle=[string]$StyleCombo.SelectedItem.id}) } })
    $SizeSlider.Add_ValueChanged({ if (-not $script:syncingUi) { [void](Invoke-DesktopPreference @{waveSize=[int]$SizeSlider.Value}) } })
    $DirectoryCombo.Add_SelectionChanged({ if (-not $script:syncingUi) { if (Get-Command Close-ShortFollowUp -ErrorAction SilentlyContinue) { Close-ShortFollowUp '目标筛选已改变，连续接话已结束。' -CancelCapture }; Reset-ManualTaskBinding '目录筛选已改变，取消上次连接。'; Invalidate-VoiceTaskCreateBinding -Reason '已手动改变目录筛选'; Reset-VoiceTaskSwitch; Update-TaskSelection; Save-Settings } })
    $RefreshTasksButton.Add_Click({ Refresh-AssistantTasks })
    $TaskCombo.Add_SelectionChanged({
        if (-not $script:syncingUi) {
            $selectedId=if ($TaskCombo.SelectedItem) { [string]$TaskCombo.SelectedItem.threadId } else { '' }
            $script:taskSelectionMessage=''
            try {
                Reset-ManualTaskBinding -KeepSelection
                if (-not $selectedId) { return }
                # Re-selecting the live destination is harmless and must not
                # move its draft or interrupt playback just to validate again.
                if ($script:connected -and $selectedId -ceq $script:threadId -and $script:bindingAvailability -notin @('archived','missing','unknown') -and -not $script:bindingReadError) { return }
                if (Get-Command Close-ShortFollowUp -ErrorAction SilentlyContinue) { Close-ShortFollowUp '目标任务选择已改变，连续接话已结束。' -CancelCapture }
                Invalidate-VoiceTaskCreateBinding -Reason '已手动改变任务选择'
                if ($script:voiceTaskSwitch -and $script:voiceTaskSwitch.Phase -ne 'choosing') { Reset-VoiceTaskSwitch }
                if (-not (Begin-ManualTaskBinding $selectedId -AutoConnect)) {
                    $script:taskSelectionMessage=$script:notice+' 未切换，请处理后重新选择任务。'
                    Sync-TaskBindingSelection
                }
            } catch {
                $script:notice='自动连接未完成，已保留原任务和未发送文字，请重新选择。'
                $script:taskSelectionMessage=$script:notice
                Reset-ManualTaskBinding
                Sync-TaskBindingSelection
            }
        }
    })
    $InputBox.Add_TextChanged({
        Update-TaskBindingInput
        if ((Get-Command Close-ShortFollowUp -ErrorAction SilentlyContinue) -and $script:shortFollowUp -and $script:shortFollowUp.Phase -ne 'recognizing') {
            $expected=($script:shortFollowUp.Phase -eq 'dispatching' -and $script:autoDispatch -and $script:autoDispatch.Text -ceq $InputBox.Text.Trim())
            if (-not $expected -and ($InputBox.Text.Trim() -or $script:shortFollowUp.Phase -eq 'dispatching')) {
                Close-ShortFollowUp '草稿已保留，连续接话已结束。' -CancelCapture
            }
        }
    })
    $OpenTaskButton.Add_Click({ if ($script:connected) { [void](Start-Bridge @{action='open';threadId=$script:threadId} 'open') } })
    $ResetPositionButton.Add_Click({ Reset-DesktopShellPosition $desktop; Save-Settings })
    $MenuPin.Add_Click({ [void](Invoke-DesktopPreference @{pinned=(-not $script:pinned)}) })
    $MenuSettings.Add_Click({ Show-AssistantSettings })
    if ($desktop.Controls.ContainsKey('RecoveryDraftButton')) { $desktop.Controls.RecoveryDraftButton.Add_Click({ Open-AssistantRecoveryDraft }) }
    if ($desktop.Controls.ContainsKey('MenuPauseResume')) { $desktop.Controls.MenuPauseResume.Add_Click({ Toggle-AnswerPlayback }) }
    if ($desktop.Controls.ContainsKey('PauseResumeButton')) { $desktop.Controls.PauseResumeButton.Add_Click({ Toggle-AnswerPlayback }) }
    if ($desktop.Controls.ContainsKey('CenterPlaybackButton')) { $desktop.Controls.CenterPlaybackButton.Add_Click({ Invoke-CenterPlayback }) }
    if ($desktop.Controls.ContainsKey('CenterStopButton')) { $desktop.Controls.CenterStopButton.Add_Click({ Invoke-CenterStop }) }
    $MenuCaptions.Add_Click({ [void](Invoke-DesktopPreference @{captionsVisible=(-not $script:captionsVisible)}) })
    $MenuStop.Add_Click({ Stop-Output '已停止朗读。' })
    if ($desktop.Controls.ContainsKey('MenuFollowUpEnd')) { $desktop.Controls.MenuFollowUpEnd.Add_Click({ Stop-ShortFollowUpByUser }) }
    $MenuVisibility.Add_Click({ [void](Invoke-DesktopPreference @{floatingVisible=(-not $script:floatingVisible)}) })
    if ($desktop.Controls.ContainsKey('PreviewVoiceButton')) { $desktop.Controls.PreviewVoiceButton.Add_Click({ Stop-Output; Queue-AnswerSpeech '你好，我是声伴。你说，我在听。' }) }
    if ($desktop.Controls.ContainsKey('ReplayButton')) { $desktop.Controls.ReplayButton.Add_Click({ Stop-Output; if ($script:latest) { Queue-AnswerSpeech $script:latest } }) }
    if ($desktop.Controls.ContainsKey('CaptionExpandButton')) { $desktop.Controls.CaptionExpandButton.Add_Click({ Set-CaptionExpanded (-not $script:captionExpanded) }) }
    if ($desktop.Controls.ContainsKey('CaptionCloseButton')) { $desktop.Controls.CaptionCloseButton.Add_Click({ Set-CaptionsVisible $false }) }
    $window.Add_LocationChanged({ if (-not $script:syncingUi) { $script:positionDirty=$true; $script:lastPositionChange=[DateTime]::UtcNow } })
    Sync-DesktopPreferences
    Set-CaptionExpanded $false
    if ($null -ne $script:savedLeft -and $null -ne $script:savedTop) { Set-DesktopShellPosition $desktop ([double]$script:savedLeft) ([double]$script:savedTop) } else { Reset-DesktopShellPosition $desktop }
}
