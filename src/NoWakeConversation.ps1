. (Join-Path $PSScriptRoot 'NoWakeDecision.ps1')

$script:noWakeMode='off'
$script:noWakePhase='off'
$script:noWakeCapture=$null
$script:noWakeAsrJob=$null
$script:noWakeGeneration=0L
$script:noWakeNextStartUtc=[DateTime]::MinValue
$script:noWakeLastDecision=$null
$script:noWakeJudgmentCount=0
$script:noWakeAcceptedCount=0
$script:noWakeLastError=''

function Get-NoWakeContextSnapshot([string]$Text='') {
    $pending=$script:voiceTaskSwitch
    $active=[bool]($pending -and $pending.Phase -eq 'choosing' -and -not $script:closing -and
        $pending.SourceThreadId -ceq [string]$script:threadId -and $pending.ExpiresAt -gt [DateTime]::UtcNow)
    if (-not $active) {
        return @{Active=$false;ContextId='';SourceThreadId='';CurrentThreadId=[string]$script:threadId;
            ExpiresUtc=[DateTime]::MinValue;CandidateCount=0;Command=$null}
    }
    $contextId=([string]$pending.Generation)+'|'+([string]$pending.SourceThreadId)+'|'+$pending.ExpiresAt.Ticks
    $command=$null
    if ($Text.Trim()) {
        $command=Get-AssistantTaskSelectionReply $Text ($pending.Candidates.Count -eq 1)
        if (-not $command) {
            $candidate=Get-AssistantVoiceCommand $Text
            if ($candidate -and $candidate.Action -in @('chooseTask','cancelTaskSwitch')) { $command=$candidate }
        }
    }
    return @{Active=$true;ContextId=$contextId;SourceThreadId=[string]$pending.SourceThreadId;
        CurrentThreadId=[string]$script:threadId;ExpiresUtc=$pending.ExpiresAt;
        CandidateCount=[int]$pending.Candidates.Count;Command=$command}
}

function Test-NoWakeExternalCapture {
    if (-not $script:mic.Ready -or $script:mic.LastError) { return $true }
    foreach ($session in @($script:mic.Sessions)) {
        if ($session.Active -and [int]$session.ProcessId -ne $PID) { return $true }
    }
    return $false
}

function Get-NoWakeBlockReason {
    if ($script:noWakeMode -eq 'off') { return 'mode-off' }
    if ($script:closing) { return 'closing' }
    if ($script:recMode -ne 'idle' -or $script:asrJob) { return 'manual-recording' }
    if ($script:bridgeJob) { return 'bridge-busy' }
    if ($script:pendingUncertain -or ($script:pendingSends -and $script:pendingSends.ContainsKey($script:threadId))) { return 'pending-send' }
    if ($InputBox.Text.Trim()) { return 'draft' }
    if (-not $script:connected -or $script:bindingAvailability -in @('archived','missing','unknown') -or $script:bindingReadError) { return 'binding' }
    if ($script:manualTaskBinding -or $script:voiceTaskCreate) { return 'target-change' }
    if ($script:ttsJob -or $script:speechQueue.Count -gt 0 -or [CodexReader.AudioPlayer]::State -in @('playing','paused')) { return 'playback' }
    if (Test-NoWakeExternalCapture) { return 'external-capture' }
    return ''
}

function Stop-NoWakeCapture([int]$WaitMilliseconds=3000) {
    $capture=$script:noWakeCapture
    if (-not $capture) { return $true }
    $capture.Stop()
    if (-not $capture.StopAndWait($WaitMilliseconds)) {
        $script:noWakePhase='stopping'
        return $false
    }
    $capture.Dispose()
    $script:noWakeCapture=$null
    return $true
}

function Stop-NoWakeAsr {
    if (-not $script:noWakeAsrJob) { return }
    $job=$script:noWakeAsrJob; $script:noWakeAsrJob=$null
    Close-Job $job -Kill
}

function Set-NoWakeMode([string]$Mode) {
    if ($Mode -notin @('off','observe','context')) { throw '未知的免唤醒模式。' }
    if ($Mode -ceq $script:noWakeMode) { return }
    $script:noWakeGeneration++
    Stop-NoWakeAsr
    [void](Stop-NoWakeCapture)
    $script:noWakeMode=$Mode
    $script:noWakeLastDecision=$null
    $script:noWakeLastError=''
    $script:noWakeNextStartUtc=[DateTime]::UtcNow.AddMilliseconds(800)
    if ($Mode -eq 'off') {
        $script:noWakePhase='off'
        $script:notice='免唤醒实验已关闭；原语音唤醒和手动录音仍可使用。'
    } elseif ($Mode -eq 'observe') {
        $script:noWakePhase='starting'
        $script:notice='免唤醒仅试判已开启；只在本机判断，不会执行或发送。'
    } else {
        $script:noWakePhase='starting'
        $script:notice='免唤醒上下文确认已开启；只处理当前候选的是、否、取消或编号。'
    }
}

