param([string]$SourceRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'src'))

# Run with Windows PowerShell 5.1 -STA. This exercises the actual XAML,
# production handlers, functions, and timer with an in-memory audio/mic double.
# No microphone, speakers, Codex UI, subprocesses, or real sends are used.
$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $SourceRoot 'Assistant.ps1'
$source = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ('Production script does not parse: ' + $parseErrors[0].Message) }
if ($source -match 'InteractionGuard|lastInputVersion|InterruptionVersion') {
    throw 'Production must not load or poll a global input interruption hook.'
}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
Add-Type -TypeDefinition @'
namespace CodexReader {
    public static class AudioPlayer {
        public static int Stops;
        public static int Pauses;
        public static int Resumes;
        public static string State = "playing";
        public static double Level = 0;
        public static string RenderEndpointId = "mock-render-endpoint";
        public static void Stop() { Stops++; State = "closed"; }
        public static void Play(string path) { State = "playing"; }
        public static void Pause() { Pauses++; State = "paused"; }
        public static void Resume() { Resumes++; State = "playing"; }
        public static void Reset() { Stops = 0; Pauses = 0; Resumes = 0; State = "playing"; }
    }
}
'@
if (-not ('EchoCapture' -as [type])) {
    Add-Type -TypeDefinition 'public static class EchoCapture { public static string GetDefaultCaptureEndpointId() { return "mock-capture-endpoint"; } }'
}

