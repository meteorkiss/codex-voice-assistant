$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
. (Join-Path $Root 'src\SecretaryConversation.ps1')

$checks=0
function Assert-Secretary($Condition,[string]$Message){$script:checks++;if(-not $Condition){throw $Message}}
function Save-Settings {}
function Set-NoWakeMode([string]$Mode){$script:noWakeMode=$Mode;$script:noWakePhase=if($Mode -eq 'off'){'off'}else{'starting'}}
function Stop-NoWakeCapture { return $true }
function Stop-NoWakeAsr {}
function Close-Job($Job,[switch]$Kill){$script:closedJobs++}
function Queue-AnswerSpeech([string]$Text){$script:queuedSpeech.Add($Text)}
function Stop-AssistantOutput {}
function Start-Worker { throw 'This unit test must not start a process.' }
function Invoke-TaskBindingCommit($Result,[string]$TargetThreadId,[scriptblock]$AfterApply=$null){
    $script:bindingCommits++
    if($script:bindingCommitFails){throw 'synthetic save failure'}
    $script:threadId=$TargetThreadId;$script:bindingGeneration++
    if($AfterApply){& $AfterApply}
}
function Send-Text([string]$VoiceSource=''){
    $script:sendCalls++
    $requestId=[Guid]::NewGuid().ToString()
    $script:bridgeJob=@{Purpose='send';Request=@{threadId=$script:threadId;text=$script:InputBox.Text;requestId=$requestId}}
}

$script:continuousConversationEnabled=$false
$script:modelEndpoint='https://example.invalid/v1/chat/completions'
$script:modelName='synthetic-model'
$script:modelAuthMode='bearer'
$script:modelCredentialEnv='SHENGBAN_TEST_KEY'
$script:modelDataConsent=$true
$script:conversationTtsConsent=$true
$script:conversationIdleSeconds=90
$script:conversationMaxSeconds=600
$script:conversationMaxTurns=20
$script:noWakeMode='off';$script:noWakePhase='off'
$script:closing=$false;$script:modelJob=$null;$script:closedJobs=0
$script:queuedSpeech=New-Object 'Collections.Generic.List[string]'
$script:InputBox=[pscustomobject]@{Text='保留的工作草稿';IsReadOnly=$false}
$script:ConversationBox=[pscustomobject]@{Text=''}
$script:ConversationStateLabel=[pscustomobject]@{Text=''}
$script:ttsJob=$null;$script:speechQueue=New-Object 'Collections.Generic.Queue[string]';$script:audioPath=''
$script:threadId='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';$script:bindingGeneration=5
$script:bindingCommits=0;$script:bindingCommitFails=$false;$script:sendCalls=0;$script:bridgeJob=$null

Initialize-SecretaryConversation
Assert-Secretary ($script:secretaryPhase -eq 'off' -and $script:secretaryGeneration -eq 0) 'Secretary conversation did not default off.'
Assert-Secretary (Start-SecretaryConversation -Now ([datetime]'2026-09-29T10:00:00Z')) 'Configured conversation did not start.'
Assert-Secretary ($script:secretaryPhase -eq 'listening' -and $script:noWakeMode -eq 'conversation') 'Start did not enter listening capture mode.'

$turn=Begin-SecretaryTurn '请帮我看看' ([datetime]'2026-09-29T10:00:01Z')
Assert-Secretary ($turn -and $script:secretaryPhase -eq 'thinking') 'Transcript did not begin a secretary turn.'
Assert-Secretary ($script:InputBox.Text -ceq '保留的工作草稿') 'Conversation transcript overwrote the Codex work draft.'
Assert-Secretary ($script:ConversationBox.Text.Contains('你：请帮我看看')) 'Transcript was not shown in the independent conversation area.'
Assert-Secretary (@(Get-SecretaryModelHistory $turn.Transcript).Count -eq 0) 'Current transcript was duplicated inside recent model history.'

