. (Join-Path $PSScriptRoot 'TaskBinding.ps1')
# Voice task changes are local bindings. Search/read results never send a prompt.
function Set-VoiceTaskSwitchNotice([string]$Message, [bool]$Speak=$false, [int]$Seconds=10) {
    $script:localCommandMessage=$Message
    $script:localCommandNoticeUntil=[DateTime]::UtcNow.AddSeconds($Seconds)
    $script:notice=$Message
    if ($Speak) { Queue-AnswerSpeech $Message }
}

function Restore-VoiceTaskCandidates($Pending) {
    if (-not $Pending -or -not $Pending.ContainsKey('OriginalItems') -or -not $TaskCombo) { return }
    $wasSyncing=$script:syncingUi
    $script:syncingUi=$true
    try {
        $TaskCombo.Items.Clear()
        foreach ($item in $Pending.OriginalItems) { [void]$TaskCombo.Items.Add($item) }
        $TaskCombo.SelectedItem=$Pending.OriginalSelection
    } finally { $script:syncingUi=$wasSyncing }
}

function Reset-VoiceTaskSwitch {
    $pending=$script:voiceTaskSwitch
    $script:voiceTaskSwitch=$null
    $script:voiceTaskSwitchGeneration++
    if ($pending -and $script:bridgeJob -and $script:bridgeJob.Purpose -in @('voice-find','voice-bind') -and
        $script:bridgeJob.VoiceTaskSwitchContext.Generation -eq $pending.Generation) {
        $job=$script:bridgeJob
        $script:bridgeJob=$null
        Close-Job $job -Kill
    }
    Restore-VoiceTaskCandidates $pending
}

function Get-VoiceTaskSwitchBlockReason {
    if ($script:closing) { return '程序正在退出，暂不切换任务。' }
    if ($script:recMode -ne 'idle' -or $script:asrJob -or $script:handsFreePhase -in @('releasing','answering-wake','acknowledging')) {
        return '请先完成这次录音，再切换任务。'
    }
    if ($script:pendingUncertain -or ($script:pendingSends -and $script:pendingSends.ContainsKey($script:threadId))) {
        return '上次发送仍待核对，请先确认发送结果，再切换任务。'
    }
    if ($script:bridgeJob -and $script:bridgeJob.Purpose -eq 'send') { return '消息正在发送，请收到回执后再切换任务。' }
    return ''
}

function Test-VoiceTaskSelectionPending {
    $pending=$script:voiceTaskSwitch
    return [bool]($pending -and $pending.Phase -eq 'choosing' -and -not $script:closing -and
        $pending.SourceThreadId -ceq [string]$script:threadId -and $pending.ExpiresAt -gt [DateTime]::UtcNow)
}

function Test-VoiceTaskSwitchContext($Context, [string]$Phase) {
    $pending=$script:voiceTaskSwitch
    return [bool]($Context -and $pending -and $pending.Phase -eq $Phase -and
        $Context.Generation -eq $pending.Generation -and $Context.SourceThreadId -ceq $pending.SourceThreadId -and
        $Context.VoiceGeneration -eq $pending.VoiceGeneration -and $Context.Query -ceq $pending.Query -and
        $Context.TargetThreadId -ceq $pending.TargetThreadId)
}

function Get-VoiceTaskSwitchStaleReason($Pending) {
    $blocked=Get-VoiceTaskSwitchBlockReason
    if ($blocked) { return $blocked }
    if ($Pending.SourceThreadId -cne [string]$script:threadId) { return '当前任务已改变，已取消这次语音切换。' }
    if ($Pending.ExpiresAt -le [DateTime]::UtcNow) { return '这次任务选择已过期，请重新说要切换的任务。' }
    if ($Pending.Phase -ne 'choosing' -and $Pending.VoiceGeneration -ne $script:voiceGeneration) { return '已开始新的语音输入，保留原任务。' }
    # The local command router clears only the exact consumed command before
    # this asynchronous callback can run. Any remaining text is a draft.
    if ($Pending.Phase -ne 'choosing' -and $InputBox -and $InputBox.Text.Trim()) {
        return '输入内容已改变，保留文字和原任务。'
    }
    if ($Pending.Phase -ne 'choosing' -and $script:autoDispatch) {
        return '已有新的待发送文字，保留原任务。'
    }
    return ''
}

function Fail-VoiceTaskSwitch {
    param([string]$Message='任务没有切换，请重试。', $Context=$null)
    if ($Context -and (-not $script:voiceTaskSwitch -or -not (Test-VoiceTaskSwitchContext $Context $script:voiceTaskSwitch.Phase))) { return $false }
    Reset-VoiceTaskSwitch
    Set-VoiceTaskSwitchNotice $Message $false
    return $true
}