function Get-ProductionHandler([string]$Control, [string]$Method, $Tree=$ast) {
    $matches = @($Tree.FindAll({
        param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
            $node.Expression.Extent.Text -in @(('$' + $Control), ('$desktop.Controls.' + $Control)) -and $node.Member.Value -eq $Method
    }, $true))
    if ($matches.Count -ne 1) { throw "Expected one $Control.$Method handler, got $($matches.Count)." }
    return $matches[0].Arguments[0].ScriptBlock.GetScriptBlock()
}
foreach ($name in @('Stop-Output','Test-FullDuplexReady','Safe-To-Play','Begin-Recording','Cancel-Recording','Send-Text','Apply-Thread','Read-BoundTaskAnswers')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Production function missing: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:TestMode=$true
$script:PreviewPath=$null
. (Join-Path $SourceRoot 'HandsFree.ps1')
. (Join-Path $SourceRoot 'DesktopController.ps1')
$script:productionUpdateDesktopDisplay=${function:Update-DesktopDisplay}
. (Join-Path $SourceRoot 'VoiceCommands.ps1')
. (Join-Path $SourceRoot 'TaskSwitch.ps1')
. (Join-Path $SourceRoot 'TaskCreate.ps1')
. (Join-Path $SourceRoot 'LocalCommands.ps1')
$readerSource=Get-Content -LiteralPath (Join-Path $SourceRoot 'reader-core.ps1') -Raw -Encoding UTF8
$readerAst=[Management.Automation.Language.Parser]::ParseInput($readerSource,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw 'reader-core does not parse.' }
$spokenTextDefinition=$readerAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertTo-SpokenText' },$true)
if (-not $spokenTextDefinition) { throw 'Production speech text filter is missing.' }
. ([scriptblock]::Create($spokenTextDefinition.Extent.Text))
$controllerSource=Get-Content -LiteralPath (Join-Path $SourceRoot 'DesktopController.ps1') -Raw -Encoding UTF8
$controllerAst=[Management.Automation.Language.Parser]::ParseInput($controllerSource,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw 'DesktopController does not parse.' }

# Mock only external side effects; cancellation policy remains production code.
function Remove-OwnedFiles($Paths) { foreach ($path in @($Paths)) { if ($path) { $script:removed += $path } } }
# WorkerLifecycle now owns cancelled synthesis audio as well as job files;
# exit/timeout behavior is covered with the real implementation in Infrastructure.
function Close-Job($Job, [switch]$Kill) { $script:jobKilled = [bool]$Kill; if($Kill){Remove-OwnedFiles @($Job.Audio)} }
function Start-Bridge($Request, [string]$Purpose) {
    if ($script:bridgeJob) { return $false }
    $script:bridgePurpose = $Purpose
    # A real in-flight shape matters: merely recording Purpose missed the AEC
    # shutdown caused by Update-HandsFree treating list/open as a send.
    $script:bridgeJob = @{ Purpose=$Purpose; Request=$Request; Process=[pscustomobject]@{HasExited=$false}; Started=[DateTime]::UtcNow }
    return $true
}
function Save-Settings {}
function Sync-DesktopPreferences {}
function Update-DesktopDisplay {}
function Reconcile-PendingSends {}
function Sync-PendingSend {}
function Read-NewCompletedAnswers($Tail) {}
function New-TranscriptTail([string]$Path) { return @{ UserTurnVersion = 0; Latest = 'Previous answer' } }
function Begin-Speech([string]$Text) {
    if (-not $script:allowMockSpeech) { throw 'Unexpected new speech worker in this regression test.' }
    $script:speechStarts++; $script:synthesizedText=$Text
    $script:ttsJob=@{Process=[pscustomobject]@{HasExited=$false};Audio='mock-synthesized-answer.mp3'}
}

. (Join-Path $SourceRoot 'DesktopShell.ps1')
function Show-DesktopSettings($Shell) { $script:settingsShown++ }
$script:desktop=New-DesktopShell
$script:window=$desktop.Window
foreach ($entry in $desktop.Controls.GetEnumerator()) { Set-Variable -Name $entry.Key -Value $entry.Value -Scope Script }
[void]$VoiceCombo.Items.Add([pscustomobject]@{name='Taiwan test voice';id='zh-TW-HsiaoChenNeural'});$VoiceCombo.SelectedIndex=0
foreach ($control in @('SpeakButton','SendButton','StopButton')) {
    (Get-Variable -Name $control -ValueOnly).Add_Click((Get-ProductionHandler $control 'Add_Click'))
}
foreach ($control in @('PinToggle','RefreshTasksButton','MenuSettings','CenterPlaybackButton','CenterStopButton')) {
    (Get-Variable -Name $control -ValueOnly).Add_Click((Get-ProductionHandler $control 'Add_Click' $controllerAst))
}
$tick = Get-ProductionHandler 'timer' 'Add_Tick'
$script:checks = 0
function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Click([string]$Name) {
    $control=Get-Variable -Name $Name -ValueOnly
    $event=if ($control -is [Windows.Controls.MenuItem]) { [Windows.Controls.MenuItem]::ClickEvent } else { [Windows.Controls.Button]::ClickEvent }
    $control.RaiseEvent((New-Object Windows.RoutedEventArgs($event)))
}
function Reset-Case {
    Reset-VoiceTaskSwitch
    [CodexReader.AudioPlayer]::Reset()
    $script:connected = $true; $script:threadId = '11111111-1111-4111-8111-111111111111'
    $script:recMode = 'idle'; $script:armDue = [DateTime]::MaxValue
    $script:manualRecorder=$null; $script:echoQuestionCapture=$false; $script:bargeInEnabled=$false
    $script:ttsJob = $null; $script:asrJob = $null; $script:bridgeJob = $null
    $script:speechQueue = New-Object 'System.Collections.Generic.Queue[string]'
    $script:audioPath = 'mock-answer.mp3'; $script:epoch = 0; $script:ttsEpoch = -1
    $script:mic = [pscustomobject]@{ Ready=$true; AnyCaptureActive=$false; LastError=''; ActivationVersion=0L; ScanCount=1L; Sessions=@() }
    $script:recorder = [pscustomobject]@{ Starts=0; Cancels=0; StopsObservedAtStart=0; Level=0; Error=''; StartedUtc=[DateTime]::MinValue; LastVoiceUtc=[DateTime]::MinValue }
    $script:recorder | Add-Member ScriptMethod Start { $this.Starts++; $this.StopsObservedAtStart=[CodexReader.AudioPlayer]::Stops; $this.StartedUtc=[DateTime]::UtcNow }
    $script:recorder | Add-Member ScriptMethod Cancel { $this.Cancels++ }
    $script:lastMicVersion=0L; $script:lastUserVersion=0; $script:interrupted=0
    $script:lastTailRead=[DateTime]::UtcNow; $script:lastPendingCheck=[DateTime]::UtcNow
    $script:lastStatusWrite=[DateTime]::MinValue; $script:tail=@{UserTurnVersion=0;Latest='Previous answer'}
    $script:pendingUncertain=''; $script:pendingSends=@{}; $script:submitAfterRecognition=$false
    $script:recordPath=''; $script:recordPrefix=''; $script:notice='Ready'; $script:errorText=''
    $script:busy=$false; $script:autoSend=$false; $script:autoRead=$true; $script:level=0.0
    $script:captionExpanded=$true; $script:captionsVisible=$false; $script:floatingVisible=$false; $script:pinned=$true
    $script:received=0; $script:spoken=0; $script:sent=0; $script:latest='Previous answer'
    $script:voiceId='zh-TW-HsiaoChenNeural'; $script:phaseClock=[Diagnostics.Stopwatch]::StartNew()
    $script:removed=@(); $script:jobKilled=$false; $script:bridgePurpose=''
    $script:handsFreeEnabled=$false; $script:handsFreePhase='off'; $script:handsFreeCapture=$false
    $script:wakeListener=$null; $script:wakeOwnsMicrophone=$false; $script:voiceGeneration=0
    $script:lastWakeVersion=0L; $script:wakeCount=0; $script:ackEpoch=-1; $script:ackWasPlaying=$false
    $script:wakeReleaseScan=0L; $script:nextWakeUtc=[DateTime]::MaxValue; $script:wakeReleaseDeadline=[DateTime]::MaxValue
    $script:autoDispatch=$null; $script:closing=$false
    $script:workspace=Split-Path $SourceRoot -Parent; $script:tasksLoaded=$false; $script:settingsShown=0
    $script:localCommandNoticeUntil=[DateTime]::MinValue; $script:localCommandMessage=''
    $script:playbackNotice=''
    $script:allowMockSpeech=$false; $script:speechStarts=0; $script:synthesizedText=''
    $script:waveStyle='rays'; $script:waveSize=140
    $script:TestMode=$true; $script:TestCommandPath=$null; $script:TestTranscriptPath=$null; $script:StatusPath=$null
    $InputBox.Text='Draft remains'; $InputBox.IsReadOnly=$false
    Set-CaptionExpanded $true
    Initialize-WakeRecovery
}
function Enable-MockEchoListener {
    $InputBox.Text=''
    $script:handsFreeEnabled=$true; $script:bargeInEnabled=$true
    $script:handsFreePhase='speaking'; $script:wakeOwnsMicrophone=$true
    $script:mic.AnyCaptureActive=$true
    $script:mic.Sessions=@([pscustomobject]@{Active=$true;ProcessId=$PID})
    $script:wakeListener=[pscustomobject]@{
        IsListening=$true; IsStopping=$false; IsReady=$true; FullDuplexReady=$true
        RenderEndpointId=[CodexReader.AudioPlayer]::RenderEndpointId; Error=''; AudioLevel=0
        ActivationVersion=0L; HasQuestion=$false; Stops=0; QuestionTakes=0
    }
    $script:wakeListener | Add-Member ScriptMethod Stop {
        $this.Stops++; $this.IsStopping=$true; $this.FullDuplexReady=$false; $this.IsReady=$false
    }
    $script:wakeListener | Add-Member ScriptMethod TakeQuestionRecorder {
        $this.QuestionTakes++; $this.HasQuestion=$false; return $script:recorder
    }
}
function Tick-And-AssertHealthy {
    . $tick
    Assert-That (-not $script:errorText) ('Production timer failed: ' + $script:errorText)
}
function Prepare-MockTaskSwitchFeedback([string]$Kind) {
    Reset-Case; Enable-MockEchoListener
    $script:TestMode=$false; $script:audioPath=''; [CodexReader.AudioPlayer]::State='closed'
    $script:boundDirectory='Original directory'; $TaskLabel.Text='Original task'; $AnswerBox.Text=$script:latest
    $script:wakeListener | Add-Member NoteProperty Starts 0
    $script:wakeListener | Add-Member ScriptMethod StartEcho {
        param($phrase,$capture,$render)
        $this.Starts++; $this.IsListening=$true; $this.IsStopping=$false
        $this.IsReady=$false; $this.FullDuplexReady=$false; $this.RenderEndpointId=$render
    }
    Assert-That (Begin-VoiceTaskSwitch 'target') 'The task-switch command did not start its local lookup.'
    Tick-And-AssertHealthy
    Assert-That ($script:wakeListener.IsStopping) 'An in-flight voice lookup did not exercise real wake suspension.'
    # The fake device now completes the asynchronous stop and a fresh mic scan.
    $script:wakeListener.IsListening=$false; $script:wakeListener.IsStopping=$false
    $script:mic.AnyCaptureActive=$false; $script:mic.Sessions=@(); $script:mic.ScanCount++
    Tick-And-AssertHealthy
    Assert-That (-not $script:wakeOwnsMicrophone) 'The fixture failed to release actual ownership before feedback.'
    $context=$script:bridgeJob.VoiceTaskSwitchContext; $script:bridgeJob=$null
    $one=[pscustomobject]@{threadId='22222222-2222-4222-8222-222222222222';title='Target';cwd='Target directory'}
    $two=[pscustomobject]@{threadId='33333333-3333-4333-8333-333333333333';title='Target two';cwd='Target directory'}
    $matchType=if ($Kind -eq 'bind') {'unique'} else {$Kind}
    $candidates=if ($Kind -eq 'none') {@()} elseif ($Kind -eq 'bind') {@($one)} else {@($one,$two)}
    Assert-That (Complete-VoiceTaskSearch ([pscustomobject]@{ok=$true;query='target';matchType=$matchType;threads=@($candidates)}) $context) 'Task lookup completion did not produce the expected local outcome.'
    if ($Kind -eq 'bind') {
        $context=$script:bridgeJob.VoiceTaskSwitchContext; $script:bridgeJob=$null
        Assert-That (Complete-VoiceTaskBind ([pscustomobject]@{ok=$true;threadId=$one.threadId;title=$one.title;cwd=$one.cwd;rolloutPath=$sourcePath;status='idle'}) $context) 'The fake validated target did not bind.'
    }
    Assert-That ($script:speechQueue.Count -eq 1 -and -not $script:wakeOwnsMicrophone -and -not (Safe-To-Play)) 'Feedback must start queued with cold, fully released AEC.'
}
try {
    Reset-Case
    Assert-That (Safe-To-Play) 'Playback must work without any global input hook installed.'
    $InputBox.Text='Typing while the answer is read'
    Set-DesktopShellPosition $desktop ($window.Left+10) ($window.Top+10)
    Set-CaptionExpanded $false; Click 'PinToggle'; Set-FloatingVisible $false
    Tick-And-AssertHealthy
    Assert-That ([CodexReader.AudioPlayer]::Stops -eq 0) 'Typing, moving, collapsing captions, pinning, or hiding interrupted playback.'
    Assert-That ([CodexReader.AudioPlayer]::State -eq 'playing') 'Ordinary UI interaction changed playback state.'
    Assert-That (-not $script:captionExpanded -and $desktop.Controls.CaptionInputPanel.Visibility -eq 'Collapsed') 'The production caption expansion function was not exercised.'
    Click 'RefreshTasksButton'; Tick-And-AssertHealthy
    Assert-That ($script:bridgePurpose -eq 'list') 'The settings refresh button must request task choices.'
    Assert-That ([CodexReader.AudioPlayer]::Stops -eq 0) 'Opening task choices interrupted playback.'

    # Opening settings for the first time starts list. Retain both the bridge
    # job and owned, ready AEC pipeline over repeated production timer ticks.
    foreach ($audioState in @('playing','paused')) {
        foreach ($purpose in @('list','open')) {
            Reset-Case; Enable-MockEchoListener
            [CodexReader.AudioPlayer]::State=$audioState
            $script:speechQueue.Enqueue('The next answer must remain queued')
            $savedEpoch=$script:epoch; $savedAudio=$script:audioPath
            if ($purpose -eq 'list') { Click 'MenuSettings' }
            else { [void](Start-Bridge @{action='open';threadId=$script:threadId} 'open') }
            Assert-That ($script:bridgeJob.Purpose -eq $purpose -and -not $script:bridgeJob.Process.HasExited) 'The read-only bridge fixture did not create a persistent in-flight request.'
            if ($purpose -eq 'list') { Assert-That ($script:settingsShown -eq 1) 'The real first-open settings handler was not exercised.' }
            foreach ($unused in 1..4) { Tick-And-AssertHealthy }
            Assert-That ([CodexReader.AudioPlayer]::Stops -eq 0 -and $script:wakeListener.Stops -eq 0) "$purpose interrupted $audioState playback or its AEC listener."
            Assert-That ([CodexReader.AudioPlayer]::State -eq $audioState -and $script:audioPath -eq $savedAudio -and $script:epoch -eq $savedEpoch) "$purpose discarded or changed the current audio."
            Assert-That ($script:speechQueue.Count -eq 1) "$purpose consumed the queued next answer."
            Assert-That ($script:recMode -eq 'idle' -and $script:wakeCount -eq 0) 'A settings query unexpectedly started voice capture.'

            # These read-only calls must not swallow a genuine wake activation.
            $script:wakeListener.ActivationVersion=1L; $script:wakeListener.HasQuestion=$true
            Tick-And-AssertHealthy
            Assert-That ($script:wakeCount -eq 1 -and $script:handsFreePhase -eq 'acknowledging') "A wake during $purpose/$audioState was lost."
            Assert-That ([CodexReader.AudioPlayer]::Stops -eq 1 -and $script:wakeListener.Stops -eq 0) 'A true AEC wake must stop the answer once while preserving capture.'
            Tick-And-AssertHealthy
            Assert-That ($script:wakeCount -eq 1) 'The same wake activation was handled twice.'
            [CodexReader.AudioPlayer]::State='stopped'
            Tick-And-AssertHealthy
            Assert-That ($script:recMode -eq 'arming' -and $script:wakeListener.QuestionTakes -eq 1) 'Completed acknowledgement did not adopt the echo-cancelled question recorder exactly once.'
        }
    }

    # Mutating/binding requests, a pending receipt, and an unsent draft retain
    # their existing capture guards; they are not granted the list/open bypass.
    foreach ($blocker in @('send','bind','pending','draft')) {
        Reset-Case; Enable-MockEchoListener
        if ($blocker -in @('send','bind')) { [void](Start-Bridge @{threadId=$script:threadId} $blocker) }
        elseif ($blocker -eq 'pending') { $script:pendingUncertain='Uncertain receipt' }
        else { $InputBox.Text='An unsent draft' }
        $script:wakeListener.ActivationVersion=1L; $script:wakeListener.HasQuestion=$true
        foreach ($unused in 1..3) { Tick-And-AssertHealthy }
        Assert-That ($script:wakeCount -eq 0 -and $script:recMode -eq 'idle' -and $script:recorder.Starts -eq 0) "$blocker unexpectedly allowed a wake to start recording."
        Assert-That ($script:wakeListener.QuestionTakes -eq 0) "$blocker adopted a blocked question."
    }

    # Pause/resume operates on the same audio session, preserving its file,
    # cancellation epoch, and the queued next answer even after several ticks.
    foreach ($useEcho in @($false,$true)) {
        Reset-Case
        if ($useEcho) { Enable-MockEchoListener; [void](Start-Bridge @{action='list'} 'list') }
        $script:speechQueue.Enqueue('A later paragraph')
        $savedAudio=$script:audioPath; $savedEpoch=$script:epoch
        Toggle-AnswerPlayback
        Assert-That ([CodexReader.AudioPlayer]::State -eq 'paused' -and [CodexReader.AudioPlayer]::Pauses -eq 1) 'Pause did not pause the existing player.'
        foreach ($unused in 1..4) { Tick-And-AssertHealthy }
        Assert-That ([CodexReader.AudioPlayer]::Stops -eq 0 -and $script:audioPath -eq $savedAudio -and $script:epoch -eq $savedEpoch -and $script:speechQueue.Count -eq 1) 'Paused playback was cleaned up, cancelled, or advanced to a later paragraph.'
        Toggle-AnswerPlayback
        Assert-That ([CodexReader.AudioPlayer]::State -eq 'playing' -and [CodexReader.AudioPlayer]::Resumes -eq 1) 'Continue did not resume the paused player.'
        Tick-And-AssertHealthy
        Assert-That ([CodexReader.AudioPlayer]::Stops -eq 0 -and $script:audioPath -eq $savedAudio -and $script:epoch -eq $savedEpoch -and $script:speechQueue.Count -eq 1) 'Continue replaced the audio or discarded queued speech.'
    }
    foreach ($entryPoint in @('MenuPauseResume','PauseResumeButton','pauseResumeItem')) {
        Reset-Case
        $tree=if ($entryPoint -eq 'pauseResumeItem') { $ast } else { $controllerAst }
        $handler=Get-ProductionHandler $entryPoint 'Add_Click' $tree
        . $handler
        Assert-That ([CodexReader.AudioPlayer]::State -eq 'paused') "$entryPoint is not connected to pause."
        . $handler
        Assert-That ([CodexReader.AudioPlayer]::State -eq 'playing' -and [CodexReader.AudioPlayer]::Stops -eq 0) "$entryPoint is not connected to continue the existing audio."
    }

    # The center button has one real routed Click handler. A single click must
    # pause once, and a second must resume the same session without replaying it.
    Reset-Case
    $script:speechQueue.Enqueue('Keep this next paragraph')
    $savedAudio=$script:audioPath; $savedEpoch=$script:epoch
    & $script:productionUpdateDesktopDisplay
    Assert-That $CenterPlaybackButton.IsEnabled 'The center control must be enabled while an answer is playing.'
    Click 'CenterPlaybackButton'
    Assert-That ([CodexReader.AudioPlayer]::Pauses -eq 1 -and [CodexReader.AudioPlayer]::Resumes -eq 0 -and [CodexReader.AudioPlayer]::State -eq 'paused') 'One center click did not pause exactly once.'
    foreach ($unused in 1..3) { Tick-And-AssertHealthy }
    Click 'CenterPlaybackButton'
    Assert-That ([CodexReader.AudioPlayer]::Resumes -eq 1 -and [CodexReader.AudioPlayer]::State -eq 'playing') 'The second center click did not resume exactly once.'
    Assert-That ([CodexReader.AudioPlayer]::Stops -eq 0 -and $script:audioPath -eq $savedAudio -and $script:epoch -eq $savedEpoch -and $script:speechQueue.Count -eq 1) 'The center pause/continue action cancelled or overlapped the existing answer.'

    foreach ($stopState in @('playing','paused','preparing','queued')) {
        Reset-Case
        $script:speechQueue.Enqueue('Must not continue after stop')
        $script:ttsJob=@{Audio='cancel-this-synthesis.mp3'}
        [CodexReader.AudioPlayer]::State=if ($stopState -in @('playing','paused')) { $stopState } else { 'closed' }
        if ($stopState -eq 'queued') { $script:ttsJob=$null }
        & $script:productionUpdateDesktopDisplay
        Assert-That $CenterStopButton.IsEnabled "Stop must be available during $stopState."
        $savedLatest=$script:latest; $savedDraft=$InputBox.Text; $savedThread=$script:threadId
        Click 'CenterStopButton'
        Assert-That ([CodexReader.AudioPlayer]::State -eq 'closed' -and $script:speechQueue.Count -eq 0 -and -not $script:ttsJob -and $script:epoch -eq 1) "Stop did not cancel current and queued output during $stopState."
        Assert-That ($script:latest -ceq $savedLatest -and $InputBox.Text -ceq $savedDraft -and $script:threadId -eq $savedThread -and $script:bridgePurpose -eq '') 'Ending speech modified the answer, draft, or Codex task.'
        Tick-And-AssertHealthy
        Assert-That ([CodexReader.AudioPlayer]::State -eq 'closed' -and $script:speechQueue.Count -eq 0) 'Stopped output restarted on the next timer tick.'
        & $script:productionUpdateDesktopDisplay
        Assert-That (-not $CenterStopButton.IsEnabled -and $CenterPlaybackButton.IsEnabled) 'Stop must become inactive while replay remains available.'
    }
    foreach ($recordingState in @('arming','listening','stopping','transcribing')) {
        Reset-Case; $script:recMode=$recordingState
        & $script:productionUpdateDesktopDisplay
        Assert-That (-not $CenterStopButton.IsEnabled) "The output stop control should not cancel $recordingState input."
        Click 'CenterStopButton'
        Assert-That ($script:recMode -eq $recordingState -and [CodexReader.AudioPlayer]::Stops -eq 0 -and $script:voiceGeneration -eq 0) 'A stale stop click cancelled an ongoing question.'
    }
    Reset-Case; Enable-MockEchoListener
    $script:handsFreePhase='listening'; $script:wakeListener.AudioLevel=92
    [CodexReader.AudioPlayer]::Level=.36
    Update-AssistantAudioLevel
    Assert-That ($script:level -eq .36 -and $script:levelSource -eq 'playback') 'AEC microphone residual must not replace playback amplitude.'
    [CodexReader.AudioPlayer]::Level=0
    Update-AssistantAudioLevel
    Assert-That ($script:level -eq 0) 'Silent playback must not generate a fake talking level.'
    [CodexReader.AudioPlayer]::State='paused'
    Update-AssistantAudioLevel
    Assert-That ($script:level -eq 0 -and $script:levelSource -eq 'silence') 'Paused playback should settle instead of showing background microphone audio.'
    [CodexReader.AudioPlayer]::State='closed'
    Update-AssistantAudioLevel
    Assert-That ($script:level -eq .92 -and $script:levelSource -eq 'microphone') 'Wake listening must display real microphone audio.'
    $script:recMode='listening'; $script:recorder.Level=48
    Update-AssistantAudioLevel
    Assert-That ($script:level -eq .48 -and $script:levelSource -eq 'microphone') 'Question recording must display its recorder level.'
    $script:recMode='idle'; $script:wakeListener.IsReady=$false
    Update-AssistantAudioLevel
    Assert-That ($script:level -eq 0 -and $script:levelSource -eq 'silence') 'An inactive listener must not leave a stale microphone level.'
    [CodexReader.AudioPlayer]::State='playing'; [CodexReader.AudioPlayer]::Level=[double]::NaN
    Update-AssistantAudioLevel
    Assert-That ($script:level -eq 0) 'Invalid audio measurements must not poison the visual envelope.'
    [CodexReader.AudioPlayer]::Level=0

    foreach ($finishedState in @('closed','stopped')) {
        Reset-Case
        [CodexReader.AudioPlayer]::State=$finishedState
        $script:audioPath=''; $script:latest='A readable final answer.'
        & $script:productionUpdateDesktopDisplay
        Assert-That $CenterPlaybackButton.IsEnabled "A completed answer must be replayable from $finishedState."
        Click 'CenterPlaybackButton'
        Assert-That ([CodexReader.AudioPlayer]::Stops -eq 1 -and $script:epoch -eq 1 -and $script:speechQueue.Count -eq 1 -and $script:speechQueue.Peek() -eq $script:latest) 'Replay did not queue the latest readable answer exactly once.'
        Assert-That ([CodexReader.AudioPlayer]::State -eq 'closed' -and $script:speechStarts -eq 0) 'The center handler started audio synchronously or overlapped synthesis.'
        Click 'CenterPlaybackButton'
        Assert-That ([CodexReader.AudioPlayer]::Stops -eq 1 -and $script:epoch -eq 1 -and $script:speechQueue.Count -eq 1) 'Repeated center clicks duplicated or replaced queued replay.'
        $script:allowMockSpeech=$true
        Tick-And-AssertHealthy
        Assert-That ($script:speechStarts -eq 1 -and $script:ttsJob -and $script:speechQueue.Count -eq 0 -and $script:synthesizedText -eq $script:latest) 'The queued replay did not enter one synthesis job.'
        $preparingJob=$script:ttsJob
        foreach ($unused in 1..3) { Click 'CenterPlaybackButton'; Tick-And-AssertHealthy }
        Assert-That ($script:speechStarts -eq 1 -and [object]::ReferenceEquals($script:ttsJob,$preparingJob) -and $script:speechQueue.Count -eq 0 -and -not $script:jobKilled) 'Clicks during preparation replaced the synthesis job or queued another replay.'
        Assert-That ([CodexReader.AudioPlayer]::Stops -eq 1 -and $script:epoch -eq 1) 'Preparation clicks reset cancellation state.'
    }
    foreach ($emptyAnswer in @('', '   ', ('~~~text'+[Environment]::NewLine+'private code only'+[Environment]::NewLine+'~~~'))) {
        Reset-Case
        [CodexReader.AudioPlayer]::State='closed'; $script:audioPath=''; $script:latest=$emptyAnswer
        & $script:productionUpdateDesktopDisplay
        Assert-That (-not $CenterPlaybackButton.IsEnabled) 'The center replay control must be disabled without readable answer text.'
        # Invoke the handler as well: stale UI enablement must not bypass guards.
        Click 'CenterPlaybackButton'
        Assert-That ([CodexReader.AudioPlayer]::Stops -eq 0 -and $script:speechQueue.Count -eq 0 -and $script:epoch -eq 0) 'An empty or code-only answer caused a replay side effect.'
    }
    foreach ($recordingState in @('arming','listening','stopping','transcribing')) {
        foreach ($playerState in @('playing','paused','closed')) {
            Reset-Case
            $script:recMode=$recordingState; [CodexReader.AudioPlayer]::State=$playerState
            & $script:productionUpdateDesktopDisplay
            Assert-That (-not $CenterPlaybackButton.IsEnabled) "The center control must be disabled while $recordingState."
            Click 'CenterPlaybackButton'
            Assert-That ([CodexReader.AudioPlayer]::State -eq $playerState -and [CodexReader.AudioPlayer]::Stops -eq 0 -and [CodexReader.AudioPlayer]::Pauses -eq 0 -and [CodexReader.AudioPlayer]::Resumes -eq 0 -and $script:speechQueue.Count -eq 0) "The center control changed output during $recordingState/$playerState."
        }
    }
    foreach ($wakeTransition in @('releasing','answering-wake','acknowledging')) {
        Reset-Case
        $script:handsFreePhase=$wakeTransition
        & $script:productionUpdateDesktopDisplay
        Assert-That (-not $CenterPlaybackButton.IsEnabled) "The center control must be disabled during $wakeTransition."
        Click 'CenterPlaybackButton'
        Assert-That ([CodexReader.AudioPlayer]::State -eq 'playing' -and [CodexReader.AudioPlayer]::Stops -eq 0 -and [CodexReader.AudioPlayer]::Pauses -eq 0 -and $script:speechQueue.Count -eq 0) "The center control interrupted $wakeTransition."
    }
    Reset-Case
    [CodexReader.AudioPlayer]::State='paused'; $script:recMode='arming'
    Toggle-AnswerPlayback
    Assert-That ([CodexReader.AudioPlayer]::Resumes -eq 0 -and [CodexReader.AudioPlayer]::State -eq 'paused') 'Continue resumed while recording was being prepared.'
    $script:recMode='idle'; $script:mic.AnyCaptureActive=$true
    Toggle-AnswerPlayback
    Assert-That ([CodexReader.AudioPlayer]::Resumes -eq 0 -and [CodexReader.AudioPlayer]::State -eq 'paused') 'Continue bypassed microphone safety.'

    foreach ($audioState in @('playing','paused')) {
        Reset-Case; Enable-MockEchoListener
        [CodexReader.AudioPlayer]::State=$audioState
        [void](Start-Bridge @{action='list'} 'list')
        $script:mic.Sessions=@([pscustomobject]@{Active=$true;ProcessId=0})
        Tick-And-AssertHealthy
        Assert-That ([CodexReader.AudioPlayer]::Stops -ge 1 -and $script:wakeListener.Stops -eq 1 -and -not (Safe-To-Play)) "An external microphone failed to stop $audioState audio and AEC capture during a task list query."
        Assert-That ($script:recMode -eq 'idle' -and $script:wakeCount -eq 0) 'External capture triggered an assistant recording.'
    }

    # Rebinding the same task preserves playback; a different confirmed task cancels it.
    Reset-Case
    Apply-Thread ([pscustomobject]@{rolloutPath=$sourcePath;threadId=$script:threadId;status='idle';title='Same task'})
    Assert-That ([CodexReader.AudioPlayer]::Stops -eq 0) 'Re-selecting the current task interrupted playback.'
    Apply-Thread ([pscustomobject]@{rolloutPath=$sourcePath;threadId='22222222-2222-4222-8222-222222222222';status='idle';title='Different task'})
    Assert-That ([CodexReader.AudioPlayer]::Stops -eq 1) 'Changing to a different task must stop the old answer.'

    Reset-Case
    $script:ttsJob=@{Audio='completed-but-unclaimed.mp3'}
    $script:speechQueue.Enqueue('queued answer')
    $before=[DateTime]::UtcNow
    Click 'SpeakButton'
    Assert-That ([CodexReader.AudioPlayer]::Stops -eq 1) 'Starting recording must stop output immediately.'
    Assert-That ($script:jobKilled -and -not $script:ttsJob -and $script:speechQueue.Count -eq 0) 'Starting recording must cancel pending synthesis and queued speech.'
    Assert-That ($script:removed -contains 'completed-but-unclaimed.mp3') 'Cancelled completed synthesis must clean its final audio.'
    Assert-That ($script:recMode -eq 'arming' -and $script:recorder.Starts -eq 0) 'Recording started before the echo guard delay.'
    Assert-That (($script:armDue-$before).TotalMilliseconds -ge 250) 'The 250 ms guard delay was removed.'
    $script:armDue=[DateTime]::UtcNow.AddSeconds(1)
    Tick-And-AssertHealthy
    Assert-That ($script:recorder.Starts -eq 0) 'Timer started capture before its arming deadline.'
    $script:armDue=[DateTime]::UtcNow.AddMilliseconds(-1)
    Tick-And-AssertHealthy
    Assert-That ($script:recorder.Starts -eq 1 -and $script:recorder.StopsObservedAtStart -ge 1) 'Capture must start only after audio was stopped.'

    Reset-Case
    $script:mic.AnyCaptureActive=$true; $script:mic.ActivationVersion=1L
    Tick-And-AssertHealthy
    Assert-That ([CodexReader.AudioPlayer]::Stops -ge 1 -and -not (Safe-To-Play)) 'Actual microphone capture must still interrupt playback.'
    $script:mic.AnyCaptureActive=$false
    Assert-That (Safe-To-Play) 'Playback should become eligible when capture ends.'

    Reset-Case
    $script:mic.ActivationVersion=1L
    Tick-And-AssertHealthy
    Assert-That ([CodexReader.AudioPlayer]::Stops -eq 1) 'A short capture detected between ticks must still cancel the previous answer.'

    Reset-Case
    Click 'StopButton'
    Assert-That ([CodexReader.AudioPlayer]::Stops -eq 1) 'Explicit stop button must stop playback.'
    Reset-Case
    Click 'SendButton'
    Assert-That ([CodexReader.AudioPlayer]::Stops -eq 1 -and $script:bridgePurpose -eq '') 'Sending new text must stop output; test mode must not dispatch it.'
    Reset-Case
    $script:tail.UserTurnVersion=1; $script:lastTailRead=[DateTime]::MinValue
    Tick-And-AssertHealthy
    Assert-That ([CodexReader.AudioPlayer]::Stops -eq 1) 'A new Codex user turn must cancel its previous answer.'

    # Use the production task outcomes, queue policy, and complete timer. Cold
    # AEC ownership is genuinely false here; do not set ownership just to keep
    # pending speech alive. TestMode=false exercises the actual duplex gate.
    foreach ($outcome in @('none','ambiguous','bind')) {
        Prepare-MockTaskSwitchFeedback $outcome
        $feedback=$script:speechQueue.Peek(); $stops=[CodexReader.AudioPlayer]::Stops
        $script:nextWakeUtc=[DateTime]::UtcNow.AddSeconds(10)
        Tick-And-AssertHealthy
        Assert-That ($script:speechQueue.Count -eq 1 -and [CodexReader.AudioPlayer]::Stops -eq $stops -and $script:wakeListener.Starts -eq 0) "$outcome feedback was discarded during the AEC restart delay."
        $script:nextWakeUtc=[DateTime]::MinValue
        foreach ($unused in 1..3) { Tick-And-AssertHealthy }
        Assert-That ($script:speechQueue.Count -eq 1 -and $script:speechStarts -eq 0 -and $script:wakeListener.Starts -eq 1) "$outcome feedback did not wait for one cold AEC startup."
        Assert-That (-not (Safe-To-Play) -and [CodexReader.AudioPlayer]::Stops -eq $stops) 'Queue preservation bypassed actual playback readiness or cancelled speech.'
        $script:wakeListener.IsReady=$true; $script:wakeListener.FullDuplexReady=$true
        $script:mic.AnyCaptureActive=$true; $script:mic.Sessions=@([pscustomobject]@{Active=$true;ProcessId=$PID})
        $script:allowMockSpeech=$true
        Tick-And-AssertHealthy
        foreach ($unused in 1..3) { Tick-And-AssertHealthy }
        Assert-That ($script:speechStarts -eq 1 -and $script:synthesizedText -eq $feedback -and $script:speechQueue.Count -eq 0) "$outcome feedback was lost or synthesized more than once after AEC became ready."
        Assert-That ([CodexReader.AudioPlayer]::Stops -eq $stops -and $script:recMode -eq 'idle') 'The task feedback started a recording or cancelled the synthesis.'
    }
    foreach ($cancellation in @('external-mic','explicit-stop')) {
        Prepare-MockTaskSwitchFeedback 'none'
        $stops=[CodexReader.AudioPlayer]::Stops
        if ($cancellation -eq 'external-mic') {
            $script:mic.AnyCaptureActive=$true
            $script:mic.Sessions=@([pscustomobject]@{Active=$true;ProcessId=0})
        } else { Click 'StopButton' }
        Tick-And-AssertHealthy
        Assert-That ($script:speechQueue.Count -eq 0 -and $script:speechStarts -eq 0 -and [CodexReader.AudioPlayer]::Stops -gt $stops) "$cancellation failed to cancel unstarted cold-AEC feedback."
        Assert-That ($script:recMode -eq 'idle') 'Cancelling feedback started capture.'
    }
    # Full production timer integration: actual health recovery must retain a
    # newly arrived answer across release/backoff, and play it only after health.
    Reset-Case; Enable-MockEchoListener
    $script:TestMode=$false;$script:audioPath='';[CodexReader.AudioPlayer]::State='closed'
    $script:wakeListener | Add-Member NoteProperty Health ([pscustomobject]@{State='stalled';NeedsRecovery=$true;Reason='progress-stalled';HasActivated=$false})
    $script:wakeListener | Add-Member ScriptMethod GetHealthSnapshot { return $this.Health }
    $script:wakeListener | Add-Member ScriptMethod RequestRecoveryStop { $this.Stop() }
    $script:speechQueue.Enqueue('obsolete speech before the fault')
    Tick-And-AssertHealthy
    Assert-That ($script:wakeRecovery.Phase -eq 'releasing' -and $script:wakeListener.IsStopping -and $script:handsFreeEnabled) 'Fault did not enter recovery while retaining the wake preference.'
    Assert-That ($script:speechQueue.Count -eq 0) 'The initial fault retained obsolete speech.'
    $script:speechQueue.Enqueue('new answer during recovery')
    $stops=[CodexReader.AudioPlayer]::Stops
    Tick-And-AssertHealthy
    Assert-That ($script:speechQueue.Count -eq 1 -and [CodexReader.AudioPlayer]::Stops -eq $stops -and -not (Safe-To-Play)) 'The timer discarded new speech or permitted playback before release.'
    $script:wakeListener.IsListening=$false;$script:wakeListener.IsStopping=$false
    $script:wakeListener.Health=[pscustomobject]@{State='idle';NeedsRecovery=$false;Reason='';HasActivated=$false}
    $script:mic.AnyCaptureActive=$false;$script:mic.Sessions=@();$script:mic.ScanCount++
    Tick-And-AssertHealthy
    Assert-That ($script:wakeRecovery.Phase -eq 'backoff' -and $script:speechQueue.Count -eq 1 -and -not $script:wakeOwnsMicrophone) 'Released recovery lost queued speech or microphone ownership stayed latched.'
    # Startup itself is separately exercised by the dedicated recovery suite.
    $script:wakeRecovery.Phase='starting';$script:wakeRecovery.StartGeneration=$script:voiceGeneration
    $script:wakeListener.IsListening=$true;$script:wakeListener.IsReady=$true;$script:wakeListener.FullDuplexReady=$true
    $script:wakeListener.Health=[pscustomobject]@{State='healthy';NeedsRecovery=$false;Reason='';HasActivated=$false}
    $script:wakeOwnsMicrophone=$true;$script:mic.AnyCaptureActive=$true;$script:mic.Sessions=@([pscustomobject]@{Active=$true;ProcessId=$PID})
    $script:allowMockSpeech=$true
    Tick-And-AssertHealthy
    Assert-That ($script:wakeRecovery.Phase -eq 'idle' -and $script:speechStarts -eq 1 -and $script:synthesizedText -eq 'new answer during recovery') 'Healthy recovery did not resume the new answer exactly once.'
    Assert-That ($script:recMode -eq 'idle' -and $script:sent -eq 0 -and $script:wakeCount -eq 0) 'Recovery manufactured a question or a Codex send.'

    # A route refresh and a newly detected keyword in the same timer pass must
    # let the existing wake/acknowledgement path consume that activation first.
    Reset-Case; Enable-MockEchoListener
    $script:TestMode=$false;$script:audioPath='';[CodexReader.AudioPlayer]::State='closed'
    $script:handsFreePhase='listening'
    $script:wakeListener | Add-Member ScriptMethod GetHealthSnapshot { return [pscustomobject]@{State='healthy';NeedsRecovery=$false;Reason='';HasActivated=$true} }
    $script:wakeListener | Add-Member ScriptMethod RequestRecoveryStop { $this.Stop() }
    $script:wakeListener.ActivationVersion=1L
    function Test-WakeRecoveryRouteChanged { return $true }
    Tick-And-AssertHealthy
    Assert-That ($script:wakeRecovery.Phase -eq 'deferred' -and $script:wakeCount -eq 1 -and $script:lastWakeVersion -eq 1L) 'Route recovery swallowed a just-detected keyword.'
    Assert-That ($script:handsFreePhase -eq 'acknowledging' -and $script:wakeListener.Stops -eq 0) 'Deferred recovery blocked the wake acknowledgement.'
    [pscustomobject]@{ok=$true;checks=$script:checks;ui='DesktopShell and production DesktopController';audio='mock';microphone='mock';codexRequests=0} | ConvertTo-Json -Compress
} finally {
    Close-DesktopShell $desktop
}
