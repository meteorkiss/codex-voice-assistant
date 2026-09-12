param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ProductionAst.ps1')
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run with Windows PowerShell 5.1 -STA.' }
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$runRoot=Join-Path $Root ('work\tests\task-switch\'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
$tokens=$null;$errors=$null
$ast=(Read-TestProductionAst (Join-Path $Root 'src\Assistant.ps1'))
if($errors.Count){throw $errors[0].Message}
foreach($name in @('Apply-Thread','Save-Settings')) {
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if(-not $node){throw ('Missing production function '+$name)}
    $source=$node.Extent.Text
    if($name -eq 'Save-Settings'){$source=$source.Replace('function Save-Settings','function Save-SettingsActual')}
    . ([scriptblock]::Create($source))
}
. (Join-Path $Root 'src\TaskSwitch.ps1')
. (Join-Path $Root 'src\TaskCreate.ps1')
. (Join-Path $Root 'src\VoiceCommands.ps1')
. (Join-Path $Root 'src\LocalCommands.ps1')
$script:InputBox=New-Object Windows.Controls.TextBox
$script:AnswerBox=New-Object Windows.Controls.TextBox
$script:TaskLabel=New-Object Windows.Controls.TextBlock
$script:TaskCombo=New-Object Windows.Controls.ComboBox
$script:desktop=@{}
$script:results=New-Object Collections.ArrayList
$script:checks=0;$script:case=0
$sourceId='11111111-1111-4111-8111-111111111111'
$targetId='22222222-2222-4222-8222-222222222222'
$thirdId='33333333-3333-4333-8333-333333333333'
$rollout=Join-Path $runRoot 'target.jsonl'
[IO.File]::WriteAllText($rollout,'fixture',(New-Object Text.UTF8Encoding($false)))
function Assert([bool]$Test,[string]$Message){if(-not $Test){throw $Message};$script:checks++}
function Start-Bridge($Request,[string]$Purpose){
    if($script:startFails){throw 'fake launch failure'}
    if($script:bridgeJob){return $false}
    [void]$script:requests.Add(@{Request=$Request.Clone();Purpose=$Purpose})
    $script:bridgeJob=@{Purpose=$Purpose;Request=$Request.Clone();Files=@();Process=$null}
    return $true
}
function Close-Job($Job,[switch]$Kill){if($Kill){[void]$script:killed.Add($Job.Purpose)}}
function Queue-AnswerSpeech([string]$Text){[void]$script:queued.Add($Text)}
function Stop-Output {$script:stopCount++}
function Suspend-WakeListener {$script:suspendCount++}
function Cancel-Recording {throw 'Task binding must not cancel an active recording.'}
function Reconcile-PendingSends {}
function Sync-PendingSend {$script:pendingUncertain=if($script:pendingSends.ContainsKey($script:threadId)){'uncertain'}else{''}}
function Show-DesktopSettings($Shell){$script:shown++}
function Set-DesktopSettingsPage($Shell,[int]$Index){$script:shownPage=$Index}
function New-TranscriptTail([string]$Path){return [pscustomobject]@{Path=$Path;Latest='Target full answer';UserTurnVersion=22;Offset=40}}
function Save-Settings {
    $script:saveCount++
    if($script:failNewSave -and $script:threadId -ne $sourceId){throw 'simulated storage failure'}
    Save-SettingsActual
}
function Reset-Case {
    $script:case++
    $script:voiceTaskSwitch=$null;$script:voiceTaskSwitchGeneration=0
    $script:threadId=$sourceId;$script:voiceGeneration=7;$script:connected=$true;$script:busy=$true
    $script:boundDirectory='original-directory';$script:lastUserVersion=4
    $script:latest='Original full answer';$AnswerBox.Text=$script:latest;$TaskLabel.Text='Original title';$TaskLabel.ToolTip='Original title'
    $script:tail=[pscustomobject]@{Path='original.jsonl';Latest=$script:latest;UserTurnVersion=4;Offset=8};$script:originalTail=$script:tail
    $script:InputBox.Text='';$InputBox.IsReadOnly=$false;$script:bridgeJob=$null;$script:asrJob=$null;$script:autoDispatch=$null
    $script:recMode='idle';$script:handsFreePhase='off';$script:handsFreeEnabled=$false;$script:closing=$false
    $script:pendingUncertain='';$script:pendingSends=@{};$script:requests=New-Object Collections.ArrayList
    $script:killed=New-Object Collections.ArrayList;$script:queued=New-Object Collections.ArrayList
    $script:startFails=$false;$script:failNewSave=$false;$script:saveCount=0;$script:stopCount=0;$script:suspendCount=0;$script:shown=0;$script:shownPage=-1
    $script:syncingUi=$false;$script:directoryFilter='keep-this-filter';$script:localCommandCount=0;$script:lastLocalCommand=''
    $script:notice='';$script:localCommandMessage='';$script:localCommandNoticeUntil=[DateTime]::MinValue
    $script:TestTranscriptPath='';$script:window=$null;$script:settingsPath=Join-Path $runRoot ('settings-'+$script:case+'.json')
    $script:voiceId='zh-TW-HsiaoChenNeural';$script:speechRate=0;$script:autoRead=$true;$script:autoSend=$false
    $script:bargeInEnabled=$false;$script:wakePhrase='你好，声伴';$script:waveStyle='rays';$script:waveSize=260
    $script:pinned=$true;$script:captionsVisible=$false;$script:floatingVisible=$true
    $TaskCombo.Items.Clear();$script:oldChoice=[pscustomobject]@{threadId=$sourceId;title='Original title';cwd='original-directory'}
    [void]$TaskCombo.Items.Add($script:oldChoice);$TaskCombo.SelectedItem=$script:oldChoice
}
function Take-Context {$ctx=$script:bridgeJob.VoiceTaskSwitchContext;$script:bridgeJob=$null;return $ctx}
function Candidate([string]$Id=$targetId,[string]$Title='Target title'){return [pscustomobject]@{threadId=$Id;title=$Title;cwd='target-directory';requiresValidation=$true}}
function Search-Result([string]$Match='unique',$Threads=@((Candidate)),[string]$Query='target'){
    return [pscustomobject]@{ok=$true;query=$Query;matchType=$Match;threads=@($Threads);totalMatches=@($Threads).Count;matchMethod='exact'}
}
function Bind-Result([string]$Id=$targetId){return [pscustomobject]@{ok=$true;threadId=$Id;title='Target title';cwd='target-directory';rolloutPath=$rollout;status='idle'}}
function Begin-Search {Assert (Begin-VoiceTaskSwitch 'target') 'An explicit switch command was not handled.';return (Take-Context)}
function Begin-Bind {$ctx=Begin-Search;Assert (Complete-VoiceTaskSearch (Search-Result) $ctx) 'Unique search was rejected.';return (Take-Context)}
function Begin-Choice {
    $ctx=Begin-Search
    Assert (Complete-VoiceTaskSearch (Search-Result 'ambiguous' @((Candidate),(Candidate $thirdId ('长标题'*20)))) $ctx) 'Ambiguous search was rejected.'
}
function Assert-Original {
    Assert ($script:threadId -ceq $sourceId -and $script:connected -and $script:busy) 'Original binding changed before validated commit.'
    Assert ([object]::ReferenceEquals($script:tail,$script:originalTail) -and $script:latest -ceq 'Original full answer' -and $AnswerBox.Text -ceq $script:latest) 'Original answer or transcript was replaced.'
    Assert ($script:boundDirectory -ceq 'original-directory' -and $script:lastUserVersion -eq 4 -and $TaskLabel.Text -ceq 'Original title') 'Original binding metadata changed.'
    Assert (@($script:requests | Where-Object {$_.Purpose -in @('send','open')}).Count -eq 0) 'Switching sent text or opened Codex.'
}
function Case([string]$Name,[scriptblock]$Body){Reset-Case;try{& $Body;[void]$script:results.Add(@{name=$Name;passed=$true})}catch{[void]$script:results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message})}}