$generation=$script:secretaryGeneration
$turn|Add-Member NoteProperty Snapshot (New-SecretaryCandidateSnapshot -Candidates @() -Turn $turn -CatalogComplete $true -Now ([datetime]'2026-09-29T10:00:01Z'))
$reply=@{ok=$true;generation=$generation;turnId=$turn.TurnId;proposal=@{chatText='当然可以。';clarification=$null;actionProposal=$null};snapshot=@();candidateCatalogComplete=$true}
Assert-Secretary (Complete-SecretaryModel $reply $turn ([datetime]'2026-09-29T10:00:02Z')) 'Valid chat proposal was not accepted.'
Assert-Secretary ($script:secretaryPhase -eq 'speaking' -and $script:queuedSpeech.Count -eq 1) 'Reply was not displayed and queued for speech.'
$script:speechQueue.Enqueue('marker')
Update-SecretaryConversation ([datetime]'2026-09-29T10:00:03Z')
$script:speechQueue.Clear();$script:secretarySpeechObserved=$true
Update-SecretaryConversation ([datetime]'2026-09-29T10:00:04Z')
Assert-Secretary ($script:secretaryPhase -eq 'listening') 'Natural speech completion did not resume listening.'

$turnNoTts=Begin-SecretaryTurn '只显示' ([datetime]'2026-09-29T10:00:05Z')
$turnNoTts|Add-Member NoteProperty Snapshot (New-SecretaryCandidateSnapshot -Candidates @() -Turn $turnNoTts -CatalogComplete $true -Now ([datetime]'2026-09-29T10:00:05Z'))
$script:conversationTtsConsent=$false;$beforeQueue=$script:queuedSpeech.Count
$noTts=@{ok=$true;generation=$script:secretaryGeneration;turnId=$turnNoTts.TurnId;proposal=@{chatText='屏幕回复';clarification=$null;actionProposal=$null};snapshot=@();candidateCatalogComplete=$true}
Assert-Secretary (Complete-SecretaryModel $noTts $turnNoTts ([datetime]'2026-09-29T10:00:06Z')) 'Display-only reply failed.'
Assert-Secretary ($script:ConversationBox.Text.Contains('模型答复（未执行操作）：屏幕回复') -and $script:queuedSpeech.Count -eq $beforeQueue -and $script:secretaryPhase -eq 'listening') 'TTS=false did not preserve the sourced model display while suppressing online speech.'
$script:conversationTtsConsent=$true

function New-TestSnapshot($ProposalTurn,[datetime]$Now){
    return New-SecretaryCandidateSnapshot -Candidates @([pscustomobject]@{candidateKey='cand_random_token';threadId='11111111-1111-4111-8111-111111111111';title='目标任务'}) -Turn $ProposalTurn -CatalogComplete $true -Now $Now
}
$proposalTurn=Begin-SecretaryTurn '交给目标任务' ([datetime]'2026-09-29T10:00:07Z')
$snapshot=New-TestSnapshot $proposalTurn ([datetime]'2026-09-29T10:00:08Z')
$proposalTurn|Add-Member NoteProperty Snapshot $snapshot
$valid=@{chatText=$null;clarification=$null;actionProposal=@{action='delegate_work';candidateKey='cand_random_token';workText='检查回归'}}
$resolved=Resolve-SecretaryProposal $valid $snapshot ([datetime]'2026-09-29T10:00:09Z')
Assert-Secretary ($resolved.ThreadId -ceq '11111111-1111-4111-8111-111111111111' -and $resolved.WorkText -ceq '检查回归') 'Opaque key did not resolve to the exact immutable work snapshot.'

$currentTurn=$script:secretaryCurrentTurn
$script:secretaryCurrentTurn=[pscustomobject]@{SessionId=$proposalTurn.SessionId;Generation=$proposalTurn.Generation;TurnId='newer-valid-turn'}
Assert-Secretary (-not (Test-SecretarySnapshotCurrent $snapshot ([datetime]'2026-09-29T10:00:09Z'))) 'An intact snapshot from an older turn remained current.'
$script:secretaryCurrentTurn=$currentTurn

