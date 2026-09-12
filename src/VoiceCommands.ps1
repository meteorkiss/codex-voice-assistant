# Pure, deliberately narrow parsing. The caller owns all settings and side effects.
. (Join-Path $PSScriptRoot 'DesktopActionCommands.ps1')

function Get-AssistantVoiceCommand {
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 120) { return $null }
    $desktopCommand=Get-AssistantDesktopActionVoiceCommand $Text
    if ($desktopCommand) { return $desktopCommand }
    $createCommand=Get-AssistantCreateVoiceCommand $Text
    if ($createCommand) { return $createCommand }
    $taskCommand=Get-AssistantTaskVoiceCommand $Text
    if ($taskCommand) { return $taskCommand }
    $candidate = $Text.Normalize([Text.NormalizationForm]::FormKC).Trim()
    # Do not turn questions, quotations, code, or separated clauses into commands.
    if ($candidate -match '[?？:：;；“”‘’「」『』《》〈〉"`''\\/\[\]{}<>=|#]') { return $null }
    if ($candidate -match '[\x00-\x08\x0b\x0c\x0e-\x1f]') { return $null }
    $candidate = [regex]::Replace($candidate, '[\s。.!！]+\z', '')
    if ($candidate -match '[。.!！]') { return $null }
    $candidate = [regex]::Replace($candidate, '[\s,，、]', '')
    if ($candidate -match '(?:不要|不用|别|不想|不需要|不能|不可以|不许|不准|是否|能否|怎么|如何|什么|为什么|可不可以|能不能)') { return $null }

    # Only one short address/politeness prefix; never discard arbitrary prose.
    $candidate = [regex]::Replace($candidate, '\A(?:(?:你好)?声伴(?:你好)?)?(?:(?:请|麻烦)(?:你)?|劳驾)?(?:帮我|给我|替我)?', '')
    $candidate = [regex]::Replace($candidate, '(?:一下)?(?:吧)?(?:谢谢)?\z', '')
    if (-not $candidate) { return $null }

    $action = $null; $value = $null
    $voiceVerb = '(?:换(?:成|为)?|切换(?:成|为|到)?|改(?:成|为)|用)(?:一个|个)?'
    if ($candidate -match ('\A' + $voiceVerb + '(?:台湾(?:的)?(?:女声|女生)(?:的声音)?(?:晓臻)?|(?:女声|女生)(?:台湾(?:女声|女生))?|(?:台湾)?(?:女声)?晓臻)\z')) {
        $action = 'voice'; $value = 'zh-TW-HsiaoChenNeural'
    } elseif ($candidate -match ('\A' + $voiceVerb + '(?:(?:台湾)?(?:女声)?晓雨)\z')) {
        $action = 'voice'; $value = 'zh-TW-HsiaoYuNeural'
    } elseif ($candidate -match ('\A' + $voiceVerb + '(?:台湾(?:的)?(?:男声|男生)(?:的声音)?(?:云哲)?|(?:男声|男生)|(?:台湾)?(?:男声)?云哲)\z')) {
        $action = 'voice'; $value = 'zh-TW-YunJheNeural'
    } elseif ($candidate -match ('\A' + $voiceVerb + '(?:普通话(?:女声)?(?:晓晓)?|(?:普通话)?(?:女声)?晓晓)\z')) {
        $action = 'voice'; $value = 'zh-CN-XiaoxiaoNeural'
    } elseif ($candidate -match '\A(?:语速(?:调|放)?慢(?:一?点|一些)|(?:把)?语速(?:调慢|放慢)(?:一?点|一些)?|说(?:得)?慢(?:一?点|一些))\z') {
        $action = 'rate'; $value = 'slow'
    } elseif ($candidate -match '\A(?:语速(?:调|放)?快(?:一?点|一些)|(?:把)?语速(?:调快|加快)(?:一?点|一些)?|说(?:得)?快(?:一?点|一些))\z') {
        $action = 'rate'; $value = 'fast'
    } elseif ($candidate -match '\A(?:(?:恢复|改成|换成|切换到)?正常语速|语速(?:恢复|改成|调回)?正常)\z') {
        $action = 'rate'; $value = 'normal'
    } elseif ($candidate -match '\A(?:(?:把)?(?:窗口|悬浮窗)|把声伴)?(?:设为)?置顶\z') {
        $action = 'pin'; $value = $true
    } elseif ($candidate -match '\A取消(?:(?:声伴|窗口|悬浮窗))?置顶\z') {
        $action = 'pin'; $value = $false
    } elseif ($candidate -match '\A(?:显示|打开|开启)字幕\z') {
        $action = 'captions'; $value = $true
    } elseif ($candidate -match '\A(?:隐藏|关闭|收起)字幕\z') {
        $action = 'captions'; $value = $false
    } elseif ($candidate -match '\A(?:显示|打开|开启)悬浮声波\z') {
        $action = 'floating'; $value = $true
    } elseif ($candidate -match '\A(?:隐藏|关闭|收起)悬浮声波\z') {
        $action = 'floating'; $value = $false
    } elseif ($candidate -match '\A打开(?:声伴)?设置\z') {
        $action = 'settings'; $value = $true
    } elseif ($candidate -match '\A(?:开启|打开)自动朗读\z') {
        $action = 'autoRead'; $value = $true
    } elseif ($candidate -match '\A关闭自动朗读\z') {
        $action = 'autoRead'; $value = $false
    } elseif ($candidate -match '\A(?:换(?:成|为)?|切换(?:成|为|到)?|改(?:成|为))(流光环|柔光环|微粒环|细线环|律动音柱|流动声线)\z') {
        $styles = @{ '流光环'='rays'; '柔光环'='halo'; '微粒环'='particles'; '细线环'='minimal'; '律动音柱'='bars'; '流动声线'='flow' }
        $action = 'style'; $value = $styles[$Matches[1]]
    } elseif ($candidate -match '\A停止朗读\z') {
        $action = 'stop'; $value = $true
    }

    if ($action) { return [pscustomobject]@{ Action=$action; Value=$value } }
    return $null
}

