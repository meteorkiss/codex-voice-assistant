param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $Root 'src\VoiceCommands.ps1')
$checks=0
function Assert-DesktopCommand([string]$Text,[string]$Operation,[hashtable]$Arguments=@{}) {
    $actual=Get-AssistantVoiceCommand $Text
    if ($null -eq $actual -or $actual.Action -cne 'desktopAction' -or $actual.Value.operation -cne $Operation) { throw ('Wrong desktop action: '+$Text+' => '+($actual|ConvertTo-Json -Compress -Depth 5)) }
    if (@($actual.PSObject.Properties).Count -ne 2 -or @($actual.Value.PSObject.Properties).Count -ne (1+$Arguments.Count)) { throw ('Wrong contract properties: '+$Text) }
    foreach($key in $Arguments.Keys) {
        if ($actual.Value.$key -isnot [string] -or $actual.Value.$key -cne $Arguments[$key]) { throw ('Wrong '+$key+': '+$Text+' => '+($actual|ConvertTo-Json -Compress -Depth 5)) }
    }
    $script:checks++
}
function Assert-DesktopOrdinary([AllowNull()][AllowEmptyString()][string]$Text) {
    $actual=Get-AssistantVoiceCommand $Text
    if ($null -ne $actual) { throw ('Ordinary text intercepted: '+$Text+' => '+($actual|ConvertTo-Json -Compress -Depth 5)) }
    $script:checks++
}
function Assert-PlaybackCommand([string]$Text,[string]$Value) {
    $actual=Get-AssistantVoiceCommand $Text
    if ($null -eq $actual -or $actual.Action -cne 'playback' -or $actual.Value -cne $Value -or @($actual.PSObject.Properties).Count -ne 2) { throw ('Wrong playback action: '+$Text+' => '+($actual|ConvertTo-Json -Compress)) }
    $script:checks++
}

foreach($text in @('新建一个分组叫待办','新建一个叫待办的分组','创建分组叫待办','新建个侧栏分组叫待办','声伴，请帮我新建一个叫待办的分组吧，谢谢。')) { Assert-DesktopCommand $text 'create_section' @{name='待办'} }
Assert-DesktopCommand '新建一个分组叫谢谢' 'create_section' @{name='谢谢'}
Assert-DesktopCommand '新建一个分组叫天气吧' 'create_section' @{name='天气吧'}
Assert-DesktopCommand '新建一个叫谢谢的分组吧，谢谢。' 'create_section' @{name='谢谢'}
Assert-DesktopCommand '新建一个分组叫ＧＰＴ－６  实验' 'create_section' @{name='ＧＰＴ－６  实验'}
Assert-DesktopCommand '新建一个分组叫语音测试' 'create_section' @{name='语音测试'}
Assert-DesktopCommand '把待办分组改名为工作' 'rename_section' @{section='待办';newName='工作'}
Assert-DesktopCommand '把ＧＰＴ－６  实验分组重命名为谢谢' 'rename_section' @{section='ＧＰＴ－６  实验';newName='谢谢'}
Assert-DesktopCommand '把当前对话改名为周末安排' 'rename_thread' @{target='current';name='周末安排'}
Assert-DesktopCommand '把这个任务改名为天气吧' 'rename_thread' @{target='current';name='天气吧'}
Assert-DesktopCommand '把谢谢对话改名为ＧＰＴ－６  实验' 'rename_thread' @{target='谢谢';name='ＧＰＴ－６  实验'}
foreach($noun in @('对话','任务','聊天')) {
    foreach($target in @('当前','这个','项目计划','谢谢','天气吧','ＧＰＴ－６  实验')) {
        $expected=if($target -in @('当前','这个')){'current'}else{$target}
        Assert-DesktopCommand ('把'+$target+$noun+'放到待办分组') 'move_thread' @{target=$expected;section='待办'}
        Assert-DesktopCommand ('把'+$target+$noun+'移动到语音助手项目里') 'unsupported_project_move' @{target=$expected;project='语音助手'}
        Assert-DesktopCommand ('打开'+$target+$noun) 'open_thread' @{target=$expected}
        Assert-DesktopCommand ('固定'+$target+$noun) 'pin_thread' @{target=$expected}
        Assert-DesktopCommand ('取消固定'+$target+$noun) 'unpin_thread' @{target=$expected}
        Assert-DesktopCommand ('归档'+$target+$noun) 'archive_thread' @{target=$expected}
        Assert-DesktopCommand ('恢复'+$target+$noun) 'restore_thread' @{target=$expected}
        Assert-DesktopCommand ('读一下'+$target+$noun+'的最新回答') 'read_thread' @{target=$expected}
        Assert-DesktopCommand ($target+$noun+'做完了吗') 'status_thread' @{target=$expected}
        Assert-DesktopCommand ($target+$noun+'完成了吗？') 'status_thread' @{target=$expected}
    }
}
Assert-DesktopCommand '把这个对话固定到侧栏顶部' 'pin_thread' @{target='current'}
Assert-DesktopCommand '把当前任务取消置顶' 'unpin_thread' @{target='current'}
Assert-DesktopCommand '把当前任务归档' 'archive_thread' @{target='current'}
Assert-DesktopCommand '取消归档语音助手任务' 'restore_thread' @{target='语音助手'}
Assert-DesktopCommand '声伴，请帮我打开语音助手任务一下吧，谢谢。' 'open_thread' @{target='语音助手'}
Assert-DesktopCommand '朗读当前任务的上一条回复' 'read_thread' @{target='current'}
Assert-DesktopCommand '把当前对话放到语音助手项目里' 'unsupported_project_move' @{target='current';project='语音助手'}
Assert-DesktopCommand '把当前对话放到谢谢项目里面' 'unsupported_project_move' @{target='current';project='谢谢'}
Assert-DesktopCommand '把当前对话移入ＧＰＴ－６  实验项目' 'unsupported_project_move' @{target='current';project='ＧＰＴ－６  实验'}
Assert-DesktopCommand '把当前对话放到天气吧分组' 'move_thread' @{target='current';section='天气吧'}
foreach($entry in @(@('任务','list_threads'),@('对话','list_threads'),@('分组','list_sections'),@('项目','list_projects'))) {
    Assert-DesktopCommand ('有哪些'+$entry[0]) $entry[1]
    Assert-DesktopCommand ('有哪些'+$entry[0]+'？') $entry[1]
    Assert-DesktopCommand ('列出所有'+$entry[0]) $entry[1]
}
Assert-DesktopCommand '删除待办分组' 'delete_section' @{section='待办'}
Assert-DesktopCommand '声伴，请删除谢谢分组吧。' 'delete_section' @{section='谢谢'}
Assert-DesktopCommand '把待办分组移到最上面' 'section_to_top' @{section='待办'}
Assert-DesktopCommand '把ＧＰＴ－６分组移动到侧栏顶部' 'section_to_top' @{section='ＧＰＴ－６'}
Assert-PlaybackCommand '暂停朗读' 'pause'
Assert-PlaybackCommand '声伴，请暂停朗读一下吧，谢谢。' 'pause'
Assert-PlaybackCommand '继续朗读' 'resume'
Assert-PlaybackCommand '继续读' 'resume'
Assert-PlaybackCommand '重读上一条回答' 'replay'
Assert-PlaybackCommand '重读上一条' 'replay'
Assert-PlaybackCommand '重读一下最后一条回复' 'replay'

