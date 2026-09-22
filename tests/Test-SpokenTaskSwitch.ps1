param(
    [string]$Root,
    [Parameter(Mandatory=$true)][string]$PythonPath
)
# Standalone spoken-switch regression: no Codex service, microphone or speaker
# is opened. Production timer, routing and binding code use synthetic workers;
# only the pure Python matcher runs in a real interpreter on fixture titles.
$ErrorActionPreference='Stop'
if(-not $Root){$Root=Split-Path -Parent $PSScriptRoot}
if(-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)){throw 'Provide an existing Python interpreter with -PythonPath.'}
$SourceRoot=Join-Path $Root 'src'
. (Join-Path $PSScriptRoot 'Test-HandsFree.ps1') -SourceRoot $SourceRoot -HelpersOnly | Out-Null
$script:checks=0
$script:workspace=$Root
$script:fixtureRoot=Join-Path $Root ('work\tests\spoken-task-switch-'+[Guid]::NewGuid().ToString('N'))
$script:fixtureFiles=New-Object 'Collections.Generic.List[string]'
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$script:stateDir=$fixtureRoot
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
foreach($name in @('Reset-Case','Tick-And-AssertHealthy','Start-WakeCase','Activate-And-ReleaseWake','Finish-AckAndStartQuestion','Finish-QuestionAfterSpeech','Begin-Transcription','Complete-FakeSend','Read-NewCompletedAnswers','New-TranscriptTail','Begin-Speech')) {
    $node=$helperAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if(-not $node){throw ('Missing synthetic helper: '+$name)}
    . ([scriptblock]::Create($node.Extent.Text))
}
$ledgerAst=Read-ProductionAst (Join-Path $SourceRoot 'PendingSends.ps1')
$node=$ledgerAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-SendReceiptState'},$true)
. ([scriptblock]::Create($node.Extent.Text))
function Save-Settings {$script:savedBinding=$script:threadId}
function Sync-DesktopPreferences {}
function Update-DesktopDisplay {}
function Reconcile-PendingSends {}
function Sync-PendingSend {}
function Clear-PendingSend([string]$TargetThreadId){$script:clearedSends+=$TargetThreadId}
function Remove-OwnedFiles($Paths){foreach($path in @($Paths)){if($path){$script:removed+=$path}}}
function Close-Job($Job,[switch]$Kill){$script:killed+=$Job}
function Start-Worker {throw 'Unexpected worker: this regression must never start a real audio or Codex worker.'}
function Update-BindingAvailability([DateTime]$Now) {} # External state-probe boundary, not task switching.
function Start-Bridge($Request,[string]$Purpose) {
    if($Request.action -notin @('find','read','send')){throw 'Unexpected synthetic bridge action.'}
    $script:bridgeRequests+=$Request
    $path=Join-Path $fixtureRoot ([Guid]::NewGuid().ToString('N')+'.bridge-result.json')
    $script:fixtureFiles.Add($path)
    $script:bridgeJob=@{Purpose=$Purpose;Request=$Request;Output=$path;Files=@($path);Process=[pscustomobject]@{HasExited=$false;ExitCode=0};BindingGeneration=$script:bindingGeneration;InputGeneration=$script:voiceGeneration}
    return $true
}
. (Join-Path $SourceRoot 'DesktopShell.ps1')
function Show-DesktopSettings($Desktop) {$script:selectionShown++} # Keep fixture WPF windows hidden.
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
$matcherProgram=@'
import json, sys
sys.path.insert(0, sys.argv[1])
from task_matcher import match_tasks
with open(sys.argv[2], encoding='utf-8-sig') as stream:
    fixture = json.load(stream)
