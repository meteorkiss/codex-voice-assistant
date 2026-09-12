param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'src\VoiceCommands.ps1')
$checks = 0
function Assert-Command([string]$Text,[string]$Action,$Value,[string]$Scope='projectless') {
    $actual = Get-AssistantVoiceCommand $Text
    if ($null -eq $actual -or $actual.Action -cne $Action -or $actual.Value -cne $Value) { throw ('Wrong command: '+$Text+' => '+($actual|ConvertTo-Json -Compress)) }
    if ($Value -is [bool] -and $actual.Value -isnot [bool]) { throw ('Expected actual bool: '+$Text) }
    $propertyCount=if($Action -eq 'createTask'){3}else{2}
    if (@($actual.PSObject.Properties).Count -ne $propertyCount) { throw ('Unexpected properties: '+$Text) }
    if ($Action -eq 'createTask' -and $actual.Scope -cne $Scope) { throw ('Wrong task scope: '+$Text) }
    $script:checks++
}
function Assert-Routed([AllowNull()][AllowEmptyString()][string]$Text) {
    $actual = Get-AssistantVoiceCommand $Text
    if ($null -ne $actual) { throw ('Ordinary input was intercepted: '+$Text+' => '+($actual|ConvertTo-Json -Compress)) }
    $script:checks++
}

foreach($text in @('给我换个女生，台湾女生','换台湾女声','换成台湾女生','换成晓臻','换台湾女声晓臻','换个女生','换一个女声','切换到台湾女声','用台湾女声','声伴，请你帮我换成台湾女声吧，谢谢。')) { Assert-Command $text 'voice' 'zh-TW-HsiaoChenNeural' }
foreach($text in @('换成晓雨','换晓雨','换台湾女声晓雨','请换成台湾晓雨','你好，声伴，麻烦你给我换成晓雨一下吧。')) { Assert-Command $text 'voice' 'zh-TW-HsiaoYuNeural' }
foreach($text in @('换男声云哲','换成台湾男声云哲','换台湾男声','换个男声','换成云哲','用台湾男生的声音')) { Assert-Command $text 'voice' 'zh-TW-YunJheNeural' }
foreach($text in @('换普通话晓晓','换成晓晓','改成普通话女声','切换到普通话女声晓晓')) { Assert-Command $text 'voice' 'zh-CN-XiaoxiaoNeural' }
foreach($text in @('语速慢一点','语速慢点','把语速调慢一点','语速放慢','说慢一点','声伴，语速慢一点吧。')) { Assert-Command $text 'rate' 'slow' }
foreach($text in @('语速快一点','语速快点','把语速调快一点','语速加快','说得快一些','请帮我语速快一点')) { Assert-Command $text 'rate' 'fast' }
foreach($text in @('正常语速','恢复正常语速','语速恢复正常','改成正常语速','语速调回正常')) { Assert-Command $text 'rate' 'normal' }
foreach($text in @('置顶','窗口置顶','把悬浮窗置顶','请帮我置顶一下吧',' 声 伴，置 顶！ ')) { Assert-Command $text 'pin' $true }
foreach($text in @('取消置顶','取消窗口置顶','声伴，取消置顶吧')) { Assert-Command $text 'pin' $false }
foreach($text in @('显示字幕','打开字幕','声伴，请显示字幕')) { Assert-Command $text 'captions' $true }
foreach($text in @('隐藏字幕','关闭字幕','收起字幕')) { Assert-Command $text 'captions' $false }
foreach($text in @('显示悬浮声波','打开悬浮声波','开启悬浮声波')) { Assert-Command $text 'floating' $true }
foreach($text in @('隐藏悬浮声波','关闭悬浮声波','收起悬浮声波')) { Assert-Command $text 'floating' $false }
foreach($text in @('打开设置','打开声伴设置','声伴，请打开设置吧')) { Assert-Command $text 'settings' $true }
foreach($text in @('开启自动朗读','打开自动朗读')) { Assert-Command $text 'autoRead' $true }
Assert-Command '关闭自动朗读' 'autoRead' $false
foreach($entry in @(@('流光环','rays'),@('柔光环','halo'),@('微粒环','particles'),@('细线环','minimal'),@('律动音柱','bars'),@('流动声线','flow'))) { Assert-Command ('换成'+$entry[0]) 'style' $entry[1] }
foreach($text in @('停止朗读','声伴，停止朗读。','麻烦你帮我停止朗读一下')) { Assert-Command $text 'stop' $true }