Case 'Unique search validates read before real Apply-Thread and isolated settings save' {
    $InputBox.Text='切换到target任务';$ctx=Begin-Search;$InputBox.Text=''
    Assert-Original
    Assert ($script:requests[0].Purpose -eq 'voice-find' -and $script:requests[0].Request.query -eq 'target') 'Find protocol changed.'
    Assert (Complete-VoiceTaskSearch (Search-Result) $ctx) 'Unique result was rejected.'
    Assert-Original
    Assert ($script:requests[1].Purpose -eq 'voice-bind' -and $script:requests[1].Request.threadId -eq $targetId) 'Read validation was skipped.'
    $bind=Take-Context
    Assert (Complete-VoiceTaskBind (Bind-Result) $bind) 'Validated target did not bind.'
    Assert ($script:threadId -eq $targetId -and $AnswerBox.Text -eq 'Target full answer' -and -not $script:busy) 'Production Apply-Thread did not update target state.'
    Assert ($TaskCombo.SelectedIndex -eq -1) 'A target absent from the restored list left the old task selected.'
    $saved=Get-Content -LiteralPath $script:settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($saved.threadId -eq $targetId -and $saved.directoryFilter -eq 'keep-this-filter') 'Saved task or unchanged directory filter is wrong.'
    Assert ($script:queued.Count -eq 1 -and $script:localCommandCount -eq 0 -and $null -eq $script:voiceTaskSwitch) 'Success was not announced once or duplicated router command statistics.'
    Assert (-not (Complete-VoiceTaskBind (Bind-Result) $bind)) 'A duplicate read result committed twice.'
}
Case 'Ambiguous full-title candidates preserve directory and allow a new spoken selection' {
    Begin-Choice;Assert-Original
    Assert ((Test-VoiceTaskSelectionPending) -and $TaskCombo.Items.Count -eq 2 -and $TaskCombo.SelectedIndex -eq -1) 'Candidates were not presented without auto-selection.'
    Assert ($TaskCombo.Items[1].title -eq ('长标题'*20) -and $script:directoryFilter -eq 'keep-this-filter') 'Candidate title/filter was changed.'
    Assert ($script:queued[0].Contains('标题开头是') -and $script:shown -eq 1 -and $script:shownPage -eq 0) 'Long title speech or connection page presentation is wrong.'
    $script:recMode='listening';$script:voiceGeneration++;Update-VoiceTaskSwitch
    Assert (Test-VoiceTaskSelectionPending) 'Recording the numbered answer discarded candidates.'
    $script:recMode='idle';$InputBox.Text='选择第二个'
    Assert (Select-VoiceTaskCandidate 2) 'Numbered selection was not handled.'
    $InputBox.Text='';$ctx=Take-Context
    Assert (Complete-VoiceTaskBind (Bind-Result $thirdId) $ctx) 'Selection from a new voice generation was rejected.'
    Assert ($script:threadId -eq $thirdId -and $TaskCombo.Items.Count -eq 1 -and $TaskCombo.Items[0].title -eq 'Original title') 'Numbered destination or restored list is wrong.'
    Assert ($TaskCombo.SelectedIndex -eq -1) 'Ambiguous selection left the old task selected after binding.'
}
Case 'New search cancels only its owned worker and ignores old successes/failures' {
    Assert (Begin-VoiceTaskSwitch 'target') 'First request failed.';$old=$script:bridgeJob.VoiceTaskSwitchContext
    Assert (Begin-VoiceTaskSwitch 'replacement') 'Replacement request failed.';$current=$script:bridgeJob.VoiceTaskSwitchContext
    Assert ($script:killed.Count -eq 1 -and $script:killed[0] -eq 'voice-find') 'Owned previous worker was not cancelled.'
    Assert (-not (Complete-VoiceTaskSearch (Search-Result) $old)) 'Old search became current.'
    Assert (-not (Fail-VoiceTaskSwitch 'old failure' $old)) 'Old failure erased the replacement.'
    Assert ($script:voiceTaskSwitch.Generation -eq $current.Generation -and $script:voiceTaskSwitch.Query -eq 'replacement') 'Replacement state was altered.'
    Assert-Original
}
Case 'Manual binding and fresh recording make late read results harmless' {
    $ctx=Begin-Bind;$script:threadId=$thirdId
    Assert (-not (Complete-VoiceTaskBind (Bind-Result) $ctx)) 'Late voice read overwrote a manual binding.'
    Assert ($script:threadId -eq $thirdId) 'Manual destination was rolled back.'
    Reset-Case;$ctx=Begin-Bind;$script:recMode='arming';$script:voiceGeneration++
    Assert (-not (Complete-VoiceTaskBind (Bind-Result) $ctx)) 'Read committed during a new recording.'
    Assert-Original;Assert ($script:recMode -eq 'arming' -and $script:stopCount -eq 0) 'Protected recording was cancelled.'
}
Case 'Draft and new automatic dispatch prevent late commit without clearing text' {
    $ctx=Begin-Bind;$InputBox.Text='New question draft'
    Assert (-not (Complete-VoiceTaskBind (Bind-Result) $ctx)) 'A new draft was discarded by binding.'
    Assert ($InputBox.Text -eq 'New question draft') 'Draft was cleared.';Assert-Original
    Reset-Case;$ctx=Begin-Bind;$script:autoDispatch=@{Text='New question';Generation=7;ThreadId=$sourceId}
    Assert (-not (Complete-VoiceTaskBind (Bind-Result) $ctx)) 'New automatic message was overwritten.'
    Assert ($script:autoDispatch.Text -eq 'New question') 'Automatic intent was cleared.';Assert-Original
}
Case 'Read failure, malformed candidates and wrong target preserve the source' {
    $ctx=Begin-Bind;$bad=Bind-Result $thirdId
    Assert (-not (Complete-VoiceTaskBind $bad $ctx)) 'Wrong target was accepted.';Assert-Original
    Reset-Case;$ctx=Begin-Bind;$bad=Bind-Result;$bad.rolloutPath=Join-Path $runRoot 'missing.jsonl'
    Assert (-not (Complete-VoiceTaskBind $bad $ctx)) 'Missing transcript was accepted.';Assert-Original
    Reset-Case;$ctx=Begin-Search
    Assert (-not (Complete-VoiceTaskSearch (Search-Result 'ambiguous' @((Candidate),(Candidate))) $ctx)) 'Duplicate candidates were accepted.';Assert-Original
    Reset-Case;$ctx=Begin-Search
    Assert (-not (Complete-VoiceTaskSearch (Search-Result 'unique' @((Candidate)) 'wrong query') $ctx)) 'Wrong query response was accepted.';Assert-Original
}
Case 'No match and launch failure provide a local outcome without applying' {
    $ctx=Begin-Search;Assert (Complete-VoiceTaskSearch (Search-Result 'none' @()) $ctx) 'No match was not handled.'
    Assert ($null -eq $script:voiceTaskSwitch -and $script:queued.Count -eq 1) 'No match had no separate feedback.';Assert-Original
    Reset-Case;$script:startFails=$true
    Assert (Begin-VoiceTaskSwitch 'target') 'An explicit command fell through after launch failure.'
    Assert ($null -eq $script:voiceTaskSwitch -and $script:saveCount -eq 0) 'Launch failure committed state.';Assert-Original
}
Case 'Busy Codex permits lookup but send uncertainty and audio transitions block it' {
    Assert (Begin-VoiceTaskSwitch 'target') 'Codex busy incorrectly blocks a local search.'
    Assert ($script:requests.Count -eq 1) 'Busy task was not searched.'
    foreach($guard in @('send','pending','ledger','asr','recording','ack','closing','list')) {
        Reset-Case
        switch($guard){
            'send' {$script:bridgeJob=@{Purpose='send'}}
            'pending' {$script:pendingUncertain='pending'}
            'ledger' {$script:pendingSends[$sourceId]=@{requestId='pending'}}
            'asr' {$script:asrJob=@{busy=$true}}
            'recording' {$script:recMode='listening'}
            'ack' {$script:handsFreePhase='acknowledging'}
            'closing' {$script:closing=$true}
            'list' {$script:bridgeJob=@{Purpose='list'}}
        }
        Assert (Begin-VoiceTaskSwitch 'target') ('Guarded command was not consumed: '+$guard)
        Assert ($script:requests.Count -eq 0 -and $script:killed.Count -eq 0 -and $script:stopCount -eq 0) ('Guard cancelled unrelated work: '+$guard)
        Assert-Original
    }
}
Case 'Candidate expiry and cancellation restore UI without touching drafts or answers' {
    Begin-Choice;$InputBox.Text='Retained draft';$script:voiceTaskSwitch.ExpiresAt=[DateTime]::UtcNow.AddSeconds(-1)
    Update-VoiceTaskSwitch
    Assert (-not (Test-VoiceTaskSelectionPending)) 'Expired selection remained active.'
    Assert ($TaskCombo.Items.Count -eq 1 -and $TaskCombo.SelectedItem -eq $script:oldChoice -and $InputBox.Text -eq 'Retained draft') 'Expiry changed original selection/draft.'
    Assert (-not (Select-VoiceTaskCandidate 1) -and -not (Cancel-VoiceTaskSwitch)) 'No-pending numbers/cancel were consumed.';Assert-Original
    Reset-Case;Begin-Choice
    Assert (Select-VoiceTaskCandidate 5) 'Out of range candidate was not handled locally.'
    Assert (Test-VoiceTaskSelectionPending) 'Out of range selection destroyed the list.'
    Assert (Cancel-VoiceTaskSwitch) 'Pending cancellation was not handled.'
    Assert ($script:requests.Count -eq 1 -and $script:stopCount -eq 0) 'Cancel tried to bind or stopped audio.';Assert-Original
}
Case 'Apply failure restores binding metadata, full answer, input and saved source' {
    $ctx=Begin-Bind;$script:failNewSave=$true
    Assert (-not (Complete-VoiceTaskBind (Bind-Result) $ctx)) 'Failed persistence reported a successful switch.'
    Assert-Original
    $saved=Get-Content -LiteralPath $script:settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($saved.threadId -eq $sourceId -and $script:localCommandCount -eq 0 -and $script:queued.Count -eq 0) 'Rollback retained a new destination or spoke success.'
    Assert ($TaskLabel.ToolTip -eq 'Original title' -and $InputBox.Text -eq '' -and -not $script:pendingUncertain) 'Rollback metadata/input/pending is inconsistent.'
    Assert ($TaskCombo.SelectedItem -eq $script:oldChoice) 'Failed apply did not restore the original task selection.'
}

