# Windows PowerShell 5.1: real WPF controls; the composer-recovery case briefly
# shows our own windows. Speech, microphones and Codex calls are mocked; settings
# serialization writes only to this test's work directory.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ProductionAst.ps1')
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run with powershell.exe -NoProfile -STA -File tests\Test-DesktopController.ps1' }
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=Join-Path $projectRoot 'src'
$runRoot=Join-Path $projectRoot 'work\tests\desktop-controller'
[void][IO.Directory]::CreateDirectory($runRoot)
$fixture=Join-Path $runRoot 'synthetic-rollout.jsonl'
[IO.File]::WriteAllText($fixture,'',(New-Object Text.UTF8Encoding($false)))
$tokens=$null; $parseErrors=$null
$ast=(Read-TestProductionAst (Join-Path $sourceRoot 'Assistant.ps1'))
if ($parseErrors.Count) { throw $parseErrors[0].Message }
foreach ($name in @('Apply-Thread','Get-SendReceiptState','Sync-PendingSend','Send-Text')) {
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if (-not $definition) { throw "Missing production function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$answerNode=$ast.Find({param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Extent.Text -match '^foreach \(\$answer in \$answers\)'},$true)
if (-not $answerNode) { throw 'Missing production completed-answer handler.' }
$answerHandler=[scriptblock]::Create($answerNode.Extent.Text)

# Do not load real AudioPlayer, recorders, MicGuard, workers or the app entrypoint.
Add-Type 'namespace CodexReader { public static class AudioPlayer { public static string State = "playing"; } }'
$script:effects=New-Object Collections.ArrayList
$script:saved=New-Object Collections.ArrayList
$script:results=New-Object Collections.ArrayList
function Save-Settings {
    if ($script:preferenceSaveFails) { throw 'Simulated preference write failure.' }
    [void]$script:saved.Add(@{threadId=$script:threadId;cwd=$script:boundDirectory;directoryFilter=$script:directoryFilter;voice=$script:voiceId;rate=$script:speechRate;style=$script:waveStyle;size=$script:waveSize;autoRead=$script:autoRead;bargeInEnabled=$script:bargeInEnabled;shortFollowUpEnabled=$script:shortFollowUpEnabled})
}
function Start-Bridge($Request,[string]$Purpose) { [void]$script:effects.Add(@{action='bridge';purpose=$Purpose;request=$Request.Clone()}); return $true }
function Stop-Output([string]$Message='') { [void]$script:effects.Add(@{action='stop'}); $script:speechQueue.Clear() }
function Queue-AnswerSpeech([string]$Text) { [void]$script:effects.Add(@{action='queue';text=$Text}); $script:speechQueue.Enqueue($Text) }
function Suspend-WakeListener { [void]$script:effects.Add(@{action='suspendWake'}) }
function Reconcile-PendingSends {}
function New-TranscriptTail($Path) {
    if ($script:tailFailure) { throw 'Simulated unreadable rollout after existence check.' }
    return [pscustomobject]@{Path=$Path;UserTurnVersion=1;Latest='saved answer';Offset=41}
}
function Cancel-Recording { $script:recMode='idle'; [void]$script:effects.Add(@{action='cancel'}) }
function Set-HandsFree([bool]$Enabled) { [void]$script:effects.Add(@{action='setHandsFree';enabled=$Enabled;bargeInEnabled=$script:bargeInEnabled}); $script:handsFreeEnabled=$Enabled }
function Test-FullDuplexReady { return [bool]$script:fakeEchoReady }
function Begin-Recording { [void]$script:effects.Add(@{action='record';floatingVisible=$window.IsVisible;captionVisible=$desktop.CaptionWindow.IsVisible;editingVisible=($desktop.Controls.CaptionInputPanel.Visibility -eq 'Visible' -and $desktop.Controls.CaptionActions.Visibility -eq 'Visible')}) }
function Assert-That([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Count-Effect([string]$Action) { return @($script:effects | Where-Object { $_.action -eq $Action }).Count }
function Invoke-Click($Control) { $Control.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
function Test-Case([string]$Name,[scriptblock]$Body) {
    try { & $Body; [void]$script:results.Add(@{name=$Name;passed=$true}) }
    catch { [void]$script:results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message}) }
}

. (Join-Path $sourceRoot 'DesktopShell.ps1')
. (Join-Path $sourceRoot 'DesktopController.ps1')
. (Join-Path $SourceRoot 'VoiceCommands.ps1')
. (Join-Path $SourceRoot 'TaskSwitch.ps1')
. (Join-Path $SourceRoot 'TaskCreate.ps1')
. (Join-Path $SourceRoot 'LocalCommands.ps1')
$script:desktop=New-DesktopShell
$script:window=$desktop.Window
foreach ($key in $desktop.Controls.Keys) { Set-Variable -Name $key -Value $desktop.Controls[$key] -Scope Script }
$script:threadId=''; $script:boundDirectory=''; $script:directoryFilter=''; $script:bridgeJob=$null
$script:connected=$false; $script:recMode='idle'; $script:autoRead=$true; $script:autoSend=$false
$script:pinned=$true; $script:captionsVisible=$false; $script:floatingVisible=$false
$script:handsFreeEnabled=$false; $script:handsFreePhase='off'; $script:wakePhrase='test'
$script:bargeInEnabled=$true; $script:shortFollowUpEnabled=$false; $script:shortFollowUp=$null; $script:followUpCapture=$false; $script:fakeEchoReady=$false; $script:wakeListener=[pscustomobject]@{Error=''}
$script:testWindowsShown=$false
$script:voiceGeneration=0; $script:autoDispatch=$null; $script:pendingSends=@{}; $script:pendingUncertain=''
$workspace=$projectRoot
$catalogInitializer=[regex]::Match([IO.File]::ReadAllText((Join-Path $sourceRoot 'Assistant.ps1')), '(?m)^\$script:voiceCatalog = [^\r\n]+').Value
if (-not $catalogInitializer) { throw 'Missing production voice catalog initializer.' }
. ([scriptblock]::Create($catalogInitializer))
$script:voiceId=$script:voiceCatalog[0].id; $script:speechRate=0; $script:waveStyle='rays'; $script:waveSize=260
$script:savedLeft=$null; $script:savedTop=$null; $script:phaseClock=[Diagnostics.Stopwatch]::StartNew()
$script:speechQueue=New-Object 'Collections.Generic.Queue[string]'
$script:busy=$false; $script:level=0.0; $script:received=0; $script:latest=''
$TestMode=$false; $TestTranscriptPath=''
$taskA=[pscustomobject]@{threadId=[Guid]::NewGuid().ToString();title='Task A';cwd=(Join-Path $runRoot 'folder-a');rolloutPath=$fixture;status='active'}
$taskB=[pscustomobject]@{threadId=[Guid]::NewGuid().ToString();title='Task B';cwd=(Join-Path $runRoot 'folder-b');rolloutPath=$fixture;status='idle'}
$requestA=[Guid]::NewGuid().ToString(); $requestB=[Guid]::NewGuid().ToString()

try {
    Initialize-DesktopController
    Test-Case 'first launch and refresh cannot invent a binding' {
        Assert-That (-not $script:threadId -and -not $script:connected) 'Initialization bound a task.'
        $before=Count-Effect 'bridge'
        Refresh-AssistantTasks
        Assert-That ((Count-Effect 'bridge') -eq $before+1) 'Refresh did not request a list.'
        $last=$script:effects[$script:effects.Count-1]
        Assert-That ($last.request.action -eq 'list' -and -not $last.request.ContainsKey('threadId')) 'First list needs an existing task.'
        Set-TaskCandidates @($taskA,$taskB)
        Assert-That ($TaskCombo.SelectedIndex -eq -1) 'First candidate was automatically selected.'
        Assert-That ($script:notice -eq '对话列表已更新，选择后点击“连接所选任务”。') 'The refreshed list did not explain the explicit connection step.'
        Set-TaskCandidates @($taskA,$taskB) '部分对话名称尚未同步。'
        Assert-That ($script:notice -eq '部分对话名称尚未同步。') 'The title synchronization warning was hidden.'
        Assert-That ($TaskCombo.SelectedIndex -eq -1 -and -not $script:threadId) 'A title warning changed the target.'
        $before=Count-Effect 'bridge'; Invoke-Click $BindTaskButton
        Assert-That ((Count-Effect 'bridge') -eq $before) 'Bind submitted without a selected task.'
    }
    Test-Case 'selection requires an explicit bind and read validation' {
        $TaskCombo.SelectedItem=$taskA
        Assert-That (-not $script:threadId) 'Selecting a row changed the binding.'
        $before=Count-Effect 'bridge'; Invoke-Click $BindTaskButton
        Assert-That ((Count-Effect 'bridge') -eq $before+1) 'Bind button did not request validation.'
        $last=$script:effects[$script:effects.Count-1]
        Assert-That ($last.purpose -eq 'bind' -and $last.request.action -eq 'read' -and $last.request.threadId -eq $taskA.threadId) 'Bind validation targeted another task.'
        Assert-That (-not $script:threadId) 'Task bound before the read receipt.'
    }
    Test-Case 'validated binding persists cwd and preserves per-task uncertainty' {
        $script:pendingSends[$taskA.threadId]=@{requestId=$requestA}
        $script:pendingSends[$taskB.threadId]=@{requestId=$requestB}
        Apply-Thread $taskA
        Assert-That ($script:threadId -eq $taskA.threadId -and $script:boundDirectory -eq $taskA.cwd) 'Live task metadata was not applied.'
        Assert-That ($script:saved[$script:saved.Count-1].threadId -eq $taskA.threadId) 'Binding was not saved.'
        Assert-That ($script:pendingUncertain -eq $requestA -and $script:pendingSends.Count -eq 2) 'Binding lost an uncertain request.'
        Apply-Thread $taskB
        Assert-That ($script:pendingUncertain -eq $requestB -and $script:pendingSends.Count -eq 2) 'Switching lost a per-task lock.'
        Apply-Thread $taskA
        Assert-That ($script:pendingUncertain -eq $requestA) 'Returning to a task lost its lock.'
    }
    Test-Case 'directory filtering and refresh do not change the bound task' {
        $DirectoryCombo.SelectedItem=@($DirectoryCombo.Items | Where-Object { $_.path -eq $taskB.cwd })[0]
        Assert-That ($TaskCombo.Items.Count -eq 1 -and $TaskCombo.Items[0].threadId -eq $taskB.threadId) 'Directory filter is incorrect.'
        Assert-That ($TaskCombo.SelectedIndex -eq -1) 'Filter silently selected a different task.'
        Set-TaskCandidates @($taskB)
        Assert-That ($script:threadId -eq $taskA.threadId -and $script:boundDirectory -eq $taskA.cwd) 'Refresh changed the live binding or cwd.'
        Assert-That ($script:pendingUncertain -eq $requestA) 'Refresh cleared uncertainty.'
    }
    Test-Case 'failed rollout initialization cannot leave a mixed live binding' {
        $previousId=$script:threadId; $previousCwd=$script:boundDirectory; $previousTail=$script:tail
        $previousConnected=$script:connected; $previousPending=$script:pendingUncertain
        $script:tailFailure=$true; $caught=$false
        try {
            try { Apply-Thread $taskB } catch { $caught=$true }
            Assert-That $caught 'The injected rollout failure did not reach the binding path.'
            $unchanged=($script:threadId -eq $previousId -and $script:boundDirectory -eq $previousCwd -and [object]::ReferenceEquals($script:tail,$previousTail))
            Assert-That (-not $script:connected -or $unchanged) 'Failed bind mixed the new destination with an old active transcript.'
        } finally {
            $script:tailFailure=$false; $script:threadId=$previousId; $script:boundDirectory=$previousCwd
            $script:tail=$previousTail; $script:connected=$previousConnected; $script:pendingUncertain=$previousPending
        }
    }
    Test-Case 'rebinding the same task preserves the active transcript cursor' {
        $previousTail=$script:tail; $previousTail.Offset=314
        $previousStop=Count-Effect 'stop'
        Apply-Thread $taskA
        Assert-That ([object]::ReferenceEquals($script:tail,$previousTail) -and $script:tail.Offset -eq 314) 'Rebinding discarded the active transcript cursor.'
        Assert-That ((Count-Effect 'stop') -eq $previousStop) 'Rebinding the current task interrupted playback.'
    }
    Test-Case 'binding is blocked while a request or recording is active' {
        $TaskCombo.SelectedItem=$taskB
        $before=Count-Effect 'bridge'
        $script:bridgeJob=@{Purpose='send'}; Invoke-Click $BindTaskButton; $script:bridgeJob=$null
        $script:recMode='transcribing'; Invoke-Click $BindTaskButton; $script:recMode='idle'
        Assert-That ((Count-Effect 'bridge') -eq $before) 'Binding bypassed the in-flight guard.'
    }
    Test-Case 'all waveform styles and sizes synchronize without stopping playback' {
        $before=Count-Effect 'stop'
        foreach ($entry in @($StyleCombo.Items)) {
            $StyleCombo.SelectedItem=$entry
            Assert-That ($script:waveStyle -eq $entry.id) 'Style preference did not synchronize.'
            $expected=if ($entry.id -in @('bars','flow')) { $script:waveSize*0.4 } else { $script:waveSize }
            Assert-That ([Math]::Abs($window.Height-$expected) -lt 0.01) 'Style has incorrect window dimensions.'
        }
        foreach ($size in @(180,260,360)) { $SizeSlider.Value=$size; Assert-That ($script:waveSize -eq $size -and $window.Width -eq $size) 'Size did not synchronize.' }
        Assert-That ((Count-Effect 'stop') -eq $before) 'Appearance stopped playback.'
    }
    Test-Case 'every voice and rate persists without interrupting existing audio' {
        $before=Count-Effect 'stop'
        Assert-That ($VoiceCombo.Items.Count -eq 7) 'Voice dropdown must contain seven separate choices.'
        Assert-That ($StyleCombo.Items.Count -eq 6 -and $RateCombo.Items.Count -eq 4) 'Style or rate choices were collapsed.'
        foreach ($entry in @($VoiceCombo.Items)) {
            Assert-That ($entry -isnot [array] -and $entry.id -is [string]) 'A voice choice contains multiple catalog entries.'
            $VoiceCombo.SelectedItem=$entry
            Assert-That ($script:voiceId -is [string] -and $script:voiceId -ceq $entry.id) 'Voice selection was not applied.'
        }
        foreach ($entry in @($RateCombo.Items)) { $RateCombo.SelectedItem=$entry; Assert-That ($script:speechRate -eq $entry.value) 'Rate selection was not applied.' }
        Assert-That ($script:saved[$script:saved.Count-1].rate -eq $script:speechRate) 'Rate was not persisted.'
        Assert-That ((Count-Effect 'stop') -eq $before) 'Voice or rate selection stopped playback.'
    }
    Test-Case 'turning automatic reading off affects only future answers' {
        $script:speechQueue.Clear(); $script:speechQueue.Enqueue('already queued')
        $before=Count-Effect 'stop'; $AutoReadToggle.IsChecked=$false; Invoke-Click $AutoReadToggle
        Assert-That (-not $script:autoRead) 'Auto-read preference did not turn off.'
        Assert-That ((Count-Effect 'stop') -eq $before -and $script:speechQueue.Count -eq 1) 'Auto-read toggle interrupted existing playback or queue.'
    }
    Test-Case 'barge-in changes restart only an enabled listener and persist the new mode' {
        $oldEnabled=$script:handsFreeEnabled; $oldBargeIn=$script:bargeInEnabled
        try {
            $script:handsFreeEnabled=$true; $script:bargeInEnabled=$true; Sync-DesktopPreferences
            foreach ($newMode in @($false,$true)) {
                $oldMode=$script:bargeInEnabled; $start=$script:effects.Count; $savedBefore=$script:saved.Count
                $BargeInToggle.IsChecked=$newMode; Invoke-Click $BargeInToggle
                $transitions=@($script:effects | Select-Object -Skip $start | Where-Object { $_.action -eq 'setHandsFree' })
                Assert-That ($transitions.Count -eq 2 -and -not $transitions[0].enabled -and $transitions[1].enabled) 'Changing echo mode did not disable and restart the active listener in order.'
                Assert-That ($transitions[0].bargeInEnabled -eq $oldMode -and $transitions[1].bargeInEnabled -eq $newMode) 'Listener restart used the old echo mode.'
                Assert-That ($script:handsFreeEnabled -and $script:bargeInEnabled -eq $newMode -and [bool]$BargeInToggle.IsChecked -eq $newMode) 'Echo preference and enabled-listener state did not synchronize.'
                Assert-That ($script:saved.Count -eq $savedBefore+1 -and $script:saved[$script:saved.Count-1].bargeInEnabled -eq $newMode) 'Echo mode change was not persisted once.'
            }
            $script:handsFreeEnabled=$false; $start=Count-Effect 'setHandsFree'
            $BargeInToggle.IsChecked=$false; Invoke-Click $BargeInToggle
            Assert-That ((Count-Effect 'setHandsFree') -eq $start -and -not $script:handsFreeEnabled) 'Changing echo mode unexpectedly enabled a disabled listener.'
            Assert-That (-not $script:saved[$script:saved.Count-1].bargeInEnabled) 'Disabled-listener echo preference was not saved.'
        } finally { $script:handsFreeEnabled=$oldEnabled; $script:bargeInEnabled=$oldBargeIn; Sync-DesktopPreferences }
    }
    Test-Case 'echo status distinguishes disabled half-duplex preparing ready and device error' {
        $oldEnabled=$script:handsFreeEnabled; $oldBargeIn=$script:bargeInEnabled
        try {
            $script:bargeInEnabled=$true; $script:handsFreeEnabled=$false; $script:fakeEchoReady=$false; $script:wakeListener.Error=''
            Update-DesktopDisplay
            Assert-That ($EchoStatusLabel.Text -like '*开启语音唤醒后检查*') 'Disabled wake mode did not explain when the device is checked.'
            $script:bargeInEnabled=$false; $script:handsFreeEnabled=$true
            Update-DesktopDisplay
            Assert-That ($EchoStatusLabel.Text -like '*轮流听说*' -and $EchoStatusLabel.Text -like '*朗读结束后*') 'Half-duplex mode incorrectly claimed wake during playback.'
            $script:bargeInEnabled=$true
            Update-DesktopDisplay
            Assert-That ($EchoStatusLabel.Text -like '*正在准备回声消除*' -and $EchoStatusLabel.Text -like '*设备不兼容*') 'Unready echo capture did not show preparation and fallback guidance.'
            $script:fakeEchoReady=$true
            Update-DesktopDisplay
            Assert-That ($EchoStatusLabel.Text -like '*回声消除已就绪*' -and $EchoStatusLabel.Text.Contains($script:wakePhrase)) 'Ready echo mode did not show the configured wake phrase.'
            $script:wakeListener.Error='Synthetic capture endpoint unavailable'
            Update-DesktopDisplay
            Assert-That ($EchoStatusLabel.Text -like '音频设备未就绪：*' -and $EchoStatusLabel.Text.Contains($script:wakeListener.Error) -and $EchoStatusLabel.Text -notlike '*已就绪*') 'A device error was hidden behind a stale ready state.'
        } finally { $script:handsFreeEnabled=$oldEnabled; $script:bargeInEnabled=$oldBargeIn; $script:fakeEchoReady=$false; $script:wakeListener.Error='' }
    }
    Test-Case 'short follow-up opt-in is explicit synchronized and persisted' {
        Assert-That (-not $script:shortFollowUpEnabled -and -not [bool]$ShortFollowUpToggle.IsChecked) 'Short follow-up was not off by default.'
        $before=$script:saved.Count; $ShortFollowUpToggle.IsChecked=$true; Invoke-Click $ShortFollowUpToggle
        Assert-That ($script:shortFollowUpEnabled -and [bool]$ShortFollowUpToggle.IsChecked) 'Short follow-up opt-in did not synchronize.'
        Assert-That ($script:saved.Count -eq $before+1 -and $script:saved[$script:saved.Count-1].shortFollowUpEnabled) 'Short follow-up opt-in was not persisted once.'
        $ShortFollowUpToggle.IsChecked=$false; Invoke-Click $ShortFollowUpToggle
        Assert-That (-not $script:shortFollowUpEnabled -and -not $script:saved[$script:saved.Count-1].shortFollowUpEnabled) 'Short follow-up opt-out was not persisted.'
    }
    Test-Case 'new answers obey auto-read and enabling does not replay history' {
        $script:autoRead=$false; $before=Count-Effect 'queue'
        $answers=@([pscustomobject]@{Text='new while disabled';UserTurnVersion=1}); . $answerHandler
        Assert-That ($AnswerBox.Text -eq 'new while disabled' -and (Count-Effect 'queue') -eq $before) 'Disabled auto-read still queued a new answer.'
        $AutoReadToggle.IsChecked=$true; Invoke-Click $AutoReadToggle
        Assert-That ((Count-Effect 'queue') -eq $before) 'Enabling auto-read replayed old text.'
        $answers=@([pscustomobject]@{Text='new while enabled';UserTurnVersion=1}); . $answerHandler
        Assert-That ((Count-Effect 'queue') -eq $before+1) 'Enabled auto-read did not queue the next answer.'
    }
    Test-Case 'hide caption settings and float do not cancel playback' {
        $before=Count-Effect 'stop'
        Set-FloatingVisible $false
        Set-CaptionsVisible $true
        Assert-That ([bool]$CaptionToggle.IsChecked -and [bool]$MenuCaptions.IsChecked) 'Caption preferences did not synchronize.'
        Set-CaptionsVisible $false
        $PinToggle.IsChecked=$false; Invoke-Click $PinToggle
        Assert-That (-not $window.Topmost -and -not $MenuPin.IsChecked -and -not $desktop.CaptionWindow.Topmost) 'Pin preferences did not synchronize.'
        $desktop.SettingsWindow.Close()
        Assert-That ((Count-Effect 'stop') -eq $before) 'Hiding a window stopped playback.'
        Assert-That (-not $window.IsVisible -and -not $desktop.CaptionWindow.IsVisible -and -not $desktop.SettingsWindow.IsVisible) 'An offscreen test showed a window.'
    }
    Test-Case 'unknown receipts never become definite acceptance or rejection' {
        foreach ($receipt in @($null,@{},@{ok=$false;error=@{}},@{ok=$false;error=@{uncertain=$true}},
            @{ok='false';error=@{uncertain='false'}},@{ok=0;error=@{uncertain=0}},
            @{ok='true';accepted='true';threadId=$taskA.threadId;requestId=$requestA},
            @{ok=$true;accepted=$true;threadId=$taskB.threadId;requestId=$requestA})) {
            Assert-That ((Get-SendReceiptState $receipt $taskA.threadId $requestA) -eq 'unknown') 'A malformed or mismatched receipt unlocked sending.'
        }
        Assert-That ((Get-SendReceiptState @{ok=$true;accepted=$true;threadId=$taskA.threadId;requestId=$requestA} $taskA.threadId $requestA) -eq 'accepted') 'Valid acceptance was not recognized.'
        Assert-That ((Get-SendReceiptState @{ok=$false;error=@{uncertain=$false}} $taskA.threadId $requestA) -eq 'rejected') 'Explicit rejection was not recognized.'
    }
    Test-Case 'voice composer restores hidden floating view and editing controls before recording' {
        $before=Count-Effect 'record'
        Set-FloatingVisible $false; Set-CaptionsVisible $false; Set-CaptionExpanded $false
        try {
            $script:testWindowsShown=$true
            Open-VoiceComposer
            Assert-That ($script:floatingVisible -and $window.IsVisible -and $script:captionsVisible -and $desktop.CaptionWindow.IsVisible) 'Voice composer left the floating view or captions hidden.'
            Assert-That ($script:captionExpanded -and $desktop.Controls.CaptionInputPanel.Visibility -eq 'Visible' -and $desktop.Controls.CaptionActions.Visibility -eq 'Visible') 'Voice composer did not expose editing, finish and send controls.'
            Assert-That ((Count-Effect 'record') -eq $before+1) 'Voice composer did not begin one recording request.'
            $recordEffect=@($script:effects | Where-Object { $_.action -eq 'record' })[-1]
            Assert-That ($recordEffect.floatingVisible -and $recordEffect.captionVisible -and $recordEffect.editingVisible) 'Recording began before its visible editing and action controls were restored.'
        } finally { Set-FloatingVisible $false; Set-CaptionsVisible $false; Set-CaptionExpanded $false }
    }
    Test-Case 'pending uncertainty and unbound mode prevent a new send' {
        $InputBox.Text='synthetic test message'; $script:connected=$true; $script:pendingUncertain=$requestA
        $before=Count-Effect 'bridge'; Send-Text
        Assert-That ((Count-Effect 'bridge') -eq $before) 'Unknown prior send was repeated.'
        $script:pendingUncertain=''; $script:connected=$false; Send-Text
        Assert-That ((Count-Effect 'bridge') -eq $before) 'Unbound mode sent a message.'
    }
    Test-Case 'preference clicks roll back state and controls when persistence fails' {
        $oldPin=$script:pinned; $oldRate=$script:speechRate; $before=$script:saved.Count; $stops=Count-Effect 'stop'
        $script:preferenceSaveFails=$true
        try {
            $PinToggle.IsChecked=-not $oldPin; Invoke-Click $PinToggle
            Assert-That ($script:pinned -eq $oldPin -and [bool]$PinToggle.IsChecked -eq $oldPin -and [bool]$MenuPin.IsChecked -eq $oldPin) 'Failed pin click left inconsistent preference controls.'
            $RateCombo.SelectedIndex=if($oldRate -eq 20){1}else{2}
            Assert-That ($script:speechRate -eq $oldRate -and $RateCombo.SelectedItem.value -eq $oldRate) 'Failed voice-rate selection was not rolled back.'
            Assert-That ($script:saved.Count -eq $before -and (Count-Effect 'stop') -eq $stops -and $script:notice -like '*已保留原设置*') 'Failed UI preference wrote state or interrupted speech.'
        } finally { $script:preferenceSaveFails=$false }
    }
    Test-Case 'an unavailable voice item restores the prior UI selection' {
        $previousVoice=$script:voiceId;$before=$script:saved.Count
        $unavailable=[pscustomobject]@{id='unavailable-fixture';name='Unavailable test voice'}
        try {
            [void]$VoiceCombo.Items.Add($unavailable);$VoiceCombo.SelectedItem=$unavailable
            Assert-That ($script:voiceId -ceq $previousVoice -and $VoiceCombo.SelectedItem.id -ceq $previousVoice -and $script:saved.Count -eq $before) 'Invalid voice selection stayed visible or was saved.'
        } finally {$VoiceCombo.Items.Remove($unavailable)}
    }
    Test-Case 'real settings create and replace stay inside the test directory' {
        $settingsPath=Join-Path $runRoot ('settings-'+[Guid]::NewGuid().ToString('N')+'.json')
        Assert-That ($settingsPath.StartsWith($runRoot+[IO.Path]::DirectorySeparatorChar)) 'Settings path escaped the test directory.'
        $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-Settings'},$true)
        if (-not $definition) { throw 'Missing production Save-Settings function.' }
        . ([scriptblock]::Create($definition.Extent.Text))
        $previousRate=$script:speechRate; $previousBargeIn=$script:bargeInEnabled; $previousFollowUp=$script:shortFollowUpEnabled
        try {
            $script:bargeInEnabled=$true; $script:shortFollowUpEnabled=$true
            Save-Settings
            $created=Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-That ($created.threadId -eq $script:threadId -and $created.voice -eq $script:voiceId) 'Real settings create lost task or voice.'
            Assert-That ($created.bargeInEnabled -is [bool] -and $created.bargeInEnabled) 'Real settings create lost the enabled echo preference.'
            Assert-That ($created.shortFollowUpEnabled -is [bool] -and $created.shortFollowUpEnabled) 'Real settings create lost the enabled short follow-up preference.'
            $script:speechRate=20; $script:bargeInEnabled=$false; $script:shortFollowUpEnabled=$false
            Save-Settings
            $replaced=Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-That ($replaced.speechRate -eq 20 -and $replaced.threadId -eq $script:threadId) 'Real settings replace failed to persist preferences.'
            Assert-That ($replaced.bargeInEnabled -is [bool] -and -not $replaced.bargeInEnabled) 'Real settings replacement lost the disabled echo preference.'
            Assert-That ($replaced.shortFollowUpEnabled -is [bool] -and -not $replaced.shortFollowUpEnabled) 'Real settings replacement lost the disabled short follow-up preference.'
            Assert-That (-not (Test-Path -LiteralPath ($settingsPath+'.tmp'))) 'Successful settings replacement left its temporary file.'
        } finally { $script:speechRate=$previousRate; $script:bargeInEnabled=$previousBargeIn; $script:shortFollowUpEnabled=$previousFollowUp }
    }
} finally {
    Close-DesktopShell $desktop
}
$failed=@($script:results | Where-Object { -not $_.passed })
$summary=@{ok=($failed.Count -eq 0);cases=@($script:results);testWindowsShown=$script:testWindowsShown;realCodexMessages=0;microphoneOpened=$false;audioPlayed=$false}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runRoot 'result.json') -Encoding UTF8
Write-Output ($script:results.Count.ToString() + ' desktop controller scenarios, ' + $failed.Count + ' failed. Own UI shown briefly for composer recovery; no real audio, microphone or Codex messages.')
foreach ($failure in $failed) { Write-Output ($failure.name + ': ' + $failure.error) }
if ($failed.Count) { exit 1 }
