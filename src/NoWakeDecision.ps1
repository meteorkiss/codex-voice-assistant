# Pure no-wake policy. Segmentation and ASR are evidence, never authorization.
function New-NoWakeDecisionResult {
    param(
        [string]$Disposition,
        [string]$Route='none',
        [string[]]$ReasonCodes=@(),
        [string]$ContextId='',
        [string]$Display='',
        $Command=$null
    )
    return [pscustomobject]@{
        Disposition=$Disposition
        Route=$Route
        ReasonCodes=@($ReasonCodes)
        ContextId=$ContextId
        Display=$Display
        Command=$Command
    }
}

function Get-NoWakeDecision {
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [ValidateSet('off','observe','context')][string]$Mode='off',
        $Evidence=$null,
        $Context=$null,
        [DateTime]$Now=[DateTime]::UtcNow
    )
    $value=if ($null -eq $Text) { '' } else { $Text.Trim() }
    if ($Mode -eq 'off') {
        return New-NoWakeDecisionResult ignore none @('mode-off') '' '免唤醒已关闭。'
    }
    if ($Evidence -and $Evidence.Stale) {
        return New-NoWakeDecisionResult ignore none @('stale-generation') '' '试判已失效：模式或目标已经改变。'
    }
    if ($Evidence -and $Evidence.ExternalCapture) {
        return New-NoWakeDecisionResult ignore none @('external-capture') '' '试判忽略：其他应用正在使用麦克风。'
    }
    if ($Evidence -and $Evidence.SelfPlayback) {
        return New-NoWakeDecisionResult ignore none @('self-playback') '' '试判忽略：声伴正在朗读。'
    }
    if (-not $value) {
        return New-NoWakeDecisionResult ignore none @('empty-transcript') '' '试判忽略：没有取得可用文字。'
    }
    if (($Evidence -and $Evidence.EndReason -eq 'maximum-duration') -or ($Evidence -and [double]$Evidence.DurationSeconds -ge 17.8)) {
        return New-NoWakeDecisionResult uncertain none @('maximum-duration','no-addressing-model') '' '试判不确定：话语达到时限，只保留本次判定，不会执行。'
    }

    $contextActive=[bool]($Context -and $Context.Active -and $Context.ContextId -and
        $Context.SourceThreadId -ceq $Context.CurrentThreadId -and $Context.ExpiresUtc -gt $Now)
    if ($contextActive) {
        $command=$Context.Command
        $validCommand=[bool]($command -and $command.Action -in @('chooseTask','cancelTaskSwitch'))
        if ($validCommand -and $command.Action -eq 'chooseTask') {
            $index=[int]$command.Value
            $validCommand=($index -ge 1 -and $index -le [int]$Context.CandidateCount)
        }
        if ($validCommand) {
            if ($Mode -eq 'context') {
                return New-NoWakeDecisionResult accept context-confirmation @('active-context','valid-confirmation') ([string]$Context.ContextId) '实验交互：匹配当前候选确认，正在重新核验。' $command
            }
            return New-NoWakeDecisionResult accept none @('active-context','valid-confirmation','observe-only') ([string]$Context.ContextId) '仅试判：这句话可匹配当前确认，但不会执行。' $command
        }
        if ($value -match '\A(?:是|对|确认|不是|不对|取消|第|选择)') {
            return New-NoWakeDecisionResult uncertain none @('active-context','invalid-confirmation') ([string]$Context.ContextId) '试判不确定：像是在回答候选，但内容或编号无效。'
        }
    }
    return New-NoWakeDecisionResult uncertain none @('speech-transcribed','no-addressing-model') '' '试判不确定：现有本地模型不能可靠判断这句话是否面向声伴；不会执行。'
}