$ordinary = @(
 $null,'','   ','晓臻','晓雨','台湾女声','普通话晓晓','流光环',
 '你能给我换个女生，台湾女生吗','给我换个女生，台湾女生？','语速慢一点吗','正常语速是多少','为什么语速慢一点比较好',
 '能不能显示字幕','可以显示字幕吗','我想知道怎么取消置顶','请问如何打开设置','打开设置是什么意思','停止朗读是什么意思',
 '不要停止朗读','别关闭字幕','不要取消置顶','不用换成晓雨','不需要打开设置','不能关闭自动朗读','不想换台湾女声',
 '我刚才说了停止朗读','他说显示字幕','如果我说显示字幕会怎样','请把停止朗读这几个字发给我','解释一下正常语速',
 '“停止朗读”','「显示字幕」','''关闭字幕''','"置顶"','`显示字幕`','```停止朗读```',
 '<command>停止朗读</command>','{"Action":"停止朗读"}','Action=停止朗读','# 打开设置','- 显示字幕','1. 显示字幕',
 '显示字幕，隐藏字幕','置顶并显示字幕','先停止朗读再换成晓雨','打开设置然后关闭字幕','关闭字幕和自动朗读','停止朗读，谢谢，然后回答我',
 '换个女生。台湾女生','置顶；显示字幕','显示字幕：置顶','换成晓雨或者晓臻','换成女声不要男声','换台湾女声还是普通话女声',
 '退出声伴','关闭声伴','关闭程序','自动退出','关闭电脑','切换任务','打开新的 Codex 任务','改成GPT-6','打开系统设置',
 '换成其它样式','换成晓明','换成英语女声','加快两倍','把窗口放到右边','记住：显示字幕','帮我研究台湾女生的声音',
 '请请置顶','声伴声伴置顶','置顶谢谢你说明一下','显示字幕帮我看看这个错误','我不要你回答，只要显示字幕'
)
foreach($text in $ordinary) { Assert-Routed $text }
Assert-Routed ('请' * 121 + '置顶')
Assert-Routed ("停止朗读"+[char]0x1b)
Assert-Command "`t显示 字幕。`r`n" 'captions' $true

