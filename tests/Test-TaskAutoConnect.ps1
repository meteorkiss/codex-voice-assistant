# Windows PowerShell 5.1 / STA. Real WPF selection callbacks and production
# binding transactions; no app entrypoint, tasks, messages, audio or microphone.
param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run with Windows PowerShell -STA.' }
. (Join-Path $PSScriptRoot 'ProductionAst.ps1')
$sourceRoot=Join-Path $Root 'src'
Add-Type -AssemblyName PresentationFramework
. (Join-Path $sourceRoot 'DesktopController.ps1')
. (Join-Path $sourceRoot 'TaskSwitch.ps1')
. (Join-Path $sourceRoot 'TaskCreate.ps1')
. (Join-Path $sourceRoot 'DraftRecovery.ps1')
. (Join-Path $sourceRoot 'BindingRecovery.ps1')
$productionSaveDraft=${function:Save-AssistantRecoveryDraft}
$assistantAst=Read-TestProductionAst (Join-Path $sourceRoot 'Assistant.ps1')
$apply=$assistantAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Apply-Thread'},$true)
if (-not $apply) { throw 'Missing production Apply-Thread.' }
. ([scriptblock]::Create($apply.Extent.Text))
$controllerAst=Read-TestProductionAst (Join-Path $sourceRoot 'DesktopController.ps1')
function Get-SelectionHandler([string]$Control,[string]$Method='Add_SelectionChanged') {
    $nodes=@($controllerAst.FindAll({param($n)
        $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Expression.Extent.Text -eq ('$'+$Control) -and $n.Member.Value -eq $Method
    },$true))
    if ($nodes.Count -ne 1) { throw ('Expected one production handler: '+$Control+'.'+$Method) }
    return $nodes[0].Arguments[0].ScriptBlock.GetScriptBlock()
}
$script:TaskCombo=New-Object Windows.Controls.ComboBox
$script:DirectoryCombo=New-Object Windows.Controls.ComboBox
$script:InputBox=New-Object Windows.Controls.TextBox
$script:TaskLabel=New-Object Windows.Controls.TextBlock
$script:AnswerBox=New-Object Windows.Controls.TextBox
$TaskCombo.Add_SelectionChanged((Get-SelectionHandler 'TaskCombo'))
$DirectoryCombo.Add_SelectionChanged((Get-SelectionHandler 'DirectoryCombo'))
$InputBox.Add_TextChanged((Get-SelectionHandler 'InputBox' 'Add_TextChanged'))
$runRoot=Join-Path $Root ('work\tests\task-auto-connect-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
$script:stateDir=$runRoot
$fixture=Join-Path $runRoot 'synthetic-rollout.jsonl'
[IO.File]::WriteAllText($fixture,'')
$fixtureFiles=New-Object 'Collections.Generic.List[string]'
$fixtureFiles.Add($fixture)
$sourceId='11111111-1111-4111-8111-111111111111'
$targetId='22222222-2222-4222-8222-222222222222'
$thirdId='33333333-3333-4333-8333-333333333333'
$taskA=[pscustomobject]@{threadId=$sourceId;title='原任务';cwd='C:\synthetic-a';rolloutPath=$fixture;status='idle'}
$taskB=[pscustomobject]@{threadId=$targetId;title='目标 B';cwd='C:\synthetic-b';rolloutPath=$fixture;status='idle'}
$taskC=[pscustomobject]@{threadId=$thirdId;title='目标 C';cwd='C:\synthetic-c';rolloutPath=$fixture;status='idle'}
$script:checks=0
$results=New-Object 'Collections.Generic.List[object]'
function Assert-That([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:checks++ }
function Start-Bridge($Request,[string]$Purpose) {
    Assert-That ($Request.action -in @('read','list')) 'A selection attempted a real mutation or send.'
    if ($script:failBridgeStart) { throw 'Synthetic bridge launch failure.' }
    if ($script:bridgeJob) { return $false }
    $script:requests.Add(@{request=$Request.Clone();purpose=$Purpose})
    $script:bridgeJob=@{Purpose=$Purpose;Key=[Guid]::NewGuid().ToString('N')}
    return $true
}
function Close-Job($Job,[switch]$Kill) { $script:closedJobs.Add($Job) }
function Save-Settings { if ($script:failSettingsSave) { throw 'Synthetic settings persistence failure.' }; $script:savedIds.Add([string]$script:threadId) }
function Stop-Output([string]$Message='') { $script:stops++ }
function Suspend-WakeListener { $script:wakeStops++ }
function Close-ShortFollowUp([string]$Message='', [switch]$CancelCapture) { $script:followUpCloses++ }
function Cancel-Recording { throw 'Task selection must not cancel an active recording.' }
function Reconcile-PendingSends {}
function Sync-PendingSend {}
function New-TranscriptTail($Path) { return [pscustomobject]@{Path=$Path;Latest='synthetic answer';UserTurnVersion=1;Offset=19} }
function Save-AssistantRecoveryDraft {
    param([string]$ThreadId,[string]$Title,[string]$Text,[string]$Reason)
    Assert-That ($InputBox.Text -ceq $Text) 'Draft was cleared before its recovery copy.'
    if ($script:failDraftSave) { throw 'Synthetic draft persistence failure.' }
    $path=& $productionSaveDraft @PSBoundParameters
    $fixtureFiles.Add($path)
    Assert-That ($InputBox.Text -ceq $Text -and [IO.File]::Exists($path)) 'Recovery copy did not precede clearing.'
    return $path
}
function Reset-Case {
    $script:manualTaskBinding=$null; $script:voiceTaskSwitch=$null; $script:voiceTaskCreate=$null
    $script:bridgeJob=$null; $script:syncingUi=$true
    try {
        $TaskCombo.Items.Clear(); $DirectoryCombo.Items.Clear(); $InputBox.Text=''
    } finally { $script:syncingUi=$false }
    $script:requests=New-Object 'Collections.Generic.List[object]'
    $script:closedJobs=New-Object 'Collections.Generic.List[object]'
    $script:savedIds=New-Object 'Collections.Generic.List[string]'
    $script:threadId=$sourceId; $script:boundDirectory=$taskA.cwd; $script:directoryFilter=''
    $script:connected=$true; $script:closing=$false; $script:recMode='idle'; $script:asrJob=$null
    $script:pendingUncertain=''; $script:pendingSends=@{}; $script:autoDispatch=$null
    $script:handsFreePhase='off'; $script:handsFreeEnabled=$false; $script:voiceGeneration=4
    $script:voiceTaskSwitchGeneration=0; $script:consumingLocalCommand=$false
    $script:shortFollowUp=$null; $script:followUpCapture=$false; $script:tail=New-TranscriptTail $fixture
    $script:busy=$false; $script:latest=''; $script:bindingReadError=''; $script:taskSelectionMessage=''
    $script:failDraftSave=$false; $script:failSettingsSave=$false; $script:failBridgeStart=$false
    $script:stops=0; $script:wakeStops=0; $script:followUpCloses=0
    $script:TestTranscriptPath=''; $TaskLabel.Text=$taskA.title; $TaskLabel.ToolTip=$taskA.title
    Initialize-BindingRecovery
    $script:bindingAvailability='active'
    Set-TaskCandidates @($taskA,$taskB,$taskC)
    Assert-That ($script:requests.Count -eq 0 -and $TaskCombo.SelectedItem.threadId -ceq $sourceId) 'Setup programmatic synchronization auto-connected.'
}
function Run-Case([string]$Name,[scriptblock]$Body) {
    try { Reset-Case; & $Body; $results.Add(@{name=$Name;passed=$true}) }
    catch { $results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message}); Write-Output ('FAIL '+$Name+': '+$_.Exception.Message) }
}
function Read-Result([string]$Id=$targetId) {
    return [pscustomobject]@{ok=$true;threadId=$Id;title='已验证目标';cwd='C:\synthetic-validated';rolloutPath=$fixture;status='idle';hostId='local';archived=$false;bindingState='active'}
}
function Deliver-Binding($Result) {
    $context=$script:bridgeJob.TaskBindingContext.Clone(); $script:bridgeJob=$null
    return (Complete-ManualTaskBinding $Result $context)
}
function Assert-SourceRestored {
    Assert-That ($script:threadId -ceq $sourceId -and $script:connected) 'A rejected selection changed the actual connection.'
    Assert-That ($TaskCombo.SelectedItem.threadId -ceq $sourceId -and -not $script:manualTaskBinding) 'Rejected selection stayed visible or queued.'
}
try {
    Run-Case 'User selection validates once then commits the selected task' {
        $TaskCombo.SelectedItem=$taskB
        Assert-That ($script:requests.Count -eq 1 -and $script:requests[0].request.threadId -ceq $targetId -and $script:requests[0].purpose -eq 'bind') 'Selection did not read exactly its selected task.'
        Assert-That ($script:manualTaskBinding.AutoConnect -and $script:threadId -ceq $sourceId -and $script:savedIds.Count -eq 0) 'Selection committed before validation or lacked guarded context.'
        Assert-That (Deliver-Binding (Read-Result)) 'A valid read receipt did not bind.'
        Assert-That ($script:threadId -ceq $targetId -and $TaskCombo.SelectedItem.threadId -ceq $targetId -and $script:savedIds[-1] -ceq $targetId) 'Validated selection and persisted destination diverged.'
        Assert-That ($script:requests.Count -eq 1 -and -not $InputBox.Text) 'Commit recursively reconnected or submitted text.'
    }
    Run-Case 'Candidate refresh filtering and binding synchronization never auto-connect' {
        Set-TaskCandidates @($taskA,$taskB,$taskC)
        Sync-TaskBindingSelection
        $DirectoryCombo.SelectedItem=@($DirectoryCombo.Items | Where-Object {$_.path -ceq $taskB.cwd})[0]
        Assert-That ($TaskCombo.Items.Count -eq 1 -and $TaskCombo.SelectedIndex -eq -1 -and $script:threadId -ceq $sourceId) 'Filtering selected or connected the remaining first task.'
        Set-TaskCandidates @($taskB)
        Assert-That ($script:requests.Count -eq 0 -and -not $script:manualTaskBinding) 'Programmatic candidate changes started binding.'
    }
    Run-Case 'Reselecting the connected task is a no-op and preserves its draft' {
        $InputBox.Text='当前草稿不能因重选保存或丢失'
        $script:syncingUi=$true; try {$TaskCombo.SelectedIndex=-1} finally {$script:syncingUi=$false}
        $priorCopies=$script:recoveryDraftCount; $priorTail=$script:tail
        $TaskCombo.SelectedItem=$taskA
        Assert-That ($script:requests.Count -eq 0 -and $script:savedIds.Count -eq 0 -and $script:stops -eq 0) 'Same-task selection restarted binding or audio.'
        Assert-That ($InputBox.Text -ceq '当前草稿不能因重选保存或丢失' -and $script:recoveryDraftCount -eq $priorCopies -and [object]::ReferenceEquals($script:tail,$priorTail)) 'Same-task selection changed draft or transcript.'
    }
    Run-Case 'Rapid B then C cancels only the B read and ignores its late receipt' {
        $TaskCombo.SelectedItem=$taskB; $oldContext=$script:bridgeJob.TaskBindingContext.Clone(); $oldJob=$script:bridgeJob
        $TaskCombo.SelectedItem=$taskC
        Assert-That ($script:requests.Count -eq 2 -and $script:closedJobs.Count -eq 1 -and [object]::ReferenceEquals($script:closedJobs[0],$oldJob)) 'Rapid selection did not replace only its prior readonly bind.'
        Assert-That ($script:manualTaskBinding.TargetThreadId -ceq $thirdId -and $TaskCombo.SelectedItem.threadId -ceq $thirdId) 'Cancelling B overwrote the new C selection.'
        Assert-That (-not (Complete-ManualTaskBinding (Read-Result) $oldContext)) 'Stale B receipt was accepted.'
        Assert-That ($script:threadId -ceq $sourceId -and $script:manualTaskBinding.TargetThreadId -ceq $thirdId) 'Stale B receipt disrupted C validation.'
        Assert-That (Deliver-Binding (Read-Result $thirdId)) 'Current C receipt failed after stale B.'
        Assert-That ($script:threadId -ceq $thirdId -and $script:requests.Count -eq 2) 'Final binding was not C or validation recursively repeated.'
    }
    Run-Case 'Selecting back to the actual task cancels the pending read without reconnecting' {
        $TaskCombo.SelectedItem=$taskB; $context=$script:bridgeJob.TaskBindingContext.Clone()
        $TaskCombo.SelectedItem=$taskA
        Assert-SourceRestored
        Assert-That ($script:requests.Count -eq 1 -and $script:closedJobs.Count -eq 1 -and -not $script:bridgeJob) 'Returning to actual task left a read or started another.'
        Assert-That (-not (Complete-ManualTaskBinding (Read-Result) $context)) 'Cancelled task receipt overwrote the selected actual task.'
    }
    Run-Case 'Draft is saved with source identity before selection validation and never forwarded' {
        $original="  合成旧草稿`r`n下一行  "; $InputBox.Text=$original
        $TaskCombo.SelectedItem=$taskB
        Assert-That (-not $InputBox.Text -and $script:requests.Count -eq 1 -and $script:lastRecoveryDraftPath) 'Selection failed to save the prior draft first.'
        $saved=[IO.File]::ReadAllText($script:lastRecoveryDraftPath)
        Assert-That ($saved.Contains($sourceId) -and $saved.EndsWith($original,[StringComparison]::Ordinal)) 'Recovery copy changed source identity or original text.'
        Assert-That (Deliver-Binding (Read-Result)) 'Saved-draft selection could not commit.'
        Assert-That (-not $InputBox.Text -and $script:requests.Count -eq 1) 'New task restored or sent the old draft.'
    }
    Run-Case 'Draft persistence failure keeps exact text and restores actual selection for explicit retry' {
        $InputBox.Text='不可丢失的原文'; $script:failDraftSave=$true
        $TaskCombo.SelectedItem=$taskB
        Assert-SourceRestored
        Assert-That ($InputBox.Text -ceq '不可丢失的原文' -and $script:requests.Count -eq 0 -and $script:recoveryDraftError) 'Failed draft save cleared text or began a connection.'
        $script:failDraftSave=$false; Update-ManualTaskBinding
        Assert-That ($script:requests.Count -eq 0) 'Clearing a failure automatically retried selection.'
        $TaskCombo.SelectedItem=$taskB
        Assert-That ($script:requests.Count -eq 1 -and -not $InputBox.Text) 'Explicit reselection could not safely retry.'
    }
    Run-Case 'Recording sends uncertain receipts and other interactive operations block without queuing' {
        foreach ($mode in @('listening','transcribing','asr','send','unknown','pending','other','dispatch','closing','acknowledging')) {
            $script:recMode='idle'; $script:asrJob=$null; $script:bridgeJob=$null; $script:pendingUncertain=''; $script:pendingSends=@{}; $script:autoDispatch=$null; $script:closing=$false; $script:handsFreePhase='off'
            switch ($mode) {
                'listening' {$script:recMode='listening'}
                'transcribing' {$script:recMode='transcribing'}
                'asr' {$script:asrJob=@{Generation=4}}
                'send' {$script:bridgeJob=@{Purpose='send'}}
                'unknown' {$script:pendingUncertain='synthetic-request'}
                'pending' {$script:pendingSends[$sourceId]=@{requestId='synthetic-request'}}
                'other' {$script:bridgeJob=@{Purpose='open'}}
                'dispatch' {$script:autoDispatch=@{Text='unsent'}}
                'closing' {$script:closing=$true}
                'acknowledging' {$script:handsFreePhase='acknowledging'}
            }
            $TaskCombo.SelectedItem=$taskB
            Assert-SourceRestored
            Assert-That ($script:requests.Count -eq 0 -and $script:closedJobs.Count -eq 0) ('Busy guard cancelled work or queued binding: '+$mode)
        }
        $script:handsFreePhase='off'; Update-ManualTaskBinding
        Assert-That ($script:requests.Count -eq 0) 'Returning idle automatically connected an earlier rejected selection.'
    }
    Run-Case 'Launch failure restores actual task and requires a new selection' {
        $script:failBridgeStart=$true; $TaskCombo.SelectedItem=$taskB
        Assert-SourceRestored
        Assert-That ($script:taskSelectionMessage -or $script:notice) 'Launch failure omitted a visible explanation.'
        $script:failBridgeStart=$false; Update-ManualTaskBinding
        Assert-That ($script:requests.Count -eq 0) 'Failed launch was automatically retried.'
        $TaskCombo.SelectedItem=$taskB
        Assert-That ($script:requests.Count -eq 1) 'Explicit launch retry could not start.'
    }
    Run-Case 'Rejected archived mismatched and malformed receipts restore the actual selection' {
        foreach ($kind in @('rejected','archived','mismatch','malformed')) {
            $TaskCombo.SelectedItem=$taskB
            $result=Read-Result
            switch ($kind) {
                'rejected' {$result.ok=$false}
                'archived' {$result.archived=$true; $result.bindingState='archived'}
                'mismatch' {$result.threadId=$thirdId}
                'malformed' {$result.ok='true'}
            }
            Assert-That (-not (Deliver-Binding $result)) ('Invalid receipt committed: '+$kind)
            Assert-SourceRestored
        }
        Assert-That ($script:requests.Count -eq 4 -and $script:savedIds.Count -eq 0) 'Receipt failure retried automatically or saved a wrong target.'
    }
    Run-Case 'Settings failure rolls back actual and displayed target and leaves the saved draft recoverable' {
        $InputBox.Text='保存连接失败也保留草稿'; $TaskCombo.SelectedItem=$taskB
        $copy=$script:lastRecoveryDraftPath; $script:failSettingsSave=$true
        Assert-That (-not (Deliver-Binding (Read-Result))) 'Settings failure was reported as successful binding.'
        Assert-SourceRestored
        Assert-That ([IO.File]::Exists($copy) -and [IO.File]::ReadAllText($copy).EndsWith('保存连接失败也保留草稿') -and -not $InputBox.Text) 'Settings rollback lost or forwarded the recovery copy.'
    }
    Run-Case 'New input cancels a pending selection and its late receipt cannot clear that input' {
        $TaskCombo.SelectedItem=$taskB; $context=$script:bridgeJob.TaskBindingContext.Clone()
        $InputBox.Text='连接期间的新输入'
        Assert-SourceRestored
        Assert-That ($script:closedJobs.Count -eq 1 -and -not $script:bridgeJob) 'Input change left its obsolete read running.'
        Assert-That (-not (Complete-ManualTaskBinding (Read-Result) $context)) 'Late read overwrote newer input context.'
        Assert-That ($InputBox.Text -ceq '连接期间的新输入') 'Late read cleared new input.'
    }
    Run-Case 'Timeout cancels validation and restores actual selection without retrying' {
        $TaskCombo.SelectedItem=$taskB; $context=$script:bridgeJob.TaskBindingContext.Clone()
        $script:manualTaskBinding.ExpiresAt=[DateTime]::UtcNow.AddSeconds(-1)
        Update-ManualTaskBinding
        Assert-SourceRestored
        Assert-That ($script:closedJobs.Count -eq 1 -and $script:requests.Count -eq 1 -and -not $script:bridgeJob) 'Timeout left work running or requeued it.'
        Assert-That (-not (Complete-ManualTaskBinding (Read-Result) $context)) 'Expired receipt was accepted.'
    }
    Run-Case 'Refreshing during validation cancels that selection and only requests the list' {
        $TaskCombo.SelectedItem=$taskB; $context=$script:bridgeJob.TaskBindingContext.Clone()
        Refresh-AssistantTasks
        Assert-SourceRestored
        Assert-That ($script:requests.Count -eq 2 -and $script:requests[1].request.action -eq 'list' -and $script:closedJobs.Count -eq 1) 'Refresh retried a binding or failed to cancel it.'
        $script:bridgeJob=$null; Set-TaskCandidates @($taskA,$taskB,$taskC)
        Assert-That ($script:requests.Count -eq 2 -and -not (Complete-ManualTaskBinding (Read-Result) $context)) 'Refreshed list or old receipt auto-connected.'
    }
    Run-Case 'Archived same-ID selection is revalidated instead of silently treated as connected' {
        $script:connected=$false; $script:bindingAvailability='archived'
        $script:syncingUi=$true; try {$TaskCombo.SelectedIndex=-1} finally {$script:syncingUi=$false}
        $TaskCombo.SelectedItem=$taskA
        Assert-That ($script:requests.Count -eq 1 -and $script:manualTaskBinding.TargetThreadId -ceq $sourceId) 'An archived same-ID selection skipped real validation.'
        Assert-That (Deliver-Binding (Read-Result $sourceId)) 'An explicitly revalidated active same-ID task did not recover.'
        Assert-That ($script:connected -and $script:bindingAvailability -eq 'active') 'Successful same-ID recovery remained disconnected.'
    }
    Run-Case 'Manual selection from voice ambiguity retains its chosen target throughout validation' {
        $script:voiceTaskSwitch=@{Phase='choosing';Generation=3;OriginalItems=@($taskA);OriginalSelection=$taskA;SourceThreadId=$sourceId}
        $script:syncingUi=$true
        try {$TaskCombo.Items.Clear(); [void]$TaskCombo.Items.Add($taskB); [void]$TaskCombo.Items.Add($taskC); $TaskCombo.SelectedIndex=-1}
        finally {$script:syncingUi=$false}
        $TaskCombo.SelectedItem=$taskB
        Assert-That (-not $script:voiceTaskSwitch -and $script:manualTaskBinding.TargetThreadId -ceq $targetId) 'Manual choice failed to consume the voice ambiguity safely.'
        Assert-That ($TaskCombo.SelectedItem.threadId -ceq $targetId -and $script:requests.Count -eq 1) 'Voice list restoration hid or duplicated the actual pending selection.'
        Assert-That (Deliver-Binding (Read-Result)) 'Explicit ambiguity-list choice could not complete.'
        Assert-That ($script:threadId -ceq $targetId -and $TaskCombo.SelectedItem.threadId -ceq $targetId) 'Voice candidate takeover committed or displayed a different task.'
    }
    Run-Case 'Unhealthy persisted targets stay unselected so a same-ID retry can be explicitly chosen' {
        foreach ($kind in @('archived','missing','unknown','read-error','disconnected')) {
            $script:bindingAvailability=if ($kind -in @('archived','missing','unknown')) {$kind} else {'active'}
            $script:bindingReadError=if ($kind -eq 'read-error') {'synthetic unavailable transcript'} else {''}
            $script:connected=($kind -notin @('archived','missing','disconnected'))
            Set-TaskCandidates @($taskA,$taskB,$taskC)
            Assert-That ($TaskCombo.SelectedIndex -eq -1 -and $script:requests.Count -eq 0) ('An unhealthy target looked selected or retried itself: '+$kind)
            Sync-TaskBindingSelection
            Assert-That ($TaskCombo.SelectedIndex -eq -1) ('Binding sync made an unhealthy target unselectable for explicit retry: '+$kind)
        }
        $TaskCombo.SelectedItem=$taskA
        Assert-That ($script:requests.Count -eq 1 -and $script:manualTaskBinding.TargetThreadId -ceq $sourceId) 'Explicit same-ID choice could not revalidate the persisted target.'
        Assert-That (Deliver-Binding (Read-Result $sourceId)) 'Explicit persisted-target retry did not recover.'
    }
    Run-Case 'A changed selected ID invalidates an old read even when UI synchronization suppressed its event' {
        $TaskCombo.SelectedItem=$taskB; $context=$script:bridgeJob.TaskBindingContext.Clone()
        $script:syncingUi=$true; try {$TaskCombo.SelectedItem=$taskC} finally {$script:syncingUi=$false}
        $script:bridgeJob=$null
        Assert-That (-not (Complete-ManualTaskBinding (Read-Result) $context)) 'Read validation ignored a no-longer-selected destination.'
        Assert-SourceRestored
        Assert-That ($script:requests.Count -eq 1) 'Restoring the actual selection auto-started another read.'
    }
    Run-Case 'Successful shared commit clears an obsolete selection failure for voice and other callers' {
        $script:taskSelectionMessage='此前的连接失败提示'
        Invoke-TaskBindingCommit (Read-Result) $targetId
        Assert-That ($script:threadId -ceq $targetId -and -not $script:taskSelectionMessage -and $TaskCombo.SelectedItem.threadId -ceq $targetId) 'Shared commit retained an old manual failure or a mismatched display.'
        Assert-That ($script:requests.Count -eq 0) 'Shared commit synchronization triggered an extra read.'
    }
} finally {
    # Only these exact generated files and now-empty fixture directories are ours.
    $prefix=[IO.Path]::GetFullPath($runRoot)+[IO.Path]::DirectorySeparatorChar
    foreach ($path in @($fixtureFiles | Select-Object -Unique)) {
        $full=[IO.Path]::GetFullPath($path)
        if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup escaped its dedicated directory.' }
        if ([IO.File]::Exists($full)) { Remove-Item -LiteralPath $full -Force }
    }
    $draftDir=Join-Path $runRoot 'recovery-drafts'
    if ([IO.Directory]::Exists($draftDir)) { [IO.Directory]::Delete($draftDir,$false) }
    if ([IO.Directory]::Exists($runRoot)) { [IO.Directory]::Delete($runRoot,$false) }
}
$failed=@($results | Where-Object {-not $_.passed})
Write-Output ($results.Count.ToString()+' task auto-connect scenarios, '+$checks+' assertions, '+$failed.Count+' failed. No windows shown, audio, microphone, real task operations or messages.')
if ($failed.Count) { exit 1 }