foreach($mutation in @('session','generation','turn','expiry','fingerprint')){
    $copy=$snapshot|ConvertTo-Json -Depth 12|ConvertFrom-Json
    switch($mutation){
        'session'{$copy.SessionId=[Guid]::NewGuid().ToString('N')}
        'generation'{$copy.ConversationGeneration++}
        'turn'{$copy.ProposalTurnId='other-turn'}
        'expiry'{$copy.ExpiresAt=([datetime]'2026-09-29T09:59:00Z')}
        'fingerprint'{$copy.Candidates[0].title='篡改名称'}
    }
    Assert-Secretary ($null -eq (Resolve-SecretaryProposal $valid $copy ([datetime]'2026-09-29T10:00:09Z'))) ('Snapshot mutation crossed validation: '+$mutation)
}
foreach($bad in @(
    @{chatText=$null;clarification=$null;actionProposal=@{action='delegate_work';candidateKey='forged';workText='检查回归'}},
    @{chatText=$null;clarification=$null;actionProposal=@{action='switch_task';candidateKey='cand_random_token';workText='unexpected'}},
    @{chatText='你好';clarification=$null;actionProposal=@{action='switch_task';candidateKey='cand_random_token';workText=$null}},
    @{chatText='';clarification=$null;actionProposal=$null},
    @{chatText=$null;clarification='';actionProposal=$null},
    @{chatText=$null;clarification=$null;actionProposal=@{action='stop';candidateKey=$null;workText=$null}}
)){Assert-Secretary ($null -eq (Resolve-SecretaryProposal $bad $snapshot ([datetime]'2026-09-29T10:00:09Z'))) 'Invalid proposal crossed the local validator.'}
$forgedSuccess=@{chatText='已交付给目标任务。';clarification=$null;actionProposal=$null}
$forgedResolved=Resolve-SecretaryProposal $forgedSuccess $snapshot ([datetime]'2026-09-29T10:00:09Z')
$operationBefore=$script:secretaryOperationStatus;$queueBeforeForged=$script:queuedSpeech.Count
Assert-Secretary ($forgedResolved.Kind -eq 'chat' -and (Write-SecretaryModelReply $forgedResolved.Text)) 'Ordinary model prose did not stay in the sourced model channel.'
Assert-Secretary ($script:secretaryOperationStatus -ceq $operationBefore -and $script:ConversationBox.Text.Contains('模型答复（未执行操作）：已交付给目标任务。') -and
    -not $script:ConversationBox.Text.Contains('声伴状态：已交付给目标任务。') -and $script:queuedSpeech.Count -eq $queueBeforeForged+1 -and
    $script:queuedSpeech[$script:queuedSpeech.Count-1].StartsWith('以下是模型答复，不代表已执行任务操作。')) 'Model prose overwrote or spoke as the authoritative local operation status.'