foreach($entry in @(
 @('切换到高斯坡建任务','高斯坡建'),@('切到高斯坡建的这个任务','高斯坡建'),
 @('帮我切换到高斯泼溅这个任务','高斯泼溅'),@('声伴，请帮我切换到高斯泼溅这个任务吧，谢谢。','高斯泼溅'),
 @('切换到 Gaussian Splatting 任务','Gaussian Splatting'),@('切到ＧＰＴ－６ 实验的任务','ＧＰＴ－６ 实验'),
 @('切换到整理代码 2026任务','整理代码 2026'),@('切到高斯  泼溅任务','高斯  泼溅')
)) { Assert-Command $entry[0] 'switchTask' $entry[1] }
# Real reported wording, with synthetic title targets only. The command verb
# may accept the single ASR homophone; the target spelling remains untouched.
foreach($entry in @(
 @('帮我切换刀声伴V0.6.17 任务','声伴V0.6.17'),
 @('帮我切换到声伴V0.6.17任务','声伴V0.6.17'),
 @('声伴，请你帮我切换到声伴 v0.6.17 任务吧，谢谢。','声伴 v0.6.17'),
 @('麻烦你直接切换刀声伴 V 0 . 6 . 17 任务','声伴 V 0 . 6 . 17'),
 @('你帮我切到声伴 ｖ０．６．１７ 任务','声伴 ｖ０．６．１７'),
 @('切换到声伴 v0.6.17 · 短时连续接话任务','声伴 v0.6.17 · 短时连续接话'),
 @('帮我切换到声伴V0.6.17','声伴V0.6.17'),
 @('帮我切换刀声伴 V 0 . 6 . 17','声伴 V 0 . 6 . 17'),
 @('切换刀刀锋 V0.6.17任务','刀锋 V0.6.17')
)) { Assert-Command $entry[0] 'switchTask' $entry[1] }
foreach($text in @(
 '不要帮我切换刀声伴V0.6.17任务','帮我不要切换刀声伴V0.6.17任务',
 '“帮我切换刀声伴V0.6.17任务”','我说的是帮我切换刀声伴V0.6.17任务',
 '帮我切换刀声伴V0.6.17任务吗','帮我切换刀声伴V0.6.17任务只是测试',
 '帮我切换刀声伴V0.6.17只是测试','帮我切换刀声伴V0.6.17是什么意思',
 '帮我切换刀声伴V0.6.17任务然后打开设置','切换刀声伴V0.6.17任务并新建任务',
 '切换刀声伴V0.6.17任务帮我查天气','切换刀声伴V0.6.17再帮我查天气',
 '切换刀声伴V0.6.17并打开设置','先切换刀声伴V0.6.17任务再总结',
 '切换到声伴。V0.6.17任务','切换到声伴.V0.6.17任务','切换到声伴V0..6.17任务',
 '切换到声伴V0.6.17。显示字幕','切换到声伴V0.6.17!任务','切刀声伴V0.6.17任务'
)) { Assert-Routed $text }
foreach($entry in @(@('一',1),@('二',2),@('三',3),@('四',4),@('五',5),@('1',1),@('5',5))) {
 Assert-Command ('选择第'+$entry[0]+'个任务') 'chooseTask' $entry[1]
 Assert-Command ('选择第'+$entry[0]+'个') 'chooseTask' $entry[1]
}
Assert-Command '声伴，请选择第二个任务吧' 'chooseTask' 2
Assert-Command '取消任务切换' 'cancelTaskSwitch' $true
Assert-Command '声伴，帮我取消任务切换吧' 'cancelTaskSwitch' $true
Assert-Command '取消切换' 'cancelTaskSwitch' $true
Assert-Command '声伴，请取消切换吧' 'cancelTaskSwitch' $true
Assert-Command '声伴，请选择第二个吧' 'chooseTask' 2
foreach($text in @('选择第二个是什么意思','选择第二个？','不要选择第二个','不要取消切换','怎么取消切换','“取消切换”','选择第二个，然后继续','选择第六个')) { Assert-Routed $text }
foreach($text in @(
 '切换到任务','切换到这个任务','切到那个任务','切换任务','切换到高斯泼溅','选择第六个任务','选择第零个任务',
 '不要切换到高斯坡建任务','别切到高斯坡建任务','不用选择第一个任务','不要取消任务切换',
 '怎么切换到高斯坡建任务','能否切到高斯坡建任务','可以切换到高斯坡建任务吗','切换到高斯坡建任务？',
 '他说切换到高斯坡建任务','我刚才说了选择第一个任务','解释选择第二个任务','“切到高斯坡建任务”',
 '`切换到高斯坡建任务`','```切换到高斯坡建任务```','<cmd>选择第一个任务</cmd>',
 '切换到高斯坡建任务，然后打开设置','切换到高斯任务并打开另一个任务','先切换到高斯任务再切到文档任务',
 '切到高斯任务和打开设置任务','切换到高斯任务或者文档任务','选择第一个任务并显示字幕',
 '取消任务切换，然后帮我总结','切到../高斯任务','切到高斯😀任务','切换到高斯。坡建任务',
 '切换到高斯任务帮我看看其它任务','切换到高斯任务之前请先保存这个任务',
 '切换到高斯并总结这个任务','切换到高斯任务且显示字幕任务'
)) { Assert-Routed $text }
Assert-Routed "切换到高斯`n坡建任务"

