param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ProductionAst.ps1')
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run Windows PowerShell 5.1 with -STA.'}
$sourceRoot=Join-Path $Root 'src'
$resultRoot=Join-Path $Root 'work\tests\wake-phrase-settings'
$runRoot=Join-Path $resultRoot ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
function Read-TestAst([string]$Path){
    $tokens=$null;$errors=$null
    $tree=(Read-TestProductionAst $Path)
    if($errors.Count){throw ($Path+': '+$errors[0].Message)}
    return $tree
}
$assistantAst=Read-TestAst (Join-Path $sourceRoot 'Assistant.ps1')
$handsFreeAst=Read-TestAst (Join-Path $sourceRoot 'HandsFree.ps1')
$controllerAst=Read-TestAst (Join-Path $sourceRoot 'DesktopController.ps1')
foreach($entry in @(@{Ast=$assistantAst;Name='Save-Settings'},@{Ast=$assistantAst;Name='Initialize-AssistantSettings'},@{Ast=$handsFreeAst;Name='Suspend-WakeListener'})){
    $functionName=$entry.Name
    $node=$entry.Ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $functionName},$true)
    if(-not $node){throw ('Missing production function '+$functionName)}
    . ([scriptblock]::Create($node.Extent.Text))
}
$startupNodes=@($assistantAst.EndBlock.Statements | Where-Object {$_.Extent.Text -match '^Initialize-AssistantSettings$'})
if($startupNodes.Count -ne 1){throw 'Missing production settings restore block.'}
$restoreSettings=[scriptblock]::Create($startupNodes[0].Extent.Text)
$initializer=$controllerAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-DesktopController'},$true)
$bindingNodes=@($initializer.Body.EndBlock.Statements | Where-Object {$_.Extent.Text -match "^if \(\`$desktop.Controls.ContainsKey\('(WakePhraseBox|SaveWakePhraseButton|ResetWakePhraseButton)'\)\)"})
if($bindingNodes.Count -ne 3){throw 'Missing production wake editor event bindings.'}
$bindWakeControls=[scriptblock]::Create(($bindingNodes.Extent.Text -join "`n"))
. (Join-Path $sourceRoot 'WakePhrase.ps1')
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
Add-Type -TypeDefinition 'namespace CodexReader { public static class AudioPlayer { public static string State = "closed"; } }'
$script:desktop=@{Controls=@{WakePhraseBox=(New-Object Windows.Controls.TextBox);WakeHintLabel=(New-Object Windows.Controls.TextBlock);SaveWakePhraseButton=(New-Object Windows.Controls.Button);ResetWakePhraseButton=(New-Object Windows.Controls.Button)}}
$script:InputBox=New-Object Windows.Controls.TextBox
$script:AnswerBox=New-Object Windows.Controls.TextBox
$script:baseCatalog=(Get-Content -LiteralPath (Join-Path $Root 'assets\voices.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
$script:results=New-Object Collections.ArrayList
$script:checks=0;$script:fixtureNumber=0
function Stop-Output{ $script:stopCalls++;throw 'Wake settings must not stop audio.' }
function Start-Bridge{ $script:bridgeCalls++;throw 'Wake settings must not make a Codex request.' }
function Assert-That([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Saved-Preferences{Get-Content -LiteralPath $script:settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json}
function Reset-Fixture{
    $script:fixtureNumber++
    $script:settingsPath=Join-Path $runRoot ('case-'+$script:fixtureNumber+'.json')
    $script:window=$null;$script:closing=$false;$script:recMode='idle';$script:asrJob=$null;$script:autoDispatch=$null;$script:bridgeJob=$null
    $script:threadId='11111111-1111-4111-8111-111111111111';$script:voiceId='zh-TW-HsiaoChenNeural';$script:voiceCatalog=$script:baseCatalog
    $script:speechRate=0;$script:autoRead=$true;$script:autoSend=$false;$script:bargeInEnabled=$true;$script:waveStyle='rays';$script:waveSize=260;$script:pinned=$true;$script:captionsVisible=$false;$script:floatingVisible=$true;$script:directoryFilter=''
    $script:wakePhrase='你好，声伴';$script:handsFreeEnabled=$true;$script:handsFreePhase='listening';$script:lastWakeVersion=5L;$script:voiceGeneration=9;$script:wakeCount=3;$script:nextWakeUtc=[DateTime]::MinValue
    $script:mic=[pscustomobject]@{ScanCount=21L};$script:wakeReleaseScan=0L;$script:listenerStops=0;$script:stopCalls=0;$script:bridgeCalls=0;$script:lateWakeOnStop=$false
    $script:wakeListener=[pscustomobject]@{ActivationVersion=5L;HasQuestion=$false;IsListening=$true;IsStopping=$false}
    $script:wakeListener | Add-Member ScriptMethod Stop {$script:listenerStops++;$this.IsStopping=$true;if($script:lateWakeOnStop){$this.ActivationVersion++}}
    $script:ttsJob=$null;$script:speechQueue=New-Object 'Collections.Generic.Queue[string]';[CodexReader.AudioPlayer]::State='closed'
    $script:busy=$true;$script:pendingUncertain='receipt-still-pending';$script:pendingSends=@{existing='preserve'};$script:notice='original status'
    $InputBox.Text='Unsent draft';$AnswerBox.Text='Original Codex answer';$script:latest=$AnswerBox.Text
    $desktop.Controls.WakePhraseBox.Text='小伴你好';$desktop.Controls.WakeHintLabel.Text=''
    $script:hasExplicitThreadId=$false;$script:TestMode=$false;$script:PreviewPath=''
    Save-Settings
    $script:initialJson=[IO.File]::ReadAllText($script:settingsPath)
}
function Assert-Preserved{
    Assert-That ($InputBox.Text -ceq 'Unsent draft' -and $AnswerBox.Text -ceq 'Original Codex answer' -and $script:latest -ceq 'Original Codex answer') 'Wake settings changed a draft or Codex answer.'
    Assert-That ($script:busy -and $script:pendingUncertain -eq 'receipt-still-pending' -and $script:pendingSends.existing -eq 'preserve') 'Wake settings changed Codex busy or pending state.'
    Assert-That ($script:voiceGeneration -eq 9 -and $script:wakeCount -eq 3 -and $script:threadId -eq '11111111-1111-4111-8111-111111111111') 'Wake settings consumed a question or changed task state.'
    Assert-That ($script:stopCalls -eq 0 -and $script:bridgeCalls -eq 0) 'Wake settings touched audio output or Codex I/O.'
}
function Assert-Rejected([string]$Text='小伴你好'){
    $oldListener=$script:wakeListener;$oldDispatch=$script:autoDispatch;$oldAsr=$script:asrJob;$oldBridge=$script:bridgeJob;$oldState=[CodexReader.AudioPlayer]::State;$oldTts=$script:ttsJob;$oldQueue=$script:speechQueue.Count
    Assert-That (-not (Set-AssistantWakePhrase $Text)) 'Unsafe or invalid wake phrase change was accepted.'
    Assert-That ($script:wakePhrase -ceq '你好，声伴' -and [IO.File]::ReadAllText($script:settingsPath) -ceq $script:initialJson) 'Rejected wake phrase reached disk or changed the current keyword.'
    Assert-That ($script:listenerStops -eq 0 -and [object]::ReferenceEquals($oldListener,$script:wakeListener)) 'Rejected wake phrase stopped or replaced the current listener.'
    Assert-That ([object]::ReferenceEquals($oldDispatch,$script:autoDispatch) -and [object]::ReferenceEquals($oldAsr,$script:asrJob) -and [object]::ReferenceEquals($oldBridge,$script:bridgeJob)) 'Rejected wake phrase cleared an in-flight operation.'
    Assert-That ([CodexReader.AudioPlayer]::State -eq $oldState -and [object]::ReferenceEquals($oldTts,$script:ttsJob) -and $script:speechQueue.Count -eq $oldQueue) 'Rejected wake phrase disturbed current speech.'
    Assert-That (-not [string]::IsNullOrWhiteSpace($desktop.Controls.WakeHintLabel.Text)) 'Rejected wake phrase has no visible validation message.'
    Assert-Preserved
}
function Test-Case([string]$Name,[scriptblock]$Body){Reset-Fixture;try{& $Body;[void]$script:results.Add(@{name=$Name;passed=$true})}catch{[void]$script:results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message})}}

# Attach the exact production control initialization blocks once, not mirror handlers.
. $bindWakeControls
Test-Case 'valid phrase is normalized persisted and restored by production startup' {
    Assert-That (Set-AssistantWakePhrase ' 小伴, 你好 ') 'Valid phrase was rejected.'
    Assert-That ($script:wakePhrase -ceq '小伴，你好' -and (Saved-Preferences).wakePhrase -ceq '小伴，你好') 'Normalized phrase was not persisted.'
    $script:wakePhrase='初始值';. $restoreSettings
    Assert-That ($script:wakePhrase -ceq '小伴，你好') 'Production startup did not restore the saved phrase.'
    Assert-That ($desktop.Controls.WakePhraseBox.Text -ceq '小伴，你好' -and $desktop.Controls.WakeHintLabel.Text -like '*已保存*') 'Saved phrase and notice did not reach the settings controls.'
    Assert-Preserved
}
Test-Case 'reset-default button uses its actual controller binding and persists the default' {
    Assert-That (Set-AssistantWakePhrase '小伴你好') 'Precondition phrase save failed.'
    $desktop.Controls.ResetWakePhraseButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    Assert-That ($script:wakePhrase -ceq '你好，声伴' -and (Saved-Preferences).wakePhrase -ceq '你好，声伴') 'Restore-default button did not save the default phrase.'
    Assert-Preserved
}
Test-Case 'invalid phrases never save or suspend listening' {
    foreach($text in @('','你','hello','你好123','小伴!你好',('声'*17))){Assert-Rejected $text}
}
Test-Case 'storage failure rolls back the phrase and retains the old listener and draft' {
    $script:settingsPath=Join-Path $runRoot 'directory-not-settings-file';[void][IO.Directory]::CreateDirectory($script:settingsPath)
    Assert-That (-not (Set-AssistantWakePhrase '小伴你好')) 'Storage failure was reported as success.'
    Assert-That ($script:wakePhrase -ceq '你好，声伴' -and $script:listenerStops -eq 0 -and $desktop.Controls.WakePhraseBox.Text -ceq '小伴你好') 'Failed save changed the listener or discarded the retry text.'
    Assert-That ($desktop.Controls.WakeHintLabel.Text -like '*保存没有完成*') 'Storage failure was not explained.'
    Assert-Preserved
}
Test-Case 'recording recognition dispatch send acknowledgement and shutdown block saving' {
    foreach($gate in @('recording','asr','autoDispatch','send','releasing','answering-wake','acknowledging','closing')){
        Reset-Fixture
        switch($gate){'recording'{$script:recMode='listening'}'asr'{$script:asrJob=@{active=$true}}'autoDispatch'{$script:autoDispatch=@{Text='Keep this intent'}}'send'{$script:bridgeJob=@{Purpose='send'}}'closing'{$script:closing=$true}default{$script:handsFreePhase=$gate}}
        Assert-Rejected
    }
}
Test-Case 'playing paused synthesizing and queued speech block saving without stopping output' {
    foreach($gate in @('playing','paused','tts','queued')){
        Reset-Fixture
        switch($gate){'playing'{[CodexReader.AudioPlayer]::State='playing'}'paused'{[CodexReader.AudioPlayer]::State='paused'}'tts'{$script:ttsJob=@{active=$true}}'queued'{$script:speechQueue.Enqueue('Keep the queued answer')}}
        Assert-Rejected
    }
}
Test-Case 'successful change suspends only the keyword listener and retains the hands-free preference' {
    foreach($enabled in @($true,$false)){
        Reset-Fixture;$script:handsFreeEnabled=$enabled;$script:handsFreePhase=if($enabled){'listening'}else{'off'};$script:bridgeJob=@{Purpose='read'};$oldBridge=$script:bridgeJob
        Assert-That (Set-AssistantWakePhrase '小伴你好') 'Idle listener settings were blocked by a draft or unrelated Codex read.'
        Assert-That ($script:handsFreeEnabled -eq $enabled -and (Saved-Preferences).handsFreeEnabled -eq $enabled -and $script:handsFreePhase -eq $(if($enabled){'waiting'}else{'off'})) 'Changing the keyword changed the hands-free opt-in.'
        Assert-That ($script:listenerStops -eq 1 -and $script:wakeListener.IsStopping -and $script:nextWakeUtc -gt [DateTime]::UtcNow -and $script:wakeReleaseScan -eq 21) 'Only the production listener suspension path should release capture.'
        Assert-That ([object]::ReferenceEquals($script:bridgeJob,$oldBridge)) 'Wake phrase save cleared an unrelated bridge read.'
        Assert-Preserved
    }
}
Test-Case 'unconsumed old wake events block save and a late stop event is marked observed' {
    foreach($pending in @('version','question')){
        Reset-Fixture
        if($pending -eq 'version'){$script:wakeListener.ActivationVersion=6L}else{$script:wakeListener.HasQuestion=$true}
        Assert-Rejected
    }
    Reset-Fixture;$script:lateWakeOnStop=$true
    Assert-That (Set-AssistantWakePhrase '小伴你好') 'Idle keyword save failed before simulated late stop callback.'
    Assert-That ($script:lastWakeVersion -eq $script:wakeListener.ActivationVersion -and $script:lastWakeVersion -eq 6L -and $script:handsFreePhase -eq 'waiting') 'Late old-keyword activation was left eligible to create a new question.'
    Assert-Preserved
}
Test-Case 'save-button and Enter run the actual production event handlers' {
    $desktop.Controls.WakePhraseBox.Text='声伴同学'
    $desktop.Controls.SaveWakePhraseButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    Assert-That ($script:wakePhrase -ceq '声伴同学' -and (Saved-Preferences).wakePhrase -ceq '声伴同学') 'Save-button binding failed.'
    $eventWindow=New-Object Windows.Window
    try{
        $handle=(New-Object Windows.Interop.WindowInteropHelper($eventWindow)).EnsureHandle()
        $source=[Windows.Interop.HwndSource]::FromHwnd($handle)
        $desktop.Controls.WakePhraseBox.Text='小伴同学'
        $key=New-Object Windows.Input.KeyEventArgs([Windows.Input.Keyboard]::PrimaryDevice,$source,[Environment]::TickCount,[Windows.Input.Key]::Return)
        $key.RoutedEvent=[Windows.Input.Keyboard]::KeyDownEvent
        $desktop.Controls.WakePhraseBox.RaiseEvent($key)
        Assert-That ($key.Handled -and -not $desktop.Controls.WakePhraseBox.IsReadOnly -and $script:wakePhrase -ceq '小伴同学' -and (Saved-Preferences).wakePhrase -ceq '小伴同学') 'Enter binding failed or editor stayed read-only.'
    }finally{$eventWindow.Close()}
    Assert-Preserved
}
$failed=@($script:results | Where-Object {-not $_.passed})
@{ok=($failed.Count -eq 0);checks=$script:checks;cases=@($script:results);settingsDirectory=$runRoot;realAudio=0;realMicrophones=0;realCodexRequests=0;windowsShown=0;eventWindow='A hidden owned HWND only, for the real WPF Enter event.'} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $resultRoot 'result.json') -Encoding UTF8
Write-Output ($script:results.Count.ToString()+' wake-phrase scenarios, '+$script:checks+' assertions, '+$failed.Count+' failed; no real audio, microphone or Codex requests.')
foreach($failure in $failed){Write-Output ($failure.name+': '+$failure.error)}
if($failed.Count){exit 1}