$incomplete=New-SecretaryCandidateSnapshot -Candidates $snapshot.Candidates -Turn $proposalTurn -CatalogComplete $false -Now ([datetime]'2026-09-29T10:00:08Z')
Assert-Secretary ($null -eq (Resolve-SecretaryProposal $valid $incomplete ([datetime]'2026-09-29T10:00:09Z'))) 'Incomplete candidate catalog authorized an action.'
$missingTitle=New-SecretaryCandidateSnapshot -Candidates @([pscustomobject]@{threadId='22222222-2222-4222-8222-222222222222';title='';hostId='local'}) -Turn $proposalTurn -CatalogComplete $true -Now ([datetime]'2026-09-29T10:00:08Z')
Assert-Secretary (-not $missingTitle.CatalogComplete -and @($missingTitle.Candidates).Count -eq 0) 'Missing candidate title was treated as a complete catalog.'
$tooMany=@();for($i=1;$i -le 41;$i++){$tooMany+=,[pscustomobject]@{threadId=[Guid]::NewGuid().ToString();title=('任务 '+$i);hostId='local'}}
$overLimit=New-SecretaryCandidateSnapshot -Candidates $tooMany -Turn $proposalTurn -CatalogComplete $true -Now ([datetime]'2026-09-29T10:00:08Z')
Assert-Secretary (-not $overLimit.CatalogComplete -and @($overLimit.Candidates).Count -eq 40) 'Over-limit candidate catalog was not bounded and marked incomplete.'
$remote=New-SecretaryCandidateSnapshot -Candidates @([pscustomobject]@{threadId='33333333-3333-4333-8333-333333333333';title='远端任务';hostId='remote'}) -Turn $proposalTurn -CatalogComplete $true -Now ([datetime]'2026-09-29T10:00:08Z')
Assert-Secretary (-not $remote.CatalogComplete -and @($remote.Candidates).Count -eq 0) 'A non-local task entered the secretary action catalog.'
$duplicateTitles=New-SecretaryCandidateSnapshot -Candidates @(
    [pscustomobject]@{threadId='44444444-4444-4444-8444-444444444444';title='同名  任务';hostId='local'},
    [pscustomobject]@{threadId='55555555-5555-4555-8555-555555555555';title='同名 任务';hostId='local'}
) -Turn $proposalTurn -CatalogComplete $true -Now ([datetime]'2026-09-29T10:00:08Z')
Assert-Secretary (-not $duplicateTitles.CatalogComplete) 'Duplicate normalized display titles left the action catalog complete.'

$actionResult=@{ok=$true;generation=$script:secretaryGeneration;turnId=$proposalTurn.TurnId;proposal=$valid;snapshot=$snapshot.Candidates;candidateCatalogComplete=$true}
$historyBeforeLocalPrompt=$script:secretaryHistory.Count
Assert-Secretary (Complete-SecretaryModel $actionResult $proposalTurn ([datetime]'2026-09-29T10:00:09Z')) 'Valid action proposal did not create confirmation.'
$pending=$script:secretaryPendingConfirmation
Assert-Secretary ($pending -and $pending.Action -eq 'delegate_work' -and $pending.WorkText -ceq '检查回归') 'Action proposal bypassed or changed the local confirmation snapshot.'
Assert-Secretary ($script:secretaryHistory.Count -eq $historyBeforeLocalPrompt) 'Local confirmation status leaked into model conversation history.'
foreach($field in @('Action','CandidateKey','ThreadId','Title','WorkText','SessionId','ConversationGeneration','ProposalTurnId','SnapshotId','ExpiresAt','OriginalBindingGeneration')){
    $mutated=$pending|ConvertTo-Json -Depth 14|ConvertFrom-Json
    switch($field){
        'Action'{$mutated.Action='switch_task'} 'CandidateKey'{$mutated.CandidateKey='cand_changed'} 'ThreadId'{$mutated.ThreadId='66666666-6666-4666-8666-666666666666'}
        'Title'{$mutated.Title='改名任务'} 'WorkText'{$mutated.WorkText='篡改正文'} 'SessionId'{$mutated.SessionId=[Guid]::NewGuid().ToString('N')}
        'ConversationGeneration'{$mutated.ConversationGeneration++} 'ProposalTurnId'{$mutated.ProposalTurnId='other-proposal'}
        'SnapshotId'{$mutated.SnapshotId=[Guid]::NewGuid().ToString('N')} 'ExpiresAt'{$mutated.ExpiresAt='2026-09-29T09:00:00Z'}
        'OriginalBindingGeneration'{$mutated.OriginalBindingGeneration++}
    }
    Assert-Secretary (-not (Test-SecretaryActionCurrent $mutated ([datetime]'2026-09-29T10:00:09Z'))) ('Mutable confirmation field crossed fingerprint validation: '+$field)
}
$tamperedPending=$pending|ConvertTo-Json -Depth 14|ConvertFrom-Json
$tamperedPending.WorkText='篡改正文'
$script:secretaryPendingConfirmation=$tamperedPending
Assert-Secretary ((Consume-SecretaryConfirmation '是的' ([datetime]'2026-09-29T10:00:10Z')).Disposition -eq 'expired') 'Mutated pending work text was authorized by an unchanged candidate fingerprint.'
$script:secretaryPendingConfirmation=$pending
$confirm=Consume-SecretaryConfirmation '是的' ([datetime]'2026-09-29T10:00:10Z')
Assert-Secretary ($confirm.Disposition -eq 'confirmed' -and $script:secretaryAuthorizedAction.SnapshotId -eq $pending.SnapshotId) 'Natural confirmation did not authorize the exact proposal snapshot once.'
Assert-Secretary ($script:secretaryAuthorizedAction.ConfirmationTurnId -and $script:secretaryAuthorizedAction.ConfirmationTurnId -cne $script:secretaryAuthorizedAction.ProposalTurnId) 'Confirmation did not bind an independent confirmation turn ID.'
$mutatedConfirmed=$script:secretaryAuthorizedAction|ConvertTo-Json -Depth 14|ConvertFrom-Json
$mutatedConfirmed.ConfirmationTurnId=[Guid]::NewGuid().ToString('N')
Assert-Secretary (-not (Test-SecretaryActionCurrent $mutatedConfirmed ([datetime]'2026-09-29T10:00:10Z') -RequireConfirmation)) 'Mutated confirmation turn crossed the complete action fingerprint.'
Assert-Secretary ((Consume-SecretaryConfirmation '是的' ([datetime]'2026-09-29T10:00:11Z')).Disposition -eq 'none') 'A confirmation replay authorized an already-consumed snapshot.'
$script:secretaryPendingConfirmation=$pending
Pause-SecretaryConversation '暂停'
Assert-Secretary ((Consume-SecretaryConfirmation '是的' ([datetime]'2026-09-29T10:00:12Z')).Disposition -eq 'none') 'Paused session authorized a stale confirmation.'

