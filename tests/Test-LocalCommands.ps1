param([string]$Root=(Split-Path -Parent $PSScriptRoot))

# Production parser/executor/routing, standalone WPF text controls, in-memory
# audio and bridge doubles. Actual settings serialization stays in a GUID folder.
# A queued acknowledgement here does not prove playback with a real AEC device.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ProductionAst.ps1')
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run with Windows PowerShell 5.1 -STA.'}
$sourceRoot=Join-Path $Root 'src'
$resultRoot=Join-Path $Root 'work\tests\local-commands'
$runRoot=Join-Path $resultRoot ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
function Read-ProductionAst([string]$Path){
    $tokens=$null;$parseErrors=$null
    $tree=(Read-TestProductionAst $Path)
    if($parseErrors.Count){throw ($Path+': '+$parseErrors[0].Message)}
    return $tree
}
$assistantAst=Read-ProductionAst (Join-Path $sourceRoot 'Assistant.ps1')
$handsFreeAst=Read-ProductionAst (Join-Path $sourceRoot 'HandsFree.ps1')
$controllerAst=Read-ProductionAst (Join-Path $sourceRoot 'DesktopController.ps1')
foreach($item in @(@{Tree=$assistantAst;Names=@('Send-Text','Save-Settings')},@{Tree=$handsFreeAst;Names=@('Try-AutoDispatch')},@{Tree=$controllerAst;Names=@('Set-FloatingVisible','Set-CaptionsVisible')})){
    foreach($functionName in $item.Names){
        $definition=$item.Tree.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName},$true)
        if(-not $definition){throw ('Missing production function: '+$functionName)}
        . ([scriptblock]::Create($definition.Extent.Text))
    }
}
foreach($moduleName in @('VoiceCommands.ps1','LocalCommands.ps1')){
    $modulePath=Join-Path $sourceRoot $moduleName
    if(-not (Test-Path -LiteralPath $modulePath)){throw ('Production module has not been delivered: '+$moduleName)}
    [void](Read-ProductionAst $modulePath)
    . $modulePath
}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$script:InputBox=New-Object Windows.Controls.TextBox
$script:AnswerBox=New-Object Windows.Controls.TextBox
$script:baseVoiceCatalog=(Get-Content -LiteralPath (Join-Path $Root 'assets\voices.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
if($script:baseVoiceCatalog.Count -ne 7 -or $script:baseVoiceCatalog[0].id -ne 'zh-TW-HsiaoChenNeural'){throw 'Voice catalog fixture must match the production flat seven-voice catalog.'}
$script:results=New-Object Collections.ArrayList
$script:checks=0;$script:caseNumber=0

function Stop-Output([string]$Message=''){
    [void]$script:effects.Add(@{action='stop';voice=$script:voiceId;rate=$script:speechRate})
    $script:speechQueue.Clear();$script:mockPlayerState='closed'
    if($Message){$script:notice=$Message}
}
function Queue-AnswerSpeech([string]$Text){
    [void]$script:effects.Add(@{action='queue';text=$Text;voice=$script:voiceId;rate=$script:speechRate})
    $script:speechQueue.Enqueue($Text)
}
function Start-Bridge($Request,[string]$Purpose){[void]$script:effects.Add(@{action='bridge';purpose=$Purpose;request=$Request.Clone()});return $true}
function Sync-DesktopPreferences{
    [void]$script:effects.Add(@{action='sync';voice=$script:voiceId;rate=$script:speechRate})
    if ($script:mockPreferenceDraft) { $InputBox.Text=$script:mockPreferenceDraft; $script:autoDispatch=@{Text=$script:mockPreferenceDraft}; $script:mockPreferenceDraft='' }
}
function Show-AssistantSettings{[void]$script:effects.Add(@{action='showSettings'})}
function Test-VoiceTaskSelectionPending { if($script:mockPendingThrows){throw 'Pending state unavailable'};return $script:mockTaskPending }
function Reset-VoiceTaskSwitch {$script:mockTaskPending=$false}
function Begin-VoiceTaskCreate([string]$Title,[string]$Scope='projectless') {
    [void]$script:effects.Add(@{action='createTask';title=$Title;scope=$Scope})
    if($script:mockTaskThrows){throw 'Simulated local create failure'}
    if($script:mockNewDraft){$InputBox.Text=$script:mockNewDraft;$script:autoDispatch=@{Text=$script:mockNewDraft}}
    $script:localCommandMessage='正在新建任务。';$script:notice=$script:localCommandMessage
    return $script:mockTaskHandled
}
function Test-VoiceTaskCreatePending { if($script:mockPendingThrows){throw 'Create state unavailable'};return $script:mockCreatePending }
function Test-VoiceTaskCreateBlocksSend { return $false }
function Resume-VoiceTaskCreateConnection {
    [void]$script:effects.Add(@{action='resumeCreatedTask'})
    if($script:mockTaskThrows){throw 'Simulated resume failure'}
    $script:notice='正在连接新任务。'
    return $script:mockTaskHandled
}
function Cancel-VoiceTaskCreateConnection {
    [void]$script:effects.Add(@{action='cancelCreatedTaskConnection'})
    if($script:mockTaskThrows){throw 'Simulated cancel failure'}
    $script:notice='已放弃连接新任务。'
    return $script:mockTaskHandled
}
function Begin-VoiceTaskSwitch([string]$Query) {
    [void]$script:effects.Add(@{action='switchTask';query=$Query})
    if($script:mockTaskThrows){throw 'Simulated local switch failure'}
    if($script:mockNewDraft){$InputBox.Text=$script:mockNewDraft;$script:autoDispatch=@{Text=$script:mockNewDraft}}
    $script:localCommandMessage='正在查找任务。';$script:notice=$script:localCommandMessage
    return $script:mockTaskHandled
}
function Select-VoiceTaskCandidate([int]$Index) {
    [void]$script:effects.Add(@{action='chooseTask';index=$Index})
    if($script:mockTaskThrows){throw 'Simulated choice failure'}
    return $script:mockTaskHandled
}
function Cancel-VoiceTaskSwitch {
    [void]$script:effects.Add(@{action='cancelTaskSwitch'})
    if($script:mockTaskThrows){throw 'Simulated cancellation failure'}
    return $script:mockTaskHandled
}
function Count-Effect([string]$Action){return @($script:effects | Where-Object {$_.action -eq $Action}).Count}
function Assert-That([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Read-SavedSettings{
    Assert-That (Test-Path -LiteralPath $script:settingsPath -PathType Leaf) 'A local preference was not persisted.'
    return (Get-Content -LiteralPath $script:settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Assert-AnswerPreserved{
    Assert-That ($script:latest -ceq 'Original full Codex answer' -and $AnswerBox.Text -ceq 'Original full Codex answer') 'A local command overwrote the last Codex answer.'
    Assert-That ([object]::ReferenceEquals($script:tail,$script:originalTail) -and $script:tail.Offset -eq 104 -and $script:tail.Latest -ceq 'Original full Codex answer') 'A local command replaced or moved the transcript cursor.'
    Assert-That ($script:threadId -eq '11111111-1111-4111-8111-111111111111' -and $script:busy) 'A local command changed the destination or Codex busy state.'
    Assert-That ((Count-Effect 'bridge') -eq 0) 'A local command reached the Codex bridge.'
}
function Assert-LocalSuccess([string]$Action){
    Assert-That ($script:localCommandCount -gt 0 -and $script:lastLocalCommand -eq $Action) 'The local command did not record its action.'
    Assert-That ($InputBox.Text -eq '' -and $null -eq $script:autoDispatch) 'The consumed local command left a draft or automatic-dispatch intent.'
    Assert-That ($script:localCommandMessage -and $script:notice -eq $script:localCommandMessage -and $script:localCommandNoticeUntil -gt [DateTime]::UtcNow) 'The local command did not retain a separate visible acknowledgement.'
    Assert-AnswerPreserved
}
function Reset-Case{
    $script:caseNumber++
    $script:mockPreferenceDraft=''
    $script:effects=New-Object Collections.ArrayList
    $script:settingsPath=Join-Path $runRoot ('case-'+$script:caseNumber+'.json')
    $script:connected=$true;$script:recMode='idle';$script:closing=$false;$script:busy=$true
    $script:threadId='11111111-1111-4111-8111-111111111111';$script:bridgeJob=$null;$script:pendingUncertain='';$script:pendingSends=@{}
    $script:voiceGeneration=8;$script:autoDispatch=$null;$script:autoSendPrepared=0
    $script:voiceCatalog=@($script:baseVoiceCatalog);$script:voiceId='en-US-GuyNeural';$script:speechRate=0
    $script:pinned=$true;$script:captionsVisible=$false;$script:floatingVisible=$true;$script:autoRead=$true;$script:autoSend=$false;$script:waveStyle='rays';$script:waveSize=260
    $script:handsFreeEnabled=$false;$script:bargeInEnabled=$false;$script:wakePhrase='你好，声伴';$script:directoryFilter=''
    $script:latest='Original full Codex answer';$AnswerBox.Text=$script:latest
    $script:tail=[pscustomobject]@{Offset=104;Latest=$script:latest;UserTurnVersion=7};$script:originalTail=$script:tail
    $script:localCommandCount=0;$script:lastLocalCommand='';$script:localCommandMessage='';$script:localCommandNoticeUntil=[DateTime]::MinValue
    $script:notice='Prior status';$script:mockPlayerState='playing';$script:speechQueue=New-Object 'Collections.Generic.Queue[string]'
    $script:mockTaskPending=$false;$script:mockCreatePending=$false;$script:mockTaskThrows=$false;$script:mockTaskHandled=$true;$script:mockNewDraft='';$script:mockPendingThrows=$false
    $script:TestMode=$false;$InputBox.Text='';$InputBox.IsReadOnly=$false
    $script:window=[pscustomobject]@{Left=120.0;Top=140.0;Visible=$true}
    $script:window | Add-Member ScriptMethod Show {$this.Visible=$true;[void]$script:effects.Add(@{action='showFloating'})}
    $script:window | Add-Member ScriptMethod Hide {$this.Visible=$false;[void]$script:effects.Add(@{action='hideFloating'})}
}
function Test-Case([string]$Name,[scriptblock]$Body){
    Reset-Case
    try{& $Body;[void]$script:results.Add(@{name=$Name;passed=$true})}
    catch{[void]$script:results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message})}
}
function Set-Intent([string]$Text){$InputBox.Text=$Text;$script:autoDispatch=@{Generation=$script:voiceGeneration;ThreadId=$script:threadId;Text=$Text}}

Test-Case 'Taiwan voice acknowledgement uses the newly selected voice and actual saved preferences' {
    $InputBox.Text='给我换个女生，台湾女生'
    $script:speechQueue.Enqueue('Old queued answer')
    Send-Text
    Assert-LocalSuccess 'voice'
    Assert-That ($script:voiceId -eq 'zh-TW-HsiaoChenNeural') 'Generic Taiwan female voice did not select HsiaoChen.'
    $feedback=@($script:effects | Where-Object {$_.action -eq 'queue'})
    Assert-That ($feedback.Count -eq 1 -and $feedback[0].voice -eq $script:voiceId) 'Voice-change acknowledgement used the old voice.'
    Assert-That ((Count-Effect 'stop') -eq 0 -and $script:mockPlayerState -eq 'playing' -and $script:speechQueue.Count -eq 2 -and $script:speechQueue.Peek() -eq 'Old queued answer') 'Voice change discarded an answer already queued or interrupted an active fragment.'
    Assert-That ((Read-SavedSettings).voice -eq $script:voiceId) 'Selected voice was not serialized.'
    $InputBox.Text='换成晓雨';Send-Text
    Assert-That ($script:voiceId -eq 'zh-TW-HsiaoYuNeural' -and (Read-SavedSettings).voice -eq 'zh-TW-HsiaoYuNeural') 'Named Taiwan voice did not replace the existing preference.'
    Assert-That (@($script:effects | Where-Object {$_.action -eq 'queue'})[-1].voice -eq 'zh-TW-HsiaoYuNeural') 'Named voice feedback did not use the new ID.'
}
Test-Case 'rate stepping clamps at both limits and normal restores the middle rate' {
    foreach($entry in @(@{text='语速快一点';rate=20},@{text='语速快一点';rate=50},@{text='语速快一点';rate=50},@{text='语速慢一点';rate=20},@{text='语速慢一点';rate=0},@{text='语速慢一点';rate=-20},@{text='语速慢一点';rate=-20},@{text='正常语速';rate=0})){
        $InputBox.Text=$entry.text;Send-Text
        Assert-That ($script:speechRate -eq $entry.rate -and (Read-SavedSettings).speechRate -eq $entry.rate) 'Rate step escaped a supported boundary or failed to save.'
        Assert-That (@($script:effects | Where-Object {$_.action -eq 'queue'})[-1].rate -eq $entry.rate) 'Rate acknowledgement used the previous speed.'
        Assert-LocalSuccess 'rate'
    }
}
Test-Case 'pin captions floating style and auto-read use current settings state and persist' {
    foreach($entry in @(@{text='取消置顶';action='pin';property='pinned';value=$false},@{text='置顶';action='pin';property='pinned';value=$true},@{text='显示字幕';action='captions';property='captionsVisible';value=$true},@{text='隐藏字幕';action='captions';property='captionsVisible';value=$false},@{text='隐藏悬浮声波';action='floating';property='floatingVisible';value=$false},@{text='显示悬浮声波';action='floating';property='floatingVisible';value=$true},@{text='换成流动声线';action='style';property='waveStyle';value='flow'},@{text='开启自动朗读';action='autoRead';property='autoRead';value=$true})){
        $InputBox.Text=$entry.text;Send-Text;Assert-LocalSuccess $entry.action
        Assert-That ((Get-Variable -Scope Script -Name $entry.property -ValueOnly) -eq $entry.value) 'Local preference state did not change.'
        $saved=Read-SavedSettings
        Assert-That ($saved.($entry.property) -eq $entry.value) 'Local preference did not reach actual settings serialization.'
    }
    Assert-That ((Count-Effect 'hideFloating') -eq 1 -and (Count-Effect 'showFloating') -eq 1) 'Floating commands bypassed the actual visibility setter.'
}
Test-Case 'stop and disabling automatic reading do not queue another spoken acknowledgement' {
    foreach($entry in @(@{text='停止朗读';action='stop'},@{text='关闭自动朗读';action='autoRead'})){
        $script:speechQueue.Enqueue('Old queued answer');$before=Count-Effect 'queue';$InputBox.Text=$entry.text
        Send-Text;Assert-LocalSuccess $entry.action
        Assert-That ($script:mockPlayerState -eq 'closed' -and $script:speechQueue.Count -eq 0 -and (Count-Effect 'queue') -eq $before) 'A stop-like command restarted speech or retained old queued audio.'
    }
    Assert-That (-not $script:autoRead -and -not (Read-SavedSettings).autoRead) 'Disabling automatic reading did not save.'
}
Test-Case 'general settings preserve a newly queued Codex answer while appending local confirmation' {
    $script:speechQueue.Enqueue('Codex answer returned this timer tick')
    foreach($text in @('取消置顶','换成流动声线','语速快一点','显示字幕','隐藏悬浮声波','显示悬浮声波','打开设置','开启自动朗读')){
        $InputBox.Text=$text;$before=$script:speechQueue.Count;Send-Text
        Assert-That ((Count-Effect 'stop') -eq 0 -and $script:speechQueue.Count -eq ($before+1) -and $script:speechQueue.Peek() -eq 'Codex answer returned this timer tick') 'A general setting cleared the latest answer queue or replaced its order.'
        Assert-That ($script:mockPlayerState -eq 'playing') 'A general setting interrupted an active speech fragment.'
        Assert-AnswerPreserved
    }
}
Test-Case 'showing captions restores a hidden floating window through production setters' {
    $script:floatingVisible=$false;$script:window.Visible=$false
    $InputBox.Text='显示字幕';Send-Text;Assert-LocalSuccess 'captions'
    Assert-That ($script:floatingVisible -and $script:window.Visible -and $script:captionsVisible -and (Count-Effect 'showFloating') -eq 1) 'Caption command left the caption host hidden.'
    $saved=Read-SavedSettings
    Assert-That ($saved.floatingVisible -and $saved.captionsVisible) 'Restored caption and floating visibility were not both saved.'
}
Test-Case 'opening settings is local and leaves the last answer intact' {
    $InputBox.Text='打开设置';Send-Text;Assert-LocalSuccess 'settings'
    Assert-That ((Count-Effect 'showSettings') -eq 1) 'Settings command did not reach the existing settings entrypoint.'
}
Test-Case 'manual local command bypasses disconnected busy pending and active bridge gates' {
    $script:connected=$false;$script:pendingUncertain='existing-unknown-request';$script:bridgeJob=@{Purpose='send';RequestId='existing-request'};$oldBridge=$script:bridgeJob
    $InputBox.Text='语速快一点';Send-Text;Assert-LocalSuccess 'rate'
    Assert-That (-not $script:connected -and $script:pendingUncertain -eq 'existing-unknown-request' -and [object]::ReferenceEquals($script:bridgeJob,$oldBridge)) 'Local routing disturbed remote connection or request uncertainty.'
}
Test-Case 'automatic local command bypasses remote gates and consumes its valid intent exactly once' {
    $script:connected=$false;$script:pendingUncertain='existing-unknown-request';$script:bridgeJob=@{Purpose='send'};$oldBridge=$script:bridgeJob
    Set-Intent '语速快一点';Try-AutoDispatch;Assert-LocalSuccess 'rate'
    $effects=$script:effects.Count;Try-AutoDispatch
    Assert-That ($script:localCommandCount -eq 1 -and $script:speechRate -eq 20 -and $script:effects.Count -eq $effects -and $script:autoSendPrepared -eq 0) 'The consumed local intent was repeated or counted as a remote send.'
    Assert-That ($script:pendingUncertain -eq 'existing-unknown-request' -and [object]::ReferenceEquals($script:bridgeJob,$oldBridge)) 'Automatic local routing cleared a remote request lock.'
}
Test-Case 'ordinary content still sends once to the bound Codex task' {
    $InputBox.Text='请帮我整理今天的工作计划';Send-Text
    $requests=@($script:effects | Where-Object {$_.action -eq 'bridge'})
    Assert-That ($requests.Count -eq 1 -and $requests[0].purpose -eq 'send' -and $requests[0].request.threadId -eq $script:threadId -and $requests[0].request.text -eq $InputBox.Text) 'Ordinary content did not keep its original remote route.'
    Assert-That ($script:localCommandCount -eq 0 -and $InputBox.IsReadOnly -and (Count-Effect 'queue') -eq 0) 'Ordinary content was treated as a local command.'
}
Test-Case 'ordinary automatic content keeps de-duplication and existing bridge wait semantics' {
    Set-Intent '请帮我整理今天的工作计划';$script:bridgeJob=@{Purpose='read'}
    Try-AutoDispatch
    Assert-That ($script:autoDispatch -and (Count-Effect 'bridge') -eq 0) 'Ordinary automatic intent was lost while the bridge was busy.'
    $script:bridgeJob=$null;Try-AutoDispatch;Try-AutoDispatch
    Assert-That ((Count-Effect 'bridge') -eq 1 -and $script:autoSendPrepared -eq 1 -and $script:localCommandCount -eq 0) 'Ordinary automatic content was duplicated or rerouted locally.'
}
Test-Case 'negated quoted conditional and compound requests are not consumed locally' {
    foreach($text in @('不要关闭自动朗读','他说“停止朗读”是什么意思','如果我说快一点，你会怎么做','请关闭字幕，然后帮我整理工作计划','我想知道台湾女声有什么区别')){
        $InputBox.Text=$text;$before=$script:effects.Count
        $handled=Try-LocalAssistantCommand $text
        Assert-That (-not $handled -and $InputBox.Text -ceq $text -and $script:effects.Count -eq $before) 'Ambiguous or quoted content was consumed as a local command.'
        Send-Text
        Assert-That (@($script:effects | Where-Object {$_.action -eq 'bridge'})[-1].request.text -ceq $text) 'Unconsumed content did not preserve its text on the normal route.'
        $InputBox.IsReadOnly=$false
    }
    Assert-That ($script:localCommandCount -eq 0) 'A negative or quoted phrase incremented local command count.'
}
Test-Case 'ordinary content remains blocked by disconnected pending and bridge states' {
    foreach($gate in @('connected','pending','bridge')){
        $script:connected=$true;$script:pendingUncertain='';$script:bridgeJob=$null;$InputBox.Text='请帮我整理今天的工作计划'
        switch($gate){'connected'{$script:connected=$false}'pending'{$script:pendingUncertain='unknown'}'bridge'{$script:bridgeJob=@{Purpose='send'}}}
        Send-Text
        Assert-That ((Count-Effect 'bridge') -eq 0 -and $script:localCommandCount -eq 0) 'Ordinary text bypassed an existing remote gate.'
    }
}
Test-Case 'stale generation changed task edited text and shutdown invalidate local automatic intents' {
    foreach($invalid in @('generation','thread','text','closing')){
        $script:closing=$false;Set-Intent '语速快一点'
        switch($invalid){'generation'{$script:autoDispatch.Generation--}'thread'{$script:autoDispatch.ThreadId='22222222-2222-4222-8222-222222222222'}'text'{$InputBox.Text='语速慢一点'}'closing'{$script:closing=$true}}
        Try-AutoDispatch
        Assert-That ($null -eq $script:autoDispatch -and $script:localCommandCount -eq 0 -and $script:speechRate -eq 0 -and $script:effects.Count -eq 0) 'An invalid local intent was executed before its freshness check.'
    }
}
Test-Case 'recording and recognition states defer all local execution until idle' {
    foreach($mode in @('arming','listening','stopping','transcribing')){
        $script:recMode=$mode;Set-Intent '语速快一点'
        Try-AutoDispatch
        Assert-That ($script:autoDispatch -and $script:localCommandCount -eq 0 -and $script:effects.Count -eq 0) 'Automatic local execution ran during capture or recognition.'
        Send-Text
        Assert-That ($script:localCommandCount -eq 0 -and $script:effects.Count -eq 0 -and $InputBox.Text -eq '语速快一点') 'Manual local routing ran during capture or recognition.'
    }
    $script:recMode='idle';Set-Intent '语速快一点';Try-AutoDispatch
    Assert-That ($script:localCommandCount -eq 1 -and $script:speechRate -eq 20) 'A valid local command did not resume after capture became idle.'
}
Test-Case 'failed settings save rolls back preferences and cannot fall through to Codex' {
    $script:settingsPath=Join-Path $runRoot 'directory-is-not-a-settings-file'
    [void][IO.Directory]::CreateDirectory($script:settingsPath)
    $InputBox.Text='语速快一点';Send-Text
    Assert-That ($script:speechRate -eq 0 -and $script:localCommandCount -eq 0 -and $InputBox.Text -eq '语速快一点') 'Failed persistence changed the preference or consumed the retry draft.'
    Assert-That ((Count-Effect 'bridge') -eq 0 -and (Count-Effect 'queue') -eq 0 -and $script:localCommandMessage -like '*设置没有完成*') 'Failed local persistence fell through to remote send or success speech.'
    Assert-AnswerPreserved
}
Test-Case 'unavailable voice stays local and preserves previous preferences' {
    $script:voiceCatalog=@($script:voiceCatalog | Where-Object {$_.id -ne 'zh-TW-HsiaoYuNeural'})
    $InputBox.Text='换成晓雨';Send-Text
    Assert-That ($script:voiceId -eq 'en-US-GuyNeural' -and $InputBox.Text -eq '换成晓雨' -and $script:localCommandCount -eq 0) 'Unavailable voice changed or discarded the current preference.'
    Assert-That ((Count-Effect 'bridge') -eq 0 -and (Count-Effect 'queue') -eq 0) 'Unavailable voice escaped the local command route.'
    Assert-AnswerPreserved
}

Test-Case 'task switch delegates raw query without saving preferences or claiming binding success' {
    Set-Intent '帮我切换到高斯泼溅这个任务';Send-Text
    Assert-That ((Count-Effect 'switchTask') -eq 1 -and @($script:effects | Where-Object {$_.action -eq 'switchTask'})[0].query -ceq '高斯泼溅') 'Task name was changed or switch not dispatched.'
    Assert-That ($InputBox.Text -eq '' -and $null -eq $script:autoDispatch -and $script:lastLocalCommand -eq 'switchTask') 'Consumed switch command was not cleaned.'
    Assert-That ((Count-Effect 'sync') -eq 0 -and (Count-Effect 'queue') -eq 0 -and -not (Test-Path -LiteralPath $script:settingsPath)) 'Task command reused generic settings persistence or immediate success speech.'
    Assert-That ($script:notice -ceq '正在查找任务。') 'Executor overwrote asynchronous switch feedback.'
    Assert-AnswerPreserved
}
Test-Case 'automatic task switch intent is consumed once without remote send' {
    Set-Intent '切到高斯坡建的这个任务';Try-AutoDispatch;Try-AutoDispatch
    Assert-That ((Count-Effect 'switchTask') -eq 1 -and (Count-Effect 'bridge') -eq 0 -and $script:autoSendPrepared -eq 0) 'Automatic task command was repeated or sent remotely.'
    Assert-That ($script:localCommandCount -eq 1 -and $null -eq $script:autoDispatch) 'Automatic task intent was not consumed.'
}
Test-Case 'candidate choices and cancellation stay ordinary content without pending selection' {
    foreach($text in @('选择第一个任务','选择第二个任务','取消任务切换')) {
        $InputBox.Text=$text
        Assert-That (-not (Try-LocalAssistantCommand $text)) 'Bare choice was intercepted without candidates.'
        Send-Text
        Assert-That (@($script:effects | Where-Object {$_.action -eq 'bridge'})[-1].request.text -ceq $text) 'Bare choice did not keep its original route.'
        $InputBox.IsReadOnly=$false
    }
    Assert-That ((Count-Effect 'chooseTask') -eq 0 -and (Count-Effect 'cancelTaskSwitch') -eq 0) 'A candidate action ran without pending candidates.'
}
Test-Case 'candidate selection and cancellation dispatch locally only while pending' {
    $script:mockTaskPending=$true
    Set-Intent '选择第二个任务';Try-AutoDispatch
    Assert-That ((Count-Effect 'chooseTask') -eq 1 -and @($script:effects | Where-Object {$_.action -eq 'chooseTask'})[0].index -eq 2) 'Candidate index was not preserved.'
    $InputBox.Text='取消任务切换';Send-Text
    Assert-That ((Count-Effect 'cancelTaskSwitch') -eq 1 -and $InputBox.Text -eq '' -and $script:localCommandCount -eq 2) 'Pending cancellation was not consumed locally.'
    Assert-That ((Count-Effect 'bridge') -eq 0 -and (Count-Effect 'sync') -eq 0 -and (Count-Effect 'queue') -eq 0) 'Task candidate operation escaped its owner.'
    Assert-AnswerPreserved
}
Test-Case 'failed task switch and pending choice never become Codex messages' {
    $script:mockTaskThrows=$true;$script:mockTaskPending=$true
    foreach($text in @('切换到高斯坡建任务','选择第一个任务','取消任务切换')) {
        Set-Intent $text;Send-Text
        Assert-That ($InputBox.Text -eq '' -and $null -eq $script:autoDispatch -and $script:notice -like '*任务切换没有完成*') 'Task failure was not contained and consumed.'
    }
    Assert-That ((Count-Effect 'bridge') -eq 0 -and (Count-Effect 'sync') -eq 0 -and (Count-Effect 'queue') -eq 0) 'Task failure reached remote bridge or unrelated preferences.'
}
Test-Case 'unexpected false switch result remains local and asynchronous new draft survives' {
    $script:mockTaskHandled=$false;Set-Intent '切换到高斯坡建任务';Send-Text
    Assert-That ((Count-Effect 'bridge') -eq 0 -and $script:notice -like '*任务切换没有完成*') 'Explicit switch fell through on a false return.'
    $script:mockTaskHandled=$true;$script:mockNewDraft='用户刚写的新问题';Set-Intent '切换到高斯坡建任务';Send-Text
    Assert-That ($InputBox.Text -ceq '用户刚写的新问题' -and $script:autoDispatch.Text -ceq '用户刚写的新问题') 'Command cleanup discarded a newer draft or dispatch intent.'
}
Test-Case 'unavailable candidate state remains local and unrelated draft is preserved' {
    $script:mockPendingThrows=$true;Set-Intent '选择第一个任务';Send-Text
    Assert-That ((Count-Effect 'bridge') -eq 0 -and (Count-Effect 'chooseTask') -eq 0 -and $script:notice -like '*任务切换没有完成*') 'Pending-state failure escaped the local route.'
    $InputBox.Text='尚未发送的其它草稿'
    Assert-That (Try-LocalAssistantCommand '切换到高斯坡建任务') 'Explicit switch was not handled.'
    Assert-That ($InputBox.Text -ceq '尚未发送的其它草稿') 'An unrelated draft was removed by task command cleanup.'
}

Test-Case 'new task delegates exact title or empty string without changing binding or settings' {
    foreach($entry in @(@('新建一个任务',''),@('帮我新建一个叫ＧＰＴ－６ 实验的任务','ＧＰＴ－６ 实验'),@('新建一个任务叫谢谢','谢谢'))){
        Set-Intent $entry[0];$before=Count-Effect 'createTask';Send-Text
        Assert-That ((Count-Effect 'createTask') -eq ($before+1) -and @($script:effects|Where-Object {$_.action -eq 'createTask'})[-1].title -ceq $entry[1]) 'Create title was changed or not delegated once.'
        Assert-That ($InputBox.Text -eq '' -and $null -eq $script:autoDispatch -and $script:lastLocalCommand -eq 'createTask') 'Consumed create command was not cleaned.'
        Assert-That ($script:notice -ceq '正在新建任务。' -and (Count-Effect 'sync') -eq 0 -and (Count-Effect 'queue') -eq 0 -and -not (Test-Path -LiteralPath $script:settingsPath)) 'Create reused preference saving or immediate success feedback.'
        Assert-AnswerPreserved
    }
}
Test-Case 'automatic create is consumed once and stale input never creates a task' {
    Set-Intent '新建任务';Try-AutoDispatch;Try-AutoDispatch
    Assert-That ((Count-Effect 'createTask') -eq 1 -and (Count-Effect 'bridge') -eq 0 -and $script:autoSendPrepared -eq 0 -and $script:localCommandCount -eq 1) 'Create auto dispatch repeated or became a prompt.'
    Set-Intent '新建一个任务';$script:autoDispatch.Generation--;Try-AutoDispatch
    Assert-That ((Count-Effect 'createTask') -eq 1 -and $null -eq $script:autoDispatch) 'Stale intent created a task.'
}
Test-Case 'create false return and exception stay local without clearing newer drafts' {
    $script:mockTaskHandled=$false;Set-Intent '新建一个任务';Send-Text
    Assert-That ((Count-Effect 'bridge') -eq 0 -and $InputBox.Text -eq '' -and $script:notice -like '*新建任务没有完成*') 'False create return fell through to Codex.'
    $script:mockTaskThrows=$true;Set-Intent '新建一个任务叫天气';Try-AutoDispatch;Try-AutoDispatch
    Assert-That ((Count-Effect 'bridge') -eq 0 -and $InputBox.Text -eq '' -and $null -eq $script:autoDispatch -and $script:notice -like '*新建任务没有完成*') 'Create exception escaped or left a retry intent.'
    $script:mockTaskThrows=$false;$script:mockTaskHandled=$true;$script:mockNewDraft='用户刚写的新问题'
    Set-Intent '新建任务';Try-AutoDispatch
    Assert-That ($InputBox.Text -ceq '用户刚写的新问题' -and $script:autoDispatch.Text -ceq '用户刚写的新问题') 'Create cleanup removed a newer draft or automatic intent.'
    $script:mockNewDraft='';$InputBox.Text='保留的其它草稿'
    Assert-That (Try-LocalAssistantCommand '新建任务') 'Explicit create was not handled.'
    Assert-That ($InputBox.Text -ceq '保留的其它草稿') 'Create cleanup removed unrelated text.'
    Assert-AnswerPreserved
}
Test-Case 'create quotations tests negation and compound text remain ordinary prompts' {
    foreach($text in @('不要新建一个任务','新建一个任务是什么意思','这是测试新建一个任务','新建一个任务叫天气只是测试','“新建一个任务”','新建一个任务，然后帮我查天气','继续连接新任务','取消连接新任务')){
        $InputBox.Text=$text
        Assert-That (-not (Try-LocalAssistantCommand $text)) 'Non-command creation text was consumed locally.'
        Send-Text
        Assert-That (@($script:effects|Where-Object {$_.action -eq 'bridge'})[-1].request.text -ceq $text) 'Ordinary creation text lost its remote route.'
        $InputBox.IsReadOnly=$false
    }
    Assert-That ((Count-Effect 'createTask') -eq 0 -and $script:localCommandCount -eq 0) 'Ordinary text created a task.'
}

foreach($route in @('manual','automatic')) {
    Test-Case ($route+' spoken creation shortcuts are consumed exactly once before remote send') {
        foreach($text in @('帮我弄一个新对话','新对话','新任务','新聊天','新聊天内容','新对话啊','新任务吧','新聊天呀','新对话哦','新任务哈','给我弄一个新对话','你帮我弄一个新对话','我想弄一个新对话','我想要弄一个新任务','我要开个新聊天','帮我直接弄一个新对话','帮我弄一个新对话一下','建个新任务','开个新对话','搞个新聊天')) {
            Set-Intent $text
            $beforeCreates=Count-Effect 'createTask';$beforeCommands=$script:localCommandCount
            if($route -eq 'manual'){Send-Text;Send-Text;Try-AutoDispatch}
            else{Try-AutoDispatch;Try-AutoDispatch}
            $created=@($script:effects | Where-Object {$_.action -eq 'createTask'})
            Assert-That ($created.Count -eq ($beforeCreates+1) -and $script:localCommandCount -eq ($beforeCommands+1)) ('Creation shortcut was not consumed exactly once: '+$text)
            Assert-That ($created[-1].title -ceq '' -and $created[-1].scope -eq 'projectless') ('Creation shortcut acquired a title or project scope: '+$text)
            Assert-That ($InputBox.Text -eq '' -and $null -eq $script:autoDispatch -and $script:autoSendPrepared -eq 0 -and $script:lastLocalCommand -eq 'createTask') ('Creation shortcut left a dispatch intent or prepared remote send: '+$text)
            Assert-AnswerPreserved
        }
    }
    Test-Case ($route+' creation shortcut discussion negation and compound speech remain ordinary prompts') {
        foreach($text in @('不要帮我弄一个新对话','我不想要新任务','帮我弄一个新对话是什么意思','新对话和新任务有什么区别','比如说新对话啊，然后新任务啊之类的这种的','帮我弄一个新对话，然后帮我查天气','帮我弄一个新对话并帮我写代码','新任务只是测试','他说新对话就能创建吗','“新对话”','打开一个任务','帮我弄一个任务')) {
            Set-Intent $text
            $beforeRequests=Count-Effect 'bridge'
            if($route -eq 'manual'){Send-Text}else{Try-AutoDispatch;Try-AutoDispatch}
            $requests=@($script:effects | Where-Object {$_.action -eq 'bridge'})
            Assert-That ($requests.Count -eq ($beforeRequests+1) -and $requests[-1].purpose -eq 'send' -and $requests[-1].request.text -ceq $text -and $requests[-1].request.threadId -ceq $script:threadId) ('Non-command shortcut content lost its exact ordinary route: '+$text)
            Assert-That ((Count-Effect 'createTask') -eq 0 -and $script:localCommandCount -eq 0) ('Non-command shortcut content created a task: '+$text)
            $InputBox.IsReadOnly=$false
        }
    }
}

Test-Case 'created-task recovery delegates only while a created connection is pending' {
    foreach($entry in @(@('连接刚才的新任务','resumeCreatedTask'),@('放弃连接新任务','cancelCreatedTaskConnection'))){
        $script:mockCreatePending=$false;$InputBox.Text=$entry[0]
        Assert-That ((Try-LocalAssistantCommand $entry[0]) -and (Count-Effect $entry[1]) -eq 0 -and $InputBox.Text -eq '' -and $script:notice -ceq '没有待连接的新任务。') 'No-pending recovery was not consumed with a local notice.'
        $script:mockCreatePending=$true;Set-Intent $entry[0];Try-AutoDispatch;Try-AutoDispatch
        Assert-That ((Count-Effect $entry[1]) -eq 1 -and $InputBox.Text -eq '' -and $null -eq $script:autoDispatch -and $script:lastLocalCommand -eq $entry[1]) 'Recovery did not delegate and consume once.'
        Assert-That ((Count-Effect 'sync') -eq 0 -and (Count-Effect 'queue') -eq 0 -and (Count-Effect 'bridge') -eq 0 -and -not (Test-Path -LiteralPath $script:settingsPath)) 'Recovery bypassed its async module owner.'
        Assert-AnswerPreserved
    }
}
Test-Case 'created-task recovery errors cannot become remote prompts' {
    $script:mockCreatePending=$true;$script:mockTaskThrows=$true
    foreach($text in @('连接刚才的新任务','放弃连接新任务')){
        Set-Intent $text;Try-AutoDispatch
        Assert-That ($null -eq $script:autoDispatch -and $InputBox.Text -eq '' -and (Count-Effect 'bridge') -eq 0 -and $script:notice -like '*新任务连接操作没有完成*') 'Recovery failure reached normal send.'
    }
    $script:mockPendingThrows=$true;Set-Intent '连接刚才的新任务';Send-Text
    Assert-That ((Count-Effect 'resumeCreatedTask') -eq 1 -and (Count-Effect 'bridge') -eq 0 -and $InputBox.Text -eq '') 'Unknown recovery state invoked an unsafe action.'
    $script:mockPendingThrows=$false;$script:mockTaskThrows=$false;$script:mockTaskHandled=$false;Set-Intent '放弃连接新任务';Send-Text
    Assert-That ((Count-Effect 'bridge') -eq 0 -and $InputBox.Text -eq '' -and $script:notice -like '*新任务连接操作没有完成*') 'Pending-state race fell through after a false recovery result.'
}

Test-Case 'chat aliases choose projectless unless current project is explicitly spoken' {
    foreach($entry in @(@('新建一个聊天','projectless'),@('新建聊天','projectless'),@('新建一个聊天内容','projectless'),@('在当前项目新建一个聊天','current-project'),@('在当前项目里新建一个任务','current-project'))){
        $InputBox.Text=$entry[0];Send-Text
        Assert-That (@($script:effects|Where-Object {$_.action -eq 'createTask'})[-1].scope -ceq $entry[1]) 'Chat command used the wrong creation scope.'
        Assert-That ($InputBox.Text -eq '' -and (Count-Effect 'bridge') -eq 0) 'Chat command reached normal remote send.'
    }
    Assert-AnswerPreserved
}

Test-Case 'preference completion preserves a newer draft and dispatch' {
    Set-Intent '语速快一点'; $script:mockPreferenceDraft='刚写的新问题'
    Send-Text
    Assert-That ($script:speechRate -eq 20 -and $InputBox.Text -ceq '刚写的新问题' -and $script:autoDispatch.Text -ceq '刚写的新问题') 'Preference cleanup removed newer input.'
    Assert-That ((Count-Effect 'bridge') -eq 0) 'Preference execution sent a chat message.'
}
Test-Case 'active candidate false returns remain local for both send routes' {
    foreach ($route in @('manual','automatic')) {
        foreach ($text in @('选择第二个任务','取消切换')) {
            $script:mockTaskPending=$true;$script:mockTaskHandled=$false;Set-Intent $text
            if ($route -eq 'manual') { Send-Text } else { Try-AutoDispatch }
            Assert-That ((Count-Effect 'bridge') -eq 0 -and $InputBox.Text -eq '' -and -not $script:autoDispatch) 'Unimplemented candidate operation became chat.'
            Assert-That ($script:notice -like '*任务切换没有完成*') 'Failed candidate operation had no local feedback.'
        }
    }
}
$failed=@($script:results | Where-Object {-not $_.passed})
$summary=@{ok=($failed.Count -eq 0);checks=$script:checks;cases=@($script:results);settingsDirectory=$runRoot;realAudio=0;realMicrophones=0;realCodexRequests=0;feedbackPlayback='Queue contract only; real AEC playback needs a separate integration test.'}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $resultRoot 'result.json') -Encoding UTF8
Write-Output ($script:results.Count.ToString()+' local-command scenarios, '+$script:checks+' assertions, '+$failed.Count+' failed; no real audio, microphone or Codex requests.')
foreach($failure in $failed){Write-Output ($failure.name+': '+$failure.error)}
if($failed.Count){exit 1}
