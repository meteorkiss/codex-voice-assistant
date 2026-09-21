# Local settings use the same state and controls as the settings window.
# Only complete, explicit commands are handled; everything else keeps its route.
. (Join-Path $PSScriptRoot 'PreferenceActions.ps1')
function Complete-LocalCommandInput([string]$Text,[string]$OriginalInput,$OriginalDispatch) {
    if ($OriginalInput.Trim() -ceq $Text.Trim() -and [string]$InputBox.Text -ceq $OriginalInput) {
        $wasConsuming=$script:consumingLocalCommand; $script:consumingLocalCommand=$true
        try { $InputBox.Text='' } finally { $script:consumingLocalCommand=$wasConsuming }
    }
    if ([object]::ReferenceEquals($script:autoDispatch,$OriginalDispatch)) { $script:autoDispatch=$null }
}
function Try-LocalAssistantCommand([string]$Text) {
    if ($script:closing -or $script:recMode -ne 'idle') { return $false }
    $command=$null
    if ((Get-Command Test-VoiceTaskSelectionPending -ErrorAction SilentlyContinue) -and (Test-VoiceTaskSelectionPending)) {
        $command=Get-AssistantTaskSelectionReply $Text ($script:voiceTaskSwitch.Candidates.Count -eq 1)
    }
    if (-not $command) { $command=Get-AssistantVoiceCommand $Text }
    if (-not $command) {
        # A new ordinary utterance changes the subject. A later generic "yes"
        # must not still confirm the previous task suggestion.
        if ($Text.Trim() -and (Get-Command Test-VoiceTaskSelectionPending -ErrorAction SilentlyContinue) -and (Test-VoiceTaskSelectionPending)) { Reset-VoiceTaskSwitch }
        return $false
    }
    if ($command.Action -in @('desktopAction','playback')) {
        $originalInput=[string]$InputBox.Text
        $originalDispatch=$script:autoDispatch
        try {
            $handled=if ($command.Action -eq 'desktopAction') { Begin-VoiceDesktopAction $command.Value } else { Invoke-VoicePlaybackAction ([string]$command.Value) }
            if (-not $handled) { throw 'Local action was not handled.' }
        } catch {
            # Recognized operations never fall through into the chat channel.
            $script:notice='本地操作没有完成，请稍后重试。'
            $script:localCommandMessage=$script:notice
            $script:localCommandNoticeUntil=[DateTime]::UtcNow.AddSeconds(12)
        }
        Complete-LocalCommandInput $Text $originalInput $originalDispatch
        $script:localCommandCount++
        $script:lastLocalCommand=[string]$command.Action
        return $true
    }
    if ($command.Action -in @('createTask','resumeCreatedTask','cancelCreatedTaskConnection','switchTask','chooseTask','cancelTaskSwitch')) {
        Cancel-SavedTaskBinding
        $pendingCheckFailed=$false
        $noCreatedTaskPending=$false
        # Bare candidate choices are ordinary input outside an active selection.
        if ($command.Action -in @('chooseTask','cancelTaskSwitch')) {
            if (-not (Get-Command Test-VoiceTaskSelectionPending -ErrorAction SilentlyContinue)) { return $false }
            try {
                if (-not (Test-VoiceTaskSelectionPending)) { return $false }
            } catch { $pendingCheckFailed=$true }
        }
        if ($command.Action -in @('resumeCreatedTask','cancelCreatedTaskConnection')) {
            if (-not (Get-Command Test-VoiceTaskCreatePending -ErrorAction SilentlyContinue)) { $pendingCheckFailed=$true }
            else {
                try { $noCreatedTaskPending=-not (Test-VoiceTaskCreatePending) }
                catch { $pendingCheckFailed=$true }
            }
        }
        $originalInput=[string]$InputBox.Text
        $originalDispatch=$script:autoDispatch
        $handled=$false
        try {
            if ($pendingCheckFailed) { throw 'Task selection state is unavailable.' }
            if ($noCreatedTaskPending) {
                $script:localCommandMessage='没有待连接的新任务。'
                $script:localCommandNoticeUntil=[DateTime]::UtcNow.AddSeconds(8)
                $script:notice=$script:localCommandMessage
                $handled=$true
            } else { switch ($command.Action) {
                'createTask' {
                    $scope=if ($command.Scope) { [string]$command.Scope } else { 'projectless' }
                    $handled=[bool](Begin-VoiceTaskCreate -Title ([string]$command.Value) -Scope $scope)
                }
                'resumeCreatedTask' { $handled=[bool](Resume-VoiceTaskCreateConnection) }
                'cancelCreatedTaskConnection' { $handled=[bool](Cancel-VoiceTaskCreateConnection) }
                'switchTask' { $handled=[bool](Begin-VoiceTaskSwitch -Query ([string]$command.Value)) }
                'chooseTask' { $handled=[bool](Select-VoiceTaskCandidate -Index ([int]$command.Value)) }
                'cancelTaskSwitch' { $handled=[bool](Cancel-VoiceTaskSwitch) }
            } }
            if (-not $handled) { throw 'Task operation was not handled.' }
        } catch {
            # A recognized task operation must never become a Codex prompt,
            # including when an asynchronous task module fails to start.
            $script:localCommandMessage=if ($command.Action -eq 'createTask') { '新建任务没有完成，请重试。' } elseif ($command.Action -in @('resumeCreatedTask','cancelCreatedTaskConnection')) { '新任务连接操作没有完成，请重试。' } else { '任务切换没有完成，请重试。' }
            $script:localCommandNoticeUntil=[DateTime]::UtcNow.AddSeconds(8)
            $script:notice=$script:localCommandMessage
            $handled=$true
        }
        if (-not $handled) { return $false }
        Complete-LocalCommandInput $Text $originalInput $originalDispatch
        $script:localCommandCount++
        $script:lastLocalCommand=[string]$command.Action
        # Task modules own binding, persistence and asynchronous feedback.
        return $true
    }
    $originalInput=[string]$InputBox.Text
    $originalDispatch=$script:autoDispatch
    $values=@{}
    $speak=$true
    try {
        if ($command.Action -eq 'stop' -or ($command.Action -eq 'autoRead' -and -not $command.Value)) { Stop-Output }
        switch ($command.Action) {
            'voice' {
                $voice=@($script:voiceCatalog | Where-Object { $_.id -is [string] -and $_.id -ceq $command.Value })
                if ($voice.Count -ne 1) { throw '这个声音暂时不可用。' }
                $values.voiceId=[string]$voice[0].id
                $message='已切换为'+[string]$voice[0].name+'。'
            }
            'rate' {
                $rates=@(-20,0,20,50)
                $index=[Array]::IndexOf($rates,[int]$script:speechRate)
                if ($index -lt 0) { $index=1 }
                switch ($command.Value) {
                    'slow' { $index=[Math]::Max(0,$index-1) }
                    'fast' { $index=[Math]::Min($rates.Count-1,$index+1) }
                    'normal' { $index=1 }
                    default { throw '这个语速暂时不可用。' }
                }
                $values.speechRate=$rates[$index]
                $message=@('语速已调为零点八倍。','已恢复正常语速。','语速已调为一点二倍。','语速已调为一点五倍。')[$index]
            }
            'pin' { $values.pinned=[bool]$command.Value; $message=if ($command.Value) { '已开启置顶。' } else { '已取消置顶。' } }
            'captions' {
                if ($command.Value -and -not $script:floatingVisible) { $values.floatingVisible=$true }
                $values.captionsVisible=[bool]$command.Value
                $message=if ($command.Value) { '已显示字幕。' } else { '已隐藏字幕。' }
            }
            'floating' { $values.floatingVisible=[bool]$command.Value; $message=if ($command.Value) { '已显示悬浮声波。' } else { '已隐藏悬浮声波。' } }
            'settings' { Show-AssistantSettings; $message='已打开设置。' }
            'autoRead' { $values.autoRead=[bool]$command.Value; $speak=[bool]$command.Value; $message=if ($command.Value) { '已开启自动朗读。' } else { '已关闭自动朗读。' } }
            'style' { $values.waveStyle=[string]$command.Value; $message='已更换声波样式。' }
            'stop' { $speak=$false; $message='已停止朗读。' }
            default { throw '暂不支持这个设置操作。' }
        }
        if ($values.Count) { Set-AssistantPreferences $values }
    } catch {
        # Keep a failed command available for manual retry, never send it to Codex.
        if ([object]::ReferenceEquals($script:autoDispatch,$originalDispatch)) { $script:autoDispatch=$null }
        $script:localCommandMessage='设置没有完成，请重试或打开设置调整。'
        $script:localCommandNoticeUntil=[DateTime]::UtcNow.AddSeconds(8)
        $script:notice=$script:localCommandMessage
        return $true
    }
    Complete-LocalCommandInput $Text $originalInput $originalDispatch
    $script:localCommandCount++
    $script:lastLocalCommand=[string]$command.Action
    $script:localCommandMessage=$message
    $script:localCommandNoticeUntil=[DateTime]::UtcNow.AddSeconds(6)
    $script:notice=$message
    # A command acknowledgement is separate from the last Codex answer.
    # Use the existing microphone guard and TTS queue, including the new voice.
    if ($speak) { Queue-AnswerSpeech $message }
    return $true
}