function Suspend-NoWakeConversation([string]$Reason) {
    if ($script:noWakeMode -eq 'off') { return }
    if ($script:noWakePhase -ne 'paused' -or $script:noWakeCapture -or $script:noWakeAsrJob) {
        $script:noWakeGeneration++
        Stop-NoWakeAsr
        [void](Stop-NoWakeCapture)
    }
    $script:noWakePhase='paused'
    $script:noWakeNextStartUtc=[DateTime]::UtcNow.AddMilliseconds(800)
    switch ($Reason) {
        'draft' { $script:notice='免唤醒已暂停：先处理未发送草稿。' }
        'pending-send' { $script:notice='免唤醒已暂停：上次发送结果仍待核对。' }
        'playback' { }
        'external-capture' { $script:notice='免唤醒已暂停：其他应用正在使用麦克风。' }
        'binding' { $script:notice='免唤醒已暂停：当前任务不可安全发送。' }
    }
}

function Start-NoWakeTranscription($Segment) {
    $wavePath=Join-Path $runtime ([Guid]::NewGuid().ToString('N')+'.nowake.wav')
    $resultPath=Join-Path $runtime ([Guid]::NewGuid().ToString('N')+'.nowake.asr.json')
    [NoWakeCapture]::WriteWave($wavePath,$Segment.Pcm)
    $proc=Start-Worker $asrPython (Join-Path $PSScriptRoot 'transcribe.py') @('--input',$wavePath,'--output',$resultPath,'--model-dir',$modelDir)
    $script:noWakeAsrJob=@{Process=$proc;Purpose='no-wake-transcribe';Output=$resultPath;Files=@($resultPath,$wavePath);
        Generation=$script:noWakeGeneration;CaptureGeneration=$Segment.Generation;ThreadId=[string]$script:threadId;
        BindingGeneration=$script:bindingGeneration;Context=(Get-NoWakeContextSnapshot);
        Evidence=@{DurationSeconds=$Segment.DurationSeconds;EndReason=$Segment.EndReason;Rms=$Segment.Rms;Peak=$Segment.Peak}}
    $script:noWakePhase='transcribing'
    $script:notice='免唤醒正在本机试判；不会自动发送普通话语。'
}

function Test-NoWakeContextStillCurrent($Snapshot) {
    if (-not $Snapshot -or -not $Snapshot.Active) { return $false }
    $current=Get-NoWakeContextSnapshot
    return [bool]($current.Active -and $current.ContextId -ceq $Snapshot.ContextId -and
        $current.SourceThreadId -ceq $Snapshot.SourceThreadId -and $current.CurrentThreadId -ceq $script:threadId)
}

function Invoke-NoWakeContextDecision([string]$Text,$Decision,$Snapshot) {
    if ($script:noWakeMode -ne 'context' -or $Decision.Route -ne 'context-confirmation' -or
        -not (Test-NoWakeContextStillCurrent $Snapshot) -or $Decision.ContextId -cne $Snapshot.ContextId -or
        $script:closing -or $script:recMode -ne 'idle' -or $script:bridgeJob -or $script:pendingUncertain -or
        $InputBox.Text.Trim() -or $script:bindingAvailability -in @('archived','missing','unknown') -or $script:bindingReadError) { return $false }
    if (-not (Stop-NoWakeCapture)) { return $false }
    $script:noWakePhase='routing'
    $beforeGeneration=$script:noWakeGeneration
    $InputBox.Text=$Text
    $handled=Try-LocalAssistantCommand $Text
    if (-not $handled -and $beforeGeneration -eq $script:noWakeGeneration -and $InputBox.Text -ceq $Text) {
        $wasConsuming=$script:consumingLocalCommand; $script:consumingLocalCommand=$true
        try { $InputBox.Text='' } finally { $script:consumingLocalCommand=$wasConsuming }
    }
    if (-not $handled) { $script:notice='免唤醒确认已失效，未执行；请重新选择。'; return $false }
    $script:noWakeAcceptedCount++
    $script:noWakeNextStartUtc=[DateTime]::UtcNow.AddMilliseconds(800)
    return $true
}