function Update-VoiceTaskSwitch([DateTime]$Now=[DateTime]::UtcNow) {
    $pending=$script:voiceTaskSwitch
    if (-not $pending) { return }
    # A candidate list survives recording the user's numbered selection. In-flight
    # search/read operations cannot commit after a different recording starts.
    if ($pending.Phase -eq 'choosing') {
        if ($script:closing -or $pending.SourceThreadId -cne [string]$script:threadId) { Reset-VoiceTaskSwitch; return }
        if ($pending.ExpiresAt -le $Now) { [void](Fail-VoiceTaskSwitch '这次任务选择已过期，请重新说要切换的任务。') }
        return
    }
    $reason=Get-VoiceTaskSwitchStaleReason $pending
    if ($reason) { [void](Fail-VoiceTaskSwitch $reason) }
}

function Start-VoiceTaskBridge($Request, [string]$Purpose) {
    $pending=$script:voiceTaskSwitch
    $context=@{Generation=$pending.Generation;SourceThreadId=$pending.SourceThreadId;VoiceGeneration=$pending.VoiceGeneration;
        Query=$pending.Query;TargetThreadId=$pending.TargetThreadId}
    if (-not (Start-Bridge $Request $Purpose)) { throw '连接仍忙，请稍后再试。' }
    $script:bridgeJob.VoiceTaskSwitchContext=$context
}

function Begin-VoiceTaskSwitch([string]$Query) {
    $blocked=Get-VoiceTaskSwitchBlockReason
    if ($blocked) { Set-VoiceTaskSwitchNotice $blocked; return $true }
    if ($script:bridgeJob -and $script:bridgeJob.Purpose -notin @('voice-find','voice-bind')) {
        Set-VoiceTaskSwitchNotice '正在读取 Codex，请稍后再说一次要切换的任务。'; return $true
    }
    Reset-VoiceTaskSwitch
    $queryText=([string]$Query).Trim()
    if (-not $queryText -or $queryText.Length -gt 120) { Set-VoiceTaskSwitchNotice '请说一个简短的任务名称。'; return $true }
    Invalidate-VoiceTaskCreateBinding -Reason '已要求切换到已有任务' -ReleaseSendBlock
    $script:voiceTaskSwitch=@{Generation=$script:voiceTaskSwitchGeneration;SourceThreadId=[string]$script:threadId;
        VoiceGeneration=$script:voiceGeneration;Query=$queryText;Candidates=@();Phase='searching';TargetThreadId='';
        ExpiresAt=[DateTime]::UtcNow.AddSeconds(30);InputSnapshot=if($InputBox){[string]$InputBox.Text}else{''}}
    try {
        Start-VoiceTaskBridge @{action='find';query=$queryText} 'voice-find'
        Set-VoiceTaskSwitchNotice '正在查找匹配的 Codex 任务…'
    } catch { [void](Fail-VoiceTaskSwitch '任务查找没有开始，请稍后重试。') }
    return $true
}

function Start-VoiceTaskBind($Candidate) {
    $pending=$script:voiceTaskSwitch
    $pending.Phase='binding'
    $pending.TargetThreadId=[string]$Candidate.threadId
    $pending.VoiceGeneration=$script:voiceGeneration
    $pending.InputSnapshot=if($InputBox){[string]$InputBox.Text}else{''}
    $pending.ExpiresAt=[DateTime]::UtcNow.AddSeconds(30)
    try {
        Start-VoiceTaskBridge @{action='read';threadId=$pending.TargetThreadId} 'voice-bind'
        Set-VoiceTaskSwitchNotice '正在确认目标任务，原任务仍保持连接…'
    } catch { [void](Fail-VoiceTaskSwitch '目标任务暂时无法读取，保留原任务。') }
}

