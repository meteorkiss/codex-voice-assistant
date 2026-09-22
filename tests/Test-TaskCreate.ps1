param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$runRoot=Join-Path $Root ('work\tests\task-create\'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
. (Join-Path $Root 'src\VoiceCommands.ps1')
. (Join-Path $Root 'src\TaskCreate.ps1')
$script:results=New-Object Collections.ArrayList;$script:checks=0;$script:case=0
$sourceId='11111111-1111-4111-8111-111111111111';$targetId='22222222-2222-4222-8222-222222222222';$otherId='33333333-3333-4333-8333-333333333333'
$rollout=Join-Path $runRoot 'target.jsonl';[IO.File]::WriteAllText($rollout,'fixture')
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function Start-Bridge($Request,[string]$Purpose){
    if($script:startFails){throw 'fake Process.Start failure'}
    if($script:bridgeJob){return $false}
    if($Purpose -eq 'voice-create'){
        $saved=Get-Content -LiteralPath $script:voiceTaskCreatePath -Raw -Encoding UTF8|ConvertFrom-Json
        Assert ($saved.RequestId -eq $Request.requestId -and $saved.DispatchState -eq 'prepared') 'Create was dispatched before its durable intent.'
    }
    [void]$script:requests.Add(@{Request=$Request.Clone();Purpose=$Purpose})
    $script:bridgeJob=@{Request=$Request;Purpose=$Purpose;Process=[pscustomobject]@{Id=999999;StartTime=[DateTime]::UtcNow;HasExited=$false}}
    return $true
}
function Queue-AnswerSpeech([string]$Text){[void]$script:spoken.Add($Text)}
function Close-Job($Job,[switch]$Kill){throw 'The lifecycle module must not kill a dispatched creation.'}
function Sync-PendingSend {}
function Save-Settings {
    if($script:failApplySave -and $script:threadId -eq $targetId){throw 'fake settings disk error'}
    [IO.File]::WriteAllText((Join-Path $stateDir 'settings.json'),(@{threadId=$script:threadId}|ConvertTo-Json))
}
function Apply-Thread($Result){
    $script:applies++
    $script:threadId=$Result.threadId;$script:boundDirectory='Target directory';$script:tail=@{Latest='Target answer'}
    $script:latest='Target answer';$script:busy=$false;$script:connected=$true;$script:lastUserVersion=21
    $TaskLabel.Text=$Result.title;$TaskLabel.ToolTip=$Result.title;$AnswerBox.Text=$script:latest;$InputBox.Text=''
    $script:voiceGeneration++;Save-Settings
}
function Reset-Case {
    $script:case++;$script:stateDir=Join-Path $runRoot ('case-'+$script:case)
    [void][IO.Directory]::CreateDirectory($stateDir)
    $script:voiceTaskCreate=$null;$script:voiceTaskCreatePath=Join-Path $stateDir 'voice-task-create.json';$script:voiceTaskCreateSession=[Guid]::NewGuid().ToString('N')
    $script:threadId=$sourceId;$script:connected=$true;$script:busy=$true;$script:voiceGeneration=4
    $script:boundDirectory='Original directory';$script:tail=@{Latest='Original answer'};$script:originalTail=$script:tail
    $script:latest='Original answer';$script:lastUserVersion=2;$script:closing=$false;$script:recMode='idle';$script:handsFreePhase='waiting'
    $script:asrJob=$null;$script:pendingUncertain='';$script:pendingSends=@{};$script:bridgeJob=$null;$script:autoDispatch=$null
    $script:InputBox=[pscustomobject]@{Text=''};$script:AnswerBox=[pscustomobject]@{Text=$script:latest};$script:TaskLabel=[pscustomobject]@{Text='Original title';ToolTip='Original title'};$script:TaskCombo=$null
    $script:requests=New-Object Collections.ArrayList;$script:spoken=New-Object Collections.ArrayList;$script:applies=0
    $script:TestMode=$false;$script:startFails=$false;$script:failApplySave=$false;$script:notice='';$script:localCommandMessage=''
}
function Take-Context {$ctx=$script:bridgeJob.VoiceTaskCreateContext;$script:bridgeJob=$null;return $ctx}
function Receipt([string]$State='ready') {
    $r=@{ok=$true;requestId=$script:voiceTaskCreate.RequestId;sourceThreadId=$sourceId;creationState=$State;accepted=$null;duplicateSuppressed=$false;message='fixture'}
    if($State -in @('ready','pending')){$r.accepted=$true;$r.hostId='local'}
    if($State -in @('rejected','not_found')){$r.accepted=$false}
    if($State -eq 'ready'){$r.threadId=$targetId}
    if($State -eq 'pending'){$r.clientThreadId='temporary-client-id'}
    return [pscustomobject]$r
}
function Read-Result {return [pscustomobject]@{ok=$true;threadId=$targetId;rolloutPath=$rollout;title='Created title';status='idle'}}
function Begin-Create([string]$Scope='projectless') {Assert (Begin-VoiceTaskCreate -Title '新工作' -Scope $Scope) 'Explicit create was not handled.';return (Take-Context)}
function Ready-To-Bind {$ctx=Begin-Create;Assert (Complete-VoiceTaskCreate (Receipt) $ctx) 'Ready receipt was rejected.';return (Take-Context)}
function Assert-Original {
    Assert ($script:threadId -eq $sourceId -and $script:connected -and $script:busy -and [object]::ReferenceEquals($script:tail,$script:originalTail)) 'Original binding changed unexpectedly.'
    Assert ($AnswerBox.Text -eq 'Original answer' -and $script:latest -eq 'Original answer' -and $TaskLabel.Text -eq 'Original title' -and $script:lastUserVersion -eq 2) 'Original answer/metadata changed.'
}
function Case([string]$Name,[scriptblock]$Body){Reset-Case;try{& $Body;[void]$script:results.Add(@{name=$Name;passed=$true})}catch{[void]$script:results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message})}}

