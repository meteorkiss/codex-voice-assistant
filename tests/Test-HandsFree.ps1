param(
    [string]$SourceRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'src'),
    [switch]$HelpersOnly
)

# Windows PowerShell 5.1 -STA; exercise production policy with asynchronous
# microphone doubles. Never open a real microphone, play sound, or send to Codex.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
namespace CodexReader {
    public static class AudioPlayer {
        public static int Stops;
        public static int CaptureOwners;
        private static string state = "closed";
        public static int ReadsUntilFinish = -1;
        public static bool FinishOnPlay;
        public static string State {
            get {
                if(ReadsUntilFinish==0) { state="stopped"; ReadsUntilFinish=-1; }
                else if(ReadsUntilFinish>0) ReadsUntilFinish--;
                return state;
            }
            set { state=value; ReadsUntilFinish=-1; }
        }
        public static readonly List<string> Played = new List<string>();
        public static void Stop() { Stops++; State = "closed"; }
        public static void Play(string path) {
            if(CaptureOwners != 0) throw new InvalidOperationException("TTS started before every owned microphone was released.");
            Played.Add(path); State = FinishOnPlay ? "stopped" : "playing";
        }
        public static void Finish() { State = "stopped"; }
        public static void Reset() { Stops = 0; CaptureOwners = 0; State = "closed"; FinishOnPlay=false; Played.Clear(); }
    }
}
'@