# Creating is deliberately separate from task lookup: a trailing title must not
# lose real words such as "谢谢" through the generic politeness-suffix cleanup.
function Get-AssistantCreateVoiceCommand {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 120) { return $null }
    $candidate=$Text.Trim()
    if ($candidate -match '[?？:：;；“”‘’「」『』《》〈〉"`''\\/\[\]{}<>=|#\r\n]' -or $candidate -match '[\x00-\x1f]') { return $null }
    $candidate=[regex]::Replace($candidate,'[\s。.!！]+\z','')
    if ($candidate -match '[。.!！]') { return $null }
    $prefix='\A(?:(?:你好[\s，,]*)?声伴(?:[\s，,]*你好)?[\s，,]*)?(?:(?:请|麻烦)(?:你)?[\s，,]*|劳驾[\s，,]*)?(?:(?:(?:你)?(?:帮我|给我|替我)|我(?:想要|想|要))\s*)?(?:直接\s*)?'
    $candidate=[regex]::Replace($candidate,$prefix,'')
    $scope='projectless'
    if ($candidate -match '\A在当前项目(?:里)?\s*') {
        $scope='current-project';$candidate=$candidate.Substring($Matches[0].Length)
    }
    # Never convert negation, a test description, or an additional action into a
    # request to create a task. Ambiguous names keep the ordinary text route.
    if ($candidate -match '(?:不要|不用|别|不想|不需要|不能|不可以|不许|不准|是否|能否|可不可以|能不能|怎么|如何|为什么|什么意思|然后|接着|并且|同时|顺便|以及|或者|还是|只是|仅为|仅是|只作|只做|仅做|只用于|仅用于|用于测试|用来测试|用作测试|做个测试|做一次测试|测试一下|测试说明|测试口令|测试用|不实际|(?:并|再|和|且)(?:帮我|给我|替我|请|切|打|关|显|隐|回|查|删|发|执行|总结|整理|保存|停止|开始|设置|运行|重启|继续|分析|生成|解释|修改|创建|新建|读|播放|朗读|调|写)|任务(?:帮我|给我|替我|请|之前|之后|以后|前|后))' -or $candidate -match '[吗么呢]\z') { return $null }
    if ($candidate -match '(?:(?:并|再|和|且)(?:帮我|给我|替我|请)?新开|(?:对话|聊天(?:内容)?)(?:帮我|给我|替我|请|之前|之后|以后|前|后))') { return $null }
    $suffix='(?:\s*一下)?(?:\s*(?:吧|啊|呀|哦|哈))?(?:\s*[，,]?\s*谢谢)?\z'
    if ($candidate -match '(?:比如|例如|如果|假设|这是(?:一个)?测试|这个是(?:一个)?测试)') { return $null }
    # Common creation verbs and task/dialogue nouns describe the same local
    # action. Match the entire utterance; never rewrite the original ASR text.
    $noun='(?:任务|对话|聊天(?:内容)?)'
    $createVerb='(?:新建|创建|新开)'
    $objectPrefix='(?:(?:一)?个\s*)?(?:新\s*)?'
    # Standalone shortcut nouns and colloquial requests are creation commands.
    # Colloquial verbs require "new" so generic requests about a task stay text.
    if ($candidate -match ('\A新\s*'+$noun+$suffix)) {
        return [pscustomobject]@{Action='createTask';Value=[string]'';Scope=$scope}
    }
    $spokenCreateVerb='(?:弄|建|开|搞)'
    $createPrefix='\A(?:'+$createVerb+'\s*'+$objectPrefix+'|'+$spokenCreateVerb+'\s*(?:(?:一)?个\s*)?新\s*)'
    if ($candidate -match ($createPrefix+$noun+$suffix)) {
        return [pscustomobject]@{Action='createTask';Value=[string]'';Scope=$scope}
    }
    $named=[regex]::Match($candidate,($createPrefix+'叫\s*(?<title>.+?)\s*的\s*(?:新\s*)?'+$noun+$suffix))
    if (-not $named.Success) { $named=[regex]::Match($candidate,($createPrefix+$noun+'\s*叫\s*(?<title>.+)\z')) }
    if (-not $named.Success) { return $null }
    $title=$named.Groups['title'].Value.Trim()
    if (-not $title -or $title -notmatch '\A[\p{L}\p{N}\p{M}\s_\-－]+\z') { return $null }
    if ($title -match ('(?:的\s*(?:新\s*)?'+$noun+'|'+$noun+'\s*叫|新建\s*一个|'+$createVerb+'\s*(?:(?:一)?个\s*)?(?:新\s*)?'+$noun+'|'+$spokenCreateVerb+'\s*(?:(?:一)?个\s*)?新\s*'+$noun+')')) { return $null }
    return [pscustomobject]@{Action='createTask';Value=$title;Scope=$scope}
}