[void](Resume-SecretaryConversation -Now ([datetime]'2026-09-29T10:00:13Z'))
$script:InputBox.Text=''
$switchTurn=Begin-SecretaryTurn '切换任务' ([datetime]'2026-09-29T10:00:14Z')
$switchSnapshot=New-TestSnapshot $switchTurn ([datetime]'2026-09-29T10:00:15Z')
$switchProposal=@{chatText=$null;clarification=$null;actionProposal=@{action='switch_task';candidateKey='cand_random_token';workText=$null}}
$switchAction=Resolve-SecretaryProposal $switchProposal $switchSnapshot ([datetime]'2026-09-29T10:00:16Z')
Assert-Secretary ($switchAction -and (Test-SecretarySnapshotCurrent $switchSnapshot ([datetime]'2026-09-29T10:00:16Z'))) 'Valid switch proposal did not resolve against its fresh snapshot.'
$script:secretaryPendingConfirmation=$switchAction
$switchAction=(Consume-SecretaryConfirmation '是的' ([datetime]'2026-09-29T10:00:16Z')).Action
$live=[pscustomobject]@{ok=$true;threadId=$switchAction.ThreadId;title='目标任务';archived=$false;bindingState='active';hostId='local';rolloutPath='synthetic'}
$beforeText=$script:ConversationBox.Text
Assert-Secretary (Complete-SecretaryLiveAction $live $switchAction ([datetime]'2026-09-29T10:00:17Z')) 'Valid switch did not commit.'
Assert-Secretary ($script:bindingCommits -eq 1 -and $script:ConversationBox.Text.Contains('已切换到《目标任务》')) 'Switch success appeared before or without binding commit.'

