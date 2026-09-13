# Shared binding validation and commit. Importing this module has no state effects.
function Get-TaskBindingBlockReason {
    param([switch]$IgnoreDraft)
    if ($script:closing) { return '程序正在退出，暂不连接任务。' }
    if ($script:recMode -ne 'idle' -or $script:asrJob -or $script:handsFreePhase -in @('releasing','answering-wake','acknowledging')) {
        return '请先完成这次录音，再连接任务。'
    }
    if ($script:pendingUncertain -or ($script:pendingSends -and $script:pendingSends.ContainsKey($script:threadId))) {
        return '上次发送仍待核对，请先确认发送结果。'
    }
    if ($script:bridgeJob -and $script:bridgeJob.Purpose -eq 'send') { return '消息正在发送，请收到回执后再连接任务。' }
    if ($script:autoDispatch -or (-not $IgnoreDraft -and $InputBox -and $InputBox.Text.Trim())) { return '文字草稿已保留，请先处理后再连接任务。' }
    return ''
}

function Test-TaskBindingResult($Result, [string]$TargetThreadId) {
    $id=[Guid]::Empty
    return [bool]($Result -and $Result.ok -is [bool] -and $Result.ok -and
        $Result.archived -ne $true -and $Result.bindingState -notin @('archived','missing') -and
        [Guid]::TryParse($TargetThreadId,[ref]$id) -and $Result.threadId -is [string] -and
        $Result.threadId -ceq $TargetThreadId -and (-not $Result.hostId -or $Result.hostId -eq 'local') -and
        $Result.rolloutPath -is [string] -and -not [string]::IsNullOrWhiteSpace($Result.rolloutPath) -and
        (Test-Path -LiteralPath $Result.rolloutPath -PathType Leaf))
}

function Test-TaskBindingSelectionHealthy {
    return [bool]($script:connected -and -not $script:bindingReadError -and $script:bindingAvailability -notin @('archived','missing','unknown'))
}

function Sync-TaskBindingSelection {
    if (-not $TaskCombo) { return }
    $wasSyncing=$script:syncingUi; $script:syncingUi=$true
    try {
        $TaskCombo.SelectedIndex=-1
        if (-not (Test-TaskBindingSelectionHealthy)) { return }
        foreach ($item in $TaskCombo.Items) {
            if ($item.threadId -ceq $script:threadId) { $TaskCombo.SelectedItem=$item; break }
        }
    } finally { $script:syncingUi=$wasSyncing }
}

function Invoke-TaskBindingCommit {
    param($Result, [string]$TargetThreadId, [scriptblock]$AfterApply=$null)
    $blocked=Get-TaskBindingBlockReason
    if ($blocked) { throw $blocked }
    if (-not (Test-TaskBindingResult $Result $TargetThreadId)) { throw '目标任务回执不完整，保留原任务。' }
    $before=@{}
    foreach ($key in @('threadId','boundDirectory','tail','latest','busy','connected','lastUserVersion','bindingReadError','bindingAvailability','bindingAvailabilityError','bindingGeneration','lastBindingProbe')) {
        $before[$key]=Get-Variable -Name $key -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    }
    $before.TaskText=$TaskLabel.Text; $before.TaskTip=$TaskLabel.ToolTip
    $before.AnswerText=$AnswerBox.Text; $before.InputText=$InputBox.Text
    $before.SelectedTask=if($TaskCombo){$TaskCombo.SelectedItem}else{$null}
    try {
        Apply-Thread $Result
        if ($AfterApply) { & $AfterApply }
        Sync-TaskBindingSelection
        $script:taskSelectionMessage=''
    } catch {
        # Persisting either settings or the caller's connection receipt can fail.
        # Restore the former destination before returning that failure.
        foreach ($key in @('threadId','boundDirectory','tail','latest','busy','connected','lastUserVersion','bindingReadError','bindingAvailability','bindingAvailabilityError','bindingGeneration','lastBindingProbe')) {
            Set-Variable -Name $key -Scope Script -Value $before[$key]
        }
        $TaskLabel.Text=$before.TaskText; $TaskLabel.ToolTip=$before.TaskTip
        $AnswerBox.Text=$before.AnswerText; $InputBox.Text=$before.InputText
        if ($TaskCombo) {
            $wasSyncing=$script:syncingUi; $script:syncingUi=$true
            try { $TaskCombo.SelectedItem=$before.SelectedTask } finally { $script:syncingUi=$wasSyncing }
        }
        try { Sync-PendingSend } catch { }
        try { Save-Settings } catch { }
        throw
    }
}

function Reset-ManualTaskBinding {
    param([string]$Message='', [switch]$KeepSelection)
    $pending=$script:manualTaskBinding
    $script:manualTaskBinding=$null
    if (-not $pending) { return }
    if ($script:bridgeJob -and $script:bridgeJob.Purpose -eq 'bind' -and
        $script:bridgeJob.TaskBindingContext.Token -ceq $pending.Token) {
        $job=$script:bridgeJob; $script:bridgeJob=$null
        Close-Job $job -Kill
    }
    if ($Message) { $script:notice=$Message }
    if ($pending.AutoConnect -and -not $KeepSelection) {
        Sync-TaskBindingSelection
        if ($Message) { $script:taskSelectionMessage=$Message+' 未切换，请重新选择任务。' }
    }
}