foreach($command in @('新建一个分组叫待办','把待办分组改名为工作','把当前对话放到待办分组','把当前对话改名为计划','固定这个对话','取消固定这个对话','归档这个对话','恢复计划任务','打开计划任务','读一下当前任务的最新回答','删除待办分组','把待办分组移到最上面','暂停朗读','继续朗读','重读上一条回答','把当前对话放到语音助手项目里')) {
    foreach($prefix in @('不要','不用','别','不能','我不想','他说','解释一下','测试','如果我说','比如说','我刚才说的是')) { Assert-DesktopOrdinary ($prefix+$command) }
    foreach($suffix in @('是什么意思','吗','？','只是测试','用于测试','然后打开设置','并新建一个任务','，再归档这个对话','之前先保存')) { Assert-DesktopOrdinary ($command+$suffix) }
    Assert-DesktopOrdinary ('“'+$command+'”')
    Assert-DesktopOrdinary ('`'+$command+'`')
}
foreach($text in @(
    $null,'','   ','分组','待办分组','新建一个分组','新建一个叫的分组','新建一个分组叫','新建两个分组叫待办',
    '新建一个分组叫待办和一个分组叫工作','新建一个分组叫待办新建一个分组叫工作',
    '新建一个分组叫待办归档当前对话','新建一个分组叫待办删除工作分组','新建一个分组叫待办打开语音助手任务','新建一个分组叫待办，工作','新建一个分组叫../待办',
    '新建一个分组叫待办😀','新建一个分组叫待办是一个测试口令','把当前对话改名为','把待办分组改名为',
    '把当前对话放到项目里','把当前对话放到分组里','把当前对话放到语音助手','把当前对话放到工作空间',
    '打开新任务','打开新的 Codex 任务','打开那个任务','打开上一个任务','打开任务','归档对话','恢复任务',
    '打开一个任务','打开个任务','打开一个新的任务','打开一个新任务','打开某个任务','打开新的任务',
    '归档一个任务','恢复个任务','固定某个对话','把一个新任务放到待办分组','读一下一个任务的最新回答',
    '归档当前任务打开别的任务','打开甲任务归档乙任务','固定这个对话和另一个对话','打开甲任务和乙任务',
    '删除待办分组和工作分组','把待办分组移到第二个','某某任务做完了吗然后归档','当前任务做完了吗？然后归档',
    '我想知道当前任务做完了吗','当前任务做完了吗为什么','有哪些分组然后新建一个任务','有哪些分组是什么意思',
    '暂停','继续','重读','暂停朗读和自动朗读','停止朗读并暂停','把当前对话放到语音助手项目里然后打开它'
)) { Assert-DesktopOrdinary $text }
Assert-DesktopOrdinary ('新建一个分组叫'+('长'*121))
Assert-DesktopOrdinary "新建一个分组`n叫待办"
Assert-DesktopOrdinary ('归档这个对话'+[char]0x1b)
$oldStop=Get-AssistantVoiceCommand '停止朗读'
if ($oldStop.Action -cne 'stop' -or $oldStop.Value -isnot [bool] -or -not $oldStop.Value) { throw 'Existing stop behavior changed.' }; $checks++
foreach($path in @((Join-Path $Root 'src\DesktopActionCommands.ps1'),(Join-Path $Root 'src\VoiceCommands.ps1'),$PSCommandPath)) {
    $bytes=[IO.File]::ReadAllBytes($path)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) { throw ('Missing UTF-8 BOM: '+$path) }; $checks++
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count) { throw $parseErrors[0].Message }; $checks++
}
Write-Output ('PASS '+$checks+' desktop command checks; names preserved and unsafe utterances routed normally.')
