param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run with Windows PowerShell 5.1 -STA.' }
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
Add-Type -TypeDefinition @'
namespace CodexReader {
 public static class AudioPlayer {
  public static string State="closed";
  public static int Pauses=0,Resumes=0;
  public static void Pause(){State="paused";Pauses++;}
  public static void Resume(){State="playing";Resumes++;}
 }
}
'@
foreach ($file in @('VoiceCommands.ps1','DesktopActions.ps1','PlaybackCommands.ps1','LocalCommands.ps1')) { . (Join-Path $Root ('src\'+$file)) }
foreach ($item in @(@{File='Assistant.ps1';Names=@('Send-Text')},@{File='HandsFree.ps1';Names=@('Try-AutoDispatch')},@{File='DesktopController.ps1';Names=@('Toggle-AnswerPlayback')})) {
 $tokens=$null;$errors=$null
 $tree=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root ('src\'+$item.File)),[ref]$tokens,[ref]$errors)
 if ($errors.Count) { throw $errors[0].Message }
 foreach ($name in $item.Names) {
  $node=$tree.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
  . ([scriptblock]::Create($node.Extent.Text))
 }
}
$script:InputBox=New-Object Windows.Controls.TextBox
$script:AnswerBox=New-Object Windows.Controls.TextBox
$script:checks=0
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message };$script:checks++ }
function Test-VoiceTaskCreateBlocksSend { return $script:createBlocked }
function Reset-VoiceTaskSwitch { $script:resets++ }
function Safe-To-Play { return $script:safePlay }
function Queue-AnswerSpeech([string]$Text) { [void]$script:speech.Add($Text) }
function Stop-Output { $script:stops++;[CodexReader.AudioPlayer]::State='closed';$script:speech.Clear() }
function Start-Bridge($Request,[string]$Purpose) {
 if ($script:mockThrow) { throw 'No worker was started.' }
 [void]$script:requests.Add(@{Request=$Request;Purpose=$Purpose})
 $script:bridgeJob=@{Request=$Request;Purpose=$Purpose}
 if ($script:newDraft) { $InputBox.Text=$script:newDraft;$script:autoDispatch=@{Text=$script:newDraft} }
 return $true
}
function Reset-Case {
 $script:closing=$false;$script:recMode='idle';$script:asrJob=$null;$script:handsFreePhase='listening'
 $script:connected=$true;$script:busy=$true;$script:threadId='11111111-1111-4111-8111-111111111111'
 $script:bridgeJob=$null;$script:autoDispatch=$null;$script:pendingUncertain=$false;$script:pendingSends=@{}
 $script:voiceGeneration=4;$script:TestMode=$false;$script:createBlocked=$false;$script:localCommandCount=0
 $script:autoSendPrepared=0;$script:resets=0;$script:mockThrow=$false;$script:newDraft='';$script:safePlay=$true
 $script:requests=New-Object Collections.ArrayList;$script:speech=New-Object Collections.ArrayList
 $script:latest='当前任务完整回答';$AnswerBox.Text=$script:latest;$script:tail=[pscustomobject]@{Offset=80}
 $InputBox.Text='';$script:stops=0;[CodexReader.AudioPlayer]::State='closed'
}
function Set-Intent([string]$Text) { $InputBox.Text=$Text;$script:autoDispatch=@{Text=$Text;Generation=$script:voiceGeneration;ThreadId=$script:threadId} }
foreach ($text in @('新建一个分组叫待办','把当前对话改名为周末安排','把当前对话放到待办分组','固定这个对话','归档这个对话','打开当前任务','有哪些分组')) {
 foreach ($route in @('manual','automatic')) {
  Reset-Case;Set-Intent $text
  if ($route -eq 'manual') { Send-Text;Send-Text } else { Try-AutoDispatch;Try-AutoDispatch }
  Assert ($script:requests.Count -eq 1) ('Expected exactly one action: '+$text+' '+$route)
  Assert ($script:requests[0].Purpose -eq 'voice-manage' -and $script:requests[0].Request.action -eq 'manage') 'Command escaped into chat.'
  Assert ($InputBox.Text -eq '' -and $null -eq $script:autoDispatch -and $script:localCommandCount -eq 1) 'Consumed command was not cleared once.'
  Assert ($script:threadId -eq '11111111-1111-4111-8111-111111111111' -and $script:latest -ceq '当前任务完整回答' -and $script:tail.Offset -eq 80) 'Management changed binding or answer cursor.'
 }
}
foreach ($text in @('不要新建待办分组','新建分组是什么意思','把当前对话改名为周末安排，然后查天气')) {
 Reset-Case;Set-Intent $text;Send-Text
 Assert ($script:requests.Count -eq 1 -and $script:requests[0].Purpose -eq 'send' -and $script:requests[0].Request.text -ceq $text) 'Discussion or negation was executed.'
}
foreach ($block in @('test','bridge','pending','create','disconnected','throw')) {
 Reset-Case
 switch ($block) {
  'test' {$script:TestMode=$true}
  'bridge' {$script:bridgeJob=@{Purpose='send'}}
  'pending' {$script:pendingUncertain=$true}
  'create' {$script:createBlocked=$true}
  'disconnected' {$script:connected=$false}
  'throw' {$script:mockThrow=$true}
 }
 Set-Intent '新建一个分组叫待办';Try-AutoDispatch
 Assert ($script:requests.Count -eq 0 -and $InputBox.Text -eq '' -and $null -eq $script:autoDispatch) ('Blocked operation escaped to chat: '+$block)
 Assert (-not [string]::IsNullOrWhiteSpace($script:notice)) 'Blocked action lacked feedback.'
}
Reset-Case;$script:newDraft='新写的问题';Set-Intent '新建一个分组叫待办';Try-AutoDispatch
Assert ($InputBox.Text -ceq '新写的问题' -and $script:autoDispatch.Text -ceq '新写的问题') 'Cleanup removed a newer draft.'
Reset-Case;$InputBox.Text='其它未发送的文字'
$cmd=[pscustomobject]@{operation='create_section';name='待办'}
[void](Begin-VoiceDesktopAction $cmd)
Assert ($script:requests.Count -eq 0 -and $InputBox.Text -ceq '其它未发送的文字') 'Different draft did not block mutation.'

Reset-Case;Set-Intent '新建一个分组叫待办';Try-AutoDispatch
$context=$script:bridgeJob.VoiceDesktopActionContext;$script:bridgeJob=$null
$result=[pscustomobject]@{ok=$true;requestId=$context.RequestId;operation=$context.Operation;message='已创建待办分组。'}
Assert (Complete-VoiceDesktopAction $result $context) 'Valid receipt failed.'
Assert ($script:speech.Count -eq 1 -and $script:speech[0] -ceq $result.message -and $script:desktopActionState -eq 'complete') 'Success feedback missing.'
Assert ($AnswerBox.Text -ceq $script:latest -and $script:tail.Offset -eq 80) 'Receipt replaced the answer or cursor.'
[void](Complete-VoiceDesktopAction $result $context)
Assert ($script:speech.Count -eq 1 -and $script:requests.Count -eq 1) 'Duplicate success repeated feedback or execution.'
foreach ($stale in @('voice','draft','thread','closing')) {
 Reset-Case;Set-Intent '新建一个分组叫待办';Try-AutoDispatch
 $context=$script:bridgeJob.VoiceDesktopActionContext;$script:bridgeJob=$null
 $result=[pscustomobject]@{ok=$true;requestId=$context.RequestId;operation=$context.Operation;message='已创建待办分组。'}
 switch ($stale) { 'voice' {$script:voiceGeneration++};'draft' {$InputBox.Text='新的草稿'};'thread' {$script:threadId='22222222-2222-4222-8222-222222222222'};'closing' {$script:closing=$true} }
 [void](Complete-VoiceDesktopAction $result $context)
 Assert ($script:speech.Count -eq 0 -and $script:desktopActionState -eq 'complete') 'Late receipt spoke over new work.'
 if ($stale -eq 'draft') { Assert ($InputBox.Text -ceq '新的草稿') 'Late receipt cleared draft.' }
}
foreach ($bad in @('id','operation','missing','uncertain','rejected','stringTrue','stringFalse','number','missingUncertainty','stringUncertainty')) {
 Reset-Case;Set-Intent '新建一个分组叫待办';Try-AutoDispatch
 $context=$script:bridgeJob.VoiceDesktopActionContext;$script:bridgeJob=$null
 $result=[pscustomobject]@{ok=$true;requestId=$context.RequestId;operation=$context.Operation;message='已创建。'}
 switch ($bad) {
  'id' {$result.requestId='wrong'}
  'operation' {$result.operation='rename_thread'}
  'missing' {$result=$null}
  'uncertain' {$result=[pscustomobject]@{ok=$false;error=@{message='结果待核对';uncertain=$true}}}
  'rejected' {$result=[pscustomobject]@{ok=$false;error=@{message='没有找到该分组';uncertain=$false}}}
  'stringTrue' {$result.ok='true'}
  'stringFalse' {$result.ok='false'}
  'number' {$result.ok=1}
  'missingUncertainty' {$result=[pscustomobject]@{ok=$false;error=@{message='不完整错误'}}}
  'stringUncertainty' {$result=[pscustomobject]@{ok=$false;error=@{message='错误类型';uncertain='false'}}}
 }
 Assert (-not (Complete-VoiceDesktopAction $result $context)) 'Invalid receipt claimed success.'
 Assert ($script:desktopActionState -eq $(if($bad -eq 'rejected'){'failed'}else{'unknown'})) 'Invalid receipt was not classified conservatively.'
 Assert ($script:speech.Count -eq 1 -and $script:speech[0] -ceq $script:notice -and $script:requests.Count -eq 1) 'Failure was not spoken locally once or replayed mutation.'
 $script:speech.Clear();$script:voiceGeneration++;$script:notice='新输入的状态'
 [void](Complete-VoiceDesktopAction $result $context)
 Assert ($script:speech.Count -eq 0 -and $script:notice -ceq '新输入的状态') 'Late failure overwrote new input feedback.'
}
Reset-Case;$context=@{RequestId='request';Operation='read_thread';SourceThreadId=$script:threadId;VoiceGeneration=$script:voiceGeneration}
$result=[pscustomobject]@{ok=$true;requestId='request';operation='read_thread';message='读取完成';text='其它任务的完整回答'}
[void](Complete-VoiceDesktopAction $result $context)
Assert ($script:speech[0] -ceq '其它任务的完整回答' -and $script:latest -ceq '当前任务完整回答') 'Temporary reading changed binding answer or read a summary.'

Reset-Case;Set-Intent '把当前对话放到语音助手项目里';Try-AutoDispatch
Assert ($script:requests.Count -eq 0 -and $InputBox.Text -eq '' -and $script:notice -like '*尚未接入*项目*') 'Unsupported project migration escaped to chat or was treated as grouping.'
Reset-Case;[CodexReader.AudioPlayer]::State='playing';Set-Intent '暂停朗读';Try-AutoDispatch
Assert ([CodexReader.AudioPlayer]::State -eq 'paused' -and $script:requests.Count -eq 0) 'Pause did not operate locally.'
Set-Intent '继续朗读';Try-AutoDispatch
Assert ([CodexReader.AudioPlayer]::State -eq 'playing') 'Resume did not operate locally.'
Set-Intent '重读上一条回答';Try-AutoDispatch
Assert ($script:speech.Count -eq 1 -and $script:speech[0] -ceq $script:latest -and $script:stops -eq 1) 'Replay did not use the last full answer.'
$resultDir=Join-Path $Root 'work\tests\desktop-actions'
[void][IO.Directory]::CreateDirectory($resultDir)
@{ok=$true;checks=$script:checks;realCodexMutations=0;realAudio=0;realMicrophones=0} | ConvertTo-Json | Set-Content (Join-Path $resultDir 'integration.json') -Encoding UTF8
Write-Output ('PASS '+$script:checks+' desktop action integration checks; no real Codex or audio operations.')