foreach($text in @('新建一个任务','帮我新建一个任务','新建任务','请新建任务','声伴，请帮我新建一个任务吧，谢谢。','麻烦你新建一个任务一下','你好，声伴，替我新建任务！','新建 一个 任务')) { Assert-Command $text 'createTask' ([string]'') }
foreach($entry in @(
 @('新建一个叫天气的任务','天气'),@('新建一个任务叫天气','天气'),
 @('帮我新建一个叫天气的任务','天气'),@('声伴，请帮我新建一个叫天气的任务吧，谢谢。','天气'),
 @('新建一个叫 Gaussian Splatting 的任务','Gaussian Splatting'),@('新建一个任务叫ＧＰＴ－６ 实验','ＧＰＴ－６ 实验'),
 @('新建一个叫高斯  泼溅的任务','高斯  泼溅'),@('新建一个任务叫语音测试','语音测试'),
 @('新建一个任务叫谢谢','谢谢'),@('新建一个叫谢谢的任务','谢谢'),@('新建一个任务叫天气吧','天气吧')
)) { Assert-Command $entry[0] 'createTask' $entry[1] }
foreach($text in @(
 '不要新建一个任务','别新建任务','不用帮我新建一个任务','不实际新建任务','暂时不要新建任务',
 '能不能新建一个任务','可以新建一个任务吗','新建一个任务吗','新建一个任务叫天气吗','为什么新建任务','新建任务是什么意思','解释新建一个任务',
 '“新建一个任务”','「帮我新建任务」','`新建任务`','```新建任务```','<command>新建任务</command>',
 '测试新建一个任务','测试说明：新建一个任务','这是测试新建任务','新建一个任务只是测试','新建一个任务叫天气只是测试',
 '新建一个叫天气的任务测试一下','新建一个任务叫天气用于测试','我刚才说的是新建一个任务','他说帮我新建一个任务',
 '新建一个任务，然后查天气','新建一个叫天气的任务并打开设置','新建一个任务叫天气并总结新闻',
 '新建任务和切换到天气任务','新建一个任务并新建其它任务','先新建一个任务再继续','新建一个任务叫天气再帮我查新闻',
 '新建一个任务，名字叫天气','新建一个任务叫天气或者新闻','新建一个叫天气的任务之后打开它',
 '新建两个任务','新建一个叫的任务','新建一个任务叫','新建一个叫天气的任务和一个叫新闻的任务',
 '新建一个叫天气的任务加一个叫新闻的任务','新建一个任务叫天气新建一个任务叫新闻',
 '新建一个任务叫../天气','新建一个任务叫天气😀','新建一个任务叫天气。新闻','新建一个任务叫天气，新闻',
 '打开新任务','继续连接新任务','取消连接新任务','新建一个任务帮我看看这个问题'
)) { Assert-Routed $text }
Assert-Routed "新建一个任务`n叫天气"
foreach($text in @('新建一个聊天','新建聊天','新建一个聊天内容','帮我新建一个聊天','声伴，请新建聊天吧')) { Assert-Command $text 'createTask' ([string]'') }
foreach($text in @('在当前项目新建一个聊天','在当前项目里新建一个任务','请帮我在当前项目里新建一个聊天内容','声伴，请在当前项目新建聊天吧')) { Assert-Command $text 'createTask' ([string]'') 'current-project' }
Assert-Command '在当前项目新建一个叫天气的聊天' 'createTask' '天气' 'current-project'
Assert-Command '新建一个聊天叫天气' 'createTask' '天气'
foreach($text in @('比如我说新建一个聊天','如果新建一个聊天会怎样','新建一个聊天只是测试','不要发送给旧任务而是新建一个聊天','在当前项目新建一个聊天，然后发消息','在另一个项目新建聊天','在当前窗口新建任务','新建一个聊天和一个任务','新建一个叫天气的聊天和一个叫新闻的聊天')) { Assert-Routed $text }
foreach($text in @('连接刚才的新任务','声伴，请帮我连接刚才的新任务吧。')) { Assert-Command $text 'resumeCreatedTask' $true }
foreach($text in @('放弃连接新任务','声伴，请放弃连接新任务吧')) { Assert-Command $text 'cancelCreatedTaskConnection' $true }
foreach($text in @('不要连接刚才的新任务','连接刚才的新任务吗','连接刚才的新任务是什么意思','“放弃连接新任务”','测试放弃连接新任务','放弃连接新任务，然后新建任务')) { Assert-Routed $text }