function Begin-ManualTaskBinding {
    param([string]$TargetThreadId, [switch]$Startup, [switch]$AutoConnect)
    Reset-ManualTaskBinding -KeepSelection
    $blocked=Get-TaskBindingBlockReason -IgnoreDraft
    if ($blocked) { $script:notice=$blocked; return $false }
    if ($script:bridgeJob) { $script:notice='上一项操作仍在处理，请稍后连接。'; return $false }
    $id=[Guid]::Empty
    if (-not [Guid]::TryParse($TargetThreadId,[ref]$id)) { $script:notice='请先选择一个有效的本机任务。'; return $false }
    if (-not $Startup) {
        if (-not $TaskCombo.SelectedItem -or $TaskCombo.SelectedItem.threadId -cne $TargetThreadId) { return $false }
        $selectedCandidate=$TaskCombo.SelectedItem
        if ($InputBox -and $InputBox.Text.Trim()) {
            if (-not (Save-InputDraftForRecovery '用户明确连接所选任务，旧文字未转发')) { return $false }
        }
        Invalidate-VoiceTaskCreateBinding -Reason '已手动选择要连接的任务' -ReleaseSendBlock
        Reset-VoiceTaskSwitch
        if ($AutoConnect) {
            # Ending a voice ambiguity prompt restores its old list. Keep the
            # user's explicit choice visible throughout this read transaction.
            $wasSyncing=$script:syncingUi; $script:syncingUi=$true
            try {
                $displayCandidate=$null
                foreach ($item in $TaskCombo.Items) { if ($item.threadId -ceq $TargetThreadId) { $displayCandidate=$item; break } }
                if (-not $displayCandidate) { $displayCandidate=$selectedCandidate; [void]$TaskCombo.Items.Add($displayCandidate) }
                $TaskCombo.SelectedItem=$displayCandidate
            } finally { $script:syncingUi=$wasSyncing }
        }
    }
    $context=@{Token=[Guid]::NewGuid().ToString('N');TargetThreadId=$TargetThreadId;
        SourceThreadId=[string]$script:threadId;VoiceGeneration=$script:voiceGeneration;
        Startup=[bool]$Startup;AutoConnect=[bool]$AutoConnect;ExpiresAt=[DateTime]::UtcNow.AddSeconds(30)}
    $script:manualTaskBinding=$context
    try {
        if (-not (Start-Bridge @{action='read';threadId=$TargetThreadId} 'bind')) { throw '连接未开始。' }
        $script:bridgeJob.TaskBindingContext=$context.Clone()
        $script:notice='正在确认目标任务，确认成功后才切换连接…'
        return $true
    } catch {
        Reset-ManualTaskBinding
        $script:notice='目标任务暂时无法读取，保留原任务。'
        return $false
    }
}

function Get-ManualTaskBindingStaleReason($Pending) {
    $blocked=Get-TaskBindingBlockReason
    if ($blocked) { return $blocked }
    if ($Pending.SourceThreadId -cne [string]$script:threadId -or $Pending.VoiceGeneration -ne $script:voiceGeneration) {
        return '已有新的输入或任务变化，已取消这次连接。'
    }
    if ($Pending.AutoConnect -and (-not $TaskCombo.SelectedItem -or $TaskCombo.SelectedItem.threadId -cne $Pending.TargetThreadId)) {
        return '目标选择已改变，已取消这次连接。'
    }
    if ($Pending.ExpiresAt -le [DateTime]::UtcNow) { return '连接等待已超时，保留原任务。' }
    return ''
}

function Update-ManualTaskBinding {
    if (-not $script:manualTaskBinding) { return }
    $reason=Get-ManualTaskBindingStaleReason $script:manualTaskBinding
    if ($reason) { Reset-ManualTaskBinding $reason }
}

function Complete-ManualTaskBinding {
    param($Result, $Context)
    $pending=$script:manualTaskBinding
    if (-not $Context -or -not $pending -or $Context.Token -cne $pending.Token -or
        $Context.TargetThreadId -cne $pending.TargetThreadId -or $Context.SourceThreadId -cne $pending.SourceThreadId -or
        $Context.VoiceGeneration -ne $pending.VoiceGeneration) { return $false }
    $reason=Get-ManualTaskBindingStaleReason $pending
    if ($reason) { Reset-ManualTaskBinding $reason; return $false }
    # Consume the context before applying: a duplicate callback cannot commit.
    $script:manualTaskBinding=$null
    if ($Result -and $Result.ok -is [bool] -and $Result.ok -and $Result.threadId -ceq $pending.TargetThreadId -and $Result.archived -is [bool] -and $Result.archived) {
        if ($pending.Startup -and $pending.TargetThreadId -ceq $script:threadId) {
            if ($Result.title) { $TaskLabel.Text=[string]$Result.title; $TaskLabel.ToolTip=[string]$Result.title }
            [void](Enter-TaskBindingRecovery 'archived')
        } else { $script:notice='所选任务已归档，未连接；请选择活动任务。' }
        if ($pending.AutoConnect) { Sync-TaskBindingSelection; $script:taskSelectionMessage=$script:notice }
        return $false
    }
    try { Invoke-TaskBindingCommit $Result $pending.TargetThreadId }
    catch {
        $script:notice='连接没有完成或保存失败，已保留原任务，请重新选择。'
        if ($pending.AutoConnect) { Sync-TaskBindingSelection; $script:taskSelectionMessage=$script:notice }
        return $false
    }
    $script:taskSelectionMessage=''
    $script:notice='任务已连接，接下来的话会发送到这个任务。'
    return $true
}

function Update-TaskBindingInput {
    # Clearing precisely the command just consumed by the router is not new
    # user input. Every other edit invalidates even if the text is later erased.
    if ($script:consumingLocalCommand) { return }
    Reset-ManualTaskBinding '文字已改变，已取消这次连接并保留草稿。'
    if ($script:voiceTaskSwitch -and $script:voiceTaskSwitch.Phase -ne 'choosing') { Reset-VoiceTaskSwitch }
    Invalidate-VoiceTaskCreateBinding -Reason '输入文字已改变，保留新建结果但不自动连接。'
}