$script:bindingCommitFails=$true;$script:threadId='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';$script:bindingGeneration=$switchSnapshot.OriginalBindingGeneration
$beforeText=$script:ConversationBox.Text
Assert-Secretary (-not (Complete-SecretaryLiveAction $live $switchAction ([datetime]'2026-09-29T10:00:18Z'))) 'Synthetic save failure reported switch success.'
Assert-Secretary (-not $script:ConversationBox.Text.Substring($beforeText.Length).Contains('已切换到')) 'Save failure emitted a false switch-success phrase.'
$script:bindingCommitFails=$false
foreach($changed in @(
    [pscustomobject]@{ok=$true;threadId=$switchAction.ThreadId;title='改名';archived=$false;bindingState='active'},
    [pscustomobject]@{ok=$true;threadId=$switchAction.ThreadId;title='目标任务';archived=$true;bindingState='archived'}
)) { Assert-Secretary (-not (Complete-SecretaryLiveAction $changed $switchAction ([datetime]'2026-09-29T10:00:18Z'))) 'Changed or archived candidate committed.' }
$script:bindingGeneration++
Assert-Secretary (-not (Complete-SecretaryLiveAction $live $switchAction ([datetime]'2026-09-29T10:00:18Z'))) 'Binding-generation change did not invalidate the action.'

$script:bindingGeneration=20;$script:threadId='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';$script:InputBox.Text=''
Set-SecretaryPhase 'listening' 'synthetic delegate setup'
$delegateTurn=Begin-SecretaryTurn '委派工作' ([datetime]'2026-09-29T10:00:20Z')
$delegateSnapshot=New-TestSnapshot $delegateTurn ([datetime]'2026-09-29T10:00:21Z')
$delegateAction=Resolve-SecretaryProposal $valid $delegateSnapshot ([datetime]'2026-09-29T10:00:22Z')
$script:secretaryPendingConfirmation=$delegateAction
$delegateAction=(Consume-SecretaryConfirmation '是的' ([datetime]'2026-09-29T10:00:22Z')).Action
$live.title='目标任务';$beforeText=$script:ConversationBox.Text
Assert-Secretary ($delegateAction) 'Delegate proposal did not resolve.'
Assert-Secretary (Test-SecretarySnapshotCurrent $delegateAction.Snapshot ([datetime]'2026-09-29T10:00:23Z')) 'Delegate snapshot was not current.'
Assert-Secretary ([long]$delegateAction.OriginalBindingGeneration -eq [long]$script:bindingGeneration) 'Delegate binding generation fixture drifted.'
Assert-Secretary (Test-SecretaryLiveCandidate $delegateAction $live) 'Delegate live candidate fixture was invalid.'
Assert-Secretary (Complete-SecretaryLiveAction $live $delegateAction ([datetime]'2026-09-29T10:00:23Z')) ('Valid delegate did not reach Send-Text: '+$script:secretaryStatus)
Assert-Secretary ($script:sendCalls -eq 1 -and $script:bridgeJob.Request.text -ceq '检查回归' -and $script:secretaryWork.State -eq 'dispatching') 'Delegate changed work text or bypassed the unique send route.'
Assert-Secretary (-not $script:ConversationBox.Text.Substring($beforeText.Length).Contains('已交付')) 'Delegate claimed success before accepted receipt.'
$oldModelText=$script:ConversationBox.Text;$oldModelQueue=$script:queuedSpeech.Count
$duplicateModel=@{ok=$true;generation=$delegateTurn.Generation;turnId=$delegateTurn.TurnId;proposal=@{chatText='这是迟到的模型文本';clarification=$null;actionProposal=$null}}
Assert-Secretary (-not (Complete-SecretaryModel $duplicateModel $delegateTurn ([datetime]'2026-09-29T10:00:23Z')) -and $script:ConversationBox.Text -ceq $oldModelText -and $script:queuedSpeech.Count -eq $oldModelQueue) 'Dispatching work accepted a late model callback into UI or TTS.'
$job=$script:bridgeJob;$script:bridgeJob=$null
[void](Complete-SecretaryWorkReceipt $job 'accepted')
Assert-Secretary ($script:secretaryWork.State -eq 'accepted' -and $script:ConversationBox.Text.Contains('已交付给《目标任务》')) 'Accepted receipt did not produce local delivery success.'
$acceptedWork=$script:secretaryWork
[void](Stop-SecretaryConversation '会话停止')
Assert-Secretary ($script:secretaryWork.RequestId -ceq $acceptedWork.RequestId -and $script:secretaryPhase -eq 'off') 'Stopping conversation erased accepted work lifecycle.'
[void](Complete-SecretaryWorkReceipt $job 'accepted')
Assert-Secretary ($script:secretaryPhase -eq 'off') 'Late accepted receipt revived listening.'