# Equivalent short creation requests must stay local without changing ASR text.
foreach($verb in @('新建','创建','新开')) {
 foreach($noun in @('任务','对话','聊天','聊天内容')) {
  foreach($objectPrefix in @('','一个','个','新','一个新','个新')) {
   $text=$verb+$objectPrefix+$noun
   Assert-Command $text 'createTask' ([string]'')
   Assert-Command ('声伴，请帮我'+$text+'吧，谢谢。') 'createTask' ([string]'')
   Assert-Command ('在当前项目里'+$text) 'createTask' ([string]'') 'current-project'
  }
  foreach($negative in @(
   ('不要'+$verb+'新'+$noun),('能不能'+$verb+'一个新'+$noun),
   ($verb+'新'+$noun+'吗'),($verb+'新'+$noun+'是什么意思'),
   ('“'+$verb+'新'+$noun+'”'),('测试'+$verb+'新'+$noun),
   ($verb+'新'+$noun+'只是测试'),($verb+'一个新'+$noun+'，然后查天气'),
   ($verb+'两个'+$noun),($verb+'新'+$noun+'并打开设置'),
   ($verb+'一个新'+$noun+'叫天气再新开一个对话'),
   ($verb+'一个叫天气的新'+$noun+'和一个叫新闻的新对话'),
   ($verb+'新'+$noun+'叫天气'+$verb+'新'+$noun+'叫新闻'),
   ('在另一个项目'+$verb+'新'+$noun),
   ('如果我说'+$verb+'新'+$noun+'会怎样')
  )) { Assert-Routed $negative }
 }
}
foreach($entry in @(
 @('帮我创建一个新任务。',''),@('创建新对话',''),@('新开一个对话',''),@('新建一个对话',''),
 @('创建一个叫天气的对话','天气'),@('创建一个叫天气的新任务','天气'),
 @('新开一个新对话叫谢谢','谢谢'),@('创建新任务叫天气吧','天气吧'),
 @('创建 一个 新 对话 叫 ＧＰＴ－６ 实验','ＧＰＴ－６ 实验'),
 @('新开一个叫高斯  泼溅的聊天','高斯  泼溅')
)) { Assert-Command $entry[0] 'createTask' $entry[1] }
Assert-Command '请帮我在当前项目创建一个叫谢谢的新对话吧' 'createTask' '谢谢' 'current-project'
foreach($text in @(
 '声伴又卡了；另外创建新对话是不是就没法用了',
 '就是创建新任务，是必须要说创建新任务才能触发对吧',
 '我说别的创建新对话这个就没法用了是么？',
 '创建新对话是一个测试口令','创建一个新对话帮我看看这个问题',
 '创建一个新对话叫天气只用于测试','创建一个新对话叫天气并新开一个任务',
 '创建一个新对话叫天气和新开一个任务','创建一个新对话叫天气且新开一个任务',
 '创建一个叫天气的对话加一个叫新闻的对话','创建一个新对话叫天气新开一个任务',
 '创建一个新对话叫天气新建一个项目','创建一个新对话叫../天气',
 '创建一个新对话叫天气😀','创建一个叫的对话','创建一个新对话叫',
 '创建一个新对话叫天气，新闻','新开一个对话之后打开设置'
)) { Assert-Routed $text }
Assert-Routed "创建一个新对话`n叫天气"

