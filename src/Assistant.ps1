param(
    [string]$ThreadId = '',
    [string]$PreviewPath,
    [string]$StatusPath,
    [string]$TestTranscriptPath,
    [string]$TestAudioPath,
    [string]$TestCommandPath,
    [string]$TestStateDir,
    [switch]$TestMode
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
. (Join-Path $PSScriptRoot 'reader-core.ps1')
. (Join-Path $PSScriptRoot 'AudioBootstrap.ps1')
foreach ($name in @('MicGuard.cs','JarvisRecorder.cs')) { Add-Type -Path (Join-Path $PSScriptRoot $name) }
$workspace = Split-Path $PSScriptRoot -Parent
foreach ($module in @('Version.ps1','Settings.ps1','PendingSends.ps1','WorkerLifecycle.ps1','CodexAdapter.ps1')) { . (Join-Path $PSScriptRoot $module) }
$script:appVersion=Get-AssistantVersion -Root $workspace
$stateDir = if ($TestMode) { if ($TestStateDir) { [IO.Path]::GetFullPath($TestStateDir) } else { Join-Path $workspace 'work\tests\app-state' } } elseif ($PreviewPath) { Join-Path $workspace 'work\preview' } else { Join-Path $workspace 'data' }
if (-not $StatusPath -and -not $PreviewPath) { $StatusPath = Join-Path $stateDir 'status.json' }
$settingsPath = Join-Path $stateDir 'settings.json'
$runtime = Join-Path $stateDir ('run-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runtime)
$python = Join-Path $workspace 'runtime\python\python.exe'
$asrPython = $python
$modelDir = Join-Path $workspace 'runtime\models\sensevoice'
$mutexName = if ($TestMode) { 'Local\Shengban.VoiceCompanion.Test' } else { 'Local\Shengban.VoiceCompanion' }
$mutex = New-Object Threading.Mutex($false, $mutexName)
$ownsMutex = $false
if (-not $PreviewPath) {
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) {
        [void][Windows.MessageBox]::Show('语音助手已经运行，请在右下角托盘中打开。','Codex 语音助手')
        $mutex.Dispose(); exit
    }
    [IO.File]::WriteAllText((Join-Path $stateDir 'pid.txt'),$PID.ToString())
}
$hasExplicitThreadId = -not [string]::IsNullOrWhiteSpace($ThreadId)
$script:threadId = if ($hasExplicitThreadId) { $ThreadId } else { '' }
$script:voiceId = 'zh-TW-HsiaoChenNeural'
$script:voiceCatalog = (Get-Content -LiteralPath (Join-Path $workspace 'assets\voices.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
$script:speechRate = 0
$script:autoRead = $true
$script:waveStyle = 'rays'
$script:waveSize = 260
$script:pinned = $true
$script:captionsVisible = $false
$script:floatingVisible = $true
$script:directoryFilter = ''
$script:boundDirectory = ''
$script:savedLeft = $null; $script:savedTop = $null
$script:positionDirty = $false; $script:lastPositionChange = [DateTime]::MinValue
$script:desktop = $null
$script:autoSend = $false
$script:compact = $false
$script:connected = $false
$script:bindingReadError = ''
$script:busy = $false
$script:notice = '请在设置里选择要连接的 Codex 任务。'
$script:recMode = 'idle'
$script:echoQuestionCapture = $false
$script:manualRecorder = $null
$script:armDue = [DateTime]::MaxValue
$script:submitAfterRecognition = $false
$script:ttsJob = $null
$script:asrJob = $null
$script:bridgeJob = $null
$script:voiceTaskSwitch = $null
$script:voiceTaskSwitchGeneration = 0
$script:voiceTaskCreate = $null
$script:voiceTaskCreatePath = Join-Path $stateDir 'voice-task-create.json'
$script:audioPath = ''
$script:recordPath = ''
$script:recordPrefix = ''
$script:lastTestCommand = ''
$script:latest = ''
$script:epoch = 0
$script:ttsEpoch = -1
$script:lastSpeechEpoch = -1
$script:lastMicVersion = 0L
$script:lastUserVersion = 0
$script:lastTailRead = [DateTime]::MinValue
$script:lastStatusWrite = [DateTime]::MinValue
$script:received = 0
$script:spoken = 0
$script:sent = 0
$script:interrupted = 0
$script:errorText = ''
$script:level = 0.0
$script:playbackNotice = ''
$script:localCommandCount = 0
$script:lastLocalCommand = ''
$script:localCommandMessage = ''
$script:localCommandNoticeUntil = [DateTime]::MinValue
$script:phaseClock = [Diagnostics.Stopwatch]::StartNew()
$script:pendingUncertain = ''
$script:pendingSends = @{}
$script:pendingPath = Join-Path $stateDir 'pending-sends.json'
$script:lastPendingCheck = [DateTime]::MinValue
$script:speechQueue = New-Object 'System.Collections.Generic.Queue[string]'
. (Join-Path $PSScriptRoot 'HandsFree.ps1')
. (Join-Path $PSScriptRoot 'WakePhrase.ps1')
Initialize-AssistantSettings

function Stop-Output([string]$Message = '', [switch]$PreserveVoiceBookmark) {
    if ($Message -and (Get-Command Close-ShortFollowUp -ErrorAction SilentlyContinue)) { Close-ShortFollowUp -CancelCapture }
    Stop-AssistantOutput -Message $Message -PreserveVoiceBookmark:$PreserveVoiceBookmark
}
function Test-FullDuplexReady {
    if (-not $script:wakeListener -or -not $script:wakeListener.FullDuplexReady) { return $false }
    try { return ($script:wakeListener.RenderEndpointId -and $script:wakeListener.RenderEndpointId -eq [CodexReader.AudioPlayer]::RenderEndpointId -and -not (Test-ExternalCapture)) } catch { return $false }
}
function Safe-To-Play {
    if (Test-WakeRecoveryPending) { return $false }
    if ($script:recMode -ne 'idle' -or -not $script:mic.Ready -or $script:mic.LastError) { return $false }
    if (Test-FullDuplexReady) { return $true }
    if ($script:handsFreeEnabled -and $script:bargeInEnabled -and -not $TestMode) { return $false }
    return (-not $script:mic.AnyCaptureActive -and -not $script:wakeOwnsMicrophone -and
        (-not $script:wakeListener -or (-not $script:wakeListener.IsListening -and -not $script:wakeListener.IsStopping)))
}
function Test-WakeRecoveryRouteChanged {
    if (-not $script:wakeListener -or -not $script:wakeListener.IsListening -or $script:wakeListener.IsStopping -or
        -not $script:mic.Ready -or $script:mic.LastError -or $script:mic.DefaultEndpointAgeMs -lt 0 -or
        $script:mic.DefaultEndpointAgeMs -gt 3000) { return $false }
    $capture=[string]$script:mic.DefaultCaptureEndpointId
    $render=[string]$script:mic.DefaultRenderEndpointId
    return [bool](($capture -and $script:wakeListener.CaptureEndpointId -and $capture -cne $script:wakeListener.CaptureEndpointId) -or
        ($render -and $script:wakeListener.RenderEndpointId -and $render -cne $script:wakeListener.RenderEndpointId))
}
function Reset-WakeRecoveryAudioRoute {
    if ($script:wakeListener.IsListening -or $script:wakeListener.IsStopping -or $script:recMode -ne 'idle' -or
        ($script:recorder -and ($script:recorder.IsRecording -or $script:recorder.IsStopping)) -or
        [CodexReader.AudioPlayer]::State -in @('playing','paused') -or -not $script:mic.Ready -or
        $script:mic.LastError -or $script:mic.AnyCaptureActive -or
        $script:mic.DefaultEndpointAgeMs -lt 0 -or $script:mic.DefaultEndpointAgeMs -gt 3000) { throw 'Audio devices are not ready for recovery.' }
    $capture=[string]$script:mic.DefaultCaptureEndpointId
    if (-not $capture) { throw 'No default microphone is available.' }
    [CodexReader.AudioPlayer]::SelectEndpoint('')
    return @{ CaptureEndpointId=$capture; RenderEndpointId=[CodexReader.AudioPlayer]::RenderEndpointId }
}
function Read-BoundTaskAnswers([DateTime]$Now) {
    # Transcript I/O must not fall into the audio Tick's global cancellation.
    # Advance the throttle even on failure; local voice commands stay usable.
    $script:lastTailRead=$Now
    try {
        $answers=@(Read-NewCompletedAnswers $script:tail)
        if ($script:bindingReadError) { $script:notice='任务记录已恢复连接。' }
        $script:bindingReadError=''
        return $answers
    } catch {
        if (-not $script:bindingReadError -and (Get-Command Close-ShortFollowUp -ErrorAction SilentlyContinue)) {
            Close-ShortFollowUp '任务连接异常，连续接话已结束。' -CancelCapture
        }
        $script:bindingReadError=$_.Exception.Message
        $script:notice='任务记录暂时不可读，普通消息已暂停；仍可说“切换到…任务”重新连接。草稿会保留。'
    }
}

function Send-Text([string]$VoiceSource = '') {
    $script:autoDispatch=$null
    if ($script:recMode -ne 'idle') { return }
    $text = $InputBox.Text.Trim()
    if (-not $text) { $script:notice = '先说一句话，或者在输入框里打字。'; return }
    if (Try-LocalAssistantCommand $text) { return }
    if (Test-VoiceTaskCreateBlocksSend) { $script:notice='新任务尚未连接，文字已保留。请连接新任务或放弃连接。'; return }
    if (-not $script:connected) { $script:notice = '尚未连接任务，请在设置里选择并连接任务。'; return }
    if ($script:bindingReadError) { $script:notice='任务连接异常，文字已保留；请先切换或重新连接任务。'; return }
    if ($script:pendingUncertain) { $script:notice = '上次发送状态待确认，请先在 Codex 查看，避免重复发送。'; return }
    if ($script:bridgeJob) { $script:notice = '上次请求还在处理，请稍等。'; return }
    Reset-VoiceTaskSwitch
    Stop-Output
    if ($TestMode) { $script:notice = '测试模式：已准备文字，未向真实任务发送。'; return }
    $requestId = [Guid]::NewGuid().ToString()
    $followUpToken=$script:shortFollowUpGeneration
    $turnBaseline=$script:tail.UserTurnVersion
    if (Start-Bridge @{ action='send'; threadId=$script:threadId; text=$text; requestId=$requestId } 'send') {
        if ($VoiceSource -in @('wake','follow-up') -and $script:bridgeJob) {
            $script:bridgeJob.VoiceSource=$VoiceSource
            $script:bridgeJob.FollowUpGeneration=$followUpToken
            $script:bridgeJob.VoiceGeneration=$script:voiceGeneration
            $script:bridgeJob.UserTurnBaseline=$turnBaseline
        }
        $script:notice = '正在发送给 Codex…'
        $InputBox.IsReadOnly = $true
    }
}
function Begin-Recording([bool]$FromWake = $false) {
    if (-not $script:connected) { $script:notice = '先连接一个 Codex 任务。'; return }
    if ($script:bridgeJob -and $script:bridgeJob.Purpose -eq 'send') { $script:notice='正在等待发送回执，请稍等再开始录音。'; return }
    if ($script:recMode -ne 'idle' -or $script:asrJob) { return }
    $useEcho=($FromWake -and (Test-FullDuplexReady) -and $script:wakeListener.HasQuestion)
    if (-not $useEcho) { Suspend-WakeListener }
    if (Get-Command Save-VoicePlaybackBookmark -ErrorAction SilentlyContinue) {
        Save-VoicePlaybackBookmark
        Stop-Output -PreserveVoiceBookmark
    } else { Stop-Output }
    if ($useEcho) {
        $script:recorder=$script:wakeListener.TakeQuestionRecorder()
    } elseif ($script:manualRecorder) {
        if (-not [object]::ReferenceEquals($script:recorder,$script:manualRecorder)) { $script:recorder.Dispose() }
        $script:recorder=$script:manualRecorder
    }
    $script:echoQuestionCapture=$useEcho
    $script:voiceGeneration++
    $script:autoDispatch=$null
    $script:handsFreeCapture=$FromWake
    $script:errorText = ''
    $script:submitAfterRecognition = $false
    $script:recMode = 'arming'
    $script:armDue = [DateTime]::UtcNow.AddMilliseconds(250)
    $script:recordPrefix = if ($FromWake) { '' } else { $InputBox.Text.Trim() }
    $InputBox.IsReadOnly = $true
    $script:notice = '正在准备麦克风…'
}
function End-Recording([bool]$SendAfter) {
    if ($script:recMode -eq 'arming') { Cancel-Recording; return }
    if ($script:recMode -ne 'listening') { return }
    $script:submitAfterRecognition = $SendAfter
    $script:recordPath = Join-Path $runtime ([Guid]::NewGuid().ToString('N') + '.wav')
    $script:recMode = 'stopping'
    if ($script:followUpCapture -and $script:shortFollowUp) { $script:shortFollowUp.Phase='recognizing'; $script:shortFollowUp.Deadline=[DateTime]::UtcNow.AddMinutes(1) }
    $script:recorder.StopToFileAsync($script:recordPath)
    $script:notice = '正在把你的话转成文字…'
}
function Cancel-Recording {
    $script:voiceGeneration++
    $script:autoDispatch=$null
    $script:handsFreeCapture=$false
    $script:echoQuestionCapture=$false
    $script:nextWakeUtc=[DateTime]::UtcNow.AddMilliseconds(800)
    $script:submitAfterRecognition = $false
    $script:armDue = [DateTime]::MaxValue
    try { $script:recorder.Cancel() } catch {}
    if ($script:asrJob) { Close-Job $script:asrJob -Kill; $script:asrJob=$null }
    else { Remove-OwnedFiles @($script:recordPath) }
    $script:recordPath = ''
    $script:recMode = 'idle'
    $InputBox.IsReadOnly = $false
    $script:notice = '已取消录音。'
}
function Begin-Transcription([string]$WavePath, [bool]$SendAfter) {
    $resultPath = Join-Path $runtime ([Guid]::NewGuid().ToString('N') + '.asr.json')
    $proc = Start-Worker $asrPython (Join-Path $PSScriptRoot 'transcribe.py') @('--input',$WavePath,'--output',$resultPath,'--model-dir',$modelDir)
    $script:asrJob = @{ Process=$proc; Output=$resultPath; Files=@($resultPath,$WavePath); Started=[DateTime]::UtcNow; Generation=$script:voiceGeneration; ThreadId=$script:threadId; SendAfter=$SendAfter; Prefix=$script:recordPrefix; FromWake=$script:handsFreeCapture; FromFollowUp=$script:followUpCapture; FollowUpGeneration=$script:shortFollowUpGeneration }
    $script:submitAfterRecognition=$SendAfter
    $script:recMode='transcribing'
}
function Begin-Speech([string]$Text) {
    Start-AssistantSpeech $Text
}
function Apply-Thread($Result) {
    if (-not $Result.rolloutPath -or -not (Test-Path -LiteralPath $Result.rolloutPath)) { throw '这个任务的本地记录暂时不可用，请先在 Codex 打开它。' }
    $path=if ($TestTranscriptPath) { $TestTranscriptPath } else { $Result.rolloutPath }
    $reuseTail=($script:connected -and $script:threadId -eq $Result.threadId -and $script:tail -and $script:tail.Path -eq $path)
    $nextTail=if ($reuseTail) { $script:tail } else { New-TranscriptTail $path }
    if ($script:threadId -ne $Result.threadId) {
        if (Get-Command Close-ShortFollowUp -ErrorAction SilentlyContinue) { Close-ShortFollowUp '目标任务已改变，连续接话已结束。' -CancelCapture }
        Suspend-WakeListener
        $script:voiceGeneration++; $script:autoDispatch=$null
        $script:handsFreePhase=if ($script:handsFreeEnabled) { 'waiting' } else { 'off' }
        Stop-Output
        if ($script:recMode -ne 'idle') { Cancel-Recording }
        $InputBox.Text=''
    }
    $script:threadId=$Result.threadId
    $script:boundDirectory=[string]$Result.cwd
    $script:tail=$nextTail
    $script:lastUserVersion=$script:tail.UserTurnVersion
    $script:latest=$script:tail.Latest
    $script:connected=$true
    $script:bindingReadError=''
    $script:busy=($Result.status -eq 'active')
    $TaskLabel.Text=$Result.title
    $TaskLabel.ToolTip=$Result.title
    $AnswerBox.Text=if ($script:latest) { $script:latest } else { '已连接。说出你的问题，Codex 的回答会显示在这里。' }
    $script:notice='已连接，点击“开始说话”。'
    Reconcile-PendingSends
    Sync-PendingSend
    if ($script:pendingUncertain) { $script:notice='这个任务有一条发送状态待确认，请先在 Codex 查看。' }
    Save-Settings
}

. (Join-Path $PSScriptRoot 'DesktopShell.ps1')
. (Join-Path $PSScriptRoot 'DesktopController.ps1')
. (Join-Path $PSScriptRoot 'VoiceCommands.ps1')
. (Join-Path $PSScriptRoot 'TaskSwitch.ps1')
. (Join-Path $PSScriptRoot 'TaskCreate.ps1')
. (Join-Path $PSScriptRoot 'DesktopActions.ps1')
. (Join-Path $PSScriptRoot 'PlaybackCommands.ps1')
. (Join-Path $PSScriptRoot 'LocalCommands.ps1')
try {
    Initialize-PendingSends
    $script:desktop=New-DesktopShell
    $window=$desktop.Window
    $window.Dispatcher.Add_UnhandledException({
        param($sender,$eventArgs)
        $eventArgs.Handled=$true
        $script:errorText=$eventArgs.Exception.Message
        $script:notice='界面操作没有完成，请重新打开设置。'
        try { Stop-Output; if ($StatusLabel) { $StatusLabel.Text=$script:notice }; @{error=$script:errorText;where='dispatcher';time=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runtime 'ui-error.json') -Encoding UTF8 } catch {}
    })
    foreach ($name in $desktop.Controls.Keys) { Set-Variable -Name $name -Value $desktop.Controls[$name] -Scope Script }
    $script:mic=New-Object CodexReader.Audio.MicGuard
    $script:recorder=New-Object JarvisRecorder
    $script:manualRecorder=$script:recorder
    $script:wakeListener=New-Object WakeListener
    $script:wakeListener.Configure($python,(Join-Path $PSScriptRoot 'wake_worker.py'),(Join-Path $workspace 'runtime\models\wake'))
    $SpeakButton.Add_Click({
        if ($script:recMode -eq 'listening') { End-Recording $false }
        elseif ($script:recMode -eq 'idle') { Begin-Recording }
    })
    $SendButton.Add_Click({
        if ($script:recMode -eq 'listening') { End-Recording $true }
        elseif ($script:recMode -in @('stopping','transcribing')) { $script:submitAfterRecognition=$true; if ($script:asrJob) { $script:asrJob.SendAfter=$true }; $script:notice='识别完成后会发送给 Codex。' }
        elseif ($script:recMode -eq 'idle') { Send-Text }
    })
    $StopButton.Add_Click({
        Reset-ManualTaskBinding '已取消这次连接。'
        if ($script:shortFollowUp -or $script:followUpCapture) { Stop-ShortFollowUpByUser; return }
        Stop-Output '已停止朗读。'
        if ($script:handsFreePhase -in @('releasing','answering-wake','acknowledging')) { $script:handsFreePhase='waiting'; Suspend-WakeListener }
        if ($script:recMode -ne 'idle') { Cancel-Recording }
    })
    $tray=New-Object Windows.Forms.NotifyIcon
    $iconPath=Join-Path $workspace 'assets\shengban.ico'
    $tray.Icon=if (Test-Path -LiteralPath $iconPath) { New-Object Drawing.Icon($iconPath) } else { [Drawing.Icon]::ExtractAssociatedIcon((Join-Path $env:WINDIR 'System32\mmsys.cpl')) }
    $tray.Text='声伴 · Codex 语音助手'
    $menu=New-Object Windows.Forms.ContextMenuStrip
    $settingsItem=$menu.Items.Add('打开设置')
    $showItem=$menu.Items.Add('隐藏悬浮声波')
    $pinItem=$menu.Items.Add('始终置顶')
    $captionItem=$menu.Items.Add('显示字幕')
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $speakItem=$menu.Items.Add('开始说话')
    $pauseResumeItem=$menu.Items.Add('暂停朗读')
    $stopItem=$menu.Items.Add('停止朗读')
    $followUpItem=$menu.Items.Add('结束连续接话')
    $handsFreeItem=$menu.Items.Add('免点击语音唤醒')
    $autoItem=$menu.Items.Add('手动录音停顿后自动发送')
    $replayItem=$menu.Items.Add('重读上一条回答')
    $openItem=$menu.Items.Add('打开当前 Codex 任务')
    $confirmSendItem=$menu.Items.Add('已在 Codex 核对上次发送')
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $exitItem=$menu.Items.Add('退出语音助手')
    $tray.ContextMenuStrip=$menu
    $settingsItem.Add_Click({ Show-AssistantSettings })
    $tray.Add_MouseClick({param($sender,$eventArgs) if ($eventArgs.Button -eq [Windows.Forms.MouseButtons]::Left) { Show-AssistantSettings } })
    $showItem.Add_Click({ [void](Invoke-DesktopPreference @{floatingVisible=(-not $script:floatingVisible)}) })
    $pinItem.Add_Click({ [void](Invoke-DesktopPreference @{pinned=(-not $script:pinned)}) })
    $captionItem.Add_Click({ [void](Invoke-DesktopPreference @{captionsVisible=(-not $script:captionsVisible)}) })
    $speakItem.Add_Click({ Open-VoiceComposer })
    $pauseResumeItem.Add_Click({ Toggle-AnswerPlayback })
    $stopItem.Add_Click({ Stop-Output '已停止朗读。' })
    $followUpItem.Add_Click({ Stop-ShortFollowUpByUser })
    $openItem.Add_Click({ if ($script:connected) { [void](Start-Bridge @{action='open';threadId=$script:threadId} 'open') } })
    $handsFreeItem.Add_Click({ Set-HandsFree (-not $script:handsFreeEnabled); Sync-DesktopPreferences; Save-Settings })
    $confirmSendItem.Add_Click({
        if ($script:bridgeJob -and $script:bridgeJob.Purpose -eq 'send') { $script:notice='发送仍在处理，请等回执后再核对。'; return }
        Reconcile-PendingSends
        if (-not $script:pendingSends.ContainsKey($script:threadId)) { $script:notice='当前任务没有待核对的发送。'; return }
        if (Test-PendingSendRunning $script:pendingSends[$script:threadId]) { $script:notice='上次发送进程仍在等待回执，请稍后再核对。'; return }
        $choice=[Windows.MessageBox]::Show('请先在 Codex 核对上次消息是否收到。解除后再次点击发送，会作为一条新消息。确认已经核对？','核对发送状态',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question)
        if ($choice -eq [Windows.MessageBoxResult]::Yes) { Clear-PendingSend $script:threadId; $script:notice='已解除待确认状态，可以继续。' }
    })
    $autoItem.Add_Click({ [void](Invoke-DesktopPreference @{autoSend=(-not $script:autoSend)}) })
    $replayItem.Add_Click({ Stop-Output; if ($script:latest) { Queue-AnswerSpeech $script:latest } })
    $exitItem.Add_Click({ Exit-Assistant })
    Initialize-DesktopController
    Initialize-WakeRecovery
    Initialize-VoiceTaskCreate

    $timer=New-Object Windows.Threading.DispatcherTimer
    $timer.Interval=[TimeSpan]::FromMilliseconds(40)
    $timer.Add_Tick({
        try {
            $now=[DateTime]::UtcNow
            Update-ManualTaskBinding
            Update-VoiceTaskSwitch $now
            Update-VoiceTaskCreate -Now $now
            Update-WakeRecovery -Now $now
            if (-not $script:bridgeJob -and ($now-$script:lastPendingCheck).TotalSeconds -ge 1) { Reconcile-PendingSends; $script:lastPendingCheck=$now }
            $micVersion=$script:mic.ActivationVersion
            if ($micVersion -ne $script:lastMicVersion) {
                if (-not $script:wakeOwnsMicrophone) { Stop-Output }
                $script:lastMicVersion=$micVersion; $script:interrupted++
            }
            $waitingForWakeRelease=($script:wakeOwnsMicrophone -and $script:recMode -eq 'idle' -and -not (Test-ExternalCapture) -and [CodexReader.AudioPlayer]::State -notin @('playing','paused'))
            # A read/bind can finish after the old echo listener fully released
            # its microphone. Keep unstarted feedback while the replacement
            # pipeline warms up; Safe-To-Play still gates synthesis/playback.
            $waitingForEchoStartup=($script:handsFreeEnabled -and $script:bargeInEnabled -and -not $TestMode -and
                $script:recMode -eq 'idle' -and $script:speechQueue.Count -gt 0 -and -not $script:ttsJob -and
                [CodexReader.AudioPlayer]::State -notin @('playing','paused') -and $script:connected -and
                -not $script:pendingUncertain -and -not $script:autoDispatch -and -not $InputBox.Text.Trim() -and
                $script:mic.Ready -and -not $script:mic.LastError -and -not (Test-ExternalCapture) -and
                $script:wakeListener -and -not $script:wakeListener.Error -and
                (-not $script:bridgeJob -or $script:bridgeJob.Purpose -in @('list','open')))
            $waitingForWakeRecovery=((Test-WakeRecoveryPending) -and $script:recMode -eq 'idle' -and
                -not (Test-ExternalCapture) -and [CodexReader.AudioPlayer]::State -notin @('playing','paused'))
            if (-not (Safe-To-Play) -and -not $waitingForWakeRelease -and -not $waitingForEchoStartup -and -not $waitingForWakeRecovery -and ($script:ttsJob -or $script:speechQueue.Count -gt 0 -or [CodexReader.AudioPlayer]::State -in @('playing','paused'))) { Stop-Output }
            Update-HandsFree $now

            $captureReady=($script:echoQuestionCapture -and (Test-FullDuplexReady)) -or (-not $script:wakeOwnsMicrophone -and -not $script:wakeListener.IsListening -and -not $script:wakeListener.IsStopping)
            if ($script:recMode -eq 'arming' -and $now -ge $script:armDue -and $captureReady) {
                $script:recorder.Start(); $script:recMode='listening'; $script:notice='正在听，你可以说话了。'
            }
            if ($script:recMode -eq 'listening') {
                if ($script:recorder.Error) { throw $script:recorder.Error }
                if (($script:autoSend -or $script:handsFreeCapture) -and $script:recorder.LastVoiceUtc -gt $script:recorder.StartedUtc -and ($now-$script:recorder.LastVoiceUtc).TotalSeconds -ge 2 -and ($now-$script:recorder.StartedUtc).TotalSeconds -ge 2.5) { End-Recording $true }
                if ($script:followUpCapture -and $script:recorder.LastVoiceUtc -le $script:recorder.StartedUtc -and ($now-$script:recorder.StartedUtc).TotalSeconds -ge $script:shortFollowUpWaitSeconds) { Close-ShortFollowUp '连续接话等待已超时，已回到唤醒待机。' -CancelCapture }
                elseif ($script:handsFreeCapture -and $script:recorder.LastVoiceUtc -le $script:recorder.StartedUtc -and ($now-$script:recorder.StartedUtc).TotalSeconds -ge 8) { Cancel-Recording; $script:notice='没有听到问题，已回到唤醒待机。' }
                if ($script:recMode -eq 'listening' -and $script:followUpCapture -and ($now-$script:recorder.StartedUtc).TotalSeconds -ge $script:shortFollowUpMaxSeconds) { End-Recording $false; $script:notice='连续接话已达到 30 秒上限，识别后只保留草稿，不自动发送。' }
                elseif ($script:recMode -eq 'listening' -and ($now-$script:recorder.StartedUtc).TotalMinutes -ge 5) { End-Recording $script:handsFreeCapture }
            }
            if ($script:recMode -eq 'stopping' -and -not $script:recorder.IsStopping) {
                if ($script:recorder.Error) { throw $script:recorder.Error }
                if (-not (Test-Path -LiteralPath $script:recordPath)) { throw '录音没有保存成功，请重新录一次。' }
                Begin-Transcription $script:recordPath $script:submitAfterRecognition
            }
            if ($script:asrJob -and $script:asrJob.Process.HasExited) {
                $job=$script:asrJob; $script:asrJob=$null
                $result=if (Test-Path -LiteralPath $job.Output) { Get-Content -LiteralPath $job.Output -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
                $code=$job.Process.ExitCode; Close-Job $job
                $script:recMode='idle'; $InputBox.IsReadOnly=$false
                $script:handsFreeCapture=$false
                $script:followUpCapture=$false
                if ($code -ne 0 -or -not $result -or -not $result.ok -or $result.error) { throw '语音识别没有完成，请重新说一次。' }
                if ($job.Generation -eq $script:voiceGeneration -and $job.ThreadId -eq $script:threadId -and -not $script:closing -and
                    (-not ($job.FromWake -or $job.FromFollowUp) -or (Test-ShortFollowUpGeneration $job.FollowUpGeneration $job.ThreadId))) {
                    $recognized=[string]$result.text
                    $InputBox.Text=if ($job.Prefix -and $recognized.Trim()) { $job.Prefix + [Environment]::NewLine + $recognized } elseif ($job.Prefix) { $job.Prefix } else { $recognized }
                    $script:notice=if ($InputBox.Text.Trim()) { '文字已识别，可以修改或发送。' } else { '没有听清内容，已回到待机。' }
                    if ($job.FromFollowUp -and -not (Test-ShortFollowUpTranscript $recognized)) {
                        Close-ShortFollowUp $(if ($recognized.Trim()) { '内容不够明确，已保留草稿但不会自动发送。' } else { '没有听清内容，已回到唤醒待机。' })
                    } elseif ($job.SendAfter -and $recognized.Trim()) {
                        $source=if ($job.FromFollowUp) { 'follow-up' } elseif ($job.FromWake) { 'wake' } else { '' }
                        $script:autoDispatch=@{Generation=$job.Generation;ThreadId=$job.ThreadId;Text=$InputBox.Text.Trim();VoiceSource=$source;FollowUpGeneration=$job.FollowUpGeneration}
                        if ($job.FromFollowUp -and $script:shortFollowUp) { $script:shortFollowUp.Phase='dispatching'; $script:shortFollowUp.DraftText=$InputBox.Text.Trim(); $script:shortFollowUp.Deadline=$now.AddMinutes(1) }
                        $script:submitAfterRecognition=$false
                    } elseif ($job.FromFollowUp) { Close-ShortFollowUp }
                }
            }
            if ($script:bridgeJob -and $script:bridgeJob.Process.HasExited) {
                $job=$script:bridgeJob; $script:bridgeJob=$null
                try { $result=if (Test-Path -LiteralPath $job.Output) { Get-Content -LiteralPath $job.Output -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null } } catch { $result=$null }
                $purpose=$job.Purpose
                $receiptState=if ($purpose -eq 'send') { Get-SendReceiptState $result $job.Request.threadId $job.Request.requestId } else { '' }
                if ($purpose -eq 'send' -and $receiptState -in @('accepted','rejected')) { Clear-PendingSend $job.Request.threadId }
                Sync-PendingSend
                Close-Job $job
                $InputBox.IsReadOnly=($script:recMode -ne 'idle')
                if ($purpose -eq 'voice-manage') {
                    [void](Complete-VoiceDesktopAction -Result $result -Context $job.VoiceDesktopActionContext)
                } elseif ($purpose -in @('voice-create','voice-create-status')) {
                    [void](Complete-VoiceTaskCreate -Result $result -Context $job.VoiceTaskCreateContext)
                } elseif ($purpose -eq 'voice-create-bind') {
                    [void](Complete-VoiceCreatedTaskRead -Result $result -Context $job.VoiceTaskCreateContext)
                } elseif ($purpose -eq 'voice-find') {
                    [void](Complete-VoiceTaskSearch -Result $result -Context $job.VoiceTaskSwitchContext)
                } elseif ($purpose -eq 'voice-bind') {
                    [void](Complete-VoiceTaskBind -Result $result -Context $job.VoiceTaskSwitchContext)
                } elseif ($purpose -eq 'bind') {
                    $bound=Complete-ManualTaskBinding $result $job.TaskBindingContext
                    if ($bound -and $TestAudioPath) { $script:recMode='transcribing'; Begin-Transcription $TestAudioPath $false; $TestAudioPath='' }
                } elseif (-not $result -or -not $result.ok) {
                    if ($job.VoiceSource -and (Test-ShortFollowUpGeneration $job.FollowUpGeneration $job.Request.threadId)) { Close-ShortFollowUp }
                    $script:notice=if ($script:pendingUncertain) { '发送状态待确认，请先在 Codex 查看，核对后可在托盘解除。' } elseif ($result.error.message) { 'Codex 连接失败：' + [string]$result.error.message } else { '无法连接 Codex，请确认它正在运行。' }
                } elseif ($purpose -eq 'list') { Set-TaskCandidates $result.threads }
                elseif ($purpose -eq 'send') {
                    if ($receiptState -eq 'accepted') {
                        $script:sent++
                        $currentReceipt=($job.Request.threadId -ceq $script:threadId -and
                            (-not $job.VoiceSource -or ((Test-ShortFollowUpGeneration $job.FollowUpGeneration $job.Request.threadId) -and
                                $job.VoiceGeneration -eq $script:voiceGeneration -and $InputBox.Text.Trim() -ceq $job.Request.text)))
                        if ($currentReceipt) {
                            # Move out of dispatching before clearing the acknowledged
                            # text, so the normal edit handler does not cancel this turn.
                            if ($job.VoiceSource) { Start-ShortFollowUpWait ([string]$job.VoiceSource) $job.FollowUpGeneration $job.Request.threadId $job.UserTurnBaseline }
                            $script:busy=$true; $script:notice='已发送，Codex 正在处理…'; $InputBox.Text=''
                        }
                    }
                    else { if ($job.VoiceSource -and (Test-ShortFollowUpGeneration $job.FollowUpGeneration $job.Request.threadId)) { Close-ShortFollowUp }; $script:notice='发送回执不完整，请先到 Codex 核对，程序不会重发。' }
                }
                elseif ($purpose -eq 'open') { $script:notice='已打开当前 Codex 任务。' }
            }
            if ($script:connected -and ($now-$script:lastTailRead).TotalMilliseconds -ge 550) {
                $answers=@(Read-BoundTaskAnswers $now)
                if ($script:tail.UserTurnVersion -ne $script:lastUserVersion) {
                    Stop-Output; $script:busy=$true; $script:lastUserVersion=$script:tail.UserTurnVersion
                }
                foreach ($answer in $answers) {
                    if (Get-Command Clear-VoicePlaybackBookmark -ErrorAction SilentlyContinue) { Clear-VoicePlaybackBookmark }
                    $script:received++; $script:latest=$answer.Text
                    $AnswerBox.Text=$answer.Text; $AnswerBox.ScrollToHome()
                    if ($answer.UserTurnVersion -eq $script:tail.UserTurnVersion) {
                        $script:busy=$false; $script:notice='回答完成。'
                        if ($script:autoRead) { Queue-AnswerSpeech $answer.Text }
                        if (Get-Command Register-ShortFollowUpAnswer -ErrorAction SilentlyContinue) { Register-ShortFollowUpAnswer $answer }
                    }
                }
            }
            Try-AutoDispatch
            Complete-AssistantSpeech
            $playbackState=[CodexReader.AudioPlayer]::State
            $playing=($playbackState -eq 'playing')
            $playbackHeld=($playbackState -in @('playing','paused'))
            # The acknowledgement transition must observe natural completion
            # before generic cleanup changes the player from stopped to closed.
            if (-not $playbackHeld -and $script:audioPath -and $script:handsFreePhase -ne 'acknowledging') { [CodexReader.AudioPlayer]::Stop(); Remove-OwnedFiles @($script:audioPath); $script:audioPath='' }
            if (-not $playbackHeld -and -not $script:ttsJob -and $script:speechQueue.Count -gt 0 -and (Safe-To-Play)) { Begin-Speech $script:speechQueue.Dequeue() }
            Update-ShortFollowUp $now

            Update-AssistantAudioLevel
            $StatusLabel.Text=if ($script:recMode -eq 'arming') { if ($script:followUpCapture) { '连续接话 · 正在准备麦克风…' } else { '正在准备麦克风…' } }
                elseif ($script:recMode -eq 'listening') { $(if ($script:followUpCapture) { '连续接话 · 正在听 · ' } else { '正在听 · ' }) + [int]($now-$script:recorder.StartedUtc).TotalSeconds + ' 秒' }
                elseif ($script:recMode -in @('stopping','transcribing')) { '正在把语音转成文字…' }
                elseif ($now -lt $script:localCommandNoticeUntil) { $script:localCommandMessage + $(if ($script:pendingUncertain) { ' · 上次发送仍待核对' } elseif ($script:bridgeJob -and $script:bridgeJob.Purpose -eq 'send') { ' · 消息正在发送' }) }
                elseif ($script:bridgeJob -and $script:bridgeJob.Purpose -eq 'send') { '正在发送给 Codex…' }
                elseif ($script:pendingUncertain) { '发送状态待确认 · 请在 Codex 核对' }
                elseif ($script:handsFreeEnabled -and (Test-WakeRecoveryPending)) { $script:wakeRecovery.Message }
                elseif ($script:handsFreePhase -in @('releasing','answering-wake','acknowledging')) { '在 · 请说你的问题' }
                elseif ($script:handsFreeEnabled -and $InputBox.Text.Trim()) { '有未发送草稿 · 唤醒已暂停 · 请打开字幕处理' }
                elseif ($script:bindingReadError) { '任务连接异常 · 普通消息暂停 · 可语音切换任务' }
                elseif ($playbackState -eq 'paused') { if ($script:playbackNotice) { $script:playbackNotice } else { '已暂停朗读，点击继续可接着听。' } }
                elseif ($playing) { '正在朗读 · '+$VoiceCombo.SelectedItem.name }
                elseif ($script:ttsJob) { '正在准备语音…' }
                elseif ($script:handsFreeEnabled -and (-not $script:mic.Ready -or $script:mic.LastError)) { '正在检查麦克风状态，语音唤醒暂缓…' }
                elseif ($script:handsFreeEnabled -and (Test-ExternalCapture)) { '其他应用正在使用麦克风，语音唤醒已暂缓。' }
                elseif ($script:handsFreeEnabled -and $script:handsFreePhase -eq 'listening') { if (-not $script:wakeListener.IsReady) { '正在准备语音唤醒…' } elseif ($script:busy) { 'Codex 正在处理 · 可以唤醒补充' } else { '免点击待机 · 喊“'+$script:wakePhrase+'”' } }
                elseif ($script:errorText -or $script:pendingUncertain) { $script:notice }
                elseif ($script:busy) { 'Codex 正在处理…' }
                else { $script:notice }
            $SpeakButton.Content=if ($script:recMode -eq 'listening') { '结束录音' } elseif ($script:recMode -ne 'idle') { '请稍等…' } else { '开始说话' }
            $SpeakButton.IsEnabled=($script:connected -and $script:recMode -in @('idle','listening') -and -not ($script:bridgeJob -and $script:bridgeJob.Purpose -eq 'send'))
            $localReady=($script:recMode -eq 'idle' -and $null -ne (Get-AssistantVoiceCommand $InputBox.Text))
            $SendButton.IsEnabled=($localReady -or ($script:connected -and -not $script:bindingReadError -and -not $script:bridgeJob -and $script:recMode -ne 'arming' -and -not $script:pendingUncertain))
            $StopButton.Content=if ($script:shortFollowUp -or $script:followUpCapture) { '结束接话' } elseif ($script:recMode -ne 'idle') { '取消录音' } else { '停止朗读' }
            $AnswerStateLabel.Text=if ($script:busy) { '处理中' } elseif ($playing) { '正在朗读' } else { '文字 · 语音' }
            $FooterHint.Text=if ($script:shortFollowUp -or $script:followUpCapture) { '连续接话有时限 · 可随时点“结束接话”' } elseif ($script:handsFreeEnabled -and $script:recMode -eq 'idle' -and $InputBox.Text.Trim()) { '草稿已保留 · 发送或自行清空后恢复唤醒；也可点击开始说话继续补充' } elseif ($script:handsFreeEnabled) { '喊“'+$script:wakePhrase+'”唤醒' } elseif ($script:autoSend) { '停顿两秒后自动发送' } else { '说完点发送，或先检查文字' }
            if ($followUpItem) { $followUpItem.Enabled=[bool]($script:shortFollowUp -or $script:followUpCapture) }
            Update-DesktopDisplay
            if ($script:positionDirty -and ($now-$script:lastPositionChange).TotalMilliseconds -gt 700) { $script:positionDirty=$false; Save-Settings }
            if ($TestMode -and $TestCommandPath -and (Test-Path -LiteralPath $TestCommandPath)) {
                $command=Get-Content -LiteralPath $TestCommandPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($command.id -and $command.id -ne $script:lastTestCommand) {
                    $script:lastTestCommand=$command.id
                    switch ($command.action) {
                        'record' { Begin-Recording }
                        'cancel' { Cancel-Recording }
                        'stop' { Stop-Output '已停止朗读。' }
                        'end' { End-Recording $false }
                        'send' { Send-Text }
                        'transcribe' { Stop-Output; $script:recordPrefix=''; Begin-Transcription ([string]$command.path) $false }
                        'compact' { Set-CaptionsVisible (-not $script:captionsVisible) }
                        'hide' { Set-FloatingVisible $false }
                        'show' { Set-FloatingVisible $true }
                        'handsfree-on' { Set-HandsFree $true }
                        'handsfree-off' { Set-HandsFree $false }
                        'wake' { Invoke-WakeActivation }
                        'wake-file' { Suspend-WakeListener; $script:testWakeInputPath=[string]$command.path; Set-HandsFree $true }
                        'question-file' { Cancel-Recording; Stop-Output; $script:recordPrefix=''; $script:handsFreeCapture=$true; Begin-Transcription ([string]$command.path) $true }
                        'clear-input' { $InputBox.Text='' }
                        'exit' { Exit-Assistant }
                    }
                }
            }
        } catch {
            $script:errorText=$_.Exception.Message
            Stop-Output
            if ($script:recMode -ne 'idle') { Cancel-Recording }
            $script:notice='遇到问题：'+$script:errorText
            $StatusLabel.Text=$script:notice
        }
        if ($StatusPath -and ([DateTime]::UtcNow-$script:lastStatusWrite).TotalMilliseconds -ge 250) {
            $statusData=@{version=7;bargeInEnabled=$script:bargeInEnabled;shortFollowUpEnabled=$script:shortFollowUpEnabled;shortFollowUpPhase=if($script:shortFollowUp){$script:shortFollowUp.Phase}else{'idle'};followUpCapture=$script:followUpCapture;echoReady=(Test-FullDuplexReady);echoQuestionCapture=$script:echoQuestionCapture;handsFreeEnabled=$script:handsFreeEnabled;handsFreePhase=$script:handsFreePhase;wakePhrase=$script:wakePhrase;wakeCount=$script:wakeCount;wakeListening=$script:wakeListener.IsListening;wakeReady=$script:wakeListener.IsReady;autoSendPrepared=$script:autoSendPrepared;connected=$script:connected;threadId=$script:threadId;recordingMode=$script:recMode;level=$script:level;status=$StatusLabel.Text;received=$script:received;spoken=$script:spoken;sent=$script:sent;busy=$script:busy;error=$script:errorText;micReady=$script:mic.Ready;micActive=$script:mic.AnyCaptureActive;topmost=$window.Topmost;windowVisible=$window.IsVisible;voice=$script:voiceId;autoSend=$script:autoSend;playerState=[CodexReader.AudioPlayer]::State;compact=(-not $script:captionsVisible);style=$script:waveStyle;waveSize=$script:waveSize;speechRate=$script:speechRate;autoRead=$script:autoRead;settingsVisible=$desktop.SettingsWindow.IsVisible;captionVisible=$desktop.CaptionWindow.IsVisible;pid=$PID}
            if ($TestMode) { $statusData.inputText=$InputBox.Text; $statusData.answerText=$AnswerBox.Text; $statusData.testCommand=$script:lastTestCommand; $statusData.taskCandidateCount=@($script:taskCandidates).Count; $statusData.selectedTaskId=if ($TaskCombo.SelectedItem) { [string]$TaskCombo.SelectedItem.threadId } else { '' } }
            $statusData.localCommandCount=$script:localCommandCount
            $statusData.bindingHealthy=($script:connected -and -not $script:bindingReadError)
            $statusData.bindingReadError=$script:bindingReadError
            $statusData.lastLocalCommand=$script:lastLocalCommand
            $statusData.localCommandMessage=$script:localCommandMessage
            $statusData.levelSource=$script:levelSource
            $statusData.wakeKeywordThreshold=$script:wakeListener.KeywordThreshold
            $statusData.wakeAudioLevel=$script:wakeListener.AudioLevel
            $statusData.wakeActivationVersion=$script:wakeListener.ActivationVersion
            $statusData.wakeAcceptedActivationVersion=$script:lastWakeVersion
            $statusData.wakeStopping=$script:wakeListener.IsStopping
            $statusData.draftPending=[bool]$InputBox.Text.Trim()
            $statusData.wakeBlockedByDraft=[bool]($script:handsFreeEnabled -and $script:recMode -eq 'idle' -and $InputBox.Text.Trim())
            $statusData.wakeError=$script:wakeListener.Error
            $statusData.micGuardError=$script:mic.LastError
            $statusData.micGuardScanCount=$script:mic.ScanCount
            $health=$script:wakeListener.GetHealthSnapshot()
            $statusData.wakeHealth=$health.State
            $statusData.wakeHealthReason=$health.Reason
            $statusData.wakeHasActivated=$health.HasActivated
            $statusData.wakeCapturedSamples=$health.CapturedSamples
            $statusData.wakeProcessedSamples=$health.ProcessedSamples
            $statusData.wakeCaptureAgeMs=$health.CaptureAgeMs
            $statusData.wakeProgressAgeMs=$health.ProgressAgeMs
            $statusData.wakeRecoveryPhase=$script:wakeRecovery.Phase
            $statusData.wakeRecoveryMessage=$script:wakeRecovery.Message
            $statusData.wakeRecoveryReason=$script:wakeRecovery.Reason
            $statusData.wakeRecoveryAttempts=$script:wakeRecovery.AttemptCount
            $statusData.externalCapturePids=@($script:mic.Sessions | Where-Object { $_.Active -and [int]$_.ProcessId -ne $PID } | ForEach-Object { $_.ProcessId } | Select-Object -Unique)
            $statusData.taskSwitchPhase=if ($script:voiceTaskSwitch) { $script:voiceTaskSwitch.Phase } else { 'idle' }
            $statusData.taskSwitchCandidateCount=if ($script:voiceTaskSwitch) { @($script:voiceTaskSwitch.Candidates).Count } else { 0 }
            $statusData.bridgePurpose=if ($script:bridgeJob) { $script:bridgeJob.Purpose } else { '' }
            $statusData.desktopActionState=[string]$script:desktopActionState
            $statusData.desktopActionOperation=[string]$script:desktopActionOperation
            $statusData.speechPreparing=[bool]$script:ttsJob
            $statusData.speechQueued=$script:speechQueue.Count
            $statusData.taskCreatePhase=if ($script:voiceTaskCreate) { $script:voiceTaskCreate.Phase } else { 'idle' }
            $statusData.taskCreateBlocksSend=[bool](Test-VoiceTaskCreateBlocksSend)
            $statusData.taskCreateMessage=if ($script:voiceTaskCreate) { $script:voiceTaskCreate.Message } else { '' }
            $statusData.appVersion=$script:appVersion
            $statusData.workerWarning=[string]$script:workerWarning
            $statusData.settingsWarning=[string]$script:settingsWarning
            try {
                $layerStatus=Get-DesktopTopmostStatus $desktop
                if ($layerStatus) {
                    $statusData.nativeTopmost=[bool]($layerStatus.Windows | Where-Object { $_.Role -eq 'main' }).NativeTopmost
                    $statusData.topmostRecoveryCount=$layerStatus.ForegroundRepairs
                    $statusData.topmostError=$layerStatus.LastError
                }
            } catch { $statusData.topmostError=$_.Exception.Message }
            # Readers may briefly hold the status file open. Telemetry must never
            # unwind the dispatcher callback or stop the UI timer.
            try {
                $statusTemporary=$StatusPath+'.tmp'
                [IO.File]::WriteAllText($statusTemporary,($statusData | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
                if (Test-Path -LiteralPath $StatusPath) { [IO.File]::Replace($statusTemporary,$StatusPath,[NullString]::Value) } else { [IO.File]::Move($statusTemporary,$StatusPath) }
            } catch { }
            $script:lastStatusWrite=[DateTime]::UtcNow
        }
    })
    $window.Add_Closed({ $script:closing=$true; Reset-ManualTaskBinding; Reset-VoiceTaskSwitch; Invalidate-VoiceTaskCreateBinding -Reason '声伴已关闭'; $script:voiceGeneration++; $script:autoDispatch=$null; Suspend-WakeListener; $timer.Stop(); Stop-Output; if ($script:recMode -ne 'idle') { Cancel-Recording }; if (-not $PreviewPath) { $window.Dispatcher.BeginInvokeShutdown([Windows.Threading.DispatcherPriority]::Background) } })
    if ($PreviewPath) {
        $TaskLabel.Text='当前 Codex 任务'; $StatusLabel.Text='点击开始说话'; $window.Show(); $window.UpdateLayout()
        $render=New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$window.ActualWidth,[int]$window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
        $render.Render($window)
        $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($render))
        $file=[IO.File]::Create($PreviewPath); $encoder.Save($file); $file.Dispose(); $window.Close()
    } else {
        $script:mic.Start()
        $tray.Visible=$true
        if ($script:threadId) { [void](Begin-ManualTaskBinding $script:threadId -Startup) } else { Show-AssistantSettings }
        $timer.Start(); if ($script:floatingVisible) { $window.Show() }; [Windows.Threading.Dispatcher]::Run()
    }
} catch {
    if ($StatusPath) { @{error=$_.Exception.Message} | ConvertTo-Json | Set-Content -LiteralPath $StatusPath -Encoding UTF8 }
    if ($TestMode -or $PreviewPath) { Write-Error $_ -ErrorAction Continue } else { [void][Windows.MessageBox]::Show(('无法启动语音助手：'+$_.Exception.Message),'Codex 语音助手') }
} finally {
    $script:closing=$true
    Reset-ManualTaskBinding
    Reset-VoiceTaskSwitch
    Invalidate-VoiceTaskCreateBinding -Reason '声伴已退出'
    if ($timer) { $timer.Stop() }
    Stop-Output
    if ($script:wakeListener) { $script:wakeListener.Dispose() }
    if ($script:recorder) { $script:recorder.Dispose() }
    if ($script:manualRecorder -and -not [object]::ReferenceEquals($script:recorder,$script:manualRecorder)) { $script:manualRecorder.Dispose() }
    if ($script:mic) { $script:mic.Dispose() }
    if ($script:asrJob) { Close-Job $script:asrJob -Kill }
    # Dispatched sends and task creations must finish their receipt ledgers.
    if ($script:bridgeJob -and $script:bridgeJob.Purpose -notin @('send','voice-create','voice-manage')) { Close-Job $script:bridgeJob -Kill }
    if ($tray) { $tray.Visible=$false; $tray.Dispose() }
    if ($menu) { $menu.Dispose() }
    if ($desktop) { try { Close-DesktopTopmost $desktop; Close-DesktopShell $desktop } catch {} }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
