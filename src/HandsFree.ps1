# WPF state transitions: legacy half-duplex, or continuous echo-cancelled capture.
$script:handsFreeEnabled = $false
$script:handsFreePhase = 'off'
$script:wakePhrase = '你好，声伴'
$script:wakeListener = $null
$script:wakeOwnsMicrophone = $false
$script:wakeReleaseScan = 0L
$script:lastWakeVersion = 0L
$script:nextWakeUtc = [DateTime]::MinValue
$script:wakeReleaseDeadline = [DateTime]::MaxValue
$script:ackEpoch = -1
$script:ackWasPlaying = $false
$script:wakeCount = 0
$script:handsFreeCapture = $false
$script:voiceGeneration = 0
$script:autoDispatch = $null
$script:autoSendPrepared = 0
$script:closing = $false
$script:bargeInEnabled = $true

function Test-ExternalCapture {
    if (-not $script:mic.Ready -or $script:mic.LastError) { return $true }
    foreach ($session in @($script:mic.Sessions)) {
        if ($session.Active -and [int]$session.ProcessId -ne $PID) { return $true }
    }
    # A missing session identity must never be treated as permission to play.
    return ($script:mic.AnyCaptureActive -and -not $script:wakeOwnsMicrophone -and $script:recMode -eq 'idle')
}

function Suspend-WakeListener {
    $script:nextWakeUtc = [DateTime]::UtcNow.AddMilliseconds(800)
    if ($script:wakeListener -and $script:wakeListener.IsListening -and -not $script:wakeListener.IsStopping) {
        $script:wakeReleaseScan = $script:mic.ScanCount
        $script:wakeListener.Stop()
    }
}

function Set-HandsFree([bool]$Enabled) {
    $script:handsFreeEnabled = $Enabled
    Initialize-WakeRecovery
    $script:voiceGeneration++
    $script:autoDispatch = $null
    if (-not $Enabled) {
        Suspend-WakeListener
        if ($script:handsFreeCapture) { Cancel-Recording }
        if ($script:handsFreePhase -in @('releasing','answering-wake','acknowledging')) { Stop-Output }
        $script:handsFreeCapture = $false
        $script:handsFreePhase = 'off'
        $script:notice = '语音唤醒已关闭，可点击开始说话。'
    } else {
        $script:nextWakeUtc = [DateTime]::UtcNow.AddMilliseconds(800)
        $script:handsFreePhase = 'waiting'
        $script:errorText = ''
        $script:notice = '免点击模式已开启，正在准备唤醒。'
    }
    if ($HandsFreeToggle) { $HandsFreeToggle.IsChecked=$Enabled }
    if ($handsFreeItem) { $handsFreeItem.Checked=$Enabled }
}

function Invoke-WakeActivation {
    if (-not $script:handsFreeEnabled -or -not $script:connected -or $script:closing -or
        $script:recMode -ne 'idle' -or ($script:bridgeJob -and $script:bridgeJob.Purpose -notin @('list','open')) -or $script:pendingUncertain -or
        $InputBox.Text.Trim()) { return }
    $duplex=Test-FullDuplexReady
    if (-not $duplex -and ($script:ttsJob -or $script:speechQueue.Count -gt 0 -or [CodexReader.AudioPlayer]::State -in @('playing','paused'))) { return }
    if (Get-Command Save-VoicePlaybackBookmark -ErrorAction SilentlyContinue) {
        Save-VoicePlaybackBookmark
        Stop-Output -PreserveVoiceBookmark
    } else { Stop-Output }
    if (-not $duplex) { Suspend-WakeListener }
    $script:voiceGeneration++
    $script:handsFreeCapture=$false
    $script:wakeReleaseScan=$script:mic.ScanCount
    $script:wakeReleaseDeadline=[DateTime]::UtcNow.AddSeconds(8)
    $script:handsFreePhase=if($duplex) { 'answering-wake' } else { 'releasing' }
    $script:wakeCount++
    $script:notice='听到唤醒词，正在回应…'
}

