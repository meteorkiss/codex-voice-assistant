param([string]$Root=(Split-Path -Parent $PSScriptRoot))

# Real routing, task-switch module, transcript reader, binding/settings functions,
# and AST-extracted production timer/controller callbacks. All bridge jobs are
# in-memory doubles with generated JSON fixtures; no Codex/audio/device process.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ProductionAst.ps1')
if($PSVersionTable.PSVersion.Major -ne 5 -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){
    throw 'Run with Windows PowerShell 5.1 -STA.'
}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$resultRoot=Join-Path $Root 'work\tests\task-switch-integration'
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
foreach($module in @('reader-core.ps1','VoiceCommands.ps1','LocalCommands.ps1','TaskSwitch.ps1','TaskCreate.ps1')){. (Join-Path $Root ('src\'+$module))}
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
$manualBind=Get-ControllerCallback 'BindTaskButton' 'Add_Click'
$selectionChanged=Get-ControllerCallback 'TaskCombo' 'Add_SelectionChanged'
$inputChanged=Get-ControllerCallback 'InputBox' 'Add_TextChanged'
$directoryChanged=Get-ControllerCallback 'DirectoryCombo' 'Add_SelectionChanged'
$refreshClicked=Get-ControllerCallback 'RefreshTasksButton' 'Add_Click'
$timerUpdate=$assistantAst.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Update-VoiceTaskSwitch'},$true)
if(-not $timerUpdate){throw 'Production timer no longer updates task selection expiry.'}

$script:InputBox=New-Object Windows.Controls.TextBox
$script:AnswerBox=New-Object Windows.Controls.TextBox
$script:TaskLabel=New-Object Windows.Controls.TextBlock
$script:TaskCombo=New-Object Windows.Controls.ComboBox
$script:desktop=@{}
$TaskCombo.Add_SelectionChanged($selectionChanged)
$InputBox.Add_TextChanged($inputChanged)
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
    $script:manualTaskBinding=$null;$script:voiceTaskCreate=$null
    $script:caseNumber++
    $script:voiceTaskSwitch=$null;$script:voiceTaskSwitchGeneration=0
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
    $TaskCombo.Items.Clear();$script:oldChoice=[pscustomobject]@{threadId=$sourceId;title='Original title';cwd='original-directory'}
    [void]$TaskCombo.Items.Add($script:oldChoice);$TaskCombo.SelectedItem=$script:oldChoice
    $script:syncingUi=$false
}
function Case([string]$Name,[scriptblock]$Body){
    Reset-Case
    try{& $Body;[void]$script:results.Add(@{name=$Name;passed=$true})}
    catch{[void]$script:results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message;line=$_.InvocationInfo.ScriptLineNumber;trace=$_.ScriptStackTrace})}
}
function Candidate([string]$Id=$targetId,[string]$Title='Target title'){return [pscustomobject]@{threadId=$Id;title=$Title;cwd='target-directory';requiresValidation=$true}}
function Search-Result([string]$Match='unique',$Candidates=@((Candidate)),[string]$Query='高斯坡建'){
    return @{ok=$true;query=$Query;matchType=$Match;threads=@($Candidates);totalMatches=@($Candidates).Count;matchMethod='fixture'}
}
function Bind-Result([string]$Id=$targetId){return @{ok=$true;threadId=$Id;title='Target title';cwd='target-directory';rolloutPath=$rollout;status='idle'}}
function Complete-Job($Result,$Job=$script:bridgeJob){
    Assert ($null -ne $Job) 'No fake bridge job to complete.'
    [IO.File]::WriteAllText($Job.Output,($Result|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
    $Job.Process.HasExited=$true;$script:bridgeJob=$Job
    & $completeBridge
}
function Start-Search {
    $InputBox.Text='切换到高斯坡建任务';Send-Text
    Assert ($script:bridgeJob.Purpose -eq 'voice-find' -and $script:bridgeJob.Request.query -ceq '高斯坡建') 'Real Send-Text did not route the exact spoken query locally.'
    Assert ($InputBox.Text -eq '' -and $null -eq $script:autoDispatch) 'Consumed switch command was retained.'
}
function Start-Choice {
    Start-Search
    Complete-Job (Search-Result 'ambiguous' @((Candidate),(Candidate $thirdId 'Second target')))
    Assert ((Test-VoiceTaskSelectionPending) -and $TaskCombo.Items.Count -eq 2 -and $TaskCombo.SelectedIndex -eq -1) 'Real completion did not present two candidates.'
}
function Assert-Source {
    Assert ($script:threadId -eq $sourceId -and $script:connected -and $AnswerBox.Text -eq 'Original full answer') 'Original task or answer was changed before validation.'
    Assert ([object]::ReferenceEquals($script:tail,$script:originalTail)) 'Original transcript was replaced early.'
}
function Assert-NoSend {Assert (@($script:requests|Where-Object {$_.Purpose -eq 'send'}).Count -eq 0) 'A task command reached remote send.'}

Case 'Unique command through real completion/read/apply routes the next ordinary message to the new ID' {
    Start-Search;Assert-Source;Assert-NoSend
    Complete-Job (Search-Result)
    Assert ($script:bridgeJob.Purpose -eq 'voice-bind' -and $script:bridgeJob.Request.threadId -eq $targetId) 'Unique search skipped read validation.'
    Assert-Source;Assert-NoSend
    Complete-Job (Bind-Result)
    Assert ($script:threadId -eq $targetId -and $script:connected -and $null -eq $script:voiceTaskSwitch) 'Validated completion failed to commit.'
    Assert ($script:tail.Path -eq $rollout -and $AnswerBox.Text -eq 'Target full answer' -and $script:lastUserVersion -eq 1) 'Actual transcript reader/binding did not load the fixture answer.'
    $saved=Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8|ConvertFrom-Json
    Assert ($saved.threadId -eq $targetId -and $saved.directoryFilter -eq 'keep-this-filter') 'Actual settings save did not persist the target.'
    Assert ($script:queued.Count -eq 1 -and $script:localCommandCount -eq 1) 'Success feedback or command accounting was duplicated.'
    $InputBox.Text='请继续解释这个算法。';Send-Text
    Assert ($script:bridgeJob.Purpose -eq 'send' -and $script:bridgeJob.Request.threadId -eq $targetId -and $script:bridgeJob.Request.text -ceq '请继续解释这个算法。') 'Next message did not use the new task ID.'
    $request=$script:bridgeJob.Request
    Complete-Job @{ok=$true;accepted=$true;threadId=$request.threadId;requestId=$request.requestId}
    Assert ($script:sent -eq 1 -and $InputBox.Text -eq '' -and -not $InputBox.IsReadOnly) 'Actual normal receipt completion regressed.'
}
Case 'Two candidates accept a spoken second selection and validate that target' {
    Start-Choice;Assert-Source;Assert-NoSend
    $script:voiceGeneration++;$InputBox.Text='选择第二个';Send-Text
    Assert ($script:bridgeJob.Purpose -eq 'voice-bind' -and $script:bridgeJob.Request.threadId -eq $thirdId) 'Spoken choice did not select the second ID.'
    Assert ($InputBox.Text -eq '' -and $script:localCommandCount -eq 2) 'Choice was not consumed once.'
    Complete-Job (Bind-Result $thirdId)
    Assert ($script:threadId -eq $thirdId -and $TaskCombo.Items.Count -eq 1 -and $TaskCombo.SelectedIndex -eq -1) 'Choice commit/list restoration is inconsistent.'
    Assert ($script:queued.Count -eq 2) 'Candidate and success feedback were not each queued once.'
    Assert-NoSend
}
Case 'Manual Bind captures candidate ID before Reset restores the original selector' {
    Start-Choice;$TaskCombo.SelectedIndex=1
    & $manualBind
    Assert ($null -eq $script:voiceTaskSwitch -and $TaskCombo.SelectedItem -eq $script:oldChoice) 'Manual bind did not reset the temporary selector.'
    Assert ($script:bridgeJob.Purpose -eq 'bind' -and $script:bridgeJob.Request.threadId -eq $thirdId) 'Manual bind accidentally read the restored original task.'
    Assert-Source
    Complete-Job (Bind-Result $thirdId)
    Assert ($script:threadId -eq $thirdId -and $AnswerBox.Text -eq 'Target full answer') 'Generic manual bind callback did not apply the captured ID.'
    Assert-NoSend
}
Case 'Ordinary send clears pending candidates and keeps its original destination' {
    Start-Choice;$InputBox.Text='我们先继续讨论原来的问题。';Send-Text
    Assert ($null -eq $script:voiceTaskSwitch -and $TaskCombo.SelectedItem -eq $script:oldChoice) 'Ordinary send retained stale candidates.'
    Assert ($script:bridgeJob.Purpose -eq 'send' -and $script:bridgeJob.Request.threadId -eq $sourceId) 'Ordinary message unexpectedly switched tasks.'
    Assert ($script:bridgeJob.Request.text -ceq '我们先继续讨论原来的问题。') 'Ordinary text was lost during reset.'
    Assert-Source
}
Case 'Late cancelled read successes and failures bypass generic bind/error effects' {
    Start-Search;Complete-Job (Search-Result);$oldJob=$script:bridgeJob
    Reset-VoiceTaskSwitch
    Assert ($null -eq $script:bridgeJob -and @($script:closedJobs|Where-Object {$_.Killed}).Count -eq 1) 'Reset did not cancel its own read job.'
    $script:notice='Newer local status';$InputBox.Text='Retained new draft'
    Complete-Job (Bind-Result) $oldJob
    Assert-Source
    Assert ($script:notice -ceq 'Newer local status' -and $InputBox.Text -ceq 'Retained new draft' -and $script:queued.Count -eq 0) 'Late success changed a newer draft or notice.'
    Complete-Job @{ok=$false;error=@{message='stale error'}} $oldJob
    Assert-Source
    Assert ($script:notice -ceq 'Newer local status' -and -not (Test-Path -LiteralPath $settingsPath)) 'Late failure reached generic connection failure or saved settings.'
}
Case 'Active lookup failure is handled locally and stale search cannot restart binding' {
    Start-Search;$oldJob=$script:bridgeJob
    Complete-Job @{ok=$false;error=@{message='fixture failure'}}
    Assert ($null -eq $script:voiceTaskSwitch -and $script:notice -and $script:notice -notlike 'Codex 连接失败*') 'Lookup failure bypassed local error handling.'
    Assert-Source;Assert-NoSend
    $notice=$script:notice
    Complete-Job (Search-Result) $oldJob
    Assert ($null -eq $script:bridgeJob -and $script:requests.Count -eq 1 -and $script:notice -ceq $notice) 'Stale lookup restarted a bind.'
    $script:startFails=$true;$InputBox.Text='帮我切换到高斯泼溅这个任务';Send-Text
    Assert ($InputBox.Text -eq '' -and $null -eq $script:bridgeJob) 'Launch failure fell through or retained a command.'
    Assert-NoSend
}
Case 'Manual refresh, directory change and exit reset candidates before their own work' {
    Start-Choice;& $refreshClicked
    Assert ($null -eq $script:voiceTaskSwitch -and $script:bridgeJob.Purpose -eq 'list' -and $TaskCombo.SelectedItem -eq $script:oldChoice) 'Refresh did not reset temporary choices.'
    Reset-Case;Start-Choice;& $directoryChanged
    Assert ($null -eq $script:voiceTaskSwitch -and $script:selectionUpdates -eq 1 -and -not $script:selectionWasPending) 'Directory selection ran before the candidate reset.'
    Assert (Test-Path -LiteralPath $settingsPath) 'Directory callback stopped saving preferences.'
    Reset-Case;Start-Choice
    $script:window=New-Object psobject
    $script:window|Add-Member ScriptMethod Close {$script:windowClosed=$true}
    Exit-Assistant
    Assert ($script:closing -and $script:windowClosed -and $null -eq $script:voiceTaskSwitch) 'Exit did not reset before closing its window double.'
}
Case 'Bare choice without candidates and ordinary task questions retain normal routing' {
    foreach($text in @('选择第二个任务','选择第二个','取消任务切换','取消切换','为什么要切换到高斯坡建任务？','不要切换到高斯坡建任务')){
        $script:bridgeJob=$null;$InputBox.Text=$text;Send-Text
        Assert ($script:bridgeJob.Purpose -eq 'send' -and $script:bridgeJob.Request.text -ceq $text -and $script:bridgeJob.Request.threadId -eq $sourceId) ('Ordinary route was intercepted: '+$text)
    }
    Assert ($script:localCommandCount -eq 0 -and $null -eq $script:voiceTaskSwitch) 'Non-command text created local switch state.'
}
Case 'Short cancellation wording is consumed only while candidates are pending' {
    Start-Choice;$InputBox.Text='取消切换';Send-Text
    Assert ($null -eq $script:voiceTaskSwitch -and $InputBox.Text -eq '' -and $script:localCommandCount -eq 2) 'Short cancellation was not consumed locally.'
    Assert ($TaskCombo.SelectedItem -eq $script:oldChoice -and $script:bridgeJob -eq $null) 'Cancellation retained a selection or started a bridge job.'
    Assert-Source;Assert-NoSend
}

function Start-Manual {
    $item=Candidate
    [void]$TaskCombo.Items.Add($item);$TaskCombo.SelectedItem=$item
    & $manualBind
    Assert ($script:bridgeJob.Purpose -eq 'bind' -and $script:bridgeJob.TaskBindingContext.TargetThreadId -eq $targetId) 'Manual request lacks validated context.'
}
Case 'Manual binding blocks an existing draft and pending dispatch without clearing either' {
    foreach ($automatic in @($false,$true)) {
        Reset-Case
        $item=Candidate;[void]$TaskCombo.Items.Add($item);$TaskCombo.SelectedItem=$item
        $InputBox.Text='Keep this draft'
        if ($automatic) { $script:autoDispatch=@{Text='Keep this draft'} }
        $intent=$script:autoDispatch
        & $manualBind
        Assert-Source
        Assert ($script:requests.Count -eq 0 -and $InputBox.Text -ceq 'Keep this draft') 'Manual bind discarded a draft or dispatched anyway.'
        Assert ([object]::ReferenceEquals($script:autoDispatch,$intent)) 'Manual bind erased an automatic dispatch intent.'
    }
}
Case 'Text changed then erased still invalidates the original manual read' {
    Start-Manual;$job=$script:bridgeJob
    $InputBox.Text='New text';$InputBox.Text=''
    Assert ($null -eq $script:manualTaskBinding -and $null -eq $script:bridgeJob) 'TextChanged did not cancel the read.'
    Assert (@($script:closedJobs|Where-Object {$_.Killed -and $_.Purpose -eq 'bind'}).Count -eq 1) 'Cancelled read was not released once.'
    $script:notice='Newer status'
    Complete-Job (Bind-Result) $job
    Assert-Source
    Assert ($script:notice -ceq 'Newer status' -and -not (Test-Path -LiteralPath $settingsPath)) 'Late success applied after text was erased.'
    Complete-Job @{ok=$false;error=@{message='Old error'}} $job
    Assert-Source
    Assert ($script:notice -ceq 'Newer status') 'Late failure overwrote the newer notice.'
}
Case 'Changing task selection away and back cannot resurrect a read' {
    Start-Manual;$job=$script:bridgeJob;$target=$TaskCombo.SelectedItem
    $TaskCombo.SelectedItem=$script:oldChoice;$TaskCombo.SelectedItem=$target
    Assert ($null -eq $script:manualTaskBinding) 'Selection change retained the old token.'
    Complete-Job (Bind-Result) $job
    Assert-Source
    Assert (-not (Test-Path -LiteralPath $settingsPath)) 'Selection ABA change committed stale settings.'
}
Case 'New recording generation and pending text reject a manual completion' {
    foreach($change in @('generation','recording','dispatch','source','closing')) {
        Reset-Case;Start-Manual;$job=$script:bridgeJob
        switch($change) {
            'generation' {$script:voiceGeneration++}
            'recording' {$script:recMode='listening'}
            'dispatch' {$script:autoDispatch=@{Text='new question'}}
            'source' {$script:threadId=$thirdId}
            'closing' {$script:closing=$true}
        }
        Complete-Job (Bind-Result) $job
        Assert ($script:threadId -ne $targetId -and $AnswerBox.Text -eq 'Original full answer') ('Late manual bind overwrote '+$change)
        Assert (-not (Test-Path -LiteralPath $settingsPath)) ('Late manual bind saved '+$change)
    }
}
Case 'Manual read failures malformed receipts and wrong targets retain the old connection' {
    foreach($kind in @('false','stringBool','otherId','missingPath','remoteHost','missingContext')) {
        Reset-Case;Start-Manual;$job=$script:bridgeJob;$receipt=Bind-Result
        switch($kind) {
            'false' {$receipt.ok=$false}
            'stringBool' {$receipt.ok='true'}
            'otherId' {$receipt.threadId=$thirdId}
            'missingPath' {$receipt.rolloutPath=Join-Path $runRoot 'missing.jsonl'}
            'remoteHost' {$receipt.hostId='remote'}
            'missingContext' {$job.TaskBindingContext=$null}
        }
        Complete-Job $receipt $job
        Assert-Source
        Assert (-not (Test-Path -LiteralPath $settingsPath)) ('Bad receipt saved settings: '+$kind)
    }
}
Case 'Manual successful commit is consumed once and next send uses its destination' {
    Start-Manual;$job=$script:bridgeJob
    Complete-Job (Bind-Result)
    $generation=$script:voiceGeneration
    Assert ($script:threadId -eq $targetId -and $TaskCombo.SelectedItem.threadId -eq $targetId) 'Manual result did not synchronize binding and selection.'
    Complete-Job (Bind-Result) $job
    Assert ($script:voiceGeneration -eq $generation) 'Duplicate receipt applied twice.'
    $InputBox.Text='Continue the new task';Send-Text
    Assert ($script:bridgeJob.Purpose -eq 'send' -and $script:bridgeJob.Request.threadId -eq $targetId) 'Manual binding sent the next message to the old task.'
}
Case 'Shared commit rolls back when settings cannot be saved' {
    Start-Manual
    $script:settingsPath=Join-Path $runRoot 'missing-parent/settings.json'
    Complete-Job (Bind-Result)
    Assert-Source
    Assert ($script:boundDirectory -eq 'original-directory' -and $TaskLabel.Text -eq 'Original title') 'Save failure retained partial target state.'
    Assert ($null -eq $script:manualTaskBinding -and $InputBox.Text -eq '') 'Failed commit retained a live token or modified input.'
}
Case 'Busy sending or uncertain receipt prevents manual reads and does not kill the sender' {
    foreach($kind in @('send','uncertain','ledger')) {
        Reset-Case
        $item=Candidate;[void]$TaskCombo.Items.Add($item);$TaskCombo.SelectedItem=$item
        switch($kind) {
            'send' {$script:bridgeJob=@{Purpose='send'}}
            'uncertain' {$script:pendingUncertain=$true}
            'ledger' {$script:pendingSends[$sourceId]=@{requestId='existing'}}
        }
        $job=$script:bridgeJob;& $manualBind
        Assert-Source
        Assert ($script:requests.Count -eq 0 -and $script:closedJobs.Count -eq 0 -and [object]::ReferenceEquals($script:bridgeJob,$job)) ('Manual bind bypassed '+$kind)
    }
}
Case 'Refresh directory change timeout and cancellation invalidate manual requests' {
    foreach($kind in @('refresh','directory','timeout','cancel')) {
        Reset-Case;Start-Manual;$job=$script:bridgeJob
        switch($kind) {
            'refresh' {& $refreshClicked}
            'directory' {& $directoryChanged}
            'timeout' {$script:manualTaskBinding.ExpiresAt=[DateTime]::UtcNow.AddSeconds(-1);Update-ManualTaskBinding}
            'cancel' {Reset-ManualTaskBinding}
        }
        Assert ($null -eq $script:manualTaskBinding) ('Manual request survived '+$kind)
        Complete-Job (Bind-Result) $job
        Assert-Source
    }
}
Case 'Startup restore uses the same validation and respects newly typed drafts' {
    Reset-Case;$script:connected=$false;$TaskCombo.SelectedIndex=-1
    Assert (Begin-ManualTaskBinding $sourceId -Startup) 'Startup restore failed to start without a combo selection.'
    Complete-Job (Bind-Result $sourceId)
    Assert ($script:connected -and $script:threadId -eq $sourceId) 'Startup result did not restore the explicit saved task.'
    Reset-Case;$script:connected=$false
    Assert (Begin-ManualTaskBinding $sourceId -Startup) 'Second startup setup failed.'
    $job=$script:bridgeJob;$InputBox.Text='A new startup draft'
    Complete-Job (Bind-Result $sourceId) $job
    Assert (-not $script:connected -and $InputBox.Text -ceq 'A new startup draft') 'Startup overwrote a draft or silently bound after cancellation.'
}

Case 'Voice read is also invalidated when new text is typed then erased' {
    Start-Search;Complete-Job (Search-Result);$job=$script:bridgeJob
    $InputBox.Text='Another question';$InputBox.Text=''
    Assert ($null -eq $script:voiceTaskSwitch) 'Voice read survived a new edit.'
    Complete-Job (Bind-Result) $job
    Assert-Source
    Assert-NoSend
}

$summary=@{passed=@($script:results|Where-Object {$_.passed}).Count;failed=@($script:results|Where-Object {-not $_.passed}).Count;checks=$script:checks;cases=@($script:results);powershell=$PSVersionTable.PSVersion.ToString();boundaries='Real production parser/executor/task-switch/Send-Text/Apply-Thread/settings/transcript reader and AST timer/controller callbacks; generated local fixtures, in-memory bridge/audio/window-close doubles. No network, real Codex send/switch, microphone, playback or running assistant changes.'}
$resultPath=Join-Path $resultRoot 'result.json'
[IO.File]::WriteAllText($resultPath,($summary|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
$summary|ConvertTo-Json -Depth 6
if($summary.failed){exit 1}
