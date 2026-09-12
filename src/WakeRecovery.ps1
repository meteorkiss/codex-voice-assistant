# Bounded microphone recovery. This module owns no Codex or ASR process.
function Initialize-WakeRecovery([DateTime]$Now=[DateTime]::UtcNow) {
    $script:wakeRecovery=@{
        Phase='idle';Reason='';Message='';ReportedError='';LastTickUtc=$Now
        NextRouteCheckUtc=$Now;ReleaseScan=0L;ReleaseDeadlineUtc=[DateTime]::MaxValue
        NextAttemptUtc=[DateTime]::MaxValue;Attempts=@();AttemptCount=0
        StopRequested=$false;LastHealthState='idle';LastRecoveryUtc=[DateTime]::MinValue
        NormalStoppingSinceUtc=[DateTime]::MinValue;StartGeneration=-1L;PreserveActivity=$false;FirstFaultHandled=$false
    }
    # Resetting retry preferences is never permission to overlap an old stream.
    if ($script:wakeListener -and $script:wakeListener.PSObject.Methods['GetHealthSnapshot'] -and $script:wakeListener.IsStopping) {
        $script:wakeRecovery.Phase='releasing'
        $script:wakeRecovery.ReleaseScan=if($script:mic){[long]$script:mic.ScanCount}else{0L}
        $script:wakeRecovery.ReleaseDeadlineUtc=$Now.AddSeconds(8)
        $script:wakeRecovery.FirstFaultHandled=$true
        $script:wakeRecovery.Message='正在等待原麦克风释放…'
    }
}

function Test-WakeRecoveryPending {
    return [bool]($script:wakeRecovery -and $script:wakeRecovery.Phase -in @('releasing','backoff','starting','blocked'))
}

function Set-WakeRecoveryNotice([string]$Message,[bool]$Failure=$false) {
    $script:wakeRecovery.Message=$Message
    $script:notice=$Message
    if ($Failure) { $script:wakeRecovery.ReportedError=$Message; $script:errorText=$Message }
}

function Get-WakeRecoveryHealth {
    if (-not $script:wakeListener -or -not $script:wakeListener.PSObject.Methods['GetHealthSnapshot']) { return $null }
    try { return $script:wakeListener.GetHealthSnapshot() }
    catch { return [pscustomobject]@{State='error';NeedsRecovery=$true;Reason='health_check_failed';HasActivated=$false} }
}

function Test-WakeRecoveryActivity($Health=$null) {
    return [bool]($script:recMode -ne 'idle' -or $script:asrJob -or $script:autoDispatch -or
        $script:ttsJob -or [CodexReader.AudioPlayer]::State -in @('playing','paused') -or
        ($script:speechQueue -and $script:speechQueue.Count -gt 0) -or
        $script:handsFreePhase -in @('releasing','answering-wake','acknowledging') -or
        ($script:wakeListener.ActivationVersion -ne $script:lastWakeVersion) -or
        ($Health -and $Health.HasActivated -and $script:wakeListener.IsListening -and
            -not $script:wakeListener.IsStopping -and $script:wakeListener.HasQuestion) -or
        ($script:bridgeJob -and $script:bridgeJob.Purpose -notin @('list','open')) -or
        ($InputBox -and $InputBox.Text.Trim()))
}

function Request-WakeRecoveryRelease([string]$Reason,[DateTime]$Now,[switch]$PreserveActivity) {
    $state=$script:wakeRecovery
    $state.Phase='releasing';$state.Reason=$Reason;$state.StopRequested=$false
    $state.ReleaseScan=if($script:mic){[long]$script:mic.ScanCount}else{0L}
    $state.ReleaseDeadlineUtc=$Now.AddSeconds(8);$state.NextAttemptUtc=[DateTime]::MaxValue
    $state.PreserveActivity=[bool]$PreserveActivity;$state.NormalStoppingSinceUtc=[DateTime]::MinValue
    # Invalidate before cancelling capture: late ASR/KWS results cannot dispatch.
    $script:lastWakeVersion=$script:wakeListener.ActivationVersion
    $draft=if($InputBox){[string]$InputBox.Text}else{''}
    if (-not $PreserveActivity) {
        $script:voiceGeneration++;$script:autoDispatch=$null;$script:submitAfterRecognition=$false
        $queued=if($state.FirstFaultHandled -and $script:speechQueue){@($script:speechQueue.ToArray())}else{@()}
        Stop-Output
        foreach($text in $queued){$script:speechQueue.Enqueue($text)}
        $state.FirstFaultHandled=$true
    }
    if (-not $PreserveActivity -and $script:asrJob) {
        # The existing completion handler owns this worker and its files.
        # Keep it running, but never auto-send the now-stale result.
        $script:asrJob.SendAfter=$false
        $script:handsFreeCapture=$false;$script:echoQuestionCapture=$false
    } elseif (-not $PreserveActivity -and $script:recMode -ne 'idle') {
        Cancel-Recording
    }
    if ($InputBox -and $InputBox.Text -cne $draft) { $InputBox.Text=$draft }
    $script:handsFreePhase='waiting'
    try { [void]$script:wakeListener.RequestRecoveryStop();$state.StopRequested=$true }
    catch { $state.Reason='recovery_stop_failed' }
    Set-WakeRecoveryNotice '语音监听暂时失效，正在释放麦克风并准备恢复…'
}