function Queue-AnswerSpeech([string]$Text) {
    if ($script:recMode -ne 'idle' -or $script:handsFreePhase -in @('releasing','answering-wake','acknowledging') -or (Test-ExternalCapture)) { return }
    if (-not (Test-FullDuplexReady)) {
        # Keep a cold AEC listener warming up. Its ownership blocks Safe-To-Play
        # until the actual microphone/reference pipeline becomes ready.
        if (-not ($script:bargeInEnabled -and $script:handsFreeEnabled -and -not $TestMode)) { Suspend-WakeListener }
        if ($script:handsFreeEnabled) { $script:handsFreePhase='waiting' }
    }
    $spokenText=ConvertTo-SpokenText $Text
    if ($spokenText.Trim()) { $script:speechQueue.Enqueue($spokenText) }
}

function Try-AutoDispatch {
    if (-not $script:autoDispatch) { return }
    $intent=$script:autoDispatch
    if ($script:closing -or $intent.Generation -ne $script:voiceGeneration -or $intent.ThreadId -ne $script:threadId -or $intent.Text -ne $InputBox.Text.Trim()) {
        $script:autoDispatch=$null; return
    }
    if ($script:recMode -ne 'idle') { return }
    if (Try-LocalAssistantCommand $intent.Text) { return }
    if ($script:pendingUncertain) {
        $script:autoDispatch=$null
        $script:notice='上次发送待核对，已保留这次文字，不会自动重发。'
        return
    }
    if (-not $script:connected -or $script:recMode -ne 'idle' -or $script:bridgeJob) {
        $script:notice='文字已识别，正在等待 Codex 连接空闲。'
        return
    }
    # Only an undispatched intent may wait. Once attempted, never auto-retry.
    $script:autoDispatch=$null
    $script:autoSendPrepared++
    Send-Text
}