# Task names remain original text. Only the command verb accepts the observed
# ASR homophone "切换刀"; never rewrite spelling inside the title or original ASR.
function Get-AssistantTaskVoiceCommand {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 120) { return $null }
    $candidate=$Text.Trim()
    if ($candidate -match '[?？:：;；“”‘’「」『』《》〈〉"`''\\/\[\]{}<>=|#\r\n]' -or $candidate -match '[\x00-\x1f]') { return $null }
    $candidate=[regex]::Replace($candidate,'[\s。.!！]+\z','')
    # Numeric version separators are not sentence boundaries. Inspect a copy;
    # the query keeps the user's exact characters and spacing for display.
    $sentenceCheck=[regex]::Replace($candidate,'(?<=[0-9０-９])\s*[.．]\s*(?=[0-9０-９])','')
    if ($sentenceCheck -match '[。.!！．]') { return $null }
    $prefix='\A(?:(?:你好[\s，,]*)?声伴(?:[\s，,]*你好)?[\s，,]*)?(?:(?:请|麻烦)(?:你)?[\s，,]*|劳驾[\s，,]*)?(?:(?:你)?(?:帮我|给我|替我)\s*)?(?:直接\s*)?'
    $candidate=[regex]::Replace($candidate,$prefix,'')
    $candidate=[regex]::Replace($candidate,'(?:\s*一下)?(?:\s*吧)?(?:\s*[，,]?\s*谢谢)?\z','').Trim()
    if (-not $candidate -or $candidate -match '[，,、]' -or $candidate -match '(?:不要|不用|别|不想|不需要|不能|不可以|不许|不准|是否|能否|可不可以|能不能)') { return $null }
    if ($candidate -match '(?:然后|接着|并且|同时|顺便|以及|或者|还是|(?:并|再|和|且)(?:帮我|给我|替我|请|切|打|关|显|隐|回|查|删|发|执行|总结|整理|保存|停止|开始|设置|运行|重启|继续|分析|生成|解释|修改|创建|新建|读|播放|朗读|调|写)|任务(?:帮我|给我|替我|请|之前|之后|以后|前|后))') { return $null }
    if ($candidate -match '(?:比如|例如|如果|假设|只是|仅为|仅是|只作|只做|仅做|只用于|仅用于|用于测试|用来测试|用作测试|做个测试|做一次测试|测试一下|测试说明|测试口令|测试用|不实际|什么意思|怎么|如何|为什么)' -or $candidate -match '[吗么呢]\z') { return $null }
    $selection=[regex]::Match($candidate,'\A选择第\s*([一二三四五1-5])\s*个(?:任务)?\z')
    if ($selection.Success) {
        $numbers=@{'一'=1;'二'=2;'三'=3;'四'=4;'五'=5;'1'=1;'2'=2;'3'=3;'4'=4;'5'=5}
        return [pscustomobject]@{Action='chooseTask';Value=[int]$numbers[$selection.Groups[1].Value]}
    }
    if ($candidate -in @('取消任务切换','取消切换')) { return [pscustomobject]@{Action='cancelTaskSwitch';Value=$true} }
    if ($candidate -ceq '连接刚才的新任务') { return [pscustomobject]@{Action='resumeCreatedTask';Value=$true} }
    if ($candidate -ceq '放弃连接新任务') { return [pscustomobject]@{Action='cancelCreatedTaskConnection';Value=$true} }
    $switch=[regex]::Match($candidate,'\A(?:切换到|切换刀|切到)\s*(?<query>.+?)(?:的这个|这个|的)?任务\z')
    # A version-qualified task title may omit "任务". Keep bare generic
    # "切换到台湾女声" in the settings parser and ordinary prose unchanged.
    if (-not $switch.Success) {
        $switch=[regex]::Match($candidate,'\A(?:切换到|切换刀|切到)\s*(?<query>.+?[vVｖＶ]\s*[0-9０-９]+(?:\s*[.．]\s*[0-9０-９]+){2,})\z')
    }
    if (-not $switch.Success) { return $null }
    $query=$switch.Groups['query'].Value.Trim()
    if (-not $query -or $query -match '\A(?:这|那|这个|那个|当前|之前|上一个|下一个)\z') { return $null }
    if ($query -notmatch '\A[\p{L}\p{N}\p{M}\s_\-－.．·]+\z') { return $null }
    return [pscustomobject]@{Action='switchTask';Value=$query}
}