Case 'Successful binding selects its entry in the restored original task list' {
    $listedTarget=Candidate
    [void]$TaskCombo.Items.Add($listedTarget)
    Begin-Choice
    Assert (Select-VoiceTaskCandidate 1) 'Choice was not accepted.'
    $ctx=Take-Context
    Assert (Complete-VoiceTaskBind (Bind-Result) $ctx) 'Listed target did not bind.'
    Assert ($TaskCombo.Items.Count -eq 2 -and $TaskCombo.SelectedItem -eq $listedTarget -and $TaskCombo.SelectedItem.threadId -eq $script:threadId) 'Restored task selector does not identify the actual bound task.'
    Assert (-not $script:syncingUi -and $script:directoryFilter -eq 'keep-this-filter') 'Selection synchronization changed unrelated UI state.'
}

Case 'Actual command parser/executor clears only consumed input and counts each instruction once' {
    $InputBox.Text='切换到高斯坡建任务'
    $script:autoDispatch=@{Text=$InputBox.Text;ThreadId=$sourceId;Generation=7}
    Assert (Try-LocalAssistantCommand $InputBox.Text) 'Actual router did not handle a task command.'
    Assert ($InputBox.Text -eq '' -and $null -eq $script:autoDispatch -and $script:localCommandCount -eq 1) 'Consumed command or statistics are incorrect.'
    $query=$script:voiceTaskSwitch.Query;$ctx=Take-Context
    Assert (Complete-VoiceTaskSearch (Search-Result 'unique' @((Candidate)) $query) $ctx) 'Actual routed search did not continue.'
    $ctx=Take-Context;Assert (Complete-VoiceTaskBind (Bind-Result) $ctx) 'Actual routed bind did not complete.'
    Assert ($script:localCommandCount -eq 1 -and $script:queued.Count -eq 1) 'Asynchronous success counted/spoke twice.'
    Reset-Case;$InputBox.Text='Unrelated original draft'
    Assert (Try-LocalAssistantCommand '切换到高斯坡建任务') 'Explicit task command was not handled with a preserved draft.'
    Assert ($InputBox.Text -eq 'Unrelated original draft') 'Router erased an unrelated original draft.'
    $query=$script:voiceTaskSwitch.Query;$ctx=Take-Context
    Assert (-not (Complete-VoiceTaskSearch (Search-Result 'unique' @((Candidate)) $query) $ctx)) 'An uncleared original draft was allowed to disappear at commit.'
    Assert-Original
}

$summary=@{passed=@($script:results|Where-Object {$_.passed}).Count;failed=@($script:results|Where-Object {-not $_.passed}).Count;checks=$script:checks;cases=@($script:results);boundaries='Production module and Apply-Thread/Save-Settings; fake bridge/audio/listener and GUID-isolated settings. No real Codex or microphone.'}
$resultPath=Join-Path (Split-Path -Parent $runRoot) 'result.json'
[IO.File]::WriteAllText($resultPath,($summary|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
$summary|ConvertTo-Json -Depth 6
if($summary.failed){exit 1}