function Test-WakeRecoveryReleased {
    if ($script:wakeListener.IsListening -or $script:wakeListener.IsStopping) { return $false }
    if ($script:recorder -and ($script:recorder.IsRecording -or $script:recorder.IsStopping)) { return $false }
    if (-not $script:mic -or -not $script:mic.Ready -or $script:mic.LastError -or
        [long]$script:mic.ScanCount -le [long]$script:wakeRecovery.ReleaseScan) { return $false }
    foreach ($session in @($script:mic.Sessions)) {
        if ($session.Active -and [int]$session.ProcessId -eq $PID) { return $false }
    }
    return $true
}

function Test-WakeRecoveryCanStart {
    if ($script:closing -or -not $script:handsFreeEnabled -or -not $script:connected -or
        $script:recMode -ne 'idle' -or $script:asrJob -or $script:autoDispatch -or $script:pendingUncertain -or
        ($script:bridgeJob -and $script:bridgeJob.Purpose -notin @('list','open')) -or
        ($InputBox -and $InputBox.Text.Trim()) -or $script:ttsJob -or
        [CodexReader.AudioPlayer]::State -in @('playing','paused') -or
        $script:wakeListener.IsListening -or $script:wakeListener.IsStopping -or
        ($script:recorder -and ($script:recorder.IsRecording -or $script:recorder.IsStopping))) { return $false }
    if (-not $script:mic -or -not $script:mic.Ready -or $script:mic.LastError -or $script:mic.AnyCaptureActive) { return $false }
    if (Test-ExternalCapture) { return $false }
    return $true
}

function Set-WakeRecoveryBlocked([string]$Message) {
    $script:wakeRecovery.Phase='blocked'
    Set-WakeRecoveryNotice $Message $true
}

function Start-WakeRecoveryAttempt([DateTime]$Now) {
    $state=$script:wakeRecovery
    $state.Attempts=@($state.Attempts|Where-Object { ($Now-$_).TotalMinutes -lt 5 })
    if ($state.Attempts.Count -ge 3) {
        Set-WakeRecoveryBlocked '语音监听多次恢复失败，已暂停重试。可关闭再开启语音唤醒，或重新打开声伴。'
        return
    }
    $state.Attempts+=,$Now;$state.AttemptCount=$state.Attempts.Count
    try {
        $route=Reset-WakeRecoveryAudioRoute
        $script:lastWakeVersion=$script:wakeListener.ActivationVersion
        $script:wakeReleaseScan=[long]$script:mic.ScanCount
        $script:wakeOwnsMicrophone=$true
        if ($script:bargeInEnabled -and -not $TestMode) {
            if (-not $route -or -not $route.CaptureEndpointId -or -not $route.RenderEndpointId) { throw 'Audio route is incomplete.' }
            [void]$script:wakeListener.StartEcho($script:wakePhrase,[string]$route.CaptureEndpointId,[string]$route.RenderEndpointId)
        } else { [void]$script:wakeListener.Start($script:wakePhrase) }
        $state.Phase='starting';$state.StopRequested=$false
        $state.StartGeneration=$script:voiceGeneration
        $script:handsFreePhase='waiting'
        Set-WakeRecoveryNotice ('正在恢复语音唤醒（第 '+$state.AttemptCount+' 次）…')
    } catch { Request-WakeRecoveryRelease 'restart_failed' $Now }
}