function Read-ProductionAst([string]$Path) {
    $tokens=$null; $errors=$null
    $tree=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ('Production parse error: '+$errors[0].Message) }
    return $tree
}
function Get-ProductionHandler($Tree,[string]$Control,[string]$Method) {
    $matches=@($Tree.FindAll({param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
            $node.Expression.Extent.Text -eq ('$'+$Control) -and $node.Member.Value -eq $Method
    },$true))
    if ($matches.Count -ne 1) { throw "Expected one handler: $Control.$Method" }
    return $matches[0].Arguments[0].ScriptBlock.GetScriptBlock()
}
function Assert-That([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Add-Trace([string]$Event) { $script:trace.Add($Event) }
function Set-FakeCaptureSnapshot {
    $wasActive=$script:mic.AnyCaptureActive
    $sessions=@()
    $owners=0
    if ($script:wakeListener.IsListening -or $script:wakeListener.IsStopping) {
        $owners++
        $sessions += [pscustomobject]@{Active=$true;ProcessId=$PID;ProcessName='powershell';SessionId='fake-wake'}
    }
    if ($script:recorder.IsRecording -or $script:recorder.IsStopping) {
        $owners++
        $sessions += [pscustomobject]@{Active=$true;ProcessId=$PID;ProcessName='powershell';SessionId='fake-recording'}
    }
    if ($script:externalCapture) {
        $sessions += [pscustomobject]@{Active=$true;ProcessId=98765;ProcessName='ExternalRecorder';SessionId='fake-external'}
    }
    [CodexReader.AudioPlayer]::CaptureOwners=$owners
    $script:mic.Sessions=$sessions
    $script:mic.AnyCaptureActive=($sessions.Count -gt 0)
    if (-not $wasActive -and $script:mic.AnyCaptureActive) { $script:mic.ActivationVersion++ }
    $script:mic.ScanCount++
}
function New-FakeWakeListener {
    $listener=[pscustomobject]@{IsListening=$false;IsStopping=$false;IsReady=$false;ActivationVersion=0L;Error='';AudioLevel=0;Starts=0;Stops=0;Disposed=$false;Phrase=''}
    $listener | Add-Member ScriptMethod Start {
        param([string]$Phrase)
        if ([CodexReader.AudioPlayer]::State -in @('playing','paused')) { throw 'Wake listener started during TTS.' }
        if ($script:recorder.IsRecording -or $script:recorder.IsStopping) { throw 'Wake listener started before question recorder released its mic.' }
        if ($this.IsListening -or $this.IsStopping) { throw 'Wake listener started twice.' }
        if ($this.Disposed) { throw 'Disposed wake listener restarted.' }
        $this.Starts++; $this.Phrase=$Phrase; $this.IsListening=$true; $this.IsReady=$true
        Add-Trace 'wake:start'; Set-FakeCaptureSnapshot
    }
    $listener | Add-Member ScriptMethod Stop {
        if ($this.IsListening -and -not $this.IsStopping) {
            $this.Stops++; $this.IsStopping=$true; $this.IsReady=$false
            Add-Trace 'wake:stop-requested'
        }
    }
    $listener | Add-Member ScriptMethod Release {
        $this.IsListening=$false; $this.IsStopping=$false; $this.IsReady=$false
        Add-Trace 'wake:released'; Set-FakeCaptureSnapshot
    }
    $listener | Add-Member ScriptMethod Activate {
        if (-not $this.IsListening -or $this.IsStopping) { throw 'Cannot activate an inactive wake listener.' }
        $this.ActivationVersion++; $this.IsStopping=$true; $this.IsReady=$false
        Add-Trace 'wake:activated'
    }
    $listener | Add-Member ScriptMethod Dispose {
        $this.Stop(); $this.Release(); $this.Disposed=$true
        Add-Trace 'wake:disposed'
    }
    return $listener
}
function New-FakeRecorder {
    $capture=[pscustomobject]@{IsRecording=$false;IsStopping=$false;Level=0;Error='';StartedUtc=[DateTime]::MinValue;LastVoiceUtc=[DateTime]::MinValue;Starts=0;Cancels=0;StoppedPath='';Disposed=$false}
    $capture | Add-Member ScriptMethod Start {
        if ([CodexReader.AudioPlayer]::State -in @('playing','paused')) { throw 'Question recording started during TTS.' }
        if ($script:wakeListener.IsListening -or $script:wakeListener.IsStopping) { throw 'Question recorder overlapped wake capture.' }
        $this.Starts++; $this.IsRecording=$true; $this.StartedUtc=[DateTime]::UtcNow; $this.LastVoiceUtc=[DateTime]::MinValue
        Add-Trace 'record:start'; Set-FakeCaptureSnapshot
    }
    $capture | Add-Member ScriptMethod StopToFileAsync {
        param([string]$Path)
        $this.StoppedPath=$Path; $this.IsStopping=$true
        Add-Trace 'record:stop-requested'
    }
    $capture | Add-Member ScriptMethod Cancel {
        $this.Cancels++
        if ($this.IsRecording) { $this.IsStopping=$true }
        Add-Trace 'record:cancel-requested'
    }
    $capture | Add-Member ScriptMethod Release {
        $this.IsRecording=$false; $this.IsStopping=$false
        if ($this.StoppedPath) {
            [IO.File]::WriteAllBytes($this.StoppedPath,(New-Object byte[] 44))
            $script:fixtureFiles.Add($this.StoppedPath)
        }
        Add-Trace 'record:released'; Set-FakeCaptureSnapshot
    }
    $capture | Add-Member ScriptMethod Dispose {
        $this.Cancel(); $this.Release(); $this.Disposed=$true
        Add-Trace 'record:disposed'
    }
    return $capture
}

function Initialize-TestDoubles {
    [CodexReader.AudioPlayer]::Reset()
    $script:trace=New-Object 'System.Collections.Generic.List[string]'
    $script:externalCapture=$false
    $script:mic=[pscustomobject]@{Ready=$true;AnyCaptureActive=$false;LastError='';ActivationVersion=0L;ScanCount=1L;Sessions=@();Disposed=$false}
    $script:mic | Add-Member ScriptMethod Dispose { $this.Ready=$false; $this.Disposed=$true }
    $script:wakeListener=New-FakeWakeListener
    $script:recorder=New-FakeRecorder
}

. (Join-Path $SourceRoot 'NoWakeConversation.ps1')

if ($HelpersOnly) {
    Initialize-TestDoubles
    Write-Output 'Hands-free test doubles initialized; behavior scenarios have not run.'
    return
}

$script:checks=0
$script:workspace=Split-Path $SourceRoot -Parent
$script:fixtureRoot=Join-Path $workspace ('work\tests\handsfree-'+[Guid]::NewGuid().ToString('N'))
$script:fixtureFiles=New-Object 'System.Collections.Generic.List[string]'
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$script:TestMode=$true; $script:PreviewPath=$null
$assistantAst=Read-ProductionAst (Join-Path $SourceRoot 'Assistant.ps1')
$handsFreePath=Join-Path $SourceRoot 'HandsFree.ps1'
[void](Read-ProductionAst $handsFreePath)
foreach ($name in @('Stop-Output','Test-FullDuplexReady','Safe-To-Play','Begin-Recording','Cancel-Recording','End-Recording','Send-Text','Apply-Thread','Read-BoundTaskAnswers')) {
    $definition=$assistantAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if (-not $definition) { throw "Production function missing: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
. (Join-Path $SourceRoot 'reader-core.ps1')
. $handsFreePath
. (Join-Path $SourceRoot 'DesktopController.ps1')
. (Join-Path $SourceRoot 'VoiceCommands.ps1')
. (Join-Path $SourceRoot 'TaskSwitch.ps1')
. (Join-Path $SourceRoot 'TaskCreate.ps1')
. (Join-Path $SourceRoot 'LocalCommands.ps1')
$ledgerAst=Read-ProductionAst (Join-Path $SourceRoot 'PendingSends.ps1')
$receiptDefinition=$ledgerAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-SendReceiptState'},$true)
. ([scriptblock]::Create($receiptDefinition.Extent.Text))
$pendingFunctions=@{}
foreach ($name in @('Sync-PendingSend','Clear-PendingSend','Set-PendingSend')) {
    $definition=$ledgerAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
    $pendingFunctions[$name]=(Get-Item ('Function:'+ $name)).ScriptBlock
}
# Persistence alone is in-memory; new regressions use the actual ledger state
# transitions, unlike the original bridge double that never set the send lock.
function Save-PendingSends {}
function Remove-OwnedFiles($Paths) { foreach ($path in @($Paths)) { if ($path) { $script:removed += $path } } }
function Close-Job($Job,[switch]$Kill) { $script:killed += $Job }
function Save-Settings {}
function Sync-DesktopPreferences {}
function Update-DesktopDisplay {}
function Reconcile-PendingSends {}
function Sync-PendingSend { if ($script:exercisePendingLedger) { & $pendingFunctions['Sync-PendingSend'] } }
function Clear-PendingSend([string]$TargetThreadId) {
    $script:clearedSends += $TargetThreadId
    if ($script:exercisePendingLedger) { & $pendingFunctions['Clear-PendingSend'] $TargetThreadId }
}
function Start-Bridge($Request,[string]$Purpose) {
    $script:bridgeRequests += $Request
    if ($script:holdBridge) {
        $path=Join-Path $fixtureRoot ([Guid]::NewGuid().ToString('N')+'.bridge-result.json')
        $script:fixtureFiles.Add($path)
        $script:bridgeJob=@{Purpose=$Purpose;Request=$Request;Output=$path;Files=@($path);Process=[pscustomobject]@{HasExited=$false;ExitCode=0};BindingGeneration=$script:bindingGeneration;InputGeneration=$script:voiceGeneration}
        if ($script:exercisePendingLedger) { Set-PendingSend @{threadId=$Request.threadId;requestId=$Request.requestId;text=$Request.text} }
    }
    return $true
}
function Complete-FakeSend([bool]$Accepted=$true) {
    $job=$script:bridgeJob
    $receipt=if ($Accepted) { @{ok=$true;accepted=$true;threadId=$job.Request.threadId;requestId=$job.Request.requestId} }
        else { @{ok=$false;error=@{uncertain=$false;message='Test rejection'}} }
    $receipt | ConvertTo-Json | Set-Content -LiteralPath $job.Output -Encoding UTF8
    $job.Process.HasExited=$true
}
function Read-NewCompletedAnswers($Tail) {
    if ($script:exitSendOnRead -and $script:bridgeJob) { $script:bridgeJob.Process.HasExited=$true; $script:exitSendOnRead=$false }
    $items=$script:pendingAnswers; $script:pendingAnswers=@(); return $items
}
function New-TranscriptTail([string]$Path) { return @{UserTurnVersion=0;Latest='Previous answer'} }
function Begin-Speech([string]$Text) {
    $script:speechInputs += $Text
    Add-Trace ('tts:queued:'+ $Text)
    $script:audioPath='mock-final-answer.mp3'
    [CodexReader.AudioPlayer]::Play($script:audioPath)
    if ($script:trackSpeechCompletion) { $script:spoken++; $script:lastSpeechEpoch=$script:epoch }
}
function Begin-Transcription([string]$WavePath,[bool]$SendAfter) {
    $path=Join-Path $fixtureRoot ([Guid]::NewGuid().ToString('N')+'.asr.json')
    @{ok=$script:asrSucceeds;text=$script:nextTranscript} | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
    $script:fixtureFiles.Add($path)
    $script:asrJob=@{Process=[pscustomobject]@{HasExited=$true;ExitCode=$(if($script:asrSucceeds){0}else{1})};Output=$path;Files=@($path,$WavePath);Generation=$script:voiceGeneration;ThreadId=$script:threadId;SendAfter=$SendAfter;Prefix=$script:recordPrefix;FromWake=$script:handsFreeCapture;FromFollowUp=$script:followUpCapture;FollowUpGeneration=$script:shortFollowUpGeneration}
    $script:recMode='transcribing'
    Add-Trace 'asr:started'
}

. (Join-Path $SourceRoot 'DesktopShell.ps1')
$script:desktop=New-DesktopShell
$script:window=$desktop.Window
foreach ($entry in $desktop.Controls.GetEnumerator()) { Set-Variable -Name $entry.Key -Value $entry.Value -Scope Script }
[void]$VoiceCombo.Items.Add([pscustomobject]@{name='Taiwan test voice';id='zh-TW-HsiaoChenNeural'});$VoiceCombo.SelectedIndex=0
$script:handsFreeItem=$null
foreach ($control in @('SpeakButton','SendButton','StopButton')) {
    (Get-Variable -Name $control -ValueOnly).Add_Click((Get-ProductionHandler $assistantAst $control 'Add_Click'))
}
$desktopAst=Read-ProductionAst (Join-Path $SourceRoot 'DesktopController.ps1')
$InputBox.Add_TextChanged((Get-ProductionHandler $desktopAst 'InputBox' 'Add_TextChanged'))
$tick=Get-ProductionHandler $assistantAst 'timer' 'Add_Tick'
function Click([string]$Name) {
    (Get-Variable -Name $Name -ValueOnly).RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
}
function Reset-Case {
    . $handsFreePath
    Initialize-TestDoubles
    $script:connected=$true; $script:threadId='11111111-1111-4111-8111-111111111111'
    $script:bindingReadError=''; $script:holdBridge=$false; $script:clearedSends=@()
    $script:exercisePendingLedger=$false; $script:bindingGeneration=1; $script:trackSpeechCompletion=$false; $script:exitSendOnRead=$false
    $script:recMode='idle'; $script:armDue=[DateTime]::MaxValue
    $script:manualRecorder=$null; $script:echoQuestionCapture=$false; $script:bargeInEnabled=$false
    $script:ttsJob=$null; $script:asrJob=$null; $script:bridgeJob=$null
    $script:speechQueue=New-Object 'System.Collections.Generic.Queue[string]'
    $script:audioPath=''; $script:epoch=0; $script:ttsEpoch=-1; $script:lastSpeechEpoch=-1
    $script:lastMicVersion=0L; $script:lastUserVersion=0; $script:interrupted=0
    $script:lastTailRead=[DateTime]::UtcNow; $script:lastPendingCheck=[DateTime]::UtcNow
    $script:lastStatusWrite=[DateTime]::MinValue; $script:tail=@{UserTurnVersion=0;Latest='Previous answer'}
    $script:pendingUncertain=''; $script:pendingSends=@{}; $script:submitAfterRecognition=$false
    $script:recordPath=''; $script:recordPrefix=''; $script:notice='Ready'; $script:errorText=''
    $script:busy=$false; $script:autoSend=$false; $script:autoRead=$true; $script:level=0.0
    $script:captionExpanded=$true; $script:captionsVisible=$false; $script:floatingVisible=$false; $script:pinned=$true
    $script:received=0; $script:spoken=0; $script:sent=0; $script:latest='Previous answer'
    $script:voiceId='zh-TW-HsiaoChenNeural'; $script:phaseClock=[Diagnostics.Stopwatch]::StartNew()
    $script:removed=@(); $script:killed=@(); $script:bridgeRequests=@()
    $script:speechInputs=@(); $script:pendingAnswers=@(); $script:nextTranscript='Recognized question'; $script:asrSucceeds=$true
    $script:TestMode=$true
    $script:PreviewPath=$null
    $script:TestCommandPath=$null; $script:TestTranscriptPath=$null; $script:TestAudioPath=$null; $script:StatusPath=$null
    $script:runtime=$fixtureRoot
    $InputBox.Text=''; $InputBox.IsReadOnly=$false
    Set-CaptionExpanded $true
}
function Tick-And-AssertHealthy {
    . $tick
    Assert-That (-not $script:errorText) ('Production timer failed: '+$script:errorText)
}
function Start-WakeCase {
    Set-HandsFree $true
    $script:nextWakeUtc=[DateTime]::UtcNow.AddMilliseconds(-1)
    Update-HandsFree ([DateTime]::UtcNow)
    Assert-That ($script:wakeListener.IsListening -and $script:wakeOwnsMicrophone) 'Enabling hands-free did not start its wake listener.'
    Assert-That ([CodexReader.AudioPlayer]::State -eq 'closed') 'Wake standby must not play sound.'
}
function Activate-And-ReleaseWake {
    $script:wakeListener.Activate()
    Update-HandsFree ([DateTime]::UtcNow)
    Assert-That ($script:handsFreePhase -eq 'releasing') 'A wake detection did not enter microphone release.'
    Assert-That ([CodexReader.AudioPlayer]::Played.Count -eq 0) 'Acknowledgement played before asynchronous microphone release.'
    $script:wakeListener.Release()
    Update-HandsFree ([DateTime]::UtcNow)
    Assert-That ($script:handsFreePhase -eq 'acknowledging') 'Released wake capture did not start the acknowledgement.'
    Assert-That ([CodexReader.AudioPlayer]::State -eq 'playing') 'The cached acknowledgement was not played.'
}
function Finish-AckAndStartQuestion {
    [CodexReader.AudioPlayer]::Finish()
    Tick-And-AssertHealthy
    Assert-That ($script:recMode -eq 'arming' -and $script:handsFreeCapture) 'Acknowledgement did not prepare automatic question recording.'
    $script:armDue=[DateTime]::UtcNow.AddMilliseconds(-1)
    Tick-And-AssertHealthy
    Assert-That ($script:recMode -eq 'listening' -and $script:recorder.IsRecording) 'Question capture did not begin after the guard delay.'
    Assert-That (-not $script:wakeListener.IsListening) 'Wake listening resumed during question capture.'
}
function Finish-QuestionAfterSpeech {
    $script:recorder.StartedUtc=[DateTime]::UtcNow.AddSeconds(-5)
    $script:recorder.LastVoiceUtc=[DateTime]::UtcNow.AddSeconds(-2.2)
    Tick-And-AssertHealthy
    Assert-That ($script:recMode -eq 'stopping' -and $script:recorder.IsStopping) 'Two seconds of silence after speech did not stop capture.'
    $script:recorder.Release()
    Tick-And-AssertHealthy
}
function Start-FakeFollowUpWait {
    Start-ShortFollowUpWait 'wake' $script:shortFollowUpGeneration $script:threadId $script:tail.UserTurnVersion
}
function Register-FakeFollowUpAnswer {
    Register-ShortFollowUpAnswer ([pscustomobject]@{UserTurnVersion=($script:tail.UserTurnVersion+1)})
}
function Open-ShortFollowUpCapture {
    $script:shortFollowUpEnabled=$true
    Start-FakeFollowUpWait
    Register-FakeFollowUpAnswer
    Assert-That ($script:shortFollowUp.Phase -eq 'waiting-playback') 'Eligible wake turn did not wait for answer playback.'
    $script:spoken++
    $script:lastSpeechEpoch=$script:epoch
    [CodexReader.AudioPlayer]::State='playing'
    Update-ShortFollowUp ([DateTime]::UtcNow)
    [CodexReader.AudioPlayer]::Finish()
    Update-ShortFollowUp ([DateTime]::UtcNow)
    Assert-That ($script:shortFollowUp.Phase -eq 'preparing' -and $script:recMode -eq 'arming' -and $script:followUpCapture) 'Natural answer completion did not prepare a follow-up capture.'
    $script:wakeListener.Release(); $script:armDue=[DateTime]::UtcNow.AddMilliseconds(-1)
    Tick-And-AssertHealthy
    Assert-That ($script:shortFollowUp.Phase -eq 'listening' -and $script:recMode -eq 'listening') 'Follow-up window did not become visibly active after microphone handoff.'
}

function Start-EarlyAnswerCase([string]$Source, [switch]$ExitDuringRead) {
    Reset-Case; Start-WakeCase
    $script:shortFollowUpEnabled=$true
    if ($Source -eq 'follow-up') { Open-ShortFollowUpCapture }
    $script:exercisePendingLedger=$true; $script:holdBridge=$true; $script:TestMode=$false
    $script:trackSpeechCompletion=$true
    if ($Source -eq 'follow-up') {
        $script:nextTranscript='提前回答的接话问题'
        $script:recorder.StartedUtc=[DateTime]::UtcNow.AddSeconds(-5)
        $script:recorder.LastVoiceUtc=[DateTime]::UtcNow.AddSeconds(-2.2)
        Tick-And-AssertHealthy; $script:recorder.Release(); Tick-And-AssertHealthy
    } else { $InputBox.Text='提前回答的唤醒问题'; Send-Text 'wake' }
    $script:tail.UserTurnVersion=$script:bridgeJob.UserTurnBaseline+1
    $script:pendingAnswers=@([pscustomobject]@{UserTurnVersion=$script:tail.UserTurnVersion;Text='先于回执到达的回答'})
    $script:lastTailRead=[DateTime]::MinValue
    if ($ExitDuringRead) { Complete-FakeSend; $script:bridgeJob.Process.HasExited=$false; $script:exitSendOnRead=$true }
    Tick-And-AssertHealthy
    Assert-That ($script:latest -ceq '先于回执到达的回答' -and $script:received -eq 1 -and $script:pendingAnswers.Count -eq 0) 'Early answer was not displayed and consumed exactly once.'
    Assert-That ($script:speechQueue.Count -eq 0 -and $script:speechInputs.Count -eq 0 -and -not $script:followUpCapture) 'Early answer played or opened capture before accepted receipt.'
}

try {
    # Reversed transport order, for both the initial wake and a later follow-up.
    foreach ($source in @('wake','follow-up')) {
        Start-EarlyAnswerCase $source -ExitDuringRead
        $script:wakeListener.Release(); Tick-And-AssertHealthy
        Assert-That ($script:shortFollowUp.Phase -eq 'waiting-playback' -and $script:speechInputs.Count -eq 1 -and -not $InputBox.Text) 'Worker exit between receipt check and tail read lost its early answer.'
        [CodexReader.AudioPlayer]::Finish(); Tick-And-AssertHealthy
        Assert-That ($script:followUpCapture -and $script:shortFollowUp.Phase -eq 'preparing') 'Worker-exit race failed to open the next follow-up.'
        foreach ($instant in @($false,$true)) {
            Start-EarlyAnswerCase $source
            foreach ($poll in 1..3) { Tick-And-AssertHealthy }
            $script:wakeListener.Release()
            [CodexReader.AudioPlayer]::FinishOnPlay=$instant
            Complete-FakeSend; Tick-And-AssertHealthy
            Assert-That (-not $InputBox.Text -and -not $script:pendingUncertain -and $script:sent -eq 1 -and $script:speechInputs.Count -eq 1) 'Early accepted answer was lost, duplicated or left its draft/ledger.'
            if (-not $instant) {
                Assert-That ($script:shortFollowUp.Phase -eq 'waiting-playback') 'Early answer was not associated with its playback.'
                [CodexReader.AudioPlayer]::Finish(); Tick-And-AssertHealthy
            }
            Assert-That ($script:followUpCapture -and $script:shortFollowUp.Phase -eq 'preparing') 'Early answer completion failed to open follow-up (including immediate completion).'
            $script:armDue=[DateTime]::UtcNow.AddMilliseconds(-1); Tick-And-AssertHealthy
            Assert-That ($script:recMode -eq 'listening' -and $script:shortFollowUp.Phase -eq 'listening' -and $script:bridgeRequests.Count -eq 1) 'Early answer did not reach listening or caused a repeated send.'
        }
        foreach ($outcome in @('rejected','unknown','target','binding','input','voice','token','draft','cancel','disabled','later-turn')) {
            Start-EarlyAnswerCase $source
            switch ($outcome) {
                'target' { $script:threadId='22222222-2222-4222-8222-222222222222' }
                'binding' { $script:bindingGeneration++ }
                'input' { $script:bridgeJob.InputGeneration-- }
                'voice' { $script:voiceGeneration++ }
                'token' { Close-ShortFollowUp }
                'draft' { $InputBox.Text='要保留的新草稿' }
                'cancel' { Stop-ShortFollowUpByUser }
                'disabled' { $script:shortFollowUpEnabled=$false; Close-ShortFollowUp -CancelCapture }
                'later-turn' { $script:tail.UserTurnVersion++; $script:lastUserVersion=$script:tail.UserTurnVersion }
            }
            $draft=$InputBox.Text
            if ($outcome -eq 'rejected') { Complete-FakeSend $false }
            elseif ($outcome -eq 'unknown') { $script:bridgeJob.Process.HasExited=$true }
            else { Complete-FakeSend }
            $script:wakeListener.Release(); Tick-And-AssertHealthy; Tick-And-AssertHealthy
            Assert-That (-not $script:shortFollowUp -and -not $script:followUpCapture -and $script:speechInputs.Count -eq 0 -and $script:bridgeRequests.Count -eq 1) ('Invalid early answer replayed or rearmed: '+$source+'/'+$outcome)
            if ($outcome -ne 'later-turn') { Assert-That ($InputBox.Text -ceq $draft) ('Invalid early receipt erased protected draft: '+$outcome) }
        }
    }

    # Exact race: the first half of a production timer tick observes playing;
    # the later generic audio cleanup observes stopped in the same tick.
    Reset-Case; Start-WakeCase; Activate-And-ReleaseWake
    [CodexReader.AudioPlayer]::ReadsUntilFinish=1
    Tick-And-AssertHealthy
    Assert-That ($script:handsFreePhase -eq 'acknowledging' -and [CodexReader.AudioPlayer]::State -eq 'stopped' -and $script:audioPath) 'Generic cleanup erased a short acknowledgement completion before its next state-machine tick.'
    Tick-And-AssertHealthy
    Assert-That ($script:recMode -eq 'arming' -and $script:handsFreeCapture) 'The preserved short acknowledgement did not enter question recording.'

    # Successful Play may already be naturally stopped before its first state read.
    Reset-Case; Start-WakeCase
    $script:wakeListener.Activate(); Update-HandsFree ([DateTime]::UtcNow)
    $script:wakeListener.Release(); [CodexReader.AudioPlayer]::FinishOnPlay=$true
    Update-HandsFree ([DateTime]::UtcNow)
    Assert-That ($script:handsFreePhase -eq 'acknowledging' -and $script:ackWasPlaying) 'An immediately completed acknowledgement was mistaken for failed playback.'
    Tick-And-AssertHealthy
    Assert-That ($script:recMode -eq 'arming' -and $script:handsFreeCapture) 'An immediately completed acknowledgement lost its recording transition.'

    # Echo capture stays active after a keyword. An interrupted acknowledgement
    # must stop that consumed keyword stream before attempting fresh standby.
    foreach($interruption in @('epoch','closed')) {
        Reset-Case; Start-WakeCase
        $script:handsFreePhase='acknowledging'; $script:ackWasPlaying=$true
        $script:ackEpoch=$script:epoch
        [CodexReader.AudioPlayer]::State='closed'
        if($interruption -eq 'epoch') { $script:epoch++ }
        Update-HandsFree ([DateTime]::UtcNow)
        Assert-That ($script:wakeListener.IsStopping -and $script:handsFreePhase -eq 'waiting' -and $script:recMode -eq 'idle') "Interrupted acknowledgement ($interruption) left a consumed echo listener latched."
        $script:wakeListener.Release(); $script:nextWakeUtc=[DateTime]::UtcNow.AddMilliseconds(-1)
        Update-HandsFree ([DateTime]::UtcNow)
        Assert-That ($script:wakeListener.Starts -eq 2 -and $script:wakeListener.IsListening) "Interrupted acknowledgement ($interruption) failed to start a fresh wake listener."
    }

    Reset-Case
    Start-WakeCase
    Activate-And-ReleaseWake
    Assert-That ($script:recorder.Starts -eq 0) 'Question capture started before the acknowledgement ended.'
    [CodexReader.AudioPlayer]::Finish()
    Update-HandsFree ([DateTime]::UtcNow)
    Assert-That ($script:recMode -eq 'arming' -and $script:handsFreeCapture) 'Acknowledgement completion did not prepare hands-free question recording.'
    Assert-That ($script:recorder.Starts -eq 0) 'The post-acknowledgement recording delay was skipped.'

    # Entire automatic loop, using production timer ASR-result and dispatch handling.
    Reset-Case; Start-WakeCase; Activate-And-ReleaseWake; Finish-AckAndStartQuestion
    $script:recorder.StartedUtc=[DateTime]::UtcNow.AddSeconds(-4)
    Tick-And-AssertHealthy
    Assert-That ($script:recMode -eq 'listening') 'Silence without prior speech caused an automatic send.'
    Set-FloatingVisible $false
    Assert-That ($script:recMode -eq 'listening' -and $script:recorder.Cancels -eq 0) 'Hiding the floating view cancelled an explicitly enabled hands-free recording.'
    $script:TestMode=$false # Only the in-memory Start-Bridge double is reachable.
    Finish-QuestionAfterSpeech
    Assert-That ($script:bridgeRequests.Count -eq 1) 'One spoken question must dispatch exactly one request.'
    Assert-That ($script:bridgeRequests[0].threadId -eq $script:threadId -and $script:bridgeRequests[0].text -eq 'Recognized question') 'Automatic dispatch changed the bound task or recognized text.'
    Tick-And-AssertHealthy
    Assert-That ($script:bridgeRequests.Count -eq 1) 'A later timer tick dispatched the same recognized question twice.'
    $InputBox.Text=''; $script:busy=$true # Successful bridge receipt, tested separately.
    $script:nextWakeUtc=[DateTime]::UtcNow.AddMilliseconds(-1)
    Update-HandsFree ([DateTime]::UtcNow)
    Assert-That ($script:wakeListener.IsListening) 'Wake standby did not resume while the app was processing.'
    $script:pendingAnswers=@([pscustomobject]@{Text='Final answer';UserTurnVersion=0})
    $script:lastTailRead=[DateTime]::MinValue
    Tick-And-AssertHealthy
    Assert-That ($script:wakeListener.IsStopping -and $script:speechQueue.Count -eq 1) 'Incoming answer was lost while releasing the wake listener.'
    Tick-And-AssertHealthy
    Assert-That ($script:speechQueue.Count -eq 1 -and $script:speechInputs.Count -eq 0) 'The queued answer was cleared or played before wake microphone release.'
    $script:wakeListener.Release()
    Tick-And-AssertHealthy
    Assert-That ($script:speechInputs.Count -eq 1 -and [CodexReader.AudioPlayer]::State -eq 'playing') 'The answer did not play after all microphone capture stopped.'
    $starts=$script:wakeListener.Starts; $stops=[CodexReader.AudioPlayer]::Stops
    Set-CaptionExpanded $false; Set-FloatingVisible $false
    $script:nextWakeUtc=[DateTime]::MinValue
    Tick-And-AssertHealthy
    Assert-That ($script:wakeListener.Starts -eq $starts -and [CodexReader.AudioPlayer]::State -eq 'playing' -and [CodexReader.AudioPlayer]::Stops -eq $stops) 'UI interaction interrupted TTS or restarted wake listening during playback.'
    $script:wakeListener.ActivationVersion++ # A late callback must not start a new cycle during TTS.
    Tick-And-AssertHealthy
    Assert-That ($script:wakeCount -eq 1 -and $script:recMode -eq 'idle') 'A stale keyword event self-activated while the answer was playing.'
    [CodexReader.AudioPlayer]::Finish(); Tick-And-AssertHealthy
    $script:nextWakeUtc=[DateTime]::UtcNow.AddMilliseconds(-1)
    Update-HandsFree ([DateTime]::UtcNow)
    Assert-That ($script:wakeListener.IsListening -and $script:wakeCount -eq 1) 'Answer completion did not return to fresh wake standby.'

    # Optional short follow-up is off by default and begins only after natural
    # playback completion of an explicitly woken turn.
    Reset-Case; Start-WakeCase
    Start-FakeFollowUpWait
    Assert-That (-not $script:shortFollowUp) 'Default-off follow-up unexpectedly armed a microphone window.'

    Reset-Case; Start-WakeCase; $script:shortFollowUpEnabled=$true; Start-FakeFollowUpWait; Register-FakeFollowUpAnswer
    $script:spoken++; $script:lastSpeechEpoch=$script:epoch; [CodexReader.AudioPlayer]::State='closed'
    Update-ShortFollowUp ([DateTime]::UtcNow)
    Assert-That ($script:shortFollowUp.Phase -eq 'preparing' -and $script:recMode -eq 'arming') 'An answer that finished between polls did not open the follow-up handoff.'

    Reset-Case; Start-WakeCase; $script:shortFollowUpEnabled=$true; Start-FakeFollowUpWait; Register-FakeFollowUpAnswer
    [CodexReader.AudioPlayer]::State='closed'; Update-ShortFollowUp ([DateTime]::UtcNow)
    Assert-That (-not $script:shortFollowUp -and $script:recMode -eq 'idle') 'Failed answer speech left a dormant follow-up window armed.'

    Reset-Case; Start-WakeCase; $script:shortFollowUpEnabled=$true; Start-FakeFollowUpWait; Register-FakeFollowUpAnswer
    $script:spoken++; $script:lastSpeechEpoch=$script:epoch; [CodexReader.AudioPlayer]::State='playing'; Update-ShortFollowUp ([DateTime]::UtcNow)
    Stop-Output; Update-ShortFollowUp ([DateTime]::UtcNow)
    Assert-That (-not $script:shortFollowUp -and $script:recMode -eq 'idle') 'Explicitly interrupted answer playback opened a follow-up window.'

    Reset-Case; Start-WakeCase; Open-ShortFollowUpCapture
    $script:recorder.StartedUtc=[DateTime]::UtcNow.AddSeconds(-7)
    Tick-And-AssertHealthy
    Assert-That (-not $script:shortFollowUp -and -not $script:followUpCapture -and $script:recMode -eq 'idle' -and $script:recorder.Cancels -eq 1) 'Idle follow-up timeout did not cancel exactly its own capture.'

    # Advance the policy clock past the original six-second deadline. Previously
    # tests only changed recorder timestamps and never expired session.Deadline.
    Reset-Case; Start-WakeCase; Open-ShortFollowUpCapture
    $captureStarted=$script:recorder.StartedUtc
    $script:recorder.LastVoiceUtc=$captureStarted.AddSeconds(5.8)
    Update-ShortFollowUp ($captureStarted.AddSeconds(6.1))
    Assert-That ($script:recMode -eq 'listening' -and $script:followUpCapture -and $script:recorder.Cancels -eq 0) 'Speech begun near six seconds was cancelled by the idle deadline.'
    $script:recorder.LastVoiceUtc=$captureStarted.AddSeconds(29)
    Update-ShortFollowUp ($captureStarted.AddSeconds(29.5))
    Assert-That ($script:recMode -eq 'listening' -and $script:shortFollowUp.Phase -eq 'listening') 'An ongoing follow-up sentence did not survive until its recording limit.'
    Update-ShortFollowUp ($captureStarted.AddSeconds(30.1))
    Assert-That ($script:recMode -eq 'stopping' -and $script:recorder.StoppedPath -and $script:recorder.Cancels -eq 0 -and -not $script:submitAfterRecognition) 'The thirty-second deadline discarded speech or prepared an automatic send instead of preserving a draft.'

    Reset-Case; Start-WakeCase; Open-ShortFollowUpCapture
    $script:recorder.StartedUtc=[DateTime]::UtcNow.AddSeconds(-31); $script:recorder.LastVoiceUtc=[DateTime]::UtcNow
    Tick-And-AssertHealthy
    Assert-That ($script:recMode -eq 'stopping' -and $script:shortFollowUp.Phase -eq 'recognizing' -and -not $script:submitAfterRecognition) 'Thirty-second follow-up limit did not preserve the sentence as an unsent draft.'
    $script:recorder.Release(); $script:TestMode=$false; Tick-And-AssertHealthy
    Assert-That ($InputBox.Text -eq 'Recognized question' -and -not $script:shortFollowUp -and $script:bridgeRequests.Count -eq 0) 'A maximum-length sentence was automatically sent after its ASR completed.'

    Reset-Case; Start-WakeCase; Open-ShortFollowUpCapture
    $script:nextTranscript='嗯'; $script:recorder.StartedUtc=[DateTime]::UtcNow.AddSeconds(-5); $script:recorder.LastVoiceUtc=[DateTime]::UtcNow.AddSeconds(-2.2)
    Tick-And-AssertHealthy; $script:recorder.Release(); Tick-And-AssertHealthy
    Assert-That ($InputBox.Text -eq '嗯' -and -not $script:shortFollowUp -and $script:bridgeRequests.Count -eq 0) 'Ambiguous follow-up was not retained as an unsent draft.'

    Reset-Case; Start-WakeCase; Open-ShortFollowUpCapture
    $script:nextTranscript='请继续解释第二种方法'; $script:recorder.StartedUtc=[DateTime]::UtcNow.AddSeconds(-5); $script:recorder.LastVoiceUtc=[DateTime]::UtcNow.AddSeconds(-2.2)
    Tick-And-AssertHealthy; $script:recorder.Release(); $script:TestMode=$false; Tick-And-AssertHealthy
    Assert-That ($script:bridgeRequests.Count -eq 1 -and $script:bridgeRequests[0].threadId -eq $script:threadId -and $script:bridgeRequests[0].text -eq '请继续解释第二种方法') 'Clear follow-up did not dispatch once to its captured task.'

    # Reported regression: Set-PendingSend marks even a healthy live request.
    # Carry two whole follow-up turns through ASR, the actual pending policy,
    # delayed acknowledgement, answer reading, speech and the next capture.
    Reset-Case; Start-WakeCase; Open-ShortFollowUpCapture
    $script:exercisePendingLedger=$true; $script:holdBridge=$true; $script:TestMode=$false
    foreach ($round in 1..2) {
        $spokenText='合成连续接话第'+$round+'轮'
        $script:nextTranscript=$spokenText
        $script:recorder.StartedUtc=[DateTime]::UtcNow.AddSeconds(-5); $script:recorder.LastVoiceUtc=[DateTime]::UtcNow.AddSeconds(-2.2)
        Tick-And-AssertHealthy; $script:recorder.Release(); Tick-And-AssertHealthy
        $token=$script:shortFollowUpGeneration
        Assert-That ($script:pendingUncertain -ceq $script:bridgeJob.Request.requestId -and $script:shortFollowUp.Phase -eq 'dispatching') 'Own live send prematurely closed follow-up.'
        foreach ($poll in 1..3) { Tick-And-AssertHealthy }
        Assert-That ($script:shortFollowUpGeneration -eq $token -and $InputBox.Text -ceq $spokenText -and $script:bridgeRequests.Count -eq $round) 'Waiting for a send cleared text, revoked its token or sent twice.'
        Complete-FakeSend; Tick-And-AssertHealthy
        Assert-That (-not $InputBox.Text -and -not $script:pendingUncertain -and $script:pendingSends.Count -eq 0 -and $script:shortFollowUp.Phase -eq 'waiting-answer') 'Accepted follow-up left a ghost draft or failed to wait for its answer.'
        $script:tail.UserTurnVersion++
        $script:pendingAnswers=@([pscustomobject]@{UserTurnVersion=$script:tail.UserTurnVersion;Text='合成回答第'+$round+'轮'})
        $script:lastTailRead=[DateTime]::MinValue
        Tick-And-AssertHealthy
        Assert-That ($script:speechInputs[-1] -ceq ('合成回答第'+$round+'轮') -and [CodexReader.AudioPlayer]::State -eq 'playing') 'The accepted follow-up answer was not read aloud.'
        $script:spoken++; $script:lastSpeechEpoch=$script:epoch
        Update-ShortFollowUp ([DateTime]::UtcNow)
        [CodexReader.AudioPlayer]::Finish(); Update-ShortFollowUp ([DateTime]::UtcNow)
        $script:armDue=[DateTime]::UtcNow.AddMilliseconds(-1); Tick-And-AssertHealthy
        Assert-That ($script:recMode -eq 'listening' -and $script:followUpCapture -and $script:shortFollowUp.Phase -eq 'listening') 'The next follow-up capture did not open after natural speech completion.'
    }
    Assert-That ($script:sent -eq 2 -and $script:bridgeRequests.Count -eq 2) 'Two follow-ups did not produce exactly two accepted sends.'

    # The narrow exemption never covers a different/unknown/stale request.
    foreach ($mismatch in @('request','target','binding','voice','token','text','worker','deadline','cancel')) {
        Reset-Case; Start-WakeCase; Open-ShortFollowUpCapture
        $script:exercisePendingLedger=$true; $script:holdBridge=$true; $script:TestMode=$false
        $script:nextTranscript='合成待回执内容'
        $script:recorder.StartedUtc=[DateTime]::UtcNow.AddSeconds(-5); $script:recorder.LastVoiceUtc=[DateTime]::UtcNow.AddSeconds(-2.2)
        Tick-And-AssertHealthy; $script:recorder.Release(); Tick-And-AssertHealthy
        switch ($mismatch) {
            'request' { $script:pendingSends[$script:threadId].requestId='different-request'; Sync-PendingSend }
            'target' { $script:bridgeJob.Request.threadId='22222222-2222-4222-8222-222222222222' }
            'binding' { $script:bindingGeneration++ }
            'voice' { $script:voiceGeneration++ }
            'token' { $script:bridgeJob.FollowUpGeneration-- }
            'text' { $InputBox.Text='用户的新草稿' }
            'worker' { $script:bridgeJob.Process.HasExited=$true }
            'deadline' { $script:shortFollowUp.Deadline=[DateTime]::UtcNow.AddSeconds(-1) }
            'cancel' { Stop-ShortFollowUpByUser }
        }
        if ($mismatch -eq 'worker') { Tick-And-AssertHealthy }
        else { Update-ShortFollowUp ([DateTime]::UtcNow) }
        Assert-That (-not $script:shortFollowUp -and $InputBox.Text -and $script:pendingUncertain -and $script:bridgeRequests.Count -eq 1) ('Uncertain or invalidated send bypassed protection: '+$mismatch)
        if ($mismatch -in @('text','cancel')) {
            $draft=$InputBox.Text
            Complete-FakeSend; Tick-And-AssertHealthy
            Assert-That ($InputBox.Text -ceq $draft -and -not $script:shortFollowUp -and -not $script:pendingUncertain) ('Late receipt erased protected text or reopened capture: '+$mismatch)
        }
    }

    foreach ($outcome in @('rejected','unknown')) {
        Reset-Case; Start-WakeCase; Open-ShortFollowUpCapture
        $script:exercisePendingLedger=$true; $script:holdBridge=$true; $script:TestMode=$false
        $script:nextTranscript='合成未确认内容'
        $script:recorder.StartedUtc=[DateTime]::UtcNow.AddSeconds(-5); $script:recorder.LastVoiceUtc=[DateTime]::UtcNow.AddSeconds(-2.2)
        Tick-And-AssertHealthy; $script:recorder.Release(); Tick-And-AssertHealthy
        if ($outcome -eq 'rejected') { Complete-FakeSend $false }
        else { $script:bridgeJob.Process.HasExited=$true }
        Tick-And-AssertHealthy; Tick-And-AssertHealthy
        Assert-That ($InputBox.Text -ceq '合成未确认内容' -and -not $script:shortFollowUp -and $script:bridgeRequests.Count -eq 1) ('Failed send lost text or retried: '+$outcome)
        Assert-That ([bool]$script:pendingUncertain -eq ($outcome -eq 'unknown')) ('Receipt classification lost its pending lock: '+$outcome)
    }

    # Closing after capture but before its completion invalidates the separate
    # follow-up token even if the ordinary recording generation has not changed.
    Reset-Case; Start-WakeCase; Open-ShortFollowUpCapture
    End-Recording $true; $script:recorder.Release(); Begin-Transcription $script:recordPath $true
    $oldVoiceGeneration=$script:voiceGeneration
    Close-ShortFollowUp
    $InputBox.Text='用户的新草稿'; $script:TestMode=$false
    Tick-And-AssertHealthy
    Assert-That ($script:voiceGeneration -eq $oldVoiceGeneration -and $InputBox.Text -eq '用户的新草稿' -and $script:bridgeRequests.Count -eq 0 -and -not $script:shortFollowUp) 'A stale follow-up ASR result overwrote or dispatched after its window closed.'

    Reset-Case; Start-WakeCase; Activate-And-ReleaseWake; Finish-AckAndStartQuestion
    End-Recording $true; $script:recorder.Release(); Begin-Transcription $script:recordPath $true
    Close-ShortFollowUp; $InputBox.Text='关闭后的新草稿'; $script:TestMode=$false
    Tick-And-AssertHealthy
    Assert-That ($InputBox.Text -eq '关闭后的新草稿' -and $script:bridgeRequests.Count -eq 0) 'A late original wake ASR bypassed the revoked follow-up token.'

    Reset-Case; Start-WakeCase; Open-ShortFollowUpCapture
    End-Recording $true; $script:recorder.Release()
    $script:bridgeJob=@{Purpose='list';Process=[pscustomobject]@{HasExited=$false}}
    Tick-And-AssertHealthy
    $oldIntent=$script:autoDispatch
    Assert-That ($oldIntent -and $oldIntent.VoiceSource -eq 'follow-up') 'The bridge-busy scenario did not preserve an undispatched follow-up.'
    Stop-ShortFollowUpByUser
    Assert-That (-not $script:autoDispatch -and $InputBox.Text -eq 'Recognized question') 'Explicit close did not revoke the waiting intent while preserving its draft.'
    $script:bridgeJob=$null; $script:autoDispatch=$oldIntent; $script:TestMode=$false
    Try-AutoDispatch
    Assert-That (-not $script:autoDispatch -and $script:bridgeRequests.Count -eq 0) 'Reintroduced stale follow-up intent was dispatched after close.'

    # Real send/receipt handlers run against a held, in-memory bridge. Revoking
    # follow-up must not erase the receipt ledger or permit a late rearm.
    Reset-Case; Start-WakeCase; $script:shortFollowUpEnabled=$true
    $script:holdBridge=$true; $script:TestMode=$false; $InputBox.Text='请解释这段内容'
    Send-Text 'wake'
    Assert-That ($null -ne $script:bridgeJob.FollowUpGeneration) 'Voice send did not snapshot its cancellation token.'
    Stop-ShortFollowUpByUser; $InputBox.Text='新的未发送草稿'
    Complete-FakeSend; Tick-And-AssertHealthy
    Assert-That ($script:clearedSends.Count -eq 1 -and $script:sent -eq 1 -and -not $script:shortFollowUp -and $InputBox.Text -eq '新的未发送草稿') 'A late accepted send either reopened follow-up, lost its ledger settlement, or cleared a newer draft.'

    foreach($accepted in @($true,$false)) {
        Reset-Case; Start-WakeCase; $script:shortFollowUpEnabled=$true
        $script:holdBridge=$true; $script:TestMode=$false; $InputBox.Text='之前的问题'
        Send-Text 'wake'; Close-ShortFollowUp; $InputBox.Text=''
        Start-FakeFollowUpWait; $newSession=$script:shortFollowUp
        Complete-FakeSend $accepted; Tick-And-AssertHealthy
        Assert-That ([object]::ReferenceEquals($script:shortFollowUp,$newSession)) 'An old send receipt replaced or closed a newer follow-up exchange.'
    }

    Reset-Case; Start-WakeCase; $script:shortFollowUpEnabled=$true
    $script:holdBridge=$true; $script:TestMode=$false; $InputBox.Text='当前问题'
    Send-Text 'wake'; Complete-FakeSend; Tick-And-AssertHealthy
    Assert-That ($script:shortFollowUp.Phase -eq 'waiting-answer') 'A current accepted voice send did not arm its answer wait.'
    Register-ShortFollowUpAnswer ([pscustomobject]@{UserTurnVersion=0})
    Assert-That ($script:shortFollowUp.Phase -eq 'waiting-answer') 'A previous answer was assigned to the new voice send.'
    Register-ShortFollowUpAnswer ([pscustomobject]@{UserTurnVersion=1})
    Assert-That ($script:shortFollowUp.Phase -eq 'waiting-playback') 'The matching answer could not enter playback wait.'
    Stop-ShortFollowUpByUser; Register-ShortFollowUpAnswer ([pscustomobject]@{UserTurnVersion=1})
    Assert-That (-not $script:shortFollowUp) 'A late answer recreated a closed follow-up exchange.'

    Reset-Case; Start-WakeCase; $script:shortFollowUpEnabled=$true; Start-FakeFollowUpWait
    Stop-Output '已停止朗读。'; Register-FakeFollowUpAnswer
    Assert-That (-not $script:shortFollowUp -and $script:recMode -eq 'idle') 'Explicit tray stop while waiting for an answer allowed a later follow-up window.'

    foreach($ending in @('draft','target','external','user','connection')) {
        Reset-Case; Start-WakeCase; Open-ShortFollowUpCapture
        switch($ending) {
            'draft' {$InputBox.Text='用户开始编辑';Update-ShortFollowUp ([DateTime]::UtcNow)}
            'target' {$script:threadId='22222222-2222-4222-8222-222222222222';Update-ShortFollowUp ([DateTime]::UtcNow)}
            'external' {$script:externalCapture=$true;Set-FakeCaptureSnapshot;Update-ShortFollowUp ([DateTime]::UtcNow)}
            'user' {Stop-ShortFollowUpByUser}
            'connection' {$script:bindingReadError='Missing transcript';Update-ShortFollowUp ([DateTime]::UtcNow)}
        }
        Assert-That (-not $script:shortFollowUp -and -not $script:followUpCapture -and $script:recMode -eq 'idle') ('Follow-up ending did not close safely: '+$ending)
    }

    # No-speech and empty-ASR paths never dispatch anything.
    Reset-Case; Start-WakeCase; Activate-And-ReleaseWake; Finish-AckAndStartQuestion
    $script:recorder.StartedUtc=[DateTime]::UtcNow.AddSeconds(-9)
    Tick-And-AssertHealthy
    Assert-That ($script:recMode -eq 'idle' -and $script:recorder.Cancels -gt 0 -and $script:bridgeRequests.Count -eq 0) 'The no-speech timeout did not cancel capture without sending.'
    $script:recorder.Release(); $script:nextWakeUtc=[DateTime]::UtcNow.AddMilliseconds(-1)
    Update-HandsFree ([DateTime]::UtcNow)
    Assert-That ($script:wakeListener.IsListening) 'No-speech cancellation did not recover to wake standby.'
    Reset-Case; Start-WakeCase; Activate-And-ReleaseWake; Finish-AckAndStartQuestion
    $script:nextTranscript=''
    Finish-QuestionAfterSpeech
    Assert-That ($script:autoSendPrepared -eq 0 -and $script:bridgeRequests.Count -eq 0 -and $InputBox.Text -eq '') 'An empty transcript created an automatic send.'

    # External capture remains protected even while our own listener keeps ANY active.
    Reset-Case; Start-WakeCase
    $version=$script:mic.ActivationVersion
    $script:externalCapture=$true; Set-FakeCaptureSnapshot
    Assert-That ($script:mic.ActivationVersion -eq $version) 'The double must model aggregate MicGuard activation semantics.'
    Update-HandsFree ([DateTime]::UtcNow)
    Assert-That ($script:wakeListener.IsStopping -and (Test-ExternalCapture)) 'External capture was missed while our wake microphone was already active.'
    $script:wakeListener.Release()
    Update-HandsFree ([DateTime]::UtcNow)
    Assert-That ([CodexReader.AudioPlayer]::Played.Count -eq 0 -and -not $script:wakeListener.IsListening) 'External capture allowed acknowledgement or wake restart.'

    # Disable and interruption cannot let an old acknowledgement reopen the mic.
    Reset-Case; Start-WakeCase; Activate-And-ReleaseWake
    Set-HandsFree $false
    [CodexReader.AudioPlayer]::Finish()
    Update-HandsFree ([DateTime]::UtcNow.AddSeconds(2))
    Assert-That (-not $script:handsFreeEnabled -and $script:recorder.Starts -eq 0 -and $script:recMode -eq 'idle') 'Disabling during acknowledgement allowed a late recording start.'
    Reset-Case; Start-WakeCase
    Set-HandsFree $false
    Assert-That ($script:wakeListener.IsStopping) 'Disabling did not request wake microphone shutdown.'
    $script:wakeListener.Release()
    Update-HandsFree ([DateTime]::UtcNow.AddSeconds(2))
    Assert-That (-not $script:wakeListener.IsListening -and -not $script:wakeOwnsMicrophone) 'Disabling left wake ownership active after release.'
    Reset-Case; Start-WakeCase; Activate-And-ReleaseWake; Finish-AckAndStartQuestion
    Set-HandsFree $false
    Assert-That ($script:recorder.Cancels -gt 0 -and $script:recMode -eq 'idle') 'Disabling hands-free did not cancel its question capture.'
    $script:recorder.Release(); Update-HandsFree ([DateTime]::UtcNow.AddSeconds(2))
    Assert-That ([CodexReader.AudioPlayer]::CaptureOwners -eq 0 -and -not $script:wakeListener.IsListening) 'Disabled mode reopened a microphone.'
    Reset-Case
    Begin-Recording
    $script:armDue=[DateTime]::UtcNow.AddMilliseconds(-1); Tick-And-AssertHealthy
    Set-FloatingVisible $false
    Assert-That ($script:recMode -eq 'listening' -and $script:recorder.Cancels -eq 0) 'Hiding the floating view must preserve manual recording under the new desktop contract.'

    # Manual recording must not arm while a timed-out no-wake capture still
    # owns the microphone. The old capture remains explicitly owned for retry.
    Reset-Case
    $stuckNoWake=[pscustomobject]@{Stops=0;IsRunning=$true}
    $stuckNoWake | Add-Member ScriptMethod Stop { $this.Stops++ }
    $stuckNoWake | Add-Member ScriptMethod StopAndWait { param([int]$TimeoutMs) return $false }
    $stuckNoWake | Add-Member ScriptMethod Dispose { throw 'Timed-out capture must not be disposed early.' }
    $script:noWakeMode='observe'; $script:noWakePhase='observing'; $script:noWakeCapture=$stuckNoWake; $script:noWakeAsrJob=$null
    Set-NoWakeMode context
    Assert-That ($script:noWakeMode -eq 'off' -and $script:noWakePhase -eq 'stopping' -and [object]::ReferenceEquals($script:noWakeCapture,$stuckNoWake)) 'A failed mode switch did not retain explicit no-wake ownership while failing closed.'
    Begin-Recording
    Assert-That ($script:recMode -eq 'idle' -and $script:noWakePhase -eq 'stopping' -and [object]::ReferenceEquals($script:noWakeCapture,$stuckNoWake)) 'Manual recording armed before a timed-out no-wake capture released its microphone.'
    $script:handsFreeEnabled=$true; $script:nextWakeUtc=[DateTime]::UtcNow.AddMilliseconds(-1)
    Update-HandsFree ([DateTime]::UtcNow)
    Assert-That (-not $script:wakeListener.IsListening -and $script:wakeListener.Starts -eq 0) 'Wake listening started while a fail-closed no-wake capture still owned the microphone.'
    $script:noWakeMode='off'; $script:noWakePhase='off'; $script:noWakeCapture=$null

    # Pending automatic sends are invalidated by edits, task changes, or generation changes.
    Reset-Case
    $InputBox.Text='Question'
    $script:autoDispatch=@{Generation=0;ThreadId=$script:threadId;Text='Question'}
    $script:bridgeJob=@{Purpose='list'}
    Try-AutoDispatch
    Assert-That ($script:autoDispatch -and $script:autoSendPrepared -eq 0) 'An undispatched intent was lost while the bridge was busy.'
    $script:bridgeJob=$null; $InputBox.Text='Edited question'
    Try-AutoDispatch
    Assert-That (-not $script:autoDispatch -and $script:autoSendPrepared -eq 0) 'Editing recognized text did not invalidate automatic dispatch.'
    $script:autoDispatch=@{Generation=0;ThreadId=$script:threadId;Text='Edited question'}
    $script:voiceGeneration++
    Try-AutoDispatch
    Assert-That (-not $script:autoDispatch -and $script:autoSendPrepared -eq 0) 'A stale recording generation was automatically dispatched.'
    $script:autoDispatch=@{Generation=$script:voiceGeneration;ThreadId='22222222-2222-4222-8222-222222222222';Text='Edited question'}
    Try-AutoDispatch
    Assert-That (-not $script:autoDispatch -and $script:autoSendPrepared -eq 0) 'A recognized question was dispatched to a changed task.'

    # A preserved draft intentionally pauses wake; the UI must say why, even
    # when Codex is busy or the hands-free toggle was just enabled again.
    Reset-Case; Start-WakeCase
    $InputBox.Text='用户尚未处理的草稿'; $script:busy=$true
    Tick-And-AssertHealthy
    Assert-That ($script:wakeListener.IsStopping -and $script:handsFreePhase -eq 'waiting') 'A draft no longer protects itself from automatic wake capture.'
    Assert-That ($StatusLabel.Text -like '有未发送草稿*唤醒已暂停*' -and $FooterHint.Text -like '草稿已保留*') 'A draft pause was hidden by busy/preparing-wake UI.'
    Assert-That ($InputBox.Text -ceq '用户尚未处理的草稿' -and $script:bridgeRequests.Count -eq 0) 'Displaying a draft pause changed or sent the draft.'
    $script:wakeListener.Release(); Set-HandsFree $true
    Tick-And-AssertHealthy
    Assert-That ($StatusLabel.Text -like '有未发送草稿*' -and -not $script:wakeListener.IsListening) 'Re-enabling hands-free hid the draft pause or overwrote protection.'
    $InputBox.Text=''; $script:nextWakeUtc=[DateTime]::MinValue
    Tick-And-AssertHealthy
    Assert-That ($script:wakeListener.IsListening -and $StatusLabel.Text -notlike '有未发送草稿*') 'Removing the draft did not recover wake listening and its UI.'

    # Physical release alone is insufficient until MicGuard observes a fresh idle scan.
    Reset-Case; Start-WakeCase
    $script:wakeListener.Activate(); Update-HandsFree ([DateTime]::UtcNow)
    $script:wakeListener.IsListening=$false; $script:wakeListener.IsStopping=$false
    [CodexReader.AudioPlayer]::CaptureOwners=0
    Update-HandsFree ([DateTime]::UtcNow)
    Assert-That ([CodexReader.AudioPlayer]::Played.Count -eq 0 -and $script:handsFreePhase -eq 'releasing') 'Acknowledgement ignored the stale MicGuard active snapshot.'
    Set-FakeCaptureSnapshot
    Update-HandsFree ([DateTime]::UtcNow)
    Assert-That ([CodexReader.AudioPlayer]::State -eq 'playing') 'A fresh idle microphone scan did not release the acknowledgement.'

    Reset-Case; Start-WakeCase; Activate-And-ReleaseWake
    Click 'StopButton'
    Update-HandsFree ([DateTime]::UtcNow)
    Assert-That ($script:recMode -eq 'idle' -and $script:recorder.Starts -eq 0 -and $script:handsFreePhase -eq 'waiting') 'Stopping the acknowledgement reopened the question microphone.'
    Reset-Case; Start-WakeCase; Activate-And-ReleaseWake
    Apply-Thread ([pscustomobject]@{rolloutPath=(Join-Path $SourceRoot 'Assistant.ps1');threadId='22222222-2222-4222-8222-222222222222';status='idle';title='Other task'})
    [CodexReader.AudioPlayer]::Finish()
    Update-HandsFree ([DateTime]::UtcNow)
    Assert-That ($script:recorder.Starts -eq 0 -and $script:recMode -eq 'idle') 'Changing task allowed a stale acknowledgement to start recording.'

    # Both user-selectable Taiwan voices use their own cached acknowledgement.
    Reset-Case; $script:voiceId='zh-TW-HsiaoYuNeural'
    Start-WakeCase; Activate-And-ReleaseWake
    Assert-That ([CodexReader.AudioPlayer]::Played[0].EndsWith('ack-zh-TW-HsiaoYuNeural.mp3')) 'Acknowledgement did not respect the selected Taiwan voice.'

    # Expected ASR/TTS failures must neither auto-send nor keep microphones latched.
    Reset-Case; Start-WakeCase; Activate-And-ReleaseWake; Finish-AckAndStartQuestion
    $script:recorder.StartedUtc=[DateTime]::UtcNow.AddSeconds(-5)
    $script:recorder.LastVoiceUtc=[DateTime]::UtcNow.AddSeconds(-2.2)
    Tick-And-AssertHealthy
    $script:asrSucceeds=$false; $script:recorder.Release()
    . $tick
    Assert-That ($script:errorText -and $script:recMode -eq 'idle' -and $script:autoSendPrepared -eq 0) 'ASR failure sent a request or left recording active.'
    $script:nextWakeUtc=[DateTime]::UtcNow.AddMilliseconds(-1)
    Update-HandsFree ([DateTime]::UtcNow)
    Assert-That ($script:wakeListener.IsListening) 'ASR failure prevented recovery to wake standby.'
    Reset-Case
    Set-HandsFree $true
    $script:ttsJob=@{Process=[pscustomobject]@{HasExited=$true;ExitCode=1};Audio='missing-failed-audio.mp3';Files=@()}
    Tick-And-AssertHealthy
    Assert-That (-not $script:ttsJob -and [CodexReader.AudioPlayer]::Played.Count -eq 0) 'Failed speech synthesis started playback or left a live job.'
    $script:nextWakeUtc=[DateTime]::UtcNow.AddMilliseconds(-1)
    Update-HandsFree ([DateTime]::UtcNow)
    Assert-That ($script:wakeListener.IsListening) 'TTS failure did not return to wake standby.'
    Reset-Case; Start-WakeCase; Activate-And-ReleaseWake
    $script:externalCapture=$true; Set-FakeCaptureSnapshot
    Tick-And-AssertHealthy
    Assert-That ([CodexReader.AudioPlayer]::State -ne 'playing' -and $script:recorder.Starts -eq 0) 'External microphone capture did not interrupt the acknowledgement.'

    # Exercise the actual window-close and final-disposal code without running a dispatcher.
    Reset-Case; Start-WakeCase
    $script:PreviewPath='test-no-dispatcher-shutdown'
    $timer=[pscustomobject]@{Stopped=$false}
    $timer | Add-Member ScriptMethod Stop { $this.Stopped=$true }
    $mutex=[pscustomobject]@{Disposed=$false}
    $mutex | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
    $ownsMutex=$false; $tray=$null; $menu=$null
    $onClosed=Get-ProductionHandler $assistantAst 'window' 'Add_Closed'
    . $onClosed
    Assert-That ($script:closing -and $script:wakeListener.IsStopping -and $timer.Stopped) 'Window close did not request wake shutdown and stop its timer.'
    $outerTry=$assistantAst.Find({param($node) $node -is [Management.Automation.Language.TryStatementAst] -and $node.Finally -and $node.Finally.Extent.Text.Contains('$mutex.Dispose()')},$true)
    if (-not $outerTry) { throw 'Production final disposal block was not found.' }
    $finalText=$outerTry.Finally.Extent.Text
    . ([scriptblock]::Create($finalText.Substring(1,$finalText.Length-2)))
    Assert-That ($script:wakeListener.Disposed -and $script:recorder.Disposed -and $script:mic.Disposed -and [CodexReader.AudioPlayer]::CaptureOwners -eq 0) 'Final shutdown did not dispose every microphone owner.'

    [pscustomobject]@{ok=$true;checks=$script:checks;coverage='production wake, recorder, ASR result, dispatch, playback and recovery state machine';realMicrophones=0;realCodexRequests=0} | ConvertTo-Json -Compress
} finally {
    Close-DesktopShell $desktop
    # Delete only files created in this test's GUID directory; never recurse.
    foreach ($path in $script:fixtureFiles) {
        if ([IO.Path]::GetFullPath($path).StartsWith([IO.Path]::GetFullPath($fixtureRoot)+'\',[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force }
    }
    if ([IO.Directory]::Exists($fixtureRoot) -and [IO.Directory]::GetFileSystemEntries($fixtureRoot).Count -eq 0) { [IO.Directory]::Delete($fixtureRoot) }
}