function Update-HandsFree([DateTime]$Now = [DateTime]::UtcNow) {
    if (-not $script:wakeListener) { return }
    if ($script:wakeOwnsMicrophone -and -not $script:wakeListener.IsListening -and -not $script:wakeListener.IsStopping -and
        $script:mic.ScanCount -gt $script:wakeReleaseScan -and -not $script:mic.AnyCaptureActive) {
        $script:wakeOwnsMicrophone=$false
        $script:lastMicVersion=$script:mic.ActivationVersion
    }
    if ($script:closing -or -not $script:handsFreeEnabled) { Suspend-WakeListener; return }
    if (Test-WakeRecoveryPending) { return }
    if ($script:wakeListener.Error) {
        $failure=$script:wakeListener.Error
        Set-HandsFree $false
        $script:notice='语音唤醒暂时不可用：'+$failure
        $script:errorText=$script:notice
        return
    }
    if ($script:wakeListener.ActivationVersion -ne $script:lastWakeVersion) {
        $script:lastWakeVersion=$script:wakeListener.ActivationVersion
        if ($script:handsFreePhase -in @('listening','speaking')) { Invoke-WakeActivation }
    }
    if (Test-ExternalCapture) {
        Suspend-WakeListener
        if ($script:handsFreePhase -in @('releasing','answering-wake','acknowledging')) { Stop-Output; $script:handsFreePhase='waiting' }
        if ($script:handsFreeCapture -and $script:recMode -ne 'idle') { Cancel-Recording }
        return
    }
    if ($script:handsFreePhase -in @('releasing','answering-wake')) {
        if ($Now -gt $script:wakeReleaseDeadline) { $script:handsFreePhase='waiting'; $script:notice='麦克风尚未释放，请稍后再唤醒。'; return }
        if ($script:handsFreePhase -eq 'answering-wake') {
            if (-not (Test-FullDuplexReady)) { Suspend-WakeListener; $script:handsFreePhase='waiting'; return }
        } elseif ($script:wakeOwnsMicrophone -or $script:wakeListener.IsListening -or $script:wakeListener.IsStopping -or
            $script:mic.ScanCount -le $script:wakeReleaseScan -or -not (Safe-To-Play)) { return }
        $ack=Join-Path $workspace ('assets\ack-'+$script:voiceId+'.mp3')
        if (-not (Test-Path -LiteralPath $ack)) { Set-HandsFree $false; throw '唤醒回应音频缺失。' }
        $script:audioPath=$ack
        [CodexReader.AudioPlayer]::Play($ack)
        $script:ackEpoch=$script:epoch
        # A very short clip can finish before the first poll after successful Play.
        $script:ackWasPlaying=([CodexReader.AudioPlayer]::State -in @('playing','stopped'))
        $script:handsFreePhase='acknowledging'
        $script:notice='在。'
        return
    }
    if ($script:handsFreePhase -eq 'acknowledging') {
        if ($script:ackEpoch -ne $script:epoch) { Suspend-WakeListener; $script:handsFreePhase='waiting'; $script:nextWakeUtc=$Now.AddMilliseconds(800); return }
        $audioState=[CodexReader.AudioPlayer]::State
        if ($audioState -eq 'playing') { $script:ackWasPlaying=$true; return }
        if (-not $script:ackWasPlaying -or $audioState -ne 'stopped') {
            Stop-Output
            Suspend-WakeListener
            $script:handsFreePhase='waiting'; $script:notice='回应被中断，请再喊一次唤醒词。'; return
        }
        Begin-Recording $true
        $script:handsFreePhase='recording'
        return
    }
    if ($script:recMode -ne 'idle') {
        if (-not ($script:handsFreeCapture -and (Test-FullDuplexReady))) { Suspend-WakeListener }
        $script:handsFreePhase=if ($script:recMode -eq 'transcribing') { 'recognizing' } else { 'recording' }
        return
    }
    if (($script:bridgeJob -and $script:bridgeJob.Purpose -notin @('list','open')) -or $script:pendingUncertain -or $script:autoDispatch -or -not $script:connected -or $InputBox.Text.Trim()) {
        Suspend-WakeListener
        $script:handsFreePhase='waiting'
        return
    }
    $hasSpeech=($script:ttsJob -or $script:speechQueue.Count -gt 0 -or [CodexReader.AudioPlayer]::State -in @('playing','paused'))
    if ($hasSpeech -and -not (Test-FullDuplexReady)) {
        if (-not ($script:bargeInEnabled -and -not $TestMode)) { Suspend-WakeListener; $script:handsFreePhase='waiting'; return }
        if ($script:wakeListener.IsListening -and -not $script:wakeListener.IsStopping) {
            if (-not $script:wakeListener.RenderEndpointId) { Suspend-WakeListener; $script:handsFreePhase='waiting' }
            else { $script:handsFreePhase='listening' }
            return
        }
        # No input stream yet: continue below and establish AEC before beginning TTS.
    }
    if ($script:wakeListener.IsListening -and -not $script:wakeListener.IsStopping) {
        $script:handsFreePhase=if($hasSpeech) { 'speaking' } else { 'listening' }; return
    }
    $script:handsFreePhase='waiting'
    if ($Now -lt $script:nextWakeUtc -or $script:wakeOwnsMicrophone -or $script:wakeListener.IsStopping -or
        $script:mic.AnyCaptureActive -or -not $script:mic.Ready) { return }
    $script:lastWakeVersion=$script:wakeListener.ActivationVersion
    $script:wakeReleaseScan=$script:mic.ScanCount
    $script:wakeOwnsMicrophone=$true
    if ($TestMode -and $script:testWakeInputPath) {
        $testInput=$script:testWakeInputPath; $script:testWakeInputPath=''
        $script:wakeListener.StartWaveFile($script:wakePhrase,$testInput)
    } elseif ($script:bargeInEnabled -and -not $TestMode) {
        $script:wakeListener.StartEcho($script:wakePhrase,[EchoCapture]::GetDefaultCaptureEndpointId(),[CodexReader.AudioPlayer]::RenderEndpointId)
    } else { $script:wakeListener.Start($script:wakePhrase) }
    $script:handsFreePhase='listening'
}

. (Join-Path $PSScriptRoot 'WakeRecovery.ps1')