function Complete-VoiceTaskSearch {
    param($Result, $Context)
    if (-not (Test-VoiceTaskSwitchContext $Context 'searching')) { return $false }
    $pending=$script:voiceTaskSwitch
    $reason=Get-VoiceTaskSwitchStaleReason $pending
    if ($reason) { [void](Fail-VoiceTaskSwitch $reason); return $false }
    if (-not $Result -or -not $Result.ok -or $Result.query -cne $pending.Query) {
        [void](Fail-VoiceTaskSwitch '任务查找失败，保留原任务。'); return $false
    }
    $candidates=@($Result.threads)
    $ids=New-Object 'Collections.Generic.HashSet[string]'
    foreach ($candidate in $candidates) {
        $parsed=[Guid]::Empty
        if (-not $candidate -or $candidate.threadId -isnot [string] -or -not [Guid]::TryParse($candidate.threadId,[ref]$parsed) -or
            -not $ids.Add([string]$candidate.threadId) -or $candidate.title -isnot [string]) {
            [void](Fail-VoiceTaskSwitch '任务列表不完整，请在设置里重新读取任务。'); return $false
        }
    }
    if ($Result.matchType -eq 'none' -and $candidates.Count -eq 0) {
        Reset-VoiceTaskSwitch
        Set-VoiceTaskSwitchNotice ('没有找到与“'+[string]$pending.Query+'”匹配的任务，未切换。请重说任务名称，或在设置里选择。') $true
        return $true
    }
    if ($Result.matchType -eq 'unique' -and $candidates.Count -eq 1) {
        $pending.Candidates=$candidates
        Start-VoiceTaskBind $candidates[0]
        return $true
    }
    if ($Result.matchType -ne 'ambiguous' -or $candidates.Count -lt 2 -or $candidates.Count -gt 5) {
        [void](Fail-VoiceTaskSwitch '任务匹配结果不完整，请重试。'); return $false
    }
    $pending.Phase='choosing'; $pending.Candidates=$candidates; $pending.ExpiresAt=[DateTime]::UtcNow.AddSeconds(90)
    if ($TaskCombo) {
        $pending.OriginalItems=@($TaskCombo.Items)
        $pending.OriginalSelection=$TaskCombo.SelectedItem
        $wasSyncing=$script:syncingUi; $script:syncingUi=$true
        try {
            $TaskCombo.Items.Clear()
            foreach ($candidate in $candidates) { [void]$TaskCombo.Items.Add($candidate) }
            $TaskCombo.SelectedIndex=-1
        } finally { $script:syncingUi=$wasSyncing }
    }
    # Showing the existing window directly avoids refreshing/re-filtering this
    # exact numbered list. Original titles remain untouched in its native combo.
    if ($desktop) { Set-DesktopSettingsPage $desktop 0; Show-DesktopSettings $desktop }
    $parts=New-Object 'Collections.Generic.List[string]'
    [void]$parts.Add('找到多个任务。')
    $numbers=@('第一个','第二个','第三个','第四个','第五个')
    for ($i=0;$i -lt $candidates.Count;$i++) {
        $title=[string]$candidates[$i].title
        if (-not $title) { $title='未命名任务' }
        $piece=if($title.Length -gt 40){$numbers[$i]+'，标题开头是：'+$title.Substring(0,40)+'。'}else{$numbers[$i]+'，'+$title+'。'}
        [void]$parts.Add($piece)
    }
    [void]$parts.Add('请说选择第几个，或者取消切换。')
    Set-VoiceTaskSwitchNotice ($parts -join '') $true 90
    return $true
}

function Select-VoiceTaskCandidate([int]$Index) {
    if (-not (Test-VoiceTaskSelectionPending)) { return $false }
    $blocked=Get-VoiceTaskSwitchBlockReason
    if ($blocked) { Set-VoiceTaskSwitchNotice $blocked; return $true }
    if ($script:bridgeJob) { Set-VoiceTaskSwitchNotice '连接仍在处理，请稍后再选择。'; return $true }
    $pending=$script:voiceTaskSwitch
    if ($Index -lt 1 -or $Index -gt $pending.Candidates.Count) {
        Set-VoiceTaskSwitchNotice ('这里只有'+$pending.Candidates.Count+'个候选，请重新选择。') $true
        return $true
    }
    Start-VoiceTaskBind $pending.Candidates[$Index-1]
    return $true
}

function Cancel-VoiceTaskSwitch {
    if (-not (Test-VoiceTaskSelectionPending)) { return $false }
    Reset-VoiceTaskSwitch
    Set-VoiceTaskSwitchNotice '已取消切换，仍然使用原任务。' $true
    return $true
}

function Complete-VoiceTaskBind {
    param($Result, $Context)
    if (-not (Test-VoiceTaskSwitchContext $Context 'binding')) { return $false }
    $pending=$script:voiceTaskSwitch
    $reason=Get-VoiceTaskSwitchStaleReason $pending
    if ($reason) { [void](Fail-VoiceTaskSwitch $reason); return $false }
    if (-not (Test-TaskBindingResult $Result $pending.TargetThreadId)) {
        [void](Fail-VoiceTaskSwitch '目标任务暂时无法读取，保留原任务。'); return $false
    }
    $targetId=$pending.TargetThreadId
    Reset-VoiceTaskSwitch
    try { Invoke-TaskBindingCommit $Result $targetId }
    catch {
        Set-VoiceTaskSwitchNotice '任务切换没有保存成功，已恢复原任务，请重试。'
        return $false
    }
    Set-VoiceTaskSwitchNotice '任务已切换，接下来的话会发送到这个任务。' $true
    return $true
}