result = match_tasks(fixture['query'], fixture['threads'])
result['ok'] = True
print(json.dumps(result, ensure_ascii=True))
'@
function Reset-SpokenSwitchCase {
    $script:voiceTaskSwitch=$null;$script:manualTaskBinding=$null;$script:voiceTaskCreate=$null
    Reset-Case
    $script:stateDir=$fixtureRoot;$script:savedBinding='';$script:consumingLocalCommand=$false
    $script:localCommandCount=0;$script:localCommandMessage='';$script:localCommandNoticeUntil=[DateTime]::MinValue
    $script:voiceTaskSwitchGeneration=0;$script:boundDirectory='C:\synthetic-project'
    $script:tasksLoaded=$true;$script:taskCandidates=@();$script:taskCreatePhase='';$script:selectionShown=0
    $script:noWakeMode='off'
    $script:fixtureTargetTitle='声伴 v0.6.17 · 短时连续接话'
    $script:settingsWarning='';$script:workerWarning='';$script:recoveryDraftError=''
    $script:voiceTaskCreateSession='synthetic-session';$script:voiceTaskCreatePath=Join-Path $fixtureRoot 'synthetic-create.json'
    $script:fixtureFiles.Add($script:voiceTaskCreatePath)
    $TaskCombo.Items.Clear();$TaskCombo.SelectedIndex=-1
    $TaskLabel.Text='原任务 · 合成数据';$TaskLabel.ToolTip=$TaskLabel.Text
    Initialize-BindingRecovery
    $script:bindingAvailability='active'
    # Ordinary sends are allowed to reach only Start-Bridge above, making an
    # unintended chat fallback visible rather than hidden by TestMode.
    $script:TestMode=$false
}
function Run-Case([string]$Name,[scriptblock]$Action) {
    Reset-SpokenSwitchCase
    try {& $Action;$script:results.Add([pscustomobject]@{name=$Name;passed=$true})}
    catch {$script:results.Add([pscustomobject]@{name=$Name;passed=$false;error=$_.Exception.Message});Write-Output ('FAIL '+$Name+': '+$_.Exception.Message)}
}
function Speak-SyntheticUtterance([string]$Text) {
    [CodexReader.AudioPlayer]::Played.Clear() # Reset only helper history, not audio ownership/state.
    Start-WakeCase;Activate-And-ReleaseWake;Finish-AckAndStartQuestion
    $script:nextTranscript=$Text
    Finish-QuestionAfterSpeech
}
function Assert-NoOrdinarySend {
    Assert-That (@($script:bridgeRequests | Where-Object {$_.action -eq 'send'}).Count -eq 0) 'A task command fell through into an ordinary chat send.'
}
function Get-SyntheticCandidates([switch]$Ambiguous) {
    $items=@([pscustomobject]@{threadId=$targetId;title=$script:fixtureTargetTitle},[pscustomobject]@{threadId=$sourceId;title='语音助手 MVP'})
    if($Ambiguous){$items+=([pscustomobject]@{threadId=$thirdId;title='声伴 v0.6.17 · 合成候选乙'})}
    return $items
}
function Complete-SyntheticJob($Result,$Job=$script:bridgeJob) {
    Assert-That ($null -ne $Job) 'Synthetic response has no pending bridge request.'
    [IO.File]::WriteAllText($Job.Output,($Result | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($true)))
    $Job.Process.HasExited=$true
    $script:bridgeJob=$Job
    Tick-And-AssertHealthy
}
function Complete-PureMatcher([switch]$Ambiguous) {
    $job=$script:bridgeJob
    Assert-That ($job.Purpose -eq 'voice-find' -and $job.Request.action -eq 'find') 'Spoken command did not reach a local title lookup.'
    $path=Join-Path $fixtureRoot ([Guid]::NewGuid().ToString('N')+'.matcher-input.json');$fixtureFiles.Add($path)
    $fixture=@{query=[string]$job.Request.query;threads=@(Get-SyntheticCandidates -Ambiguous:$Ambiguous)}
    [IO.File]::WriteAllText($path,($fixture | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
    $output=& $PythonPath -B -c $matcherProgram $SourceRoot $path
    if($LASTEXITCODE -ne 0){throw ('Pure matcher failed: '+($output -join ' '))}
    $result=($output -join "`n") | ConvertFrom-Json
    Assert-That ($result.ok -and $result.query -ceq $job.Request.query) 'The pure matcher rewrote the recognized lookup query.'
    Complete-SyntheticJob $result $job
    return $result
}
function Complete-TargetRead {
    Assert-That ($script:bridgeJob.Purpose -eq 'voice-bind' -and $script:bridgeJob.Request.threadId -ceq $targetId) 'Unique lookup did not request live validation of the synthetic target.'
    Complete-SyntheticJob ([pscustomobject]@{ok=$true;threadId=$targetId;title=$script:fixtureTargetTitle;cwd='C:\synthetic-target';rolloutPath=$targetPath;status='idle';archived=$false;bindingState='active';hostId='local'})
    Assert-That ($script:connected -and $script:threadId -ceq $targetId -and $script:savedBinding -ceq $targetId -and $script:bindingAvailability -eq 'active') 'Validated target was not committed and persisted by the production binding path.'
}
function Finish-SyntheticFeedback {
    for($i=0;$i -lt 8;$i++) {
        if($script:wakeListener.IsStopping){$script:wakeListener.Release()}
        if([CodexReader.AudioPlayer]::State -in @('playing','paused')){[CodexReader.AudioPlayer]::Finish()}
        Tick-And-AssertHealthy
        if($script:speechQueue.Count -eq 0 -and -not $script:audioPath -and [CodexReader.AudioPlayer]::State -eq 'closed'){return}
    }
    throw 'Synthetic local feedback did not drain.'
}
try {
    Run-Case 'Reported 0.6.18 cut homophone stays local and confirms product alias' {
        $script:fixtureTargetTitle='声伴 v0.6.18 · 免唤醒架构与实现'
        Speak-SyntheticUtterance '切道生办V0.6.18任务。'
        $match=Complete-PureMatcher
        Assert-That ($match.requiresConfirmation -and $match.query -ceq '生办V0.6.18' -and $script:voiceTaskSwitch.Phase -eq 'choosing' -and $script:threadId -ceq $sourceId) 'Reported homophones failed local matching or bound without confirmation.'
        Finish-SyntheticFeedback
        Speak-SyntheticUtterance '是的。'
        Complete-TargetRead
        Assert-NoOrdinarySend
    }
    Run-Case 'Reported corrupted greeting plus alias and omitted conjunction resolves together' {
        $script:fixtureTargetTitle='声伴 v0.6.18 · 免唤醒架构与实现'
        Speak-SyntheticUtterance '你好帅喂，切换到申办0.6.18免唤醒架构实现。'
        $match=Complete-PureMatcher
        Assert-That ($match.requiresConfirmation -and $match.query -ceq '申办0.6.18免唤醒架构实现' -and $script:voiceTaskSwitch.Phase -eq 'choosing' -and $script:threadId -ceq $sourceId) 'Combined ASR deviations failed recall or changed binding early.'
        Finish-SyntheticFeedback
        Speak-SyntheticUtterance '是的。'
        Complete-TargetRead
        Assert-NoOrdinarySend
        Finish-SyntheticFeedback
        Speak-SyntheticUtterance '这是目标切换后的合成普通消息。'
        $sends=@($script:bridgeRequests | Where-Object {$_.action -eq 'send'})
        Assert-That ($sends.Count -eq 1 -and $sends[0].threadId -ceq $targetId) 'Following speech used the old destination.'
        Complete-FakeSend;Tick-And-AssertHealthy
    }
    Run-Case 'Natural object-between and conversational suffix forms stay local' {
        $script:fixtureTargetTitle='声伴 v0.6.18 · 免唤醒架构与实现'
        Speak-SyntheticUtterance '切换任务到0.6.18。'
        $match=Complete-PureMatcher
        Assert-That ($match.query -ceq '0.6.18' -and $script:bridgeJob.Purpose -eq 'voice-bind') 'Object-between switch syntax did not start the validated local bind.'
        Complete-TargetRead
        Assert-NoOrdinarySend
    }
    Run-Case 'Trailing this-dialogue marker is not kept in the title query' {
        $script:fixtureTargetTitle='高斯泼溅'
        Speak-SyntheticUtterance '切到高斯泼溅这个对话。'
        $match=Complete-PureMatcher
        Assert-That ($match.query -ceq '高斯泼溅' -and $script:bridgeJob.Purpose -eq 'voice-bind') 'Conversational suffix leaked into the title query.'
        Complete-TargetRead
        Assert-NoOrdinarySend
    }
    Run-Case 'Corrupted no-comma greeting is clarified locally instead of discarding its prefix' {
        Speak-SyntheticUtterance '你好小班帮我换到0.6.18任务。'
        Assert-That ($script:lastLocalCommand -eq 'clarifyTaskSwitch' -and -not $InputBox.Text -and -not $script:voiceTaskSwitch) 'No-comma corrupted greeting was sent or executed.'
        Assert-NoOrdinarySend
    }
    Run-Case 'Recovered greeting must confirm even a literal unique version' {
        $script:fixtureTargetTitle='声伴 v0.6.18 · 免唤醒架构与实现'
        Speak-SyntheticUtterance '你好喂，切到0.6.18任务。'
        $match=Complete-PureMatcher
        Assert-That (-not $match.requiresConfirmation -and $script:voiceTaskSwitch.Phase -eq 'choosing' -and -not $script:bridgeJob) 'Greeting uncertainty was lost after literal matching.'
        Assert-NoOrdinarySend
    }
    Run-Case 'Unparsed imperative stays local without blocking the next wake with a draft' {
        Speak-SyntheticUtterance '喂喂，切换到0.6.18任务。'
        Assert-That ($script:lastLocalCommand -eq 'clarifyTaskSwitch' -and -not $InputBox.Text -and -not $script:voiceTaskSwitch -and $script:threadId -ceq $sourceId) 'Unresolved command did not settle safely.'
        Assert-NoOrdinarySend
        Finish-SyntheticFeedback
        Speak-SyntheticUtterance '切到6.17。'
        [void](Complete-PureMatcher)
        Complete-TargetRead
        Assert-NoOrdinarySend
    }
    Run-Case 'Reported product alias utterance stays local and binds only after target read' {
        Speak-SyntheticUtterance '把任务切到这个申办0.6.17。'
        Assert-That ($script:localCommandCount -eq 1 -and $script:bridgeRequests[0].query -ceq '申办0.6.17' -and -not $InputBox.Text) 'Reported object-first command was not consumed with its exact query.'
        $match=Complete-PureMatcher
        Assert-That ($match.matchType -eq 'unique' -and $match.matchMethod -eq 'known_alias' -and $script:threadId -ceq $sourceId) 'Known alias did not uniquely match, or switched before live read.'
        Assert-That ($script:voiceTaskSwitch.Phase -eq 'choosing' -and -not $script:bridgeJob) 'Approximate alias started a read without confirmation.'
        Finish-SyntheticFeedback
        Speak-SyntheticUtterance '是的。'
        Complete-TargetRead
        Assert-NoOrdinarySend
    }
    Run-Case 'Unnamed targets prevent a false unique binding and explain missing recall' {
        Speak-SyntheticUtterance '切到6.17。'
        Complete-SyntheticJob ([pscustomobject]@{ok=$true;query='6.17';matchType='unique';matchMethod='contains';requiresConfirmation=$true;missingTitleCount=1;threads=@([pscustomobject]@{threadId=$targetId;title=$script:fixtureTargetTitle})})
        Assert-That ($script:voiceTaskSwitch.Phase -eq 'choosing' -and -not $script:bridgeJob -and $script:localCommandMessage.Contains('名称为空')) 'Incomplete task names silently auto-bound the visible candidate.'
        Finish-SyntheticFeedback
        Speak-SyntheticUtterance '不是。'
        Finish-SyntheticFeedback
        Speak-SyntheticUtterance '切到免唤醒架构任务。'
        Complete-SyntheticJob ([pscustomobject]@{ok=$true;query='免唤醒架构';matchType='none';missingTitleCount=1;threads=@()})
        Assert-That ($script:threadId -ceq $sourceId -and $script:localCommandMessage.Contains('名称为空') -and -not $InputBox.Text) 'No-match result hid missing names or blocked the next wake.'
        Assert-NoOrdinarySend
    }
    Run-Case 'Reported 6.117 remains unmatched and is explained locally without version guessing' {
        Speak-SyntheticUtterance '把任务切到6.117。'
        $match=Complete-PureMatcher
        Assert-That ($match.matchType -eq 'none' -and $script:threadId -ceq $sourceId -and -not $script:bridgeJob -and -not $script:voiceTaskSwitch) 'Wrong version was guessed or left a pending bind.'
        Assert-That ($script:localCommandCount -eq 1 -and $script:localCommandMessage.Contains('6.117')) 'No-match feedback omitted the exact recognized version.'
        Assert-NoOrdinarySend
    }
    Run-Case 'Bare 6.17 binds and the following ordinary spoken message uses only the new ID' {
        Speak-SyntheticUtterance '把任务切到6.17。'
        $match=Complete-PureMatcher
        Assert-That ($match.matchType -eq 'unique') 'Bare version did not resolve uniquely.'
        Complete-TargetRead
        Assert-NoOrdinarySend
        Finish-SyntheticFeedback
        Speak-SyntheticUtterance '这里是合成普通语音，不访问任何真实聊天。'
        $sends=@($script:bridgeRequests | Where-Object {$_.action -eq 'send'})
        Assert-That ($sends.Count -eq 1 -and $sends[0].threadId -ceq $targetId -and $sends[0].text -ceq '这里是合成普通语音，不访问任何真实聊天。') 'The next utterance did not preserve its text and newly confirmed destination.'
        Complete-FakeSend;Tick-And-AssertHealthy
        Assert-That ($script:sent -eq 1 -and -not $InputBox.Text) 'Synthetic send receipt did not settle once.'
    }
    Run-Case 'Same-version ambiguity shows choices without selecting or reading a target' {
        Speak-SyntheticUtterance '把任务切到6.17。'
        $match=Complete-PureMatcher -Ambiguous
        Assert-That ($match.matchType -eq 'ambiguous' -and $script:threadId -ceq $sourceId -and $script:voiceTaskSwitch.Phase -eq 'choosing') 'Ambiguous versions selected a destination.'
        Assert-That ($script:selectionShown -eq 1 -and $TaskCombo.Items.Count -eq 2 -and @($script:bridgeRequests | Where-Object {$_.action -eq 'read'}).Count -eq 0) 'Ambiguous lookup did not present choices or performed premature validation.'
        Assert-NoOrdinarySend
    }
    Run-Case 'More than five matches reports the full count and safely distinguishes duplicate titles' {
        Speak-SyntheticUtterance '把任务切到6.17。'
        $items=@(
            [pscustomobject]@{threadId=$targetId;title='声伴 v0.6.17';cwd='C:\projects\alpha'},
            [pscustomobject]@{threadId=$thirdId;title='声伴 v0.6.17';cwd='C:\projects\beta'},
            [pscustomobject]@{threadId='44444444-4444-4444-8444-444444444444';title='声伴 v0.6.17 · 三';cwd='C:\projects\three'},
            [pscustomobject]@{threadId='55555555-5555-4555-8555-555555555555';title='声伴 v0.6.17 · 四';cwd='C:\projects\four'},
            [pscustomobject]@{threadId='66666666-6666-4666-8666-666666666666';title='声伴 v0.6.17 · 五';cwd='C:\projects\five'}
        )
        Complete-SyntheticJob ([pscustomobject]@{ok=$true;query='6.17';matchType='ambiguous';matchMethod='contains';totalMatches=7;threads=$items})
        Assert-That ($script:voiceTaskSwitch.Phase -eq 'choosing' -and $script:voiceTaskSwitch.CandidatesTruncated -and $script:voiceTaskSwitch.TotalMatches -eq 7) 'Truncated result metadata was not retained.'
        Assert-That ($script:localCommandMessage.Contains('共找到7个') -and $script:localCommandMessage.Contains('只列前5个') -and $script:localCommandMessage.Contains('缩小任务关键词')) 'Truncated choices were presented as though complete.'
        Assert-That ($script:localCommandMessage.Contains('alpha') -and $script:localCommandMessage.Contains('beta') -and -not $script:localCommandMessage.Contains('C:\projects')) 'Duplicate titles lacked a safe directory-leaf distinction or exposed a full path.'
        Assert-NoOrdinarySend
    }
    Run-Case 'Different long titles with the same spoken prefix use distinct directory leaves' {
        Speak-SyntheticUtterance '把任务切到6.17。'
        $prefix=('同'*40)
        $items=@(
            [pscustomobject]@{threadId=$targetId;title=$prefix+'甲';cwd='C:\projects\alpha'},
            [pscustomobject]@{threadId=$thirdId;title=$prefix+'乙';cwd='C:\projects\beta'}
        )
        Complete-SyntheticJob ([pscustomobject]@{ok=$true;query='6.17';matchType='ambiguous';matchMethod='contains';totalMatches=2;threads=$items})
        Assert-That ($script:localCommandMessage.Contains('alpha') -and $script:localCommandMessage.Contains('beta')) 'Truncated spoken labels collided without directory-leaf disambiguation.'
        Assert-NoOrdinarySend
    }
    Run-Case 'Colliding long labels and directory leaves fall back to distinct task IDs' {
        Speak-SyntheticUtterance '把任务切到6.17。'
        $prefix=('同'*40)
        $items=@(
            [pscustomobject]@{threadId='11111111-1111-4111-8111-aaaaaaaaaaaa';title=$prefix+'甲';cwd='C:\one\shared'},
            [pscustomobject]@{threadId='22222222-2222-4222-8222-aaaaaaaaaaaa';title=$prefix+'乙';cwd='D:\two\shared'}
        )
        Complete-SyntheticJob ([pscustomobject]@{ok=$true;query='6.17';matchType='ambiguous';matchMethod='contains';totalMatches=2;threads=$items})
        Assert-That ($script:localCommandMessage.Contains('任务编号末') -and -not $script:localCommandMessage.Contains('末八位') -and $script:localCommandMessage.Contains('1-aaaaaaaaaaaa') -and $script:localCommandMessage.Contains('2-aaaaaaaaaaaa')) 'Same-leaf candidates did not expand beyond a colliding eight-character ID suffix.'
        Assert-That (-not $script:localCommandMessage.Contains('C:\one') -and -not $script:localCommandMessage.Contains('D:\two')) 'Candidate disambiguation exposed a full path.'
        Assert-NoOrdinarySend
    }
    Run-Case 'Missing candidate directories still receive distinct safe identifiers' {
        Speak-SyntheticUtterance '把任务切到6.17。'
        $prefix=('同'*40)
        $items=@(
            [pscustomobject]@{threadId='77777777-7777-4777-8777-111111111111';title=$prefix+'甲'},
            [pscustomobject]@{threadId='88888888-8888-4888-8888-222222222222';title=$prefix+'乙'}
        )
        Complete-SyntheticJob ([pscustomobject]@{ok=$true;query='6.17';matchType='ambiguous';matchMethod='contains';totalMatches=2;threads=$items})
        Assert-That ($script:localCommandMessage.Contains('11111111') -and $script:localCommandMessage.Contains('22222222')) 'Candidates without directories were not distinguishable by safe IDs.'
        Assert-NoOrdinarySend
    }
    Run-Case 'A same-ID rename during live validation preserves the old target and requires reconfirmation' {
        Speak-SyntheticUtterance '把任务切到申办6.17。'
        [void](Complete-PureMatcher)
        Finish-SyntheticFeedback
        Speak-SyntheticUtterance '是的。'
        Assert-That ($script:bridgeJob.Purpose -eq 'voice-bind') 'Confirmed candidate did not start live validation.'
        Complete-SyntheticJob ([pscustomobject]@{ok=$true;threadId=$targetId;title='已改名的任务';cwd='C:\synthetic-target';rolloutPath=$targetPath;status='idle';archived=$false;bindingState='active';hostId='local'})
        Assert-That ($script:threadId -ceq $sourceId -and -not $script:voiceTaskSwitch -and $script:localCommandMessage.Contains('显示名称已改变') -and $script:localCommandMessage.Contains('再次确认')) 'Same-ID rename silently bound the changed display identity.'
        Assert-NoOrdinarySend
    }
    Run-Case 'Context experiment asks for a direct reply only after its prompt finishes' {
        Speak-SyntheticUtterance '把任务切到申办6.17。'
        $script:noWakeMode='context'
        [void](Complete-PureMatcher)
        Assert-That ($script:voiceTaskSwitch.Phase -eq 'choosing' -and $script:localCommandMessage.Contains('朗读结束后直接说') -and -not $script:localCommandMessage.Contains('唤醒后')) 'Context mode gave a wake-only confirmation instruction.'
        Assert-NoOrdinarySend
    }
    Run-Case 'Context prompt exposes a real fallback while creation status is unknown' {
        Speak-SyntheticUtterance '把任务切到申办6.17。'
        $script:noWakeMode='context'
        $script:voiceTaskCreate=@{Phase='unknown';CreationState='unknown';SendBlocked=$true;ConnectionAbandoned=$false;AutoBindAllowed=$false}
        [void](Complete-PureMatcher)
        Assert-That ($script:localCommandMessage.Contains('新建请求仍待核对') -and $script:localCommandMessage.Contains('设置里选择') -and $script:localCommandMessage.Contains('关闭免唤醒实验后再唤醒') -and -not $script:localCommandMessage.Contains('朗读结束后直接说')) 'Unknown creation promised an unavailable direct confirmation channel.'
        Assert-NoOrdinarySend
    }
    Run-Case 'Context prompt does not promise direct confirmation for an unreadable creation ledger' {
        Speak-SyntheticUtterance '把任务切到申办6.17。'
        $script:noWakeMode='context'
        $script:voiceTaskCreate=@{Phase='unavailable';SendBlocked=$true;AutoBindAllowed=$false}
        [void](Complete-PureMatcher)
        Assert-That ($script:localCommandMessage.Contains('新建请求仍待核对') -and $script:localCommandMessage.Contains('设置里选择') -and -not $script:localCommandMessage.Contains('朗读结束后直接说')) 'Unreadable creation ledger promised direct confirmation.'
        Assert-NoOrdinarySend
    }
    Run-Case 'Context prompt degrades for archived and unknown binding states' {
        Speak-SyntheticUtterance '把任务切到申办6.17。'
        $script:noWakeMode='context'
        $script:bindingAvailability='archived'
        [void](Complete-PureMatcher)
        Assert-That ($script:localCommandMessage.Contains('当前任务状态不可安全确认') -and $script:localCommandMessage.Contains('设置里选择') -and -not $script:localCommandMessage.Contains('朗读结束后直接说')) 'Archived binding promised direct confirmation.'
        $script:bindingAvailability='unknown'
        $instruction=Get-VoiceTaskConfirmationInstruction
        Assert-That ($instruction.Contains('当前任务状态不可安全确认') -and $instruction.Contains('关闭免唤醒实验后再唤醒')) 'Unknown binding omitted the real fallback entry.'
        Assert-NoOrdinarySend
    }
    Run-Case 'Context prompt degrades for a pending send and a retained draft' {
        Speak-SyntheticUtterance '把任务切到申办6.17。'
        $script:noWakeMode='context'
        [void](Complete-PureMatcher)
        $script:pendingUncertain='unknown-request'
        $instruction=Get-VoiceTaskConfirmationInstruction
        Assert-That ($instruction.Contains('发送结果仍待核对') -and $instruction.Contains('设置里选择') -and -not $instruction.Contains('朗读结束后直接说')) 'Pending send promised direct confirmation.'
        $script:pendingUncertain='';$InputBox.Text='保留草稿'
        $instruction=Get-VoiceTaskConfirmationInstruction
        Assert-That ($instruction.Contains('先处理未发送草稿') -and $instruction.Contains('关闭免唤醒实验后再唤醒')) 'Draft blocker omitted the real fallback entry.'
        Assert-NoOrdinarySend
    }
    Run-Case 'Observe mode never tells the user to use an unavailable ordinary wake channel' {
        Speak-SyntheticUtterance '把任务切到申办6.17。'
        $script:noWakeMode='observe'
        [void](Complete-PureMatcher)
        Assert-That ($script:localCommandMessage.Contains('仅试判') -and $script:localCommandMessage.Contains('设置里选择') -and $script:localCommandMessage.Contains('关闭免唤醒实验后再唤醒') -and -not $script:localCommandMessage.Contains('请再次唤醒后说')) 'Observe mode advertised an unavailable confirmation route.'
        Assert-NoOrdinarySend
    }
    Run-Case 'New input invalidates a late search response and preserves the new draft' {
        Speak-SyntheticUtterance '把任务切到6.17。'
        $oldJob=$script:bridgeJob
        $InputBox.Text='新的手动草稿'
        Complete-SyntheticJob ([pscustomobject]@{ok=$true;query='6.17';matchType='unique';threads=@([pscustomobject]@{threadId=$targetId;title='声伴 v0.6.17'})}) $oldJob
        Assert-That ($script:threadId -ceq $sourceId -and $InputBox.Text -ceq '新的手动草稿' -and -not $script:voiceTaskSwitch -and -not $script:bridgeJob) 'Late lookup rebound a task or changed newer input.'
        Assert-NoOrdinarySend
    }
    Run-Case 'New input invalidates a late target read without binding or clearing the draft' {
        Speak-SyntheticUtterance '把任务切到6.17。'
        [void](Complete-PureMatcher)
        $oldJob=$script:bridgeJob
        $InputBox.Text='读取期间的新草稿'
        Complete-SyntheticJob ([pscustomobject]@{ok=$true;threadId=$targetId;title='声伴 v0.6.17';rolloutPath=$targetPath;hostId='local';archived=$false;bindingState='active'}) $oldJob
        Assert-That ($script:threadId -ceq $sourceId -and $InputBox.Text -ceq '读取期间的新草稿' -and -not $script:voiceTaskSwitch) 'Late target read committed after newer input.'
        Assert-NoOrdinarySend
    }
    Run-Case 'Failed lookup remains a local failure and keeps the original destination' {
        Speak-SyntheticUtterance '把任务切到6.17。'
        Complete-SyntheticJob ([pscustomobject]@{ok=$false;error=[pscustomobject]@{message='Synthetic lookup failure'}})
        Assert-That ($script:threadId -ceq $sourceId -and -not $script:voiceTaskSwitch -and $script:localCommandMessage.Contains('查找失败')) 'Lookup failure changed the destination or lacked local feedback.'
        Assert-NoOrdinarySend
    }
    Run-Case 'Failed target read remains a local failure and keeps the original destination' {
        Speak-SyntheticUtterance '把任务切到6.17。'
        [void](Complete-PureMatcher)
        Complete-SyntheticJob ([pscustomobject]@{ok=$false;error=[pscustomobject]@{message='Synthetic target read failure'}})
        Assert-That ($script:threadId -ceq $sourceId -and -not $script:voiceTaskSwitch -and $script:localCommandMessage.Contains('无法读取')) 'Target read failure changed the destination or lacked local feedback.'
        Assert-NoOrdinarySend
    }
    Run-Case 'Reported mixed-script spelling and locative suffix ask before binding' {
        $script:fixtureTargetTitle='排查 Codex 重试与归档对话'
        Speak-SyntheticUtterance '把任务切换到排查codedex任务里。'
        $match=Complete-PureMatcher
        Assert-That ($match.requiresConfirmation -and $match.query -ceq '排查codedex' -and $script:voiceTaskSwitch.Phase -eq 'choosing' -and -not $script:bridgeJob) 'Misspelled title did not ask for confirmation.'
        Assert-That ($script:localCommandMessage.Contains($script:fixtureTargetTitle)) 'Confirmation did not name the actual candidate.'
        Assert-NoOrdinarySend
        Finish-SyntheticFeedback
        Speak-SyntheticUtterance '对。'
        Complete-TargetRead
        Assert-NoOrdinarySend
    }
    Run-Case 'Negative response cancels suggestion and preserves the original destination' {
        Speak-SyntheticUtterance '把任务切到申办6.17。'
        [void](Complete-PureMatcher)
        Finish-SyntheticFeedback
        Speak-SyntheticUtterance '不是。'
        Assert-That (-not $script:voiceTaskSwitch -and -not $script:bridgeJob -and $script:threadId -ceq $sourceId -and -not $InputBox.Text) 'Negative response did not cancel locally.'
        Assert-NoOrdinarySend
    }
    Run-Case 'Generic yes cannot choose between multiple tasks' {
        Speak-SyntheticUtterance '把任务切到6.17。'
        [void](Complete-PureMatcher -Ambiguous)
        Finish-SyntheticFeedback
        Speak-SyntheticUtterance '是的。'
        Assert-That ($script:voiceTaskSwitch.Phase -eq 'choosing' -and -not $script:bridgeJob -and $script:threadId -ceq $sourceId) 'Generic yes guessed one of several targets.'
        Assert-NoOrdinarySend
        Finish-SyntheticFeedback
        Speak-SyntheticUtterance '选择第一个。'
        Complete-TargetRead
        Assert-NoOrdinarySend
    }
    Run-Case 'Confirmation outside its source and deadline cannot bind a stale candidate' {
        Speak-SyntheticUtterance '把任务切到申办6.17。'
        [void](Complete-PureMatcher)
        $script:voiceTaskSwitch.ExpiresAt=[DateTime]::UtcNow.AddSeconds(-1)
        Assert-That (-not (Try-LocalAssistantCommand '是的')) 'Expired suggestion still accepted confirmation.'
        Assert-That (-not $script:bridgeJob -and $script:threadId -ceq $sourceId) 'Expired confirmation changed the destination.'
        $script:voiceTaskSwitch.ExpiresAt=[DateTime]::UtcNow.AddSeconds(30)
        $script:threadId=$thirdId
        Assert-That (-not (Try-LocalAssistantCommand '对')) 'A confirmation from another source was accepted.'
        Assert-NoOrdinarySend
    }
    Run-Case 'Changing the subject revokes the suggestion and retains the new draft' {
        Speak-SyntheticUtterance '把任务切到申办6.17。'
        [void](Complete-PureMatcher)
        $InputBox.Text='先解释一下这段代码'
        Assert-That (-not (Try-LocalAssistantCommand $InputBox.Text)) 'Ordinary text was consumed as a choice.'
        Assert-That (-not $script:voiceTaskSwitch -and $InputBox.Text -ceq '先解释一下这段代码' -and $script:threadId -ceq $sourceId) 'New topic lost its draft or left a stale suggestion.'
        Assert-That (-not (Try-LocalAssistantCommand '是的')) 'A later generic yes confirmed an obsolete suggestion.'
        Assert-NoOrdinarySend
    }
    $failed=@($script:results | Where-Object {-not $_.passed})
    [pscustomobject]@{ok=($failed.Count -eq 0);checks=$script:checks;passed=($script:results.Count-$failed.Count);failed=$failed.Count;cases=$script:results.ToArray();boundary='Production wake/question lifecycle and Tick -> ASR -> local routing -> task matching -> read/bind; synthetic devices, worker receipts and titles; pure Python matcher only; no real recording, Codex task or message.'} | ConvertTo-Json -Depth 5 -Compress
    if($failed.Count){throw ('Spoken task switch regression failures: '+$failed.Count)}
} finally {
    Close-DesktopShell $desktop
    $allowed=[IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\')+'\'
    foreach($path in @($script:fixtureFiles | Select-Object -Unique)) {
        $full=[IO.Path]::GetFullPath($path)
        if(-not $full.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Test cleanup escaped its uniquely owned fixture directory.'}
        if([IO.File]::Exists($full)){[IO.File]::Delete($full)}
    }
    if([IO.Directory]::Exists($fixtureRoot) -and [IO.Directory]::GetFileSystemEntries($fixtureRoot).Count -eq 0){[IO.Directory]::Delete($fixtureRoot)}
}