$script:secretaryWork=@{RequestId='unknown-1';State='dispatching';Title='目标任务';Generation=1}
$unknownJob=@{SecretaryWorkContext=$script:secretaryWork.Clone()}
[void](Complete-SecretaryWorkReceipt $unknownJob 'unknown')
Assert-Secretary ($script:secretaryWork.State -eq 'unknown' -and $script:sendCalls -eq 1) 'Unknown receipt lost its lock or retried the work.'
[void](Stop-SecretaryConversation '仍保持停止')
Assert-Secretary ($script:secretaryWork.State -eq 'unknown') 'Stopping conversation erased unknown receipt protection.'

[void](Start-SecretaryConversation -Now ([datetime]'2026-09-29T11:00:00Z'))
$old=$script:secretaryGeneration
Pause-SecretaryConversation '用户立即暂停'
Assert-Secretary ($script:secretaryPhase -eq 'paused' -and $script:secretaryGeneration -gt $old) 'Pause did not invalidate outstanding callbacks.'
Assert-Secretary (-not (Complete-SecretaryModel $reply $turn ([datetime]'2026-09-29T11:00:01Z'))) 'A late model result revived a paused conversation.'
$lateContext=@{RequestId='late-accepted';ThreadId='11111111-1111-4111-8111-111111111111';Title='目标任务';WorkText='旧工作';State='dispatching';SessionId=$script:secretarySessionId;Generation=$old}
$script:secretaryWork=$lateContext.Clone();$lateJob=@{SecretaryWorkContext=$lateContext.Clone()};$queueBeforeLate=$script:queuedSpeech.Count
[void](Complete-SecretaryWorkReceipt $lateJob 'accepted')
Assert-Secretary ($script:secretaryWork.State -eq 'accepted' -and $script:secretaryPhase -eq 'paused' -and $script:queuedSpeech.Count -eq $queueBeforeLate) 'Late accepted receipt revived or spoke inside a paused conversation.'
$inactiveGeneration=$script:secretaryGeneration
foreach($case in @(
    @{Phase='off';Enabled=$false;Receipt='rejected'},
    @{Phase='error';Enabled=$true;Receipt='unknown'},
    @{Phase='paused';Enabled=$true;Receipt='accepted'}
)){
    $script:secretaryPhase=$case.Phase;$script:continuousConversationEnabled=$case.Enabled;$script:noWakeMode='off'
    $ctx=@{RequestId=([Guid]::NewGuid().ToString('N'));ThreadId='11111111-1111-4111-8111-111111111111';Title='目标任务';WorkText='迟到工作';State='dispatching';SessionId=$script:secretarySessionId;Generation=$inactiveGeneration}
    $script:secretaryWork=$ctx.Clone();$inactiveJob=@{SecretaryWorkContext=$ctx.Clone()};$inactiveQueue=$script:queuedSpeech.Count
    [void](Complete-SecretaryWorkReceipt $inactiveJob $case.Receipt)
    Assert-Secretary ($script:secretaryPhase -ceq $case.Phase -and $script:noWakeMode -eq 'off' -and $script:queuedSpeech.Count -eq $inactiveQueue) ('Inactive receipt changed phase, capture or TTS: '+$case.Phase+'/'+$case.Receipt)
}
$script:secretaryPhase='listening';$script:continuousConversationEnabled=$true;$oldSession=[Guid]::NewGuid().ToString('N')
$newSessionContext=@{RequestId='old-session-unknown';ThreadId='11111111-1111-4111-8111-111111111111';Title='目标任务';WorkText='旧会话工作';State='dispatching';SessionId=$oldSession;Generation=$script:secretaryGeneration}
$script:secretaryWork=$newSessionContext.Clone();$newSessionJob=@{SecretaryWorkContext=$newSessionContext.Clone()};$newSessionQueue=$script:queuedSpeech.Count
[void](Complete-SecretaryWorkReceipt $newSessionJob 'unknown')
Assert-Secretary ($script:secretaryPhase -eq 'listening' -and $script:queuedSpeech.Count -eq $newSessionQueue) 'A prior-session receipt changed the new session phase or TTS.'
[void](Resume-SecretaryConversation -Now ([datetime]'2026-09-29T11:00:02Z'))
$script:secretaryIdleDeadlineUtc=[datetime]'2026-09-29T11:00:03Z'
Update-SecretaryConversation ([datetime]'2026-09-29T11:00:04Z')
Assert-Secretary ($script:secretaryPhase -eq 'off' -and -not $script:continuousConversationEnabled) 'Visible idle expiry did not close the finite session.'