function Update-WakeRecovery([DateTime]$Now=[DateTime]::UtcNow) {
    if (-not $script:wakeRecovery) { Initialize-WakeRecovery $Now }
    $state=$script:wakeRecovery
    $gap=($Now-[DateTime]$state.LastTickUtc).TotalSeconds -gt 10
    $state.LastTickUtc=$Now
    if (-not $script:wakeListener -or -not $script:wakeListener.PSObject.Methods['GetHealthSnapshot']) { return }
    if ($script:closing -or -not $script:handsFreeEnabled) {
        # Existing shutdown/disable code owns normal cleanup. A pending recovery
        # never starts or changes either user preference after this point.
        if ((Test-WakeRecoveryPending) -and -not $state.StopRequested -and
            ($script:wakeListener.IsListening -or $script:wakeListener.IsStopping)) {
            try {[void]$script:wakeListener.RequestRecoveryStop();$state.StopRequested=$true}catch{}
        }
        if ((Test-WakeRecoveryPending) -and (Test-WakeRecoveryReleased)) {
            $script:wakeOwnsMicrophone=$false;$script:lastMicVersion=$script:mic.ActivationVersion
            $state.Phase='idle';$state.Reason='';$state.Message=''
            if($state.ReportedError -and $script:errorText -ceq $state.ReportedError){$script:errorText=''}
            $state.ReportedError=''
        }
        return
    }
    $health=Get-WakeRecoveryHealth
    if ($health) { $state.LastHealthState=[string]$health.State }
    if ($state.Phase -eq 'blocked') { return }
    if ($state.Phase -eq 'releasing') {
        if(-not $state.StopRequested){try{[void]$script:wakeListener.RequestRecoveryStop()}catch{};$state.StopRequested=$true}
        # A later manual recording is not the failed listener. Let that caller
        # finish normally; the eight-second release deadline concerns the old stream.
        if ($state.PreserveActivity -and -not $script:wakeListener.IsListening -and -not $script:wakeListener.IsStopping -and
            $script:recorder -and ($script:recorder.IsRecording -or $script:recorder.IsStopping)) {
            $state.ReleaseDeadlineUtc=$Now.AddSeconds(8)
            return
        }
        if (Test-WakeRecoveryReleased) {
            $script:wakeOwnsMicrophone=$false
            $script:lastMicVersion=$script:mic.ActivationVersion
            $state.Attempts=@($state.Attempts|Where-Object { ($Now-$_).TotalMinutes -lt 5 })
            $state.AttemptCount=$state.Attempts.Count
            if ($state.AttemptCount -ge 3) {
                Set-WakeRecoveryBlocked '语音监听多次恢复失败，已暂停重试。可关闭再开启语音唤醒，或重新打开声伴。'
                return
            }
            $delay=@(3,6,12)[$state.AttemptCount]
            $state.NextAttemptUtc=$Now.AddSeconds($delay);$state.Phase='backoff'
            Set-WakeRecoveryNotice ('麦克风已释放，'+$delay+' 秒后尝试恢复语音唤醒…')
        } elseif ($Now -ge [DateTime]$state.ReleaseDeadlineUtc) {
            Set-WakeRecoveryBlocked '未能确认原麦克风已释放，已停止自动恢复。请退出后重新打开声伴。'
        }
        return
    }
    if ($state.Phase -eq 'backoff') {
        if ($Now -ge [DateTime]$state.NextAttemptUtc -and (Test-WakeRecoveryCanStart)) { Start-WakeRecoveryAttempt $Now }
        return
    }
    if ($state.Phase -eq 'starting') {
        if (-not $script:connected -or $script:recMode -ne 'idle' -or $script:asrJob -or $script:autoDispatch -or
            $script:pendingUncertain -or $script:voiceGeneration -ne $state.StartGeneration -or
            ($script:bridgeJob -and $script:bridgeJob.Purpose -notin @('list','open')) -or
            ($InputBox -and $InputBox.Text.Trim()) -or (Test-ExternalCapture)) {
            Request-WakeRecoveryRelease 'recovery_context_changed' $Now -PreserveActivity
            return
        }
        if ($health -and $health.State -eq 'healthy' -and -not $health.NeedsRecovery -and
            $script:wakeListener.IsListening -and -not $script:wakeListener.IsStopping) {
            $state.Phase='idle';$state.Reason='';$state.LastRecoveryUtc=$Now;$state.NextRouteCheckUtc=$Now.AddSeconds(2)
            $state.FirstFaultHandled=$false
            $script:handsFreePhase='listening'
            if ($state.ReportedError -and $script:errorText -ceq $state.ReportedError) { $script:errorText='' }
            $state.ReportedError=''
            Set-WakeRecoveryNotice '语音唤醒已恢复，可以喊唤醒词。'
        } elseif ($health -and $health.NeedsRecovery) { Request-WakeRecoveryRelease ([string]$health.Reason) $Now }
        return
    }
    # A real pipeline failure takes precedence over a deferred route refresh.
    if ($health -and $health.NeedsRecovery) {
        Request-WakeRecoveryRelease ([string]$health.Reason) $Now
        return
    }
    if ($script:wakeListener.IsStopping) {
        if ($state.NormalStoppingSinceUtc -eq [DateTime]::MinValue) { $state.NormalStoppingSinceUtc=$Now }
        elseif (($Now-[DateTime]$state.NormalStoppingSinceUtc).TotalSeconds -ge 3) {
            Request-WakeRecoveryRelease 'normal_stop_stalled' $Now
        }
        return
    }
    $state.NormalStoppingSinceUtc=[DateTime]::MinValue
    $routeChanged=$false
    if ($Now -ge [DateTime]$state.NextRouteCheckUtc) {
        $state.NextRouteCheckUtc=$Now.AddSeconds(2)
        try { $routeChanged=[bool](Test-WakeRecoveryRouteChanged) } catch { }
    }
    if (($gap -and $script:wakeListener.IsListening) -or $routeChanged) {
        $state.Phase='deferred';$state.Reason=if($routeChanged){'default_device_changed'}else{'timer_gap'}
        $state.Message='当前这轮结束后将重新检查语音设备。'
    }
    if ($state.Phase -eq 'deferred' -and -not (Test-WakeRecoveryActivity $health)) {
        Request-WakeRecoveryRelease $state.Reason $Now
    }
}
