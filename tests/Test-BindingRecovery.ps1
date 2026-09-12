param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$SourceRoot=Join-Path $Root 'src'
. (Join-Path $PSScriptRoot 'Test-HandsFree.ps1') -SourceRoot $SourceRoot -HelpersOnly | Out-Null
$script:checks=0
$script:workspace=$Root
$script:fixtureRoot=Join-Path $Root ('work\tests\binding-recovery-'+[Guid]::NewGuid().ToString('N'))
$script:fixtureFiles=New-Object 'Collections.Generic.List[string]'
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$script:stateDir=$fixtureRoot
$script:runtime=$fixtureRoot
$handsFreePath=Join-Path $SourceRoot 'HandsFree.ps1'
$assistantAst=Read-ProductionAst (Join-Path $SourceRoot 'Assistant.ps1')
$helperAst=Read-ProductionAst (Join-Path $PSScriptRoot 'Test-HandsFree.ps1')
foreach($name in @('Stop-Output','Test-FullDuplexReady','Safe-To-Play','Begin-Recording','Cancel-Recording','End-Recording','Send-Text','Apply-Thread','Read-BoundTaskAnswers')) {
    $node=$assistantAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if(-not $node){throw ('Missing production function: '+$name)}
    . ([scriptblock]::Create($node.Extent.Text))
}
foreach($name in @('reader-core.ps1','HandsFree.ps1','DesktopController.ps1','VoiceCommands.ps1','TaskSwitch.ps1','TaskCreate.ps1','LocalCommands.ps1','Persistence.ps1','DraftRecovery.ps1','BindingRecovery.ps1')) {
    . (Join-Path $SourceRoot $name)
}
$script:productionSaveDraft=${function:Save-AssistantRecoveryDraft}
foreach($name in @('Reset-Case','Tick-And-AssertHealthy','Start-WakeCase','Activate-And-ReleaseWake','Finish-AckAndStartQuestion','Finish-QuestionAfterSpeech','Begin-Transcription','Start-Bridge','Complete-FakeSend','Read-NewCompletedAnswers','New-TranscriptTail','Begin-Speech')) {
    $node=$helperAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if(-not $node){throw ('Missing synthetic helper: '+$name)}
    . ([scriptblock]::Create($node.Extent.Text))
}
$ledgerAst=Read-ProductionAst (Join-Path $SourceRoot 'PendingSends.ps1')
$node=$ledgerAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-SendReceiptState'},$true)
. ([scriptblock]::Create($node.Extent.Text))
function Save-AssistantRecoveryDraft {
    param([string]$ThreadId,[string]$Title,[string]$Text,[string]$Reason)
    Assert-That ($InputBox.Text -ceq $Text) 'Input was cleared before its recovery copy was saved.'
    if($script:failDraftSave){throw 'Synthetic recovery persistence failure.'}
    $saved=& $script:productionSaveDraft @PSBoundParameters
    $script:fixtureFiles.Add($saved)
    Assert-That ([IO.File]::Exists($saved) -and $InputBox.Text -ceq $Text) 'Save did not finish before the original input changed.'
    return $saved
}
function Save-Settings {if($script:failSettingsSave){throw 'Synthetic settings persistence failure.'};$script:savedBinding=$script:threadId}
function Sync-DesktopPreferences {}
function Update-DesktopDisplay {}
function Reconcile-PendingSends {}
function Sync-PendingSend {}
function Clear-PendingSend([string]$TargetThreadId){$script:clearedSends+=$TargetThreadId}
function Remove-OwnedFiles($Paths){foreach($path in @($Paths)){if($path){$script:removed+=$path}}}
function Close-Job($Job,[switch]$Kill){$script:killed+=$Job}
function Start-Worker($Interpreter,$Script,$Arguments) {
    $script:workerStarts++
    if($Script -notlike '*codex_bridge.py' -or $Arguments[0] -ne '--request'){throw 'Unexpected synthetic worker request.'}
    $script:fixtureFiles.Add([string]$Arguments[1]);$script:fixtureFiles.Add([string]$Arguments[3])
    if($script:failProbeLaunch){throw 'Synthetic probe launch failure.'}
    return [pscustomobject]@{HasExited=$false;ExitCode=0}
}
function Reset-WakeRecoveryAudioRoute {return @{CaptureEndpointId='synthetic-capture';RenderEndpointId='synthetic-render'}}
. (Join-Path $SourceRoot 'DesktopShell.ps1')
$script:desktop=New-DesktopShell
$script:window=$desktop.Window
foreach($entry in $desktop.Controls.GetEnumerator()){Set-Variable -Name $entry.Key -Value $entry.Value -Scope Script}
[void]$VoiceCombo.Items.Add([pscustomobject]@{name='Synthetic voice';id='zh-TW-HsiaoChenNeural'});$VoiceCombo.SelectedIndex=0
$desktopAst=Read-ProductionAst (Join-Path $SourceRoot 'DesktopController.ps1')
$InputBox.Add_TextChanged((Get-ProductionHandler $desktopAst 'InputBox' 'Add_TextChanged'))
$tick=Get-ProductionHandler $assistantAst 'timer' 'Add_Tick'
$sourceId='11111111-1111-4111-8111-111111111111'
$targetId='22222222-2222-4222-8222-222222222222'
$thirdId='33333333-3333-4333-8333-333333333333'
$targetPath=Join-Path $fixtureRoot 'synthetic-target.jsonl';$fixtureFiles.Add($targetPath)
[IO.File]::WriteAllText($targetPath,'')
$script:results=New-Object 'Collections.Generic.List[object]'
function Reset-RecoveryCase {
    $script:voiceTaskSwitch=$null;$script:manualTaskBinding=$null;$script:voiceTaskCreate=$null
    Reset-Case
    $script:stateDir=$fixtureRoot
    $script:failDraftSave=$false;$script:failSettingsSave=$false;$script:failProbeLaunch=$false
    $script:workerStarts=0;$script:savedBinding='';$script:consumingLocalCommand=$false
    $script:localCommandCount=0;$script:localCommandMessage='';$script:localCommandNoticeUntil=[DateTime]::MinValue
    $script:voiceTaskSwitchGeneration=0;$script:boundDirectory='C:\synthetic-project'
    $script:tasksLoaded=$true;$script:taskCandidates=@();$script:taskCreatePhase=''
    $script:settingsWarning='';$script:workerWarning='';$script:recoveryDraftError=''
    $script:voiceTaskCreateSession='synthetic-session';$script:voiceTaskCreatePath=Join-Path $fixtureRoot 'synthetic-create.json'
    $script:fixtureFiles.Add($script:voiceTaskCreatePath)
    $TaskCombo.Items.Clear();$TaskCombo.SelectedIndex=-1
    $TaskLabel.Text='原任务 · 合成数据';$TaskLabel.ToolTip=$TaskLabel.Text
    Initialize-BindingRecovery
    $script:bindingAvailability='active'
}
function Probe-Context {return @{ThreadId=[string]$script:threadId;Generation=$script:bindingGeneration}}
function Archive-Result {return [pscustomobject]@{ok=$true;threadId=[string]$script:threadId;state='archived';archived=$true}}
function Target-Result([string]$Id=$targetId) {return [pscustomobject]@{ok=$true;threadId=$Id;title='新任务 · 合成数据';cwd='C:\synthetic-target';rolloutPath=$targetPath;status='idle';archived=$false;bindingState='active';hostId='local'}}
function Run-Case([string]$Name,[scriptblock]$Action) {
    Reset-RecoveryCase
    try {& $Action;$script:results.Add([pscustomobject]@{name=$Name;passed=$true})}
    catch {$script:results.Add([pscustomobject]@{name=$Name;passed=$false;error=$_.Exception.Message});Write-Output ('FAIL '+$Name+': '+$_.Exception.Message)}
}
function Deliver-Asr([string]$Text,[int]$Generation=$script:voiceGeneration,[string]$Thread=$script:threadId) {
    $script:nextTranscript=$Text
    Begin-Transcription '' $true
    $script:asrJob.Generation=$Generation;$script:asrJob.ThreadId=$Thread
    Tick-And-AssertHealthy
}
try {
    Run-Case 'Confirmed archive saves the old draft before clearing and retains only its known context' {
        $original="  旧草稿`r`n不应发送到新任务  ";$InputBox.Text=$original
        $priorVoice=$script:voiceGeneration;$priorBinding=$script:bindingGeneration
        $context=Probe-Context
        Assert-That (Complete-BindingAvailability (Archive-Result) $context) 'Confirmed archive did not complete recovery.'
        Assert-That (-not $script:connected -and $script:threadId -ceq $sourceId -and $script:bindingAvailability -eq 'archived') 'Archive changed the known ID or left ordinary sending connected.'
        Assert-That ($script:voiceGeneration -gt $priorVoice -and $script:bindingGeneration -gt $priorBinding -and -not $script:autoDispatch) 'Archive did not invalidate old voice/binding generations.'
        Assert-That (-not $InputBox.Text -and [IO.File]::ReadAllText($script:lastRecoveryDraftPath).EndsWith($original,[StringComparison]::Ordinal)) 'Archive lost or changed the original draft.'
        Assert-That ($TaskCombo.SelectedIndex -eq -1 -and $script:bridgeRequests.Count -eq 0) 'Archive chose a default destination or sent a request.'
    }
    Run-Case 'Failed recovery persistence keeps the draft until an explicit connection retry' {
        $InputBox.Text='失败时保留原文';$script:failDraftSave=$true
        Assert-That (-not (Complete-BindingAvailability (Archive-Result) (Probe-Context))) 'Persistence failure was treated as successful recovery.'
        Assert-That ($InputBox.Text -ceq '失败时保留原文' -and $script:recoveryDraftError -and -not $script:connected) 'Persistence failure discarded text or re-enabled sending.'
        Set-HandsFree $true;$script:nextWakeUtc=[DateTime]::UtcNow.AddMilliseconds(-1);Update-HandsFree
        Assert-That (-not $script:wakeListener.IsListening) 'An unsaved draft no longer protected wake capture.'
        Assert-That (-not (Enter-TaskBindingRecovery 'archived')) 'Repeated passive archive handling hid an unsaved draft.'
        $script:failDraftSave=$false
        $choice=[pscustomobject]@{threadId=$targetId;title='新任务'};[void]$TaskCombo.Items.Add($choice);$TaskCombo.SelectedItem=$choice;$script:holdBridge=$true
        Assert-That (Begin-ManualTaskBinding $targetId) 'Explicit connection retry did not retry draft persistence.'
        Assert-That (-not $InputBox.Text -and [IO.File]::Exists($script:lastRecoveryDraftPath)) 'Explicit connection retry skipped the unsaved draft.'
        $context=$script:bridgeJob.TaskBindingContext;$script:bridgeJob=$null
        Assert-That (Complete-ManualTaskBinding (Target-Result) $context) 'Explicit retry did not complete the new binding.'
    }
    Run-Case 'Archive still permits wake capture and local keyword switch through the production Tick' {
        [void](Complete-BindingAvailability (Archive-Result) (Probe-Context))
        Start-WakeCase;Activate-And-ReleaseWake;Finish-AckAndStartQuestion
        $script:nextTranscript='切到声伴 6.17';$script:holdBridge=$true
        Finish-QuestionAfterSpeech
        Assert-That ($script:localCommandCount -eq 1 -and $script:bridgeJob.Purpose -eq 'voice-find') 'Recovery ASR did not reach local task lookup.'
        Assert-That ($script:bridgeRequests.Count -eq 1 -and $script:bridgeRequests[0].action -eq 'find' -and $script:bridgeRequests[0].query -ceq '声伴 6.17') 'Recovery forwarded a command or changed its keyword.'
        $findContext=$script:bridgeJob.VoiceTaskSwitchContext;$script:bridgeJob=$null
        [void](Complete-VoiceTaskSearch ([pscustomobject]@{ok=$true;query='声伴 6.17';matchType='unique';threads=@([pscustomobject]@{threadId=$targetId;title='新任务'})}) $findContext)
        $bindContext=$script:bridgeJob.VoiceTaskSwitchContext;$script:bridgeJob=$null
        Assert-That (Complete-VoiceTaskBind (Target-Result) $bindContext) 'Validated recovery target did not bind.'
        Assert-That ($script:connected -and $script:threadId -ceq $targetId -and $script:bindingAvailability -eq 'active' -and -not $InputBox.Text) 'Binding restored old text or kept the archived target.'
    }
    Run-Case 'Non-command ASR in recovery is saved without an ordinary send' {
        [void](Complete-BindingAvailability (Archive-Result) (Probe-Context))
        Deliver-Asr '普通问题，不允许发给归档任务'
        Assert-That ($script:bridgeRequests.Count -eq 0 -and -not $InputBox.Text -and -not $script:autoDispatch) 'Ordinary recovery ASR was sent or left an auto-dispatch intent.'
        $copy=$script:lastRecoveryDraftPath
        Assert-That ([IO.File]::ReadAllText($copy).Contains('普通问题，不允许发给归档任务')) 'Ordinary recovery ASR was not preserved.'
        Invoke-TaskBindingCommit (Target-Result) $targetId
        Assert-That (-not $InputBox.Text -and [IO.File]::Exists($copy) -and $script:bridgeRequests.Count -eq 0) 'New binding automatically restored or forwarded recovery text.'
    }
    Run-Case 'Archive permits a new-task command using only its known source context' {
        [void](Complete-BindingAvailability (Archive-Result) (Probe-Context))
        $script:TestMode=$false;$script:holdBridge=$true
        Deliver-Asr '新建一个任务'
        Assert-That ($script:localCommandCount -eq 1 -and $script:bridgeRequests.Count -eq 1 -and $script:bridgeRequests[0].action -eq 'create') 'Archive blocked local creation or forwarded the command as chat.'
        Assert-That ($script:bridgeRequests[0].threadId -ceq $sourceId -and -not $script:connected -and $script:threadId -ceq $sourceId) 'Creation invented a source or silently reconnected the archived target.'
    }
    Run-Case 'Explicit manual connection saves a draft and a failed target keeps the copy' {
        $InputBox.Text='手动连接前的草稿'
        $choice=[pscustomobject]@{threadId=$targetId;title='新任务'};[void]$TaskCombo.Items.Add($choice);$TaskCombo.SelectedItem=$choice
        $script:holdBridge=$true
        Assert-That (Begin-ManualTaskBinding $targetId) 'Explicit manual selection was blocked instead of safely saving its draft.'
        $copy=$script:lastRecoveryDraftPath;$context=$script:bridgeJob.TaskBindingContext;$script:bridgeJob=$null
        Assert-That ([IO.File]::Exists($copy) -and -not $InputBox.Text) 'Manual connection did not preserve text first.'
        Assert-That (-not (Complete-ManualTaskBinding ([pscustomobject]@{ok=$false}) $context)) 'Failed target unexpectedly committed.'
        Assert-That ($script:threadId -ceq $sourceId -and [IO.File]::ReadAllText($copy).Contains('手动连接前的草稿') -and $script:bridgeRequests[0].action -eq 'read') 'Failed manual connection lost its copy or sent text.'
    }
    Run-Case 'Manual draft save failure never starts the bind request' {
        $InputBox.Text='不能保存就不连接';$script:failDraftSave=$true
        $choice=[pscustomobject]@{threadId=$targetId;title='新任务'};[void]$TaskCombo.Items.Add($choice);$TaskCombo.SelectedItem=$choice
        Assert-That (-not (Begin-ManualTaskBinding $targetId)) 'Manual bind ignored recovery persistence failure.'
        Assert-That ($InputBox.Text -ceq '不能保存就不连接' -and $script:bridgeRequests.Count -eq 0) 'Manual persistence failure discarded text or launched a request.'
    }
    Run-Case 'A failed settings commit rolls back availability without removing the recovery copy' {
        $InputBox.Text='回退也保留';[void](Enter-TaskBindingRecovery 'archived');$copy=$script:lastRecoveryDraftPath
        $oldGeneration=$script:bindingGeneration;$script:failSettingsSave=$true;$failed=$false
        try {Invoke-TaskBindingCommit (Target-Result) $targetId} catch {$failed=$true}
        Assert-That ($failed -and $script:threadId -ceq $sourceId -and -not $script:connected -and $script:bindingAvailability -eq 'archived' -and $script:bindingGeneration -eq $oldGeneration) 'Failed commit did not restore the recovery state.'
        Assert-That ([IO.File]::Exists($copy) -and -not $InputBox.Text) 'Failed commit deleted or silently restored the recovery draft.'
    }
    Run-Case 'Unknown, malformed and missing states never guess that a task is archived' {
        $InputBox.Text='状态未知时保留'
        foreach($result in @($null,[pscustomobject]@{ok=$false},[pscustomobject]@{ok=$true;threadId=$sourceId;state='unknown';archived=$false},[pscustomobject]@{ok=$true;threadId=$sourceId;state='active';archived=$true})) {
            [void](Complete-BindingAvailability $result (Probe-Context))
            Assert-That ($script:bindingAvailability -eq 'unknown' -and $InputBox.Text -ceq '状态未知时保留' -and $script:connected) 'Unknown state was converted to archive or discarded binding/text.'
        }
        Send-Text
        Assert-That ($script:bridgeRequests.Count -eq 0 -and $InputBox.Text -ceq '状态未知时保留') 'Unknown target allowed ordinary send.'
        [void](Complete-BindingAvailability ([pscustomobject]@{ok=$true;threadId=$sourceId;state='missing';archived=$false}) (Probe-Context))
        Assert-That ($script:bindingAvailability -eq 'missing' -and -not $script:connected -and $script:threadId -ceq $sourceId) 'Explicit missing state was mislabeled archived or selected a new ID.'
    }
    Run-Case 'Stale probes and ASR cannot replace a newly connected target or input' {
        $context=Probe-Context;$oldVoice=$script:voiceGeneration
        [void](Enter-TaskBindingRecovery 'archived');Invoke-TaskBindingCommit (Target-Result) $targetId
        $InputBox.Text='新目标的新草稿';$generation=$script:bindingGeneration
        Assert-That (-not (Complete-BindingAvailability ([pscustomobject]@{ok=$true;threadId=$sourceId;state='archived';archived=$true}) $context)) 'Old probe was accepted after a new binding.'
        Deliver-Asr '迟到的旧任务转写' $oldVoice $sourceId
        Assert-That ($script:threadId -ceq $targetId -and $script:bindingGeneration -eq $generation -and $InputBox.Text -ceq '新目标的新草稿' -and $script:connected) 'Stale probe/ASR changed the new target or input.'
    }
    Run-Case 'Late ordinary send receipt settles its old ledger without clearing new text' {
        $script:holdBridge=$true
        $request=@{action='send';threadId=$sourceId;requestId=[Guid]::NewGuid().ToString();text='先前发送内容'}
        [void](Start-Bridge $request 'send');$oldJob=$script:bridgeJob
        $oldJob.BindingGeneration=$script:bindingGeneration;$oldJob.InputGeneration=$script:voiceGeneration
        $script:bridgeJob=$null
        [void](Enter-TaskBindingRecovery 'archived');Invoke-TaskBindingCommit (Target-Result) $targetId
        $InputBox.Text='新目标的新输入';$script:bridgeJob=$oldJob
        Complete-FakeSend;Tick-And-AssertHealthy
        Assert-That ($script:threadId -ceq $targetId -and $InputBox.Text -ceq '新目标的新输入' -and $script:clearedSends -contains $sourceId) 'Late ordinary receipt cleared new text, rebound a task or failed to settle the old ledger.'
    }
    Run-Case 'Same-ID rebind also invalidates an old ordinary receipt with identical text' {
        $script:holdBridge=$true;$text='同样的字但属于后来输入'
        [void](Start-Bridge @{action='send';threadId=$sourceId;requestId=[Guid]::NewGuid().ToString();text=$text} 'send')
        $oldJob=$script:bridgeJob;$oldJob.BindingGeneration=$script:bindingGeneration;$oldJob.InputGeneration=$script:voiceGeneration;$script:bridgeJob=$null
        [void](Enter-TaskBindingRecovery 'archived');Invoke-TaskBindingCommit (Target-Result $sourceId) $sourceId
        $InputBox.Text=$text;$script:bridgeJob=$oldJob
        Complete-FakeSend;Tick-And-AssertHealthy
        Assert-That ($InputBox.Text -ceq $text -and $script:connected) 'Same-ID late receipt cleared a later identical draft.'
    }
    Run-Case 'Probe jobs are independent of interactive jobs and never stall active audio' {
        Start-WakeCase
        $script:TestMode=$false;$script:lastBindingProbe=[DateTime]::MinValue
        Update-BindingAvailability ([DateTime]::UtcNow)
        Assert-That ($script:bindingProbeJob -and -not $script:bridgeJob -and $script:workerStarts -eq 1) 'Probe occupied the interactive bridge slot.'
        $probe=$script:bindingProbeJob;$starts=$script:wakeListener.Starts
        Tick-And-AssertHealthy
        Assert-That ($script:wakeListener.IsListening -and $script:wakeListener.Starts -eq $starts -and $script:bindingProbeJob -eq $probe) 'An unfinished probe stopped or restarted wake capture.'
        $script:bindingProbeJob.Started=[DateTime]::UtcNow.AddSeconds(-9)
        Tick-And-AssertHealthy
        Assert-That ($script:bindingAvailability -eq 'unknown' -and $script:wakeListener.IsListening -and -not $script:errorText) 'Probe timeout cancelled audio or guessed an archive.'
    }
    Run-Case 'Probe launch failure cannot cancel an active recorder' {
        Begin-Recording;$script:armDue=[DateTime]::UtcNow.AddMilliseconds(-1);Tick-And-AssertHealthy
        $script:TestMode=$false;$script:failProbeLaunch=$true;$script:lastBindingProbe=[DateTime]::MinValue
        Tick-And-AssertHealthy
        Assert-That ($script:bindingAvailability -eq 'unknown' -and $script:recMode -eq 'listening' -and $script:recorder.IsRecording -and $script:recorder.Cancels -eq 0) 'Probe failure unwound into recording cancellation.'
    }
    Run-Case 'Local-only archived and missing bindings can recover a failed wake listener' {
        foreach($state in @('archived','missing')) {
            Reset-RecoveryCase
            [void](Enter-TaskBindingRecovery $state);Set-HandsFree $true
            $script:wakeListener | Add-Member ScriptMethod GetHealthSnapshot {return [pscustomobject]@{State='healthy';NeedsRecovery=$false;Reason=''}}
            Assert-That (Test-WakeRecoveryCanStart) ('Local-only '+$state+' context blocked wake recovery.')
            $script:wakeRecovery.Phase='backoff';$script:wakeRecovery.NextAttemptUtc=[DateTime]::UtcNow.AddMilliseconds(-1)
            Update-WakeRecovery ([DateTime]::UtcNow)
            Assert-That ($script:wakeRecovery.Phase -eq 'starting' -and $script:wakeListener.IsListening) ('Local-only '+$state+' context could not restart the wake listener.')
            Update-WakeRecovery ([DateTime]::UtcNow)
            Assert-That ($script:wakeRecovery.Phase -eq 'idle' -and $script:wakeListener.IsListening -and -not $script:connected) ('Local-only '+$state+' recovery was cancelled or changed the binding.')
        }
    }
    $failed=@($script:results | Where-Object {-not $_.passed})
    [pscustomobject]@{ok=($failed.Count -eq 0);checks=$script:checks;passed=($script:results.Count-$failed.Count);failed=$failed.Count;cases=$script:results.ToArray();boundary='Production binding recovery, local routing and real Tick with synthetic drafts, bridge/process/audio doubles; no real tasks, audio, copied source trees or recursive cleanup.'} | ConvertTo-Json -Depth 5 -Compress
    if($failed.Count){throw ('Binding recovery regression failures: '+$failed.Count)}
} finally {
    Close-DesktopShell $desktop
    $allowed=[IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\')+'\'
    foreach($path in @($script:fixtureFiles | Select-Object -Unique)) {
        $full=[IO.Path]::GetFullPath($path)
        if(-not $full.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Test cleanup escaped its owned fixture directory.'}
        if([IO.File]::Exists($full)){[IO.File]::Delete($full)}
    }
    foreach($path in @((Join-Path $fixtureRoot 'recovery-drafts'),$fixtureRoot)) {
        if([IO.Directory]::Exists($path) -and [IO.Directory]::GetFileSystemEntries($path).Count -eq 0){[IO.Directory]::Delete($path)}
    }
}
