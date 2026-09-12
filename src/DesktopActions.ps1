# Explicit local actions use the desktop bridge; none are ordinary chat prompts.
function Set-VoiceDesktopActionNotice([string]$Message,[bool]$Speak=$false) {
    $script:notice=$Message
    $script:localCommandMessage=$Message
    $script:localCommandNoticeUntil=[DateTime]::UtcNow.AddSeconds(14)
    if ($Speak -and -not $script:closing) { Queue-AnswerSpeech $Message }
}

. (Join-Path $PSScriptRoot 'CodexAdapter.ps1')
function Begin-VoiceDesktopAction($Command) {
    if (-not $Command -or -not $Command.operation) { throw 'Missing desktop operation.' }
    $operation=[string]$Command.operation
    if ($operation -eq 'unsupported_project_move') {
        Set-VoiceDesktopActionNotice '声伴尚未接入移动项目。可在 Codex 侧栏右键这条对话，打开项目菜单后选择目标项目。' $true
        return $true
    }
    if ($script:closing -or $script:recMode -ne 'idle' -or $script:asrJob -or $script:handsFreePhase -in @('releasing','answering-wake','acknowledging')) {
        Set-VoiceDesktopActionNotice '请先完成这次录音，再操作。'; return $true
    }
    if (-not $script:connected) { Set-VoiceDesktopActionNotice '请先连接一个本机 Codex 任务。' $true; return $true }
    if ($script:bridgeJob) { Set-VoiceDesktopActionNotice '上一项操作仍在处理，请稍后再说。'; return $true }
    if ($script:pendingUncertain -or ($script:pendingSends -and $script:pendingSends.ContainsKey($script:threadId))) {
        Set-VoiceDesktopActionNotice '上次发送仍待核对，请先确认发送结果。'; return $true
    }
    if (Test-VoiceTaskCreateBlocksSend) { Set-VoiceDesktopActionNotice '新任务尚未连接，请先连接或放弃连接。'; return $true }
    # A different input or a newer dispatch intent remains the user's draft.
    if ($InputBox -and $InputBox.Text.Trim()) {
        $parsed=Get-AssistantVoiceCommand $InputBox.Text
        if (-not $parsed -or $parsed.Action -ne 'desktopAction' -or
            ($parsed.Value | ConvertTo-Json -Depth 5 -Compress) -cne ($Command | ConvertTo-Json -Depth 5 -Compress)) {
            Set-VoiceDesktopActionNotice '输入区还有其它文字，已保留，请先处理草稿。'; return $true
        }
    }
    if ($script:autoDispatch -and (-not $InputBox -or $script:autoDispatch.Text -cne $InputBox.Text.Trim())) {
        Set-VoiceDesktopActionNotice '还有待发送的文字，已保留，请先处理。'; return $true
    }
    if ($TestMode) { Set-VoiceDesktopActionNotice '测试模式：已识别操作，没有修改真实 Codex。'; return $true }
    Reset-VoiceTaskSwitch
    $requestId=[Guid]::NewGuid().ToString()
    $context=@{RequestId=$requestId;Operation=$operation;SourceThreadId=[string]$script:threadId;VoiceGeneration=$script:voiceGeneration}
    $request=@{action='manage';threadId=$context.SourceThreadId;requestId=$requestId;command=$Command}
    try {
        if (-not (Start-Bridge $request 'voice-manage')) { throw 'Desktop bridge did not start.' }
        $script:bridgeJob.VoiceDesktopActionContext=$context
        $script:desktopActionState='running'
        $script:desktopActionOperation=$operation
        Set-VoiceDesktopActionNotice '正在执行 Codex 本地操作…'
    } catch {
        $script:desktopActionState='failed'
        Set-VoiceDesktopActionNotice '操作没有开始，请稍后再试。'
    }
    return $true
}

function Test-VoiceDesktopActionFresh($Context) {
    return [bool]($Context -and -not $script:closing -and $Context.SourceThreadId -ceq [string]$script:threadId -and
        $script:recMode -eq 'idle' -and $Context.VoiceGeneration -eq $script:voiceGeneration -and
        -not $script:autoDispatch -and (-not $InputBox -or -not $InputBox.Text.Trim()))
}

function Complete-VoiceDesktopAction($Result,$Context) {
    if (-not $Context) { return $false }
    if ($Context.ReceiptApplied) { return $true }
    $script:desktopActionState=Get-CodexOperationReceipt $Result $Context.RequestId $Context.Operation
    if ($script:desktopActionState -ne 'complete') {
        $message=if ($Result -and $Result.ok -is [bool] -and $Result.ok -eq $false -and $Result.error -and $Result.error.message -is [string]) { [string]$Result.error.message } else { '操作结果尚未确认，请在 Codex 核对；不会自动重复执行。' }
        if (Test-VoiceDesktopActionFresh $Context) { Set-VoiceDesktopActionNotice $message $true }
        return $false
    }
    $script:desktopActionState='complete'
    $Context.ReceiptApplied=$true
    # A receipt records a completed operation even after a new recording starts.
    # Late results must not speak over the new input or replace its destination.
    if (-not (Test-VoiceDesktopActionFresh $Context)) { return $true }
    Set-VoiceDesktopActionNotice ([string]$Result.message) $false
    if ($Context.Operation -eq 'read_thread' -and $Result.text -is [string] -and $Result.text.Trim()) {
        Queue-AnswerSpeech ([string]$Result.text)
    } else { Queue-AnswerSpeech ([string]$Result.message) }
    return $true
}
