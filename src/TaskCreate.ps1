. (Join-Path $PSScriptRoot 'TaskBinding.ps1')
# Creation is an irreversible dispatch. Its receipt outlives any automatic binding.
function Save-VoiceTaskCreateRecord {
    if (-not $script:voiceTaskCreatePath) { $script:voiceTaskCreatePath=Join-Path $stateDir 'voice-task-create.json' }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $script:voiceTaskCreatePath))
    $temporary=$script:voiceTaskCreatePath+'.tmp'
    [IO.File]::WriteAllText($temporary,($script:voiceTaskCreate | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $script:voiceTaskCreatePath) { [IO.File]::Replace($temporary,$script:voiceTaskCreatePath,[NullString]::Value) }
    else { [IO.File]::Move($temporary,$script:voiceTaskCreatePath) }
}
function Set-VoiceTaskCreateNotice([string]$Message,[bool]$Speak=$false) {
    if ($script:voiceTaskCreate) { $script:voiceTaskCreate.Message=$Message }
    $script:notice=$Message; $script:localCommandMessage=$Message
    $script:localCommandNoticeUntil=[DateTime]::UtcNow.AddSeconds(12)
    if ($Speak -and -not $script:closing) { Queue-AnswerSpeech $Message }
}
function Test-VoiceTaskCreatePending {
    return [bool]($script:voiceTaskCreate -and $script:voiceTaskCreate.Phase -notin @('bound','rejected','not_found'))
}
function Test-VoiceTaskCreateBlocksSend {
    return [bool]((Test-VoiceTaskCreatePending) -and $script:voiceTaskCreate.SendBlocked)
}
function Get-VoiceTaskCreateBlockReason([string]$Action='') {
    if ($script:closing) { return '程序正在退出，请稍后操作。' }
    if ($script:recMode -ne 'idle' -or $script:asrJob -or $script:handsFreePhase -in @('releasing','answering-wake','acknowledging')) { return '请先完成这次录音。' }
    if ($script:pendingUncertain -or ($script:pendingSends -and $script:pendingSends.ContainsKey($script:threadId))) { return '上次发送仍待核对，请先确认发送结果。' }
    if ($script:bridgeJob -and $script:bridgeJob.Purpose -eq 'send') { return '消息正在发送，请等待发送回执。' }
    if ($InputBox -and $InputBox.Text.Trim()) {
        $command=Get-AssistantVoiceCommand $InputBox.Text
        if (-not $Action -or -not $command -or $command.Action -ne $Action) { return '输入框里还有文字，已保留，请先处理这份草稿。' }
    }
    if ($script:autoDispatch -and (-not $InputBox -or $script:autoDispatch.Text -cne $InputBox.Text.Trim())) { return '还有待发送文字，已保留，请先处理。' }
    return ''
}
function Initialize-VoiceTaskCreate {
    $script:voiceTaskCreate=$null
    $script:voiceTaskCreatePath=Join-Path $stateDir 'voice-task-create.json'
    $script:voiceTaskCreateSession=[Guid]::NewGuid().ToString('N')
    if (-not (Test-Path -LiteralPath $script:voiceTaskCreatePath)) { return }
    try {
        $saved=Get-Content -LiteralPath $script:voiceTaskCreatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $id=[Guid]::Empty; $source=[Guid]::Empty
        if ($saved.Version -ne 1 -or $saved.RequestId -isnot [string] -or $saved.SourceThreadId -isnot [string] -or -not [Guid]::TryParse([string]$saved.RequestId,[ref]$id) -or
            -not [Guid]::TryParse([string]$saved.SourceThreadId,[ref]$source)) { throw 'Invalid creation receipt.' }
        if ($saved.AutoBindAllowed -isnot [bool] -or $saved.SendBlocked -isnot [bool] -or $saved.ConnectionAbandoned -isnot [bool] -or
            $saved.CreationState -notin @('dispatching','ready','pending','unknown','rejected','not_found') -or
            $saved.Phase -notin @('creating','checking','unknown','created','reading','bound','abandoned','rejected','not_found') -or
            $saved.Scope -isnot [string] -or $saved.Scope -notin @('projectless','current-project') -or $null -eq $saved.BindingGeneration -or
            [int]$saved.BindingGeneration -lt 0) { throw 'Incomplete creation journal.' }
        if ($saved.ProcessId -isnot [int] -and $saved.ProcessId -isnot [long]) { throw 'Invalid worker identity.' }
        if ([long]$saved.ProcessId -lt 0 -or ($saved.ProcessId -gt 0 -and -not $saved.ProcessStartedUtc)) { throw 'Incomplete worker identity.' }
        if ($saved.ProcessId -gt 0) { [void][DateTime]::Parse([string]$saved.ProcessStartedUtc) }
        $target=[Guid]::Empty
        if ($saved.CreationState -eq 'ready' -and (-not [Guid]::TryParse([string]$saved.ThreadId,[ref]$target) -or $target -eq $source)) { throw 'Invalid created task ID.' }
        if ($saved.Phase -eq 'bound' -and $saved.CreationState -ne 'ready') { throw 'Conflicting creation state.' }
        if (-not $saved.SendBlocked -and -not $saved.ConnectionAbandoned -and $saved.Phase -notin @('bound','rejected','not_found')) { throw 'Missing pending-send protection.' }
        $record=@{}; foreach ($property in $saved.PSObject.Properties) { $record[$property.Name]=$property.Value }
        $script:voiceTaskCreate=$record
        $record.AutoBindAllowed=$false; $record.BindingGeneration=[int]$record.BindingGeneration+1
        $record.SessionId=$script:voiceTaskCreateSession
        $record.NextStatusUtc=[DateTime]::UtcNow
        $record.PollUntilUtc=[DateTime]::UtcNow.AddSeconds(30)
        if ($record.CreationState -eq 'ready' -and $record.Phase -ne 'bound') { $record.Phase='created' }
        if (Test-VoiceTaskCreatePending) {
            $message=if ($record.ThreadId) { '之前的新任务已创建，尚未连接。可说“连接刚才的新任务”，或“放弃连接新任务”。' } else { '之前的新建请求仍待确认；只查询原请求，不会重复创建。' }
            Set-VoiceTaskCreateNotice $message
            Save-VoiceTaskCreateRecord
        }
    } catch {
        # A damaged journal must not enable a second mutation by forgetting the first.
        if (-not $script:voiceTaskCreate) { $script:voiceTaskCreate=@{Phase='unavailable';Message='新建任务记录暂时无法读取，请先在 Codex 核对。';SendBlocked=$true;AutoBindAllowed=$false;RequestId=''} }
        Set-VoiceTaskCreateNotice '新建任务记录暂时无法读取或保存，请先在 Codex 核对。'
    }
}
function Invalidate-VoiceTaskCreateBinding {
    param([string]$Reason='当前操作已改变，保留新建结果但不自动连接。',[switch]$ReleaseSendBlock)
    $record=$script:voiceTaskCreate
    if (-not $record -or $record.Phase -in @('bound','rejected','not_found')) { return }
    if ($record.AutoBindAllowed -or ($ReleaseSendBlock -and $record.SendBlocked)) {
        $priorSendBlock=$record.SendBlocked
        $record.AutoBindAllowed=$false; $record.BindingGeneration=[int]$record.BindingGeneration+1
        $record.InvalidReason=$Reason
        if ($ReleaseSendBlock) { $record.SendBlocked=$false; $record.ConnectionAbandoned=$true }
        if ($record.CreationState -eq 'ready') { $record.Phase=if ($ReleaseSendBlock) {'abandoned'} else {'created'} }
        try { Save-VoiceTaskCreateRecord; $record.LastPersistenceError=$false } catch { $record.SendBlocked=$priorSendBlock;$record.LastPersistenceError=$true;Set-VoiceTaskCreateNotice '连接状态未能保存；新建请求不会重发，请在 Codex 核对。' }
    }
}
function Test-VoiceTaskCreateWorkerRunning($Record) {
    if (-not $Record.ProcessId -or -not $Record.ProcessStartedUtc) { return -not [bool]$Record.DefinitelyNotDispatched }
    try {
        $process=Get-Process -Id ([int]$Record.ProcessId) -ErrorAction Stop
        return (-not $process.HasExited -and [Math]::Abs(($process.StartTime.ToUniversalTime()-[DateTime]::Parse([string]$Record.ProcessStartedUtc).ToUniversalTime()).TotalSeconds) -lt 1)
    } catch { return $false }
}
function Start-VoiceTaskCreateBridge($Request,[string]$Purpose) {
    $record=$script:voiceTaskCreate
    if (-not (Start-Bridge $Request $Purpose)) { return $false }
    $script:bridgeJob.VoiceTaskCreateContext=@{RequestId=$record.RequestId;SourceThreadId=$record.SourceThreadId;
        SessionId=$record.SessionId;BindingGeneration=$record.BindingGeneration}
    if ($Purpose -eq 'voice-create') {
        $record.DispatchState='dispatched'
        try { $record.ProcessId=$script:bridgeJob.Process.Id; $record.ProcessStartedUtc=$script:bridgeJob.Process.StartTime.ToUniversalTime().ToString('o') } catch { }
        # Failure here is uncertain, never evidence that creating may be retried.
        try { Save-VoiceTaskCreateRecord } catch { Set-VoiceTaskCreateNotice '新建请求已发出，但记录未能更新；不会重复创建。' }
    }
    return $true
}
function Begin-VoiceTaskCreate([string]$Title='', [string]$Scope='projectless') {
    $blocked=Get-VoiceTaskCreateBlockReason 'createTask'
    if ($blocked) { Set-VoiceTaskCreateNotice $blocked; return $true }
    $previous=$script:voiceTaskCreate
    if ($previous -and $previous.CreationState -notin @('ready','rejected','not_found')) {
        Set-VoiceTaskCreateNotice '上次新建请求还没有确定结果，请先查询或连接刚才的新任务；不会重复创建。'; return $true
    }
    if ($previous -and $previous.CreationState -eq 'ready' -and $previous.Phase -ne 'bound' -and -not $previous.ConnectionAbandoned) {
        Set-VoiceTaskCreateNotice '刚才的新任务已创建但尚未连接，请先连接它或明确放弃连接；不会再次创建。'; return $true
    }
    if ($script:bridgeJob) { Set-VoiceTaskCreateNotice '连接仍在处理，请稍后再新建任务。'; return $true }
    $source=[Guid]::Empty
    if ((-not $script:connected -and $script:bindingAvailability -ne 'archived') -or -not [Guid]::TryParse([string]$script:threadId,[ref]$source)) { Set-VoiceTaskCreateNotice '请先连接一个本机 Codex 任务，再创建新任务。'; return $true }
    $titleText=([string]$Title).Trim()
    if ($titleText.Length -gt 120) { Set-VoiceTaskCreateNotice '任务名称请控制在一百二十个字以内。'; return $true }
    if ($Scope -notin @('projectless','current-project')) { Set-VoiceTaskCreateNotice '无法确认新任务的位置，请重新说一次。';return $true }
    if ($TestMode) { Set-VoiceTaskCreateNotice '测试模式：已识别新建口令，没有创建真实任务。'; return $true }
    if (-not $script:voiceTaskCreateSession) { $script:voiceTaskCreateSession=[Guid]::NewGuid().ToString('N') }
    try {
        if ($previous -and $previous.RequestId) {
            $archive=Join-Path $stateDir 'voice-task-create-history'; [void][IO.Directory]::CreateDirectory($archive)
            $archivePath=Join-Path $archive (([Guid]$previous.RequestId).ToString()+'.json')
            [IO.File]::WriteAllText($archivePath,($previous|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
        }
        $now=[DateTime]::UtcNow
        $script:voiceTaskCreate=@{Version=1;RequestId=[Guid]::NewGuid().ToString();SourceThreadId=$source.ToString();BindingSourceThreadId=[string]$script:threadId;Title=$titleText;Scope=$Scope;
            CreatedUtc=$now.ToString('o');DispatchState='prepared';CreationState='dispatching';Phase='creating';ThreadId='';ClientThreadId='';
            AutoBindAllowed=$true;SendBlocked=$true;ConnectionAbandoned=$false;BindingGeneration=1;VoiceGeneration=$script:voiceGeneration;
            SessionId=$script:voiceTaskCreateSession;NextStatusUtc=$now.AddSeconds(3);PollUntilUtc=$now.AddSeconds(30);
            ReadAttempts=0;NextReadUtc=$now;BindUntilUtc=$now.AddSeconds(30);ProcessId=0;ProcessStartedUtc='';DefinitelyNotDispatched=$false;Message='正在创建新任务…'}
        Save-VoiceTaskCreateRecord
    } catch {
        $script:voiceTaskCreate=$previous
        Set-VoiceTaskCreateNotice '新建记录无法保存，没有发出创建请求。'; return $true
    }
    $request=@{action='create';scope=$Scope;threadId=$script:voiceTaskCreate.SourceThreadId;requestId=$script:voiceTaskCreate.RequestId}
    if ($titleText) { $request.title=$titleText }
    try {
        if (-not (Start-VoiceTaskCreateBridge $request 'voice-create')) { throw 'Bridge busy before dispatch.' }
        Set-VoiceTaskCreateNotice '正在创建新任务，完成前仍保留原连接。'
    } catch {
        # Production Start-Bridge throws on pre-launch setup/Process.Start errors.
        # If it already has this job, conservatively retain the dispatch journal.
        if ($script:bridgeJob -and $script:bridgeJob.Purpose -eq 'voice-create') {
            $script:voiceTaskCreate.CreationState='unknown'; $script:voiceTaskCreate.Phase='unknown'
            Set-VoiceTaskCreateNotice '创建状态待确认，不会重复创建。'
        } else {
            $script:voiceTaskCreate.DefinitelyNotDispatched=$true
            $script:voiceTaskCreate.CreationState='rejected';$script:voiceTaskCreate.Phase='rejected';$script:voiceTaskCreate.SendBlocked=$false
            Set-VoiceTaskCreateNotice '新建请求没有发出，请稍后重试。'
        }
        try { Save-VoiceTaskCreateRecord } catch { }
    }
    return $true
}
function Test-VoiceTaskCreateBindingFresh($Record) {
    $bindingSource=if ($Record.BindingSourceThreadId) { [string]$Record.BindingSourceThreadId } else { [string]$Record.SourceThreadId }
    return [bool]($Record.AutoBindAllowed -and $Record.SessionId -ceq $script:voiceTaskCreateSession -and
        $bindingSource -ceq [string]$script:threadId -and $Record.VoiceGeneration -eq $script:voiceGeneration -and
        -not (Get-VoiceTaskCreateBlockReason) -and -not $script:autoDispatch)
}
function Start-VoiceCreatedTaskRead([DateTime]$Now=[DateTime]::UtcNow) {
    $record=$script:voiceTaskCreate
    if (-not (Test-VoiceTaskCreateBindingFresh $record) -or $script:bridgeJob) { return $false }
    if ([int]$record.ReadAttempts -ge 3 -or $Now -gt [DateTime]$record.BindUntilUtc) {
        Invalidate-VoiceTaskCreateBinding '新任务记录还未就绪，可稍后连接。'
        Set-VoiceTaskCreateNotice '新任务已创建，记录暂未就绪。稍后可说“连接刚才的新任务”。'; return $false
    }
    try {
        if (-not (Start-VoiceTaskCreateBridge @{action='read';threadId=$record.ThreadId} 'voice-create-bind')) { return $false }
        $record.ReadAttempts=[int]$record.ReadAttempts+1; $record.Phase='reading'
        Set-VoiceTaskCreateNotice '新任务已创建，正在确认连接…'
        return $true
    } catch {
        $record.ReadAttempts=[int]$record.ReadAttempts+1; $record.NextReadUtc=$Now.AddSeconds(2); $record.Phase='created'
        return $false
    }
}
function Complete-VoiceTaskCreate {
    param($Result,$Context)
    $record=$script:voiceTaskCreate
    if (-not $record -or -not $Context -or $Context.RequestId -cne $record.RequestId -or $Context.SourceThreadId -cne $record.SourceThreadId) { return $false }
    if ($record.Phase -eq 'bound') { return $false }
    if (-not $Result -or $Result.requestId -cne $record.RequestId -or $Result.sourceThreadId -cne $record.SourceThreadId -or
        $Result.creationState -notin @('ready','pending','unknown','rejected','not_found')) {
        if ($record.CreationState -eq 'ready' -and $record.ThreadId) { return $false }
        $record.CreationState='unknown';$record.Phase='unknown'
        Set-VoiceTaskCreateNotice '创建回执不完整，将查询原请求，不会重复创建。'
    } else {
        $state=[string]$Result.creationState
        $target=[Guid]::Empty
        $valid=($Result.ok -is [bool] -and $Result.ok -eq $true)
        if ($state -in @('ready','pending')) { $valid=$valid -and $Result.accepted -is [bool] -and $Result.accepted }
        if ($state -in @('rejected','not_found')) { $valid=$valid -and $Result.accepted -is [bool] -and -not $Result.accepted }
        if ($state -eq 'unknown') { $valid=$valid -and $null -eq $Result.accepted }
        if ($state -eq 'ready') { $valid=$valid -and [Guid]::TryParse([string]$Result.threadId,[ref]$target) -and $target -ne [Guid]$record.SourceThreadId -and $Result.hostId -eq 'local' }
        if (-not $valid) { $state='unknown' }
        if ($state -eq 'not_found' -and (Test-VoiceTaskCreateWorkerRunning $record)) { $state='unknown' }
        # Once a real created ID has been recorded, a weaker late status cannot
        # erase it or authorize a second create.
        if ($record.CreationState -eq 'ready' -and $record.ThreadId -and $state -ne 'ready') { return $false }
        $record.CreationState=$state
        switch ($state) {
            'ready' {
                if ($record.ThreadId -and [Guid]$record.ThreadId -ne $target) { Set-VoiceTaskCreateNotice '创建回执的任务编号不一致，请在 Codex 核对。'; return $false }
                $record.ThreadId=$target.ToString(); $record.ClientThreadId=''; $record.Phase='created'
                $record.NextReadUtc=[DateTime]::UtcNow; $record.BindUntilUtc=[DateTime]::UtcNow.AddSeconds(30)
                Set-VoiceTaskCreateNotice '新任务已创建，尚未连接。'
            }
            'pending' {$record.ClientThreadId=[string]$Result.clientThreadId;$record.Phase='checking';Set-VoiceTaskCreateNotice 'Codex 正在准备新任务，尚未获得可连接的任务编号。'}
            'unknown' {$record.Phase='unknown';Set-VoiceTaskCreateNotice '创建结果仍待核对，只查询原请求，不会重复创建。'}
            'rejected' {
                $record.Phase=$state;$record.AutoBindAllowed=$false;$record.SendBlocked=$false
                $reason=if($Result.message -is [string]){$Result.message.Trim()}else{''}
                if($reason.Length -gt 240){$reason=$reason.Substring(0,240)+'…'}
                if(-not $reason){$reason='已确认这次没有创建任务，可以重新发出新建口令。'}
                Set-VoiceTaskCreateNotice $reason
            }
            default {$record.Phase=$state;$record.AutoBindAllowed=$false;$record.SendBlocked=$false;Set-VoiceTaskCreateNotice '已确认这次没有创建任务，可以重新发出新建口令。'}
        }
    }
    $record.NextStatusUtc=[DateTime]::UtcNow.AddSeconds(3)
    try { Save-VoiceTaskCreateRecord }
    catch { $record.AutoBindAllowed=$false;Set-VoiceTaskCreateNotice '创建回执未能保存，已保留当前连接；新任务不会重复创建。';return $false }
    if ($record.CreationState -eq 'ready' -and (Test-VoiceTaskCreateBindingFresh $record)) { [void](Start-VoiceCreatedTaskRead) }
    return $true
}
function Complete-VoiceCreatedTaskRead {
    param($Result,$Context)
    $record=$script:voiceTaskCreate
    if (-not $record -or -not $Context -or $Context.RequestId -cne $record.RequestId -or $Context.SourceThreadId -cne $record.SourceThreadId -or
        $Context.SessionId -cne $record.SessionId -or $Context.BindingGeneration -ne $record.BindingGeneration -or $record.Phase -ne 'reading') { return $false }
    if (-not (Test-VoiceTaskCreateBindingFresh $record)) { Invalidate-VoiceTaskCreateBinding; return $false }
    if (-not (Test-TaskBindingResult $Result $record.ThreadId)) {
        $record.Phase='created';$record.NextReadUtc=[DateTime]::UtcNow.AddSeconds(2)
        Set-VoiceTaskCreateNotice '新任务已创建，正在等待本地记录就绪…';return $false
    }
    try {
        Invoke-TaskBindingCommit $Result $record.ThreadId -AfterApply {
            $record.Phase='bound';$record.AutoBindAllowed=$false;$record.SendBlocked=$false
            Save-VoiceTaskCreateRecord
        }
    } catch {
        $record.Phase='created';$record.AutoBindAllowed=$false;$record.SendBlocked=$true
        try {Save-VoiceTaskCreateRecord}catch{}
        Set-VoiceTaskCreateNotice '新任务已创建，但连接未能保存。保留原任务，稍后可连接刚才的新任务。'
        return $false
    }
    Set-VoiceTaskCreateNotice '新任务已创建并连接，可以说新的问题了。' $true
    return $true
}
function Update-VoiceTaskCreate([DateTime]$Now=[DateTime]::UtcNow) {
    $record=$script:voiceTaskCreate
    if (-not $record -or $record.Phase -in @('bound','rejected','not_found','unavailable')) { return }
    if ($record.AutoBindAllowed -and -not (Test-VoiceTaskCreateBindingFresh $record)) { Invalidate-VoiceTaskCreateBinding '语音或当前任务已改变，保留新建结果但不自动连接。' }
    if ($script:closing -or $script:bridgeJob -or $script:recMode -ne 'idle' -or $script:asrJob) { return }
    if ($record.CreationState -eq 'ready') {
        if ($record.AutoBindAllowed -and $Now -ge [DateTime]$record.NextReadUtc) { [void](Start-VoiceCreatedTaskRead $Now) }
        return
    }
    if ($Now -gt [DateTime]$record.PollUntilUtc) {
        if (-not $record.PollExpired) {
            $record.PollExpired=$true
            Set-VoiceTaskCreateNotice '创建结果尚未确认，已停止后台查询。可说“连接刚才的新任务”再次核对；不会重新创建。'
            try {Save-VoiceTaskCreateRecord}catch{}
        }
        return
    }
    if ($Now -lt [DateTime]$record.NextStatusUtc) { return }
    $record.NextStatusUtc=$Now.AddSeconds(3)
    try { [void](Start-VoiceTaskCreateBridge @{action='create-status';threadId=$record.SourceThreadId;requestId=$record.RequestId} 'voice-create-status') } catch { }
}
function Resume-VoiceTaskCreateConnection {
    if (-not (Test-VoiceTaskCreatePending)) { return $false }
    $blocked=Get-VoiceTaskCreateBlockReason 'resumeCreatedTask'
    if ($blocked) { Set-VoiceTaskCreateNotice $blocked; return $true }
    $record=$script:voiceTaskCreate
    if (-not $record.RequestId) { Set-VoiceTaskCreateNotice '创建记录无法读取，请先在 Codex 核对。';return $true }
    if ($script:bridgeJob) { Set-VoiceTaskCreateNotice '创建或连接仍在处理，请稍后再连接。';return $true }
    # SourceThreadId is the immutable ledger key; a separate binding source is
    # captured below by retaining the old key and using a binding-only override.
    $record.BindingSourceThreadId=[string]$script:threadId
    $record.AutoBindAllowed=$true;$record.SendBlocked=$true;$record.ConnectionAbandoned=$false
    $record.BindingGeneration=[int]$record.BindingGeneration+1;$record.VoiceGeneration=$script:voiceGeneration;$record.SessionId=$script:voiceTaskCreateSession
    $record.ReadAttempts=0;$record.NextReadUtc=[DateTime]::UtcNow;$record.BindUntilUtc=[DateTime]::UtcNow.AddSeconds(30)
    $record.NextStatusUtc=[DateTime]::UtcNow;$record.PollUntilUtc=[DateTime]::UtcNow.AddSeconds(30);$record.PollExpired=$false
    try {Save-VoiceTaskCreateRecord}catch{$record.AutoBindAllowed=$false;Set-VoiceTaskCreateNotice '连接意图无法保存，保留当前任务。';return $true}
    Set-VoiceTaskCreateNotice '正在恢复刚才的新任务连接；不会重新创建任务。'
    return $true
}
function Cancel-VoiceTaskCreateConnection {
    if (-not (Test-VoiceTaskCreatePending)) { return $false }
    $blocked=Get-VoiceTaskCreateBlockReason 'cancelCreatedTaskConnection'
    if ($blocked) { Set-VoiceTaskCreateNotice $blocked;return $true }
    Invalidate-VoiceTaskCreateBinding '用户放弃连接新任务。' -ReleaseSendBlock
    if ($script:voiceTaskCreate.LastPersistenceError) { return $true }
    Set-VoiceTaskCreateNotice '已放弃连接新任务；已发出的创建请求仍会保留，不会重复创建。'
    return $true
}
