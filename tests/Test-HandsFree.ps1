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
foreach ($name in @('Stop-Output','Test-FullDuplexReady','Safe-To-Play','Begin-Recording','Cancel-Recording','End-Recording','Send-Text','Apply-Thread')) {
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
function Remove-OwnedFiles($Paths) { foreach ($path in @($Paths)) { if ($path) { $script:removed += $path } } }
function Close-Job($Job,[switch]$Kill) { $script:killed += $Job }
function Save-Settings {}
function Sync-DesktopPreferences {}
function Update-DesktopDisplay {}
function Reconcile-PendingSends {}
function Sync-PendingSend {}
function Start-Bridge($Request,[string]$Purpose) { $script:bridgeRequests += $Request; return $true }
function Read-NewCompletedAnswers($Tail) { $items=$script:pendingAnswers; $script:pendingAnswers=@(); return $items }
function New-TranscriptTail([string]$Path) { return @{UserTurnVersion=0;Latest='Previous answer'} }
function Begin-Speech([string]$Text) {
    $script:speechInputs += $Text
    Add-Trace ('tts:queued:'+ $Text)
    $script:audioPath='mock-final-answer.mp3'
    [CodexReader.AudioPlayer]::Play($script:audioPath)
}
function Begin-Transcription([string]$WavePath,[bool]$SendAfter) {
    $path=Join-Path $fixtureRoot ([Guid]::NewGuid().ToString('N')+'.asr.json')
    @{ok=$script:asrSucceeds;text=$script:nextTranscript} | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
    $script:fixtureFiles.Add($path)
    $script:asrJob=@{Process=[pscustomobject]@{HasExited=$true;ExitCode=$(if($script:asrSucceeds){0}else{1})};Output=$path;Files=@($path,$WavePath);Generation=$script:voiceGeneration;ThreadId=$script:threadId;SendAfter=$SendAfter;Prefix=$script:recordPrefix;FromWake=$script:handsFreeCapture}
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
$tick=Get-ProductionHandler $assistantAst 'timer' 'Add_Tick'
function Click([string]$Name) {
    (Get-Variable -Name $Name -ValueOnly).RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
}
function Reset-Case {
    . $handsFreePath
    Initialize-TestDoubles
    $script:connected=$true; $script:threadId='11111111-1111-4111-8111-111111111111'
    $script:recMode='idle'; $script:armDue=[DateTime]::MaxValue
    $script:manualRecorder=$null; $script:echoQuestionCapture=$false; $script:bargeInEnabled=$false
    $script:ttsJob=$null; $script:asrJob=$null; $script:bridgeJob=$null
    $script:speechQueue=New-Object 'System.Collections.Generic.Queue[string]'
    $script:audioPath=''; $script:epoch=0; $script:ttsEpoch=-1
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

try {
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