Case 'Durable single create, validated read, success persistence and exact scope' {
    $ctx=Begin-Create
    Assert (Test-VoiceTaskCreateBlocksSend) 'Ordinary input could reach the old task while creation is pending.'
    Assert ($script:requests.Count -eq 1 -and $script:requests[0].Request.scope -eq 'projectless' -and -not $script:requests[0].Request.ContainsKey('model') -and -not $script:requests[0].Request.ContainsKey('thinking')) 'Default scope/model contract changed.'
    Assert (Begin-VoiceTaskCreate '重复口令') 'Repeated create was not locally handled.'
    Assert ($script:requests.Count -eq 1) 'Repeated command dispatched a second creation.';Assert-Original
    Assert (Complete-VoiceTaskCreate (Receipt) $ctx) 'Ready receipt failed.'
    Assert ($script:requests.Count -eq 2 -and $script:requests[1].Purpose -eq 'voice-create-bind' -and $script:applies -eq 0) 'Creation skipped live read validation.'
    $read=Take-Context;Assert (Complete-VoiceCreatedTaskRead (Read-Result) $read) 'Validated created task was not connected.'
    Assert ($script:threadId -eq $targetId -and $script:voiceTaskCreate.Phase -eq 'bound' -and -not (Test-VoiceTaskCreateBlocksSend) -and $script:spoken.Count -eq 1) 'Bound state or success feedback is wrong.'
    Assert (-not (Complete-VoiceTaskCreate (Receipt) $ctx) -and $script:voiceTaskCreate.Phase -eq 'bound') 'Duplicate creation receipt reverted a bound operation.'
    Reset-Case;$ctx=Begin-Create 'current-project'
    Assert ($script:requests[0].Request.scope -eq 'current-project' -and $script:voiceTaskCreate.Scope -eq 'current-project') 'Explicit project scope was not retained.'
}
Case 'New recording and draft prevent automatic binding but retain the created ID' {
    $ctx=Begin-Create;$script:recMode='listening';$script:voiceGeneration++;$InputBox.Text='My new words'
    Update-VoiceTaskCreate
    Assert (-not $script:voiceTaskCreate.AutoBindAllowed -and (Test-VoiceTaskCreateBlocksSend)) 'New recording discarded the send block or retained automatic binding.'
    Assert (Complete-VoiceTaskCreate (Receipt) $ctx) 'Late creation receipt was not recorded.'
    Assert ($script:voiceTaskCreate.ThreadId -eq $targetId -and $script:requests.Count -eq 1 -and $InputBox.Text -eq 'My new words') 'Late creation lost its ID, cleared words or started a bind.'
    Assert-Original
    $saved=Get-Content -LiteralPath $script:voiceTaskCreatePath -Raw -Encoding UTF8|ConvertFrom-Json
    Assert ($saved.ThreadId -eq $targetId -and -not $saved.AutoBindAllowed) 'Late created ID was not durably recoverable.'
}
Case 'Explicit abandon never kills create; ready then permits a genuinely new request' {
    Assert (Begin-VoiceTaskCreate 'first') 'First command failed.';$job=$script:bridgeJob;$ctx=$job.VoiceTaskCreateContext;$first=$script:voiceTaskCreate.RequestId
    Assert (Cancel-VoiceTaskCreateConnection) 'Abandon was not handled.'
    Assert ([object]::ReferenceEquals($script:bridgeJob,$job) -and -not (Test-VoiceTaskCreateBlocksSend)) 'Abandon killed creation or retained the ordinary-send block.'
    Assert (Begin-VoiceTaskCreate 'second') 'Blocked new command was not consumed.'
    Assert ($script:requests.Count -eq 1) 'An unterminated abandoned creation was duplicated.'
    $script:bridgeJob=$null;Assert (Complete-VoiceTaskCreate (Receipt) $ctx) 'Abandoned ready result was lost.'
    Assert ($script:applies -eq 0 -and -not $script:voiceTaskCreate.AutoBindAllowed) 'Abandoned creation auto-bound.'
    Assert (Begin-VoiceTaskCreate 'second') 'A later new create was blocked after explicit abandon and completion.'
    Assert ($script:voiceTaskCreate.RequestId -ne $first -and @($script:requests|Where-Object{$_.Purpose -eq 'voice-create'}).Count -eq 2) 'New command reused/replayed the old request.'
    Assert (Test-Path -LiteralPath (Join-Path $stateDir ('voice-task-create-history\'+$first+'.json'))) 'Prior created ID was not retained in history.'
}
Case 'Abandoned unresolved creation releases the current destination but never permits duplicate create' {
    $ctx=Begin-Create
    Assert (Cancel-VoiceTaskCreateConnection) 'Explicit abandon was not handled.'
    $script:bridgeJob=$null
    Assert (Complete-VoiceTaskCreate (Receipt 'unknown') $ctx) 'Late unknown creation receipt was not retained.'
    Assert ($script:voiceTaskCreate.ConnectionAbandoned -and -not $script:voiceTaskCreate.SendBlocked -and (Test-VoiceTaskCreatePending)) 'Abandoned unresolved creation lost its released-send or recoverable-ledger semantics.'
    Assert (Begin-VoiceTaskCreate 'must-not-repeat') 'Duplicate create command was not consumed locally.'
    Assert (@($script:requests|Where-Object{$_.Purpose -eq 'voice-create'}).Count -eq 1) 'Abandoned unresolved creation was dispatched a second time.'
}
Case 'Unknown and client IDs are never read as real tasks and polling is bounded' {
    $ctx=Begin-Create;Assert (Complete-VoiceTaskCreate (Receipt 'pending') $ctx) 'Pending receipt failed.'
    Assert ($script:voiceTaskCreate.ClientThreadId -eq 'temporary-client-id' -and -not $script:voiceTaskCreate.ThreadId -and $script:requests.Count -eq 1) 'Temporary ID was treated as a real task.'
    $script:voiceTaskCreate.NextStatusUtc=[DateTime]::UtcNow.AddSeconds(-1);Update-VoiceTaskCreate
    Assert ($script:bridgeJob.Purpose -eq 'voice-create-status' -and $script:bridgeJob.Request.requestId -eq $ctx.RequestId) 'Pending state did not query only its existing receipt.'
    $status=Take-Context;Assert (Complete-VoiceTaskCreate (Receipt 'unknown') $status) 'Unknown receipt failed.'
    $script:voiceTaskCreate.PollUntilUtc=[DateTime]::UtcNow.AddSeconds(-1);Update-VoiceTaskCreate
    $count=$script:requests.Count;foreach($unused in 1..4){Update-VoiceTaskCreate ([DateTime]::UtcNow.AddMinutes(2))}
    Assert ($script:requests.Count -eq $count -and $script:voiceTaskCreate.PollExpired -and (Test-VoiceTaskCreateBlocksSend)) 'Unknown result polled forever or unlocked the old destination.'
    Assert (Begin-VoiceTaskCreate 'retry') 'Duplicate unknown request was not handled.'
    Assert (@($script:requests|Where-Object{$_.Purpose -eq 'voice-create'}).Count -eq 1) 'Unknown result triggered a second creation.'
}
Case 'Restart only queries saved request; resume can bind from a different current task' {
    $ctx=Begin-Create;Assert (Complete-VoiceTaskCreate (Receipt 'unknown') $ctx) 'Unknown setup failed.'
    $requestId=$script:voiceTaskCreate.RequestId;Initialize-VoiceTaskCreate
    Assert (-not $script:voiceTaskCreate.AutoBindAllowed -and (Test-VoiceTaskCreateBlocksSend)) 'Restart automatically re-enabled binding or sending.'
    Update-VoiceTaskCreate
    Assert ($script:bridgeJob.Purpose -eq 'voice-create-status' -and $script:bridgeJob.Request.requestId -eq $requestId) 'Restart replayed mutation instead of querying.'
    $status=Take-Context;Assert (Complete-VoiceTaskCreate (Receipt) $status) 'Restart did not retain ready ID.'
    Assert ($script:applies -eq 0 -and $null -eq $script:bridgeJob) 'Restart auto-bound a newly discovered task.'
    $script:threadId=$otherId;$script:voiceGeneration++
    Assert (Resume-VoiceTaskCreateConnection) 'Explicit resume failed.';Update-VoiceTaskCreate
    Assert ($script:bridgeJob.Purpose -eq 'voice-create-bind' -and $script:voiceTaskCreate.SourceThreadId -eq $sourceId) 'Resume rewrote the immutable ledger source or re-created.'
    $read=Take-Context;Assert (Complete-VoiceCreatedTaskRead (Read-Result) $read) 'Resume from a different source did not bind.'
    Assert (@($script:requests|Where-Object{$_.Purpose -eq 'voice-create'}).Count -eq 1) 'Resume duplicated creation.'
}
Case 'Read retries reuse the target and stop after three attempts' {
    $read=Ready-To-Bind
    foreach($attempt in 1..3){
        Assert (-not (Complete-VoiceCreatedTaskRead ([pscustomobject]@{ok=$false}) $read)) 'Unreadable target was connected.'
        $script:voiceTaskCreate.NextReadUtc=[DateTime]::UtcNow.AddSeconds(-1);Update-VoiceTaskCreate
        if($script:bridgeJob){$read=Take-Context}
    }
    Assert ($script:voiceTaskCreate.ReadAttempts -eq 3 -and -not $script:voiceTaskCreate.AutoBindAllowed -and $script:voiceTaskCreate.ThreadId -eq $targetId) 'Read retry limit or recoverable target was lost.'
    Assert (@($script:requests|Where-Object{$_.Purpose -eq 'voice-create-bind'}).Count -eq 3 -and @($script:requests|Where-Object{$_.Purpose -eq 'voice-create'}).Count -eq 1) 'Read retry created another task or retried unboundedly.'
    Assert (Begin-VoiceTaskCreate 'repeat') 'Repeated ready command was not handled.'
    Assert (@($script:requests|Where-Object{$_.Purpose -eq 'voice-create'}).Count -eq 1) 'Ready but unbound task permitted duplicate creation.';Assert-Original
}
Case 'Settings failure restores source and keeps created ID available for resume' {
    $read=Ready-To-Bind;$script:failApplySave=$true
    Assert (-not (Complete-VoiceCreatedTaskRead (Read-Result) $read)) 'A failed settings save was reported successful.'
    Assert-Original
    Assert ($script:voiceTaskCreate.ThreadId -eq $targetId -and (Test-VoiceTaskCreateBlocksSend) -and $script:spoken.Count -eq 0) 'Failed binding lost its ID, cleared send protection or spoke success.'
    Initialize-VoiceTaskCreate
    Assert ($script:voiceTaskCreate.ThreadId -eq $targetId -and -not $script:voiceTaskCreate.AutoBindAllowed) 'Restart lost a created task after settings failure.'
}
Case 'Malformed journal and receipts fail closed without accepting source as new task' {
    $ctx=Begin-Create;$bad=Receipt;$bad.threadId=$sourceId
    Assert (Complete-VoiceTaskCreate $bad $ctx) 'Malformed receipt was not captured as uncertain.'
    Assert ($script:voiceTaskCreate.CreationState -eq 'unknown' -and -not $script:voiceTaskCreate.ThreadId -and (Test-VoiceTaskCreateBlocksSend)) 'Source was accepted as its own created target.'
    $saved=Get-Content -LiteralPath $script:voiceTaskCreatePath -Raw -Encoding UTF8|ConvertFrom-Json
    $saved.PSObject.Properties.Remove('SendBlocked')
    [IO.File]::WriteAllText($script:voiceTaskCreatePath,($saved|ConvertTo-Json -Depth 8))
    Initialize-VoiceTaskCreate
    Assert ($script:voiceTaskCreate.Phase -eq 'unavailable' -and (Test-VoiceTaskCreateBlocksSend)) 'Incomplete journal silently unlocked sending.'
    Assert (Begin-VoiceTaskCreate 'repeat') 'Damaged journal command was not consumed.'
    Assert (@($script:requests|Where-Object{$_.Purpose -eq 'voice-create'}).Count -eq 1) 'Damaged journal allowed a new mutation.'
}
Case 'No dispatch occurs in TestMode or when journal/worker startup fails' {
    $script:TestMode=$true;Assert (Begin-VoiceTaskCreate 'fixture') 'Test command failed.'
    Assert ($script:requests.Count -eq 0 -and $null -eq $script:voiceTaskCreate) 'TestMode dispatched create.'
    Reset-Case;$script:voiceTaskCreatePath=Join-Path $stateDir 'directory-not-file';[void][IO.Directory]::CreateDirectory($script:voiceTaskCreatePath)
    Assert (Begin-VoiceTaskCreate 'fixture') 'Persistence failure was not handled.'
    Assert ($script:requests.Count -eq 0 -and $null -eq $script:voiceTaskCreate) 'Failed pre-dispatch journal still created a task.'
    Reset-Case;$script:startFails=$true;Assert (Begin-VoiceTaskCreate 'fixture') 'Start failure was not handled.'
    Assert ($script:voiceTaskCreate.DefinitelyNotDispatched -and -not (Test-VoiceTaskCreateBlocksSend)) 'Known launch failure remained uncertain.'
}
Case 'Current project rejection retains the exact reason without binding or retrying' {
    Assert (Begin-VoiceTaskCreate -Title 'fixture' -Scope 'current-project') 'Current-project command failed.'
    $ctx=Take-Context;$rejected=Receipt 'rejected'
    $rejected.message='当前任务目录没有唯一对应的已保存本机项目，请先在 Codex 中确认项目。'
    Assert (Complete-VoiceTaskCreate $rejected $ctx) 'Validated rejection was not consumed.'
    Assert ($script:voiceTaskCreate.Message -eq $rejected.message -and $script:voiceTaskCreate.Phase -eq 'rejected') 'The actionable project rejection reason was lost.'
    Assert (-not (Test-VoiceTaskCreateBlocksSend) -and $script:applies -eq 0 -and $script:requests.Count -eq 1) 'Rejection changed the binding, kept the send block or retried creation.'
    Update-VoiceTaskCreate
    Assert ($script:requests.Count -eq 1) 'A rejected request was retried by the timer.'
    Assert-Original
}
Case 'Malformed late create receipts never downgrade a recorded ready task' {
    $create=Begin-Create
    Assert (Complete-VoiceTaskCreate (Receipt) $create) 'Ready setup failed.'
    $read=Take-Context
    $wrong=Receipt;$wrong.requestId=[Guid]::NewGuid().ToString()
    foreach($bad in @($null,[pscustomobject]@{ok=$true},$wrong)) {
        Assert (-not (Complete-VoiceTaskCreate $bad $create)) 'Malformed late receipt was accepted.'
        Assert ($script:voiceTaskCreate.CreationState -eq 'ready' -and $script:voiceTaskCreate.ThreadId -eq $targetId -and $script:voiceTaskCreate.Phase -eq 'reading') 'Malformed receipt downgraded ready state or its verified ID.'
    }
    Assert ($script:requests.Count -eq 2) 'A malformed duplicate restarted creation or read.'
    Assert (Complete-VoiceCreatedTaskRead (Read-Result) $read) 'The original read lost its ability to complete after a malformed duplicate.'
}
Case 'Explicit manual change releases sending while recording invalidation and exit never kill mutation' {
    Assert (Begin-VoiceTaskCreate 'fixture') 'Create failed.';$job=$script:bridgeJob;$ctx=$job.VoiceTaskCreateContext
    Invalidate-VoiceTaskCreateBinding 'recording changed'
    Assert ((Test-VoiceTaskCreateBlocksSend) -and [object]::ReferenceEquals($script:bridgeJob,$job)) 'Recording invalidation released sending or killed create.'
    Invalidate-VoiceTaskCreateBinding 'manual task selected' -ReleaseSendBlock
    Assert (-not (Test-VoiceTaskCreateBlocksSend)) 'Explicit manual binding did not release sending.'
    $script:closing=$true;Invalidate-VoiceTaskCreateBinding 'exit';Update-VoiceTaskCreate
    Assert ([object]::ReferenceEquals($script:bridgeJob,$job)) 'Exit killed the owned mutation.'
    $script:bridgeJob=$null;Assert (Complete-VoiceTaskCreate (Receipt) $ctx) 'Late shutdown receipt was not retained.'
    Assert ($script:applies -eq 0 -and $script:spoken.Count -eq 0 -and $script:voiceTaskCreate.ThreadId -eq $targetId) 'Shutdown result applied/spoke or lost created ID.'
}

$summary=@{passed=@($script:results|Where-Object{$_.passed}).Count;failed=@($script:results|Where-Object{-not $_.passed}).Count;checks=$script:checks;cases=@($script:results);boundaries='Production TaskCreate and parser, real GUID-isolated journal IO; fake bridge/process/apply/audio. No real creation, microphone or audio.'}
[IO.File]::WriteAllText((Join-Path (Split-Path -Parent $runRoot) 'result.json'),($summary|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
$summary|ConvertTo-Json -Depth 6
if($summary.failed){exit 1}