function Complete-NoWakeTranscription([DateTime]$Now) {
    $job=$script:noWakeAsrJob
    if (-not $job -or -not $job.Process.HasExited) { return }
    $script:noWakeAsrJob=$null
    try { $result=if (Test-Path -LiteralPath $job.Output) { Get-Content -LiteralPath $job.Output -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null } } catch { $result=$null }
    $code=$job.Process.ExitCode
    Close-Job $job
    $stale=($job.Generation -ne $script:noWakeGeneration -or $job.ThreadId -cne [string]$script:threadId -or
        $job.BindingGeneration -ne $script:bindingGeneration -or $script:noWakeMode -eq 'off' -or $script:closing)
    if ($code -ne 0 -or -not $result -or -not $result.ok -or $result.error) {
        if (-not $stale) {
            $script:noWakeLastError='本地试判转写失败。'
            [void](Stop-NoWakeCapture)
            $script:noWakePhase='error'
            $script:noWakeNextStartUtc=$Now.AddSeconds(10)
            $script:notice=$script:noWakeLastError+' 稍后会重新准备。'
        }
        return
    }
    $text=[string]$result.text
    $context=$job.Context
    if ($context -and $context.Active -and (Test-NoWakeContextStillCurrent $context)) {
        $parsed=Get-NoWakeContextSnapshot $text
        $context.Command=$parsed.Command
        $context.CurrentThreadId=[string]$script:threadId
    } else { $context=@{Active=$false;ContextId='';SourceThreadId='';CurrentThreadId=[string]$script:threadId;ExpiresUtc=[DateTime]::MinValue;CandidateCount=0;Command=$null} }
    $evidence=$job.Evidence
    $evidence.Stale=$stale
    $evidence.ExternalCapture=(Test-NoWakeExternalCapture)
    $evidence.SelfPlayback=[bool]($script:ttsJob -or $script:speechQueue.Count -gt 0 -or [CodexReader.AudioPlayer]::State -in @('playing','paused'))
    $decision=Get-NoWakeDecision -Text $text -Mode $script:noWakeMode -Evidence $evidence -Context $context -Now $Now
    if ($stale) { return }
    $script:noWakeJudgmentCount++
    $script:noWakeLastDecision=@{Disposition=$decision.Disposition;Route=$decision.Route;ReasonCodes=@($decision.ReasonCodes);
        ContextId=$decision.ContextId;Display=$decision.Display;AtUtc=$Now;DurationSeconds=$evidence.DurationSeconds}
    $script:noWakePhase='observing'
    $script:notice=$decision.Display
    if ($decision.Disposition -eq 'accept' -and $decision.Route -eq 'context-confirmation') {
        [void](Invoke-NoWakeContextDecision $text $decision $context)
    }
}

function Update-NoWakeConversation([DateTime]$Now=[DateTime]::UtcNow) {
    if ($script:noWakeMode -eq 'off') {
        if ($script:noWakeCapture) { [void](Stop-NoWakeCapture) }
        if ($script:noWakeAsrJob) { Stop-NoWakeAsr }
        $script:noWakePhase='off'
        return
    }
    Complete-NoWakeTranscription $Now
    $reason=Get-NoWakeBlockReason
    if ($reason) { Suspend-NoWakeConversation $reason; return }
    if ($script:noWakeCapture -and $script:noWakeCapture.Error) {
        $script:noWakeLastError=[string]$script:noWakeCapture.Error
        [void](Stop-NoWakeCapture)
        $script:noWakePhase='error'
        $script:noWakeNextStartUtc=$Now.AddSeconds(10)
        $script:notice='免唤醒采集暂不可用：'+$script:noWakeLastError
        return
    }
    if (-not $script:noWakeCapture) {
        Suspend-WakeListener
        if ($Now -lt $script:noWakeNextStartUtc -or $script:wakeOwnsMicrophone -or
            $script:wakeListener.IsListening -or $script:wakeListener.IsStopping -or $script:mic.AnyCaptureActive) {
            $script:noWakePhase='starting'; return
        }
        $captureId=[string]$script:mic.DefaultCaptureEndpointId
        $renderId=[string][CodexReader.AudioPlayer]::RenderEndpointId
        if (-not $captureId -or -not $renderId) { $script:noWakePhase='error'; $script:notice='免唤醒需要可用的默认麦克风和朗读输出设备。'; return }
        $script:noWakeGeneration++
        $script:noWakeCapture=New-Object NoWakeCapture
        try { $script:noWakeCapture.Start($captureId,$renderId,$script:noWakeGeneration); $script:noWakeLastError=''; $script:noWakePhase='observing' }
        catch { $script:noWakeLastError=$_.Exception.Message; try { $script:noWakeCapture.Dispose() } catch {}; $script:noWakeCapture=$null; $script:noWakePhase='error'; $script:noWakeNextStartUtc=$Now.AddSeconds(10); $script:notice='免唤醒采集没有开始：'+$script:noWakeLastError; return }
    }
    if (-not $script:noWakeAsrJob) {
        $segment=$script:noWakeCapture.TryDequeueSegment()
        if ($segment) { Start-NoWakeTranscription $segment }
        elseif ($script:noWakePhase -ne 'observing') { $script:noWakePhase='observing' }
    }
}

function Close-NoWakeConversation {
    $script:noWakeGeneration++
    Stop-NoWakeAsr
    [void](Stop-NoWakeCapture)
    $script:noWakePhase='off'
}
