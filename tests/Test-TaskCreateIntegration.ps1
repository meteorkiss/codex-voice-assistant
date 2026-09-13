param([string]$Root=(Split-Path -Parent $PSScriptRoot))

# Real routing, task-create module, transcript reader, binding/settings functions,
# and AST-extracted production timer/controller callbacks. All bridge jobs are
# in-memory doubles with generated JSON fixtures; no Codex/audio/device process.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ProductionAst.ps1')
if($PSVersionTable.PSVersion.Major -ne 5 -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){
    throw 'Run with Windows PowerShell 5.1 -STA.'
}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$resultRoot=Join-Path $Root 'work\tests\task-create-integration'
$runRoot=Join-Path $resultRoot ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
function Read-Ast([string]$Path){
    $tokens=$null;$parseErrors=$null
    $tree=(Read-TestProductionAst $Path)
    if($parseErrors.Count){throw ($Path+': '+$parseErrors[0].Message)}
    return $tree
}
$assistantAst=Read-Ast (Join-Path $Root 'src\Assistant.ps1')
$controllerAst=Read-Ast (Join-Path $Root 'src\DesktopController.ps1')
foreach($item in @(@{Tree=$assistantAst;Names=@('Send-Text','Apply-Thread','Save-Settings','Sync-PendingSend','Get-SendReceiptState')},@{Tree=$controllerAst;Names=@('Refresh-AssistantTasks','Exit-Assistant')})){
    foreach($name in $item.Names){
        $node=$item.Tree.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        if(-not $node){throw ('Missing production function '+$name)}
        . ([scriptblock]::Create($node.Extent.Text))
    }
}
foreach($module in @('reader-core.ps1','VoiceCommands.ps1','LocalCommands.ps1','TaskSwitch.ps1','TaskCreate.ps1','TaskCreate.ps1')){. (Join-Path $Root ('src\'+$module))}
$completionNode=$assistantAst.Find({param($n)
    $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses.Count -eq 1 -and
    $n.Clauses[0].Item1.Extent.Text -match '^\$script:bridgeJob\s+-and\s+\$script:bridgeJob\.Process\.HasExited$'
},$true)
if(-not $completionNode){throw 'Missing actual bridge completion block.'}
$completeBridge=[scriptblock]::Create($completionNode.Extent.Text)
function Get-ControllerCallback([string]$Variable,[string]$Event){
    $node=$controllerAst.Find({param($n)
        $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Expression -is [Management.Automation.Language.VariableExpressionAst] -and
        $n.Expression.VariablePath.UserPath -eq $Variable -and $n.Member.Value -eq $Event
    },$true)
    if(-not $node){throw ('Missing production callback '+$Variable+'.'+$Event)}
    $source=$node.Arguments[0].ScriptBlock.Extent.Text
    return [scriptblock]::Create($source.Substring(1,$source.Length-2))
}
$selectionChanged=Get-ControllerCallback 'TaskCombo' 'Add_SelectionChanged'
$directoryChanged=Get-ControllerCallback 'DirectoryCombo' 'Add_SelectionChanged'
$refreshClicked=Get-ControllerCallback 'RefreshTasksButton' 'Add_Click'
$timerUpdate=$assistantAst.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Update-VoiceTaskSwitch'},$true)
if(-not $timerUpdate){throw 'Production timer no longer updates task selection expiry.'}
$createTimerUpdate=$assistantAst.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Update-VoiceTaskCreate'},$true)
if(-not $createTimerUpdate){throw 'Production timer no longer updates creation status.'}
$exitJobCleanup=$assistantAst.Find({param($n)
    $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses.Count -eq 1 -and
    $n.Clauses[0].Item1.Extent.Text -match 'bridgeJob\.Purpose\s+-notin' -and
    $n.Extent.Text -match 'Close-Job\s+\$script:bridgeJob\s+-Kill'
},$true)
if(-not $exitJobCleanup){throw 'Missing production finally bridge cleanup guard.'}
$cleanupBridge=[scriptblock]::Create($exitJobCleanup.Extent.Text)
$script:workspace=$Root

$script:InputBox=New-Object Windows.Controls.TextBox
$InputBox.Add_TextChanged({ Update-TaskBindingInput })
$script:AnswerBox=New-Object Windows.Controls.TextBox
$script:TaskLabel=New-Object Windows.Controls.TextBlock
$script:TaskCombo=New-Object Windows.Controls.ComboBox
$script:desktop=@{}
$TaskCombo.Add_SelectionChanged($selectionChanged)
$script:checks=0;$script:caseNumber=0;$script:results=New-Object Collections.ArrayList
$sourceId='11111111-1111-4111-8111-111111111111'
$targetId='22222222-2222-4222-8222-222222222222'
$thirdId='33333333-3333-4333-8333-333333333333'
$rollout=Join-Path $runRoot 'target.jsonl'
$events=@(
    @{type='event_msg';payload=@{type='task_started'}},
    @{type='event_msg';payload=@{type='task_complete';turn_id='fixture-turn';last_agent_message='Target full answer'}}
)
[IO.File]::WriteAllText($rollout,((@($events|ForEach-Object {$_|ConvertTo-Json -Depth 4 -Compress}) -join "`n")+"`n"),(New-Object Text.UTF8Encoding($false)))
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Start-Bridge($Request,[string]$Purpose){
    if($script:bridgeJob){return $false}
    if($script:startFails){throw 'Simulated bridge launch failure.'}
    $output=Join-Path $runRoot ([Guid]::NewGuid().ToString('N')+'.result.json')
    $script:bridgeJob=@{Purpose=$Purpose;Request=$Request.Clone();Output=$output;Files=@($output);Process=[pscustomobject]@{HasExited=$false;ExitCode=0}}
    [void]$script:requests.Add(@{Request=$Request.Clone();Purpose=$Purpose})
    return $true
}
function Close-Job($Job,[switch]$Kill){[void]$script:closedJobs.Add(@{Purpose=$Job.Purpose;Killed=[bool]$Kill})}
function Queue-AnswerSpeech([string]$Text){[void]$script:queued.Add($Text)}
function Stop-Output {$script:stopCount++}
function Suspend-WakeListener {$script:suspendCount++}
function Cancel-Recording {throw 'Fixture must not cancel a recording.'}
function Begin-Transcription {throw 'Fixture must not launch ASR.'}
function Reconcile-PendingSends {}
function Clear-PendingSend([string]$TargetThreadId){$script:pendingSends.Remove($TargetThreadId);$script:clearedReceipts++}
function Set-DesktopSettingsPage($Shell,[int]$Index){$script:shownPage=$Index}
function Show-DesktopSettings($Shell){$script:shown++}
function Update-TaskSelection {$script:selectionUpdates++;$script:selectionWasPending=($null -ne $script:voiceTaskSwitch)}
function Reset-Case {
    $script:caseNumber++
    $script:manualTaskBinding=$null;$script:bindingAvailability='active';$script:bindingReadError='';$script:taskSelectionMessage=''
    $script:voiceTaskSwitch=$null;$script:voiceTaskSwitchGeneration=0
    $script:voiceTaskCreate=$null;$script:stateDir=Join-Path $runRoot ('case-'+$script:caseNumber);[void][IO.Directory]::CreateDirectory($script:stateDir)
    $script:voiceTaskCreatePath=Join-Path $script:stateDir 'voice-task-create.json'
    $script:threadId=$sourceId;$script:voiceGeneration=7;$script:connected=$true;$script:busy=$true
    $script:boundDirectory='original-directory';$script:lastUserVersion=4
    $script:latest='Original full answer';$AnswerBox.Text=$script:latest;$TaskLabel.Text='Original title';$TaskLabel.ToolTip='Original title'
    $script:tail=@{Path='original.jsonl';Latest=$script:latest;UserTurnVersion=4;Offset=8};$script:originalTail=$script:tail
    $InputBox.Text='';$InputBox.IsReadOnly=$false;$script:bridgeJob=$null;$script:asrJob=$null;$script:autoDispatch=$null
    $script:recMode='idle';$script:handsFreePhase='off';$script:handsFreeEnabled=$false;$script:closing=$false
    $script:pendingUncertain='';$script:pendingSends=@{};$script:requests=New-Object Collections.ArrayList
    $script:closedJobs=New-Object Collections.ArrayList;$script:queued=New-Object Collections.ArrayList
    $script:startFails=$false;$script:stopCount=0;$script:suspendCount=0;$script:shown=0;$script:shownPage=-1
    $script:syncingUi=$false;$script:directoryFilter='keep-this-filter';$script:localCommandCount=0;$script:lastLocalCommand=''
    $script:notice='';$script:localCommandMessage='';$script:localCommandNoticeUntil=[DateTime]::MinValue
    $script:TestMode=$false;$script:TestTranscriptPath='';$script:TestAudioPath='';$script:window=$null
    $script:settingsPath=Join-Path $runRoot ('settings-'+$script:caseNumber+'.json')
    $script:voiceId='zh-TW-HsiaoChenNeural';$script:speechRate=0;$script:autoRead=$true;$script:autoSend=$false
    $script:bargeInEnabled=$false;$script:wakePhrase='你好，声伴';$script:waveStyle='rays';$script:waveSize=260
    $script:pinned=$true;$script:captionsVisible=$false;$script:floatingVisible=$true
    $script:selectionUpdates=0;$script:selectionWasPending=$false;$script:sent=0;$script:clearedReceipts=0;$script:windowClosed=$false
    $script:syncingUi=$true
    try {
        $TaskCombo.Items.Clear();$script:oldChoice=[pscustomobject]@{threadId=$sourceId;title='Original title';cwd='original-directory'}
        [void]$TaskCombo.Items.Add($script:oldChoice);$TaskCombo.SelectedItem=$script:oldChoice
    } finally { $script:syncingUi=$false }
    Initialize-VoiceTaskCreate
}
function Case([string]$Name,[scriptblock]$Body){
    Reset-Case
    try{& $Body;[void]$script:results.Add(@{name=$Name;passed=$true})}
    catch{[void]$script:results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message;line=$_.InvocationInfo.ScriptLineNumber;trace=$_.ScriptStackTrace})}
}
function Count-Request([string]$Action){return @($script:requests|Where-Object {$_.Request.action -eq $Action}).Count}
function Read-Result([string]$Id=$targetId){return @{ok=$true;threadId=$Id;title='Created fixture task';cwd='target-directory';rolloutPath=$rollout;status='idle'}}
function Create-Result([string]$State='ready',$Job=$script:bridgeJob){
    $result=@{ok=$true;creationState=$State;sourceThreadId=$sourceId;requestId=$Job.Request.requestId;accepted=$true;duplicateSuppressed=$false;hostId='local'}
    switch($State){
        'ready' {$result.threadId=$targetId}
        'pending' {$result.clientThreadId='fixture-client-opaque';$result.resolution='manual_check_required'}
        'unknown' {$result.accepted=$null}
        'rejected' {$result.accepted=$false}
    }
    return $result
}
function Complete-Job($Result,$Job=$script:bridgeJob){
    Assert ($null -ne $Job) 'No fake bridge job to complete.'
    [IO.File]::WriteAllText($Job.Output,($Result|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
    $Job.Process.HasExited=$true;$script:bridgeJob=$Job
    & $completeBridge
}
function Start-Create([string]$Text='新建一个叫天气的任务',[string]$Scope='projectless'){
    $InputBox.Text=$Text;Send-Text
    Assert ($script:bridgeJob.Purpose -eq 'voice-create' -and $script:bridgeJob.Request.action -eq 'create') 'Actual parser/executor/Send-Text did not start one creation job.'
    Assert ($script:bridgeJob.Request.scope -eq $Scope -and $script:bridgeJob.Request.threadId -eq $sourceId) 'Create request used the wrong scope or source.'
    Assert ($InputBox.Text -eq '' -and $null -eq $script:autoDispatch -and (Test-VoiceTaskCreateBlocksSend)) 'Create command cleanup or send blocking is missing.'
    Assert (Test-Path -LiteralPath $script:voiceTaskCreatePath) 'Create state was not persisted before waiting for its result.'
}
function Assert-Source {
    Assert ($script:threadId -eq $sourceId -and $script:connected -and $AnswerBox.Text -eq 'Original full answer') 'Original task or answer was changed before validation.'
    Assert ([object]::ReferenceEquals($script:tail,$script:originalTail)) 'Original transcript was replaced early.'
}
function Assert-NoSend {Assert ((Count-Request 'send') -eq 0) 'A task operation or protected draft reached normal send.'}
function Assert-DurableTarget {
    $record=Get-Content -LiteralPath $script:voiceTaskCreatePath -Raw -Encoding UTF8|ConvertFrom-Json
    Assert (($record|ConvertTo-Json -Depth 12) -like ('*'+$targetId+'*')) 'The late successful receipt did not retain its real target ID.'
}

Case 'Programmatic selector population during creation does not trigger auto-connect or invalidate its receipt' {
    Start-Create;$mutation=$script:bridgeJob
    $script:syncingUi=$true
    try {
        $item=[pscustomobject]@{threadId=$targetId;title='Created fixture task';cwd='target-directory'}
        [void]$TaskCombo.Items.Add($item);$TaskCombo.SelectedItem=$item
    } finally { $script:syncingUi=$false }
    Sync-TaskBindingSelection
    Assert ([object]::ReferenceEquals($script:bridgeJob,$mutation) -and $script:voiceTaskCreate.AutoBindAllowed -and (Count-Request 'read') -eq 0 -and $null -eq $script:manualTaskBinding) 'Programmatic selector synchronization started a manual read or invalidated creation.'
    Assert ($TaskCombo.SelectedItem -eq $script:oldChoice) 'Programmatic synchronization did not retain the actual binding.'
    Assert-Source;Assert-NoSend
    Complete-Job (Create-Result)
    Complete-Job (Read-Result)
    Assert ($script:threadId -eq $targetId -and $TaskCombo.SelectedItem.threadId -eq $targetId -and (Count-Request 'create') -eq 1 -and (Count-Request 'read') -eq 1 -and $null -eq $script:manualTaskBinding) 'Validated creation triggered an extra selection auto-connect or lost its target.'
    Assert-NoSend
}

Case 'Creation receipt is read-validated before binding and the next message uses the new ID' {
    Start-Create;Assert-Source;Assert-NoSend
    Assert ($script:bridgeJob.Request.title -ceq '天气' -and (Count-Request 'create') -eq 1) 'Explicit title was not preserved.'
    Complete-Job (Create-Result)
    Assert ($script:bridgeJob.Purpose -eq 'voice-create-bind' -and $script:bridgeJob.Request.action -eq 'read' -and $script:bridgeJob.Request.threadId -eq $targetId) 'Ready receipt skipped validation or used a client/source ID.'
    Assert-Source;Assert-NoSend
    Complete-Job (Read-Result)
    Assert ($script:threadId -eq $targetId -and -not (Test-VoiceTaskCreateBlocksSend)) 'Validated new target was not bound or remained send-blocked.'
    Assert ($script:tail.Path -eq $rollout -and $AnswerBox.Text -eq 'Target full answer') 'Real Apply-Thread/transcript loading did not run.'
    $saved=Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8|ConvertFrom-Json
    Assert ($saved.threadId -eq $targetId) 'New binding was not saved through production settings.'
    $InputBox.Text='请帮我看看今天的天气。';Send-Text
    Assert ($script:bridgeJob.Purpose -eq 'send' -and $script:bridgeJob.Request.threadId -eq $targetId -and $script:bridgeJob.Request.text -ceq '请帮我看看今天的天气。') 'First real question would be sent to the old destination.'
    Assert ((Count-Request 'create') -eq 1 -and (Count-Request 'send') -eq 1) 'Creation or next send was duplicated.'
}
Case 'Repeated create command stays at one mutation while dispatching and pending' {
    Start-Create '新建任务';$mutation=$script:bridgeJob
    $InputBox.Text='帮我新建一个任务';Send-Text
    Assert ((Count-Request 'create') -eq 1 -and [object]::ReferenceEquals($mutation,$script:bridgeJob)) 'Second create replaced or repeated an in-flight mutation.'
    Assert ($InputBox.Text -eq '') 'Duplicate instruction was left as a future message.'
    Complete-Job (Create-Result 'pending' $mutation)
    Assert (Test-VoiceTaskCreatePending) 'Pending client result was discarded.'
    $InputBox.Text='新建任务';Send-Text
    Assert ((Count-Request 'create') -eq 1 -and $InputBox.Text -eq '') 'Pending result allowed another create.'
    Assert (@($script:requests|Where-Object {$_.Request.action -eq 'read' -and $_.Request.threadId -eq 'fixture-client-opaque'}).Count -eq 0) 'Opaque client ID was used as a real thread ID.'
    Assert-Source;Assert-NoSend
}
Case 'Early ordinary question stays local; late receipt is saved without clearing the draft or binding' {
    Start-Create;$mutation=$script:bridgeJob
    $InputBox.Text='先保留这个真正的问题';Send-Text
    Assert ($InputBox.Text -ceq '先保留这个真正的问题' -and -not $InputBox.IsReadOnly) 'Send guard discarded or locked the draft.'
    Assert-NoSend
    Complete-Job (Create-Result 'ready' $mutation)
    Assert-Source;Assert-DurableTarget
    Assert ($InputBox.Text -ceq '先保留这个真正的问题' -and (Count-Request 'read') -eq 0 -and (Test-VoiceTaskCreateBlocksSend)) 'Late create response overwrote intent or auto-bound.'
    $InputBox.Text='连接刚才的新任务';Send-Text
    Update-VoiceTaskCreate
    Assert ($script:bridgeJob.Purpose -eq 'voice-create-bind' -and $script:bridgeJob.Request.threadId -eq $targetId -and (Count-Request 'create') -eq 1) 'Explicit resume recreated instead of reading the saved target.'
    Complete-Job (Read-Result)
    Assert ($script:threadId -eq $targetId -and -not (Test-VoiceTaskCreateBlocksSend)) 'Explicit resume did not finish binding.'
    Assert-NoSend
}
Case 'Read arriving after a new draft preserves old binding and remains recoverable without another create' {
    Start-Create;Complete-Job (Create-Result);$read=$script:bridgeJob
    $script:voiceGeneration++;$InputBox.Text='识别刚返回的新问题'
    Complete-Job (Read-Result) $read
    Assert-Source;Assert-DurableTarget
    Assert ($InputBox.Text -ceq '识别刚返回的新问题' -and (Test-VoiceTaskCreateBlocksSend)) 'Late validation discarded a new draft or opened the old send route.'
    $InputBox.Text='连接刚才的新任务';Send-Text
    Update-VoiceTaskCreate
    Assert ($script:bridgeJob.Purpose -eq 'voice-create-bind' -and (Count-Request 'create') -eq 1) 'Recovering a stale validation repeated creation.'
    Complete-Job (Read-Result)
    Assert ($script:threadId -eq $targetId) 'Recovered read did not commit.'
    Assert-NoSend
}
Case 'Pending status callback resolves only to a validated real ID without another mutation' {
    Start-Create;$id=$script:bridgeJob.Request.requestId
    Complete-Job (Create-Result 'pending')
    Update-VoiceTaskCreate -Now ([DateTime]::UtcNow.AddSeconds(4))
    Assert ($script:bridgeJob.Purpose -eq 'voice-create-status' -and $script:bridgeJob.Request.action -eq 'create-status' -and $script:bridgeJob.Request.requestId -eq $id) 'Pending polling did not inspect the same creation receipt.'
    Complete-Job (Create-Result)
    Assert ((Count-Request 'create') -eq 1 -and $script:bridgeJob.Purpose -eq 'voice-create-bind' -and $script:bridgeJob.Request.threadId -eq $targetId) 'Status completion did not use the real read route.'
    Complete-Job (Read-Result)
    Assert ($script:threadId -eq $targetId) 'Resolved status did not finish binding.'
    Assert-NoSend
}
Case 'Explicit abandon releases old-task send block while late creation stays recorded without binding' {
    Start-Create;$mutation=$script:bridgeJob
    $InputBox.Text='放弃连接新任务';Send-Text
    Assert (-not (Test-VoiceTaskCreateBlocksSend) -and (Count-Request 'create') -eq 1) 'Abandon did not release send blocking or created another task.'
    Assert (@($script:closedJobs|Where-Object {$_.Killed -and $_.Purpose -eq 'voice-create'}).Count -eq 0) 'Abandon killed a dispatched mutation.'
    Complete-Job (Create-Result 'ready' $mutation)
    Assert-Source;Assert-DurableTarget
    Assert ($script:bridgeJob -eq $null -and (Count-Request 'read') -eq 0) 'Late abandoned receipt auto-bound.'
    $InputBox.Text='继续原来的问题。';Send-Text
    Assert ($script:bridgeJob.Purpose -eq 'send' -and $script:bridgeJob.Request.threadId -eq $sourceId) 'Explicit abandon did not retain original destination.'
}
Case 'Production exit invalidates auto-bind but finally never kills an active create mutation' {
    Start-Create;$mutation=$script:bridgeJob
    $script:window=New-Object psobject
    $script:window|Add-Member ScriptMethod Close {$script:windowClosed=$true}
    Exit-Assistant
    & $cleanupBridge
    Assert ($script:closing -and $script:windowClosed -and [object]::ReferenceEquals($mutation,$script:bridgeJob)) 'Exit lost the active mutation job.'
    Assert (@($script:closedJobs|Where-Object {$_.Killed -and $_.Purpose -eq 'voice-create'}).Count -eq 0) 'Actual finally cleanup killed an uncertain create.'
    Assert (Test-Path -LiteralPath $script:voiceTaskCreatePath) 'Exit erased the recoverable creation record.'
    Assert-NoSend
}
Case 'Current-project chat forwards explicit scope using the bound task as source' {
    Start-Create '在当前项目里新建一个聊天' 'current-project'
    Assert ($script:voiceTaskCreate.Scope -eq 'current-project' -and $script:voiceTaskCreate.SourceThreadId -eq $sourceId) 'Journal lost explicit project scope or bound source.'
    Assert (-not $script:bridgeJob.Request.ContainsKey('title') -and -not $script:bridgeJob.Request.ContainsKey('projectId')) 'Untitled current-project request invented a title or project identity.'
    Assert-Source;Assert-NoSend
    Complete-Job (Create-Result)
    Complete-Job (Read-Result)
    Assert ($script:threadId -eq $targetId -and (Count-Request 'create') -eq 1) 'Current-project creation did not share the validated binding route.'
    Reset-Case;Start-Create '新建一个聊天内容'
    Assert ($script:voiceTaskCreate.Scope -eq 'projectless') 'Generic chat incorrectly inherited the current project.'
}

Case 'New edit then erase retains the created ID but prevents stale automatic binding' {
    Start-Create
    Complete-Job (Create-Result)
    $job=$script:bridgeJob
    Assert ($job.Purpose -eq 'voice-create-bind') 'Created task did not enter read verification.'
    $InputBox.Text='New words';$InputBox.Text=''
    Complete-Job (Read-Result) $job
    Assert-Source;Assert-DurableTarget
    Assert (-not $script:voiceTaskCreate.AutoBindAllowed -and (Test-VoiceTaskCreateBlocksSend)) 'Editing lost the unbound-task protection.'
    Assert-NoSend
}

$summary=@{passed=@($script:results|Where-Object {$_.passed}).Count;failed=@($script:results|Where-Object {-not $_.passed}).Count;checks=$script:checks;cases=@($script:results);powershell=$PSVersionTable.PSVersion.ToString();boundaries='Real parser, LocalCommands, TaskCreate, TaskSwitch, Send-Text, Apply-Thread/settings/transcript and AST bridge/controller/finally branches. Synthetic JSON receipts and in-memory bridge/audio/window doubles only; no network, real create/send/switch, microphone or playback.'}
$resultPath=Join-Path $resultRoot 'result.json'
[IO.File]::WriteAllText($resultPath,($summary|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
$summary|ConvertTo-Json -Depth 6
if($summary.failed){exit 1}