[void](Start-SecretaryConversation -Now ([datetime]'2026-09-29T12:00:00Z'))
$script:conversationMaxSeconds=60
Update-SecretaryConversation ([datetime]'2026-09-29T12:01:00Z')
Assert-Secretary ($script:secretaryPhase -eq 'off' -and $script:secretaryStatus -like '*60 秒上限*') 'Maximum session duration did not close the conversation visibly.'

$script:conversationMaxTurns=1
[void](Start-SecretaryConversation -Now ([datetime]'2026-09-29T13:00:00Z'))
$limitTurn=Begin-SecretaryTurn '唯一一轮' ([datetime]'2026-09-29T13:00:01Z')
Set-SecretaryPhase 'listening' 'synthetic completed turn'
Update-SecretaryConversation ([datetime]'2026-09-29T13:00:02Z')
Assert-Secretary ($limitTurn -and $script:secretaryPhase -eq 'off' -and $script:secretaryStatus -like '*轮数上限*') 'Maximum turn count did not close the conversation visibly.'

$script:conversationMaxTurns=20;$script:conversationMaxSeconds=600
[void](Start-SecretaryConversation -Now ([datetime]'2026-09-29T14:00:00Z'))
Set-SecretaryPhase 'speaking' 'synthetic speech'
Cancel-SecretarySpeech '用户停止秘书朗读'
Assert-Secretary ($script:secretaryPhase -eq 'paused' -and $script:noWakeMode -eq 'off') 'Stopping secretary speech did not pause capture.'

[void](Resume-SecretaryConversation -Now ([datetime]'2026-09-29T14:01:00Z'))
Set-SecretaryPhase 'thinking' 'synthetic model wait'
$closedBefore=$script:closedJobs
$script:modelJob=@{Process=[pscustomobject]@{HasExited=$false};Started=[datetime]'2026-09-29T14:01:00Z';SessionId=$script:secretarySessionId;Generation=$script:secretaryGeneration}
Update-SecretaryConversation ([datetime]'2026-09-29T14:01:25Z')
Assert-Secretary ($null -eq $script:modelJob -and $script:closedJobs -eq $closedBefore+1 -and $script:secretaryPhase -eq 'error') 'Hard model-worker deadline did not terminate the process and fail closed.'

[pscustomobject]@{passed=$true;checks=$checks;boundary='Synthetic state only; no microphone, ASR, HTTP, Codex task, real message send or playback.'}|ConvertTo-Json -Compress