# Natural spoken shortcuts must trigger locally, without extracting keywords
# from a discussion, negation, quoted example or multi-action request.
foreach($noun in @('任务','对话','聊天','聊天内容')) {
 foreach($prefix in @('','帮我','给我','你帮我','我想','我想要','我要','帮我直接')) {
  foreach($suffix in @('','吧','啊','呀','。')) {
   Assert-Command ($prefix+'新'+$noun+$suffix) 'createTask' ([string]'')
  }
  foreach($verb in @('弄','建','开','搞')) {
   Assert-Command ($prefix+$verb+'一个新'+$noun) 'createTask' ([string]'')
  }
 }
 Assert-Command ('在当前项目里新'+$noun) 'createTask' ([string]'') 'current-project'
 foreach($verb in @('弄','建','开','搞')) {
  Assert-Command ('声伴，请帮我'+$verb+'个新'+$noun+'吧，谢谢。') 'createTask' ([string]'')
  Assert-Command ('帮我在当前项目'+$verb+'一个新'+$noun) 'createTask' ([string]'') 'current-project'
  Assert-Command ('帮我'+$verb+'一个新'+$noun+'叫ＧＰＴ－６ 实验') 'createTask' 'ＧＰＴ－６ 实验'
  foreach($ordinary in @(
   ('帮我'+$verb+'一个'+$noun),('不要'+$verb+'一个新'+$noun),
   ('我想知道怎么'+$verb+'一个新'+$noun),('帮我'+$verb+'两个新'+$noun),
   ($verb+'一个新'+$noun+'，然后查天气'),('帮我'+$verb+'一个新'+$noun+'是什么意思'),
   ('新建一个任务叫天气再'+$verb+'一个新'+$noun)
  )) { Assert-Routed $ordinary }
 }
 foreach($ordinary in @(
  ('不要新'+$noun),('新'+$noun+'是什么意思'),('新'+$noun+'吗'),
  ('比如说新'+$noun+'啊'),('“新'+$noun+'”'),('我说的是新'+$noun),
  ('新'+$noun+'然后帮我查天气'),('这个新'+$noun),('新'+$noun+'创建失败了')
 )) { Assert-Routed $ordinary }
}
Assert-Command '帮我弄一个新对话' 'createTask' ([string]'')
Assert-Command '声伴，麻烦你给我建个新对话一下吧，谢谢。' 'createTask' ([string]'')
foreach($ordinary in @(
 '创建','帮我创建','新','新的','对话','任务',
 '这个怎么能让他就是关键词触发呢？就是比如说新对话啊，然后新任务啊之类的这种的，然后创建。',
 '我刚才说的帮我弄一个新对话没有触发','你看我刚才说的新对话又发到聊天里面了',
 '我想知道新对话怎么创建','新对话，新任务','帮我弄一个新对话帮我看看这个问题',
 '帮我弄一个新对话只是测试','我想新对话是什么意思'
)) { Assert-Routed $ordinary }

# Source encoding and parser syntax must work in the production PS 5.1 host.
$sourcePath = Join-Path $Root 'src\VoiceCommands.ps1'
$sourceBytes = [IO.File]::ReadAllBytes($sourcePath)
if ($sourceBytes.Length -lt 3 -or $sourceBytes[0] -ne 239 -or $sourceBytes[1] -ne 187 -or $sourceBytes[2] -ne 191) { throw 'VoiceCommands.ps1 must contain a UTF-8 BOM.' }; $checks++
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw $parseErrors[0].Message};$checks++
Write-Output ('PASS '+$checks+' voice command checks; matched commands and ordinary routing protected.')
