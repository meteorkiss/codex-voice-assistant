# A read-only target probe is independent of the audio/interactive bridge job.
function Initialize-BindingRecovery {
    $script:bindingAvailability='unchecked'; $script:bindingAvailabilityError=''
    $script:bindingGeneration=0; $script:bindingProbeJob=$null
    $script:lastBindingProbe=[DateTime]::MinValue
    $script:recoveryDraftError=''; $script:lastRecoveryDraftPath=''; $script:recoveryDraftCount=0
    try {
        $files=@(Get-AssistantRecoveryDraftFiles)
        $script:recoveryDraftCount=$files.Count
        if ($files.Count) { $script:lastRecoveryDraftPath=$files[0].FullName }
    } catch { $script:recoveryDraftError='保留草稿目录暂时不可读。' }
}

function Save-InputDraftForRecovery([string]$Reason) {
    if (-not $InputBox -or -not $InputBox.Text.Trim()) { return $true }
    $original=[string]$InputBox.Text
    try {
        $path=Save-AssistantRecoveryDraft -ThreadId ([string]$script:threadId) -Title ([string]$TaskLabel.Text) -Text $original -Reason $Reason
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Draft was not saved.' }
        $script:lastRecoveryDraftPath=$path; $script:recoveryDraftCount++
        if ([string]$InputBox.Text -cne $original) { throw 'Input changed during draft save.' }
        $wasConsuming=$script:consumingLocalCommand; $script:consumingLocalCommand=$true
        try { $InputBox.Text=''; $script:autoDispatch=$null }
        finally { $script:consumingLocalCommand=$wasConsuming }
        $script:recoveryDraftError=''
        return $true
    } catch {
        $script:recoveryDraftError='草稿未能安全保存，原文仍在输入框；请先复制保存，再重新连接。'
        $script:notice=$script:recoveryDraftError
        return $false
    }
}

function Enter-TaskBindingRecovery([string]$State) {
    if ($State -notin @('archived','missing')) { return $false }
    if ($script:bindingAvailability -eq $State) { return (-not $script:recoveryDraftError) }
    $script:bindingGeneration++; $script:bindingAvailability=$State
    $script:bindingAvailabilityError=''; $script:connected=$false; $script:busy=$false
    $script:voiceGeneration++; $script:autoDispatch=$null
    Reset-ManualTaskBinding
    Reset-VoiceTaskSwitch
    Invalidate-VoiceTaskCreateBinding -Reason '原任务已归档或不存在，等待明确选择新目标。'
    Close-ShortFollowUp -CancelCapture
    Stop-Output
    if ($script:recMode -ne 'idle' -or $script:asrJob) { Cancel-Recording }
    $reason=if ($State -eq 'archived') { '原任务已归档' } else { '原任务已不存在' }
    $saved=Save-InputDraftForRecovery $reason
    $script:handsFreePhase=if ($script:handsFreeEnabled) { 'waiting' } else { 'off' }
    if ($saved) { $script:notice=$reason+'，普通发送已停用；旧草稿已单独保留，可以说“切到声伴 6.17”。' }
    return $saved
}

function Complete-BindingAvailability($Result,$Context) {
    if (-not $Context -or $Context.ThreadId -cne [string]$script:threadId -or
        $Context.Generation -ne $script:bindingGeneration -or $script:closing) { return $false }
    # A fresh explicit repair takes precedence over an older passive probe.
    if ($script:manualTaskBinding -or $script:voiceTaskSwitch) { return $false }
    if (-not $Result -or $Result.ok -isnot [bool] -or -not $Result.ok -or
        $Result.threadId -cne $Context.ThreadId -or $Result.archived -isnot [bool] -or
        $Result.state -notin @('active','archived','missing') -or
        (($Result.state -eq 'archived') -ne $Result.archived)) {
        $script:bindingAvailability='unknown'
        $script:bindingAvailabilityError='无法确认当前任务状态，普通发送暂缓；不会把查找失败当成归档。'
        return $false
    }
    $script:bindingAvailabilityError=''
    if ($Result.state -in @('archived','missing')) { return Enter-TaskBindingRecovery $Result.state }
    if ($script:bindingAvailability -notin @('archived','missing')) { $script:bindingAvailability='active' }
    return $true
}

function Close-BindingProbe {
    if ($script:bindingProbeJob) {
        $job=$script:bindingProbeJob; $script:bindingProbeJob=$null
        Close-Job $job -Kill
    }
}

function Update-BindingAvailability([DateTime]$Now=[DateTime]::UtcNow) {
    if ($TestMode -or $PreviewPath -or $script:closing) { return }
    try {
        if ($script:bindingProbeJob) {
            $job=$script:bindingProbeJob
            if (-not $job.Process.HasExited -and ($Now-$job.Started).TotalSeconds -lt 8) { return }
            $script:bindingProbeJob=$null; $result=$null
            try {
                if ($job.Process.HasExited -and (Test-Path -LiteralPath $job.Output)) {
                    $result=Get-Content -LiteralPath $job.Output -Raw -Encoding UTF8 | ConvertFrom-Json
                }
            } catch { $result=$null }
            finally { Close-Job $job -Kill }
            [void](Complete-BindingAvailability $result $job.Context)
        }
        if (-not $script:threadId -or $script:bindingAvailability -in @('archived','missing') -or
            $script:manualTaskBinding -or $script:voiceTaskSwitch -or
            ($Now-$script:lastBindingProbe).TotalSeconds -lt 5) { return }
        $script:lastBindingProbe=$Now
        $token=[Guid]::NewGuid().ToString('N')
        $requestPath=Join-Path $runtime ($token+'.binding-state.json')
        $outputPath=Join-Path $runtime ($token+'.binding-state-result.json')
        try {
            Write-AtomicJson -Path $requestPath -Value @{action='binding-state';threadId=[string]$script:threadId}
            $proc=Start-Worker $python (Join-Path $PSScriptRoot 'codex_bridge.py') @('--request',$requestPath,'--output',$outputPath)
        } catch { Remove-OwnedFiles @($requestPath,$outputPath); throw }
        $script:bindingProbeJob=@{Process=$proc;Output=$outputPath;Files=@($requestPath,$outputPath);Started=$Now;
            Context=@{ThreadId=[string]$script:threadId;Generation=$script:bindingGeneration}}
    } catch {
        # Polling never unwinds into the audio Tick's global cancellation.
        $script:bindingAvailability='unknown'
        $script:bindingAvailabilityError='当前任务状态检查失败，普通发送暂缓；请重新连接。'
    }
}

function Open-AssistantRecoveryDraft {
    try {
        $files=@(Get-AssistantRecoveryDraftFiles)
        if (-not $files.Count) { $script:notice='没有已保留的草稿。'; return }
        # Only an explicit user click opens the folder. Never restore or send.
        Invoke-Item -LiteralPath ([IO.Path]::GetDirectoryName($files[0].FullName))
    } catch { $script:notice='无法打开保留草稿，请查看 data/recovery-drafts 目录。' }
}
