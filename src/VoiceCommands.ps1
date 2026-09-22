# Pure, deliberately narrow parsing. The caller owns all settings and side effects.
. (Join-Path $PSScriptRoot 'DesktopActionCommands.ps1')

# This parser must only be called inside a live local task-selection context.
function Get-AssistantTaskSelectionReply {
    param([string]$Text,[bool]$SingleCandidate=$false)
    $reply=[regex]::Replace($Text.Trim(),'[。.!！]+\z','').Trim()
    if ($reply -match '\A(?:不是|不对|不要|取消|取消切换|都不是|不是这个)\z') {
        return [pscustomobject]@{Action='cancelTaskSwitch';Value=$true}
    }
    if ($reply -match '\A(?:对|对的|是|是的|没错|就是这个|确认|确认切换)\z') {
        return [pscustomobject]@{Action='chooseTask';Value=$(if($SingleCandidate){1}else{0})}
    }
    return $null
}

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
    # Keep numeric keyword separators for the final task lookup. This only
    # relaxes the sentence check; settings still run before bare title lookup,
    # and that lookup receives the original ASR text rather than this copy.
    $sentenceCheck = [regex]::Replace($candidate, '(?<=[0-9])\s*\.\s*(?=[0-9])', '')
    if ($sentenceCheck -match '[。.!！]') { return $null }
    $candidate = [regex]::Replace($candidate, '[\s,，、]', '')
    if ($candidate -match '(?:不要|不用|别|不想|不需要|不能|不可以|不许|不准|是否|能否|怎么|如何|什么|为什么|可不可以|能不能)') { return $null }

    # Only one short address/politeness prefix; never discard arbitrary prose.
    $candidate = [regex]::Replace($candidate, '\A(?:(?:你好)?声伴(?:你好)?)?(?:(?:请|麻烦)(?:你)?|劳驾)?(?:帮我|给我|替我)?', '')
    $candidate = [regex]::Replace($candidate, '(?:一下)?(?:吧)?(?:谢谢)?\z', '')
    if (-not $candidate) { return $null }

    $action = $null; $value = $null
    $voiceVerb = '(?:换(?:成|为|到)?|切换(?:成|为|到)?|改(?:成|为)|用)(?:一个|个)?'
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
    # A bare task title is a local lookup only after known settings have had
    # their turn; "切换到台湾女声" must not become a task search.
    return Get-AssistantTaskVoiceCommand $Text -AllowBareTitle
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
# ASR homophones "切换刀" / "切刀"; never rewrite the title or original ASR.
function Get-AssistantTaskVoiceCommand {
    param([AllowNull()][AllowEmptyString()][string]$Text, [switch]$AllowBareTitle)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 120) { return $null }
    $candidate=$Text.Trim()
    if ($candidate -match '[?？:：;；“”‘’「」『』《》〈〉"`''\\/\[\]{}<>=|#\r\n]' -or $candidate -match '[\x00-\x1f]') { return $null }
    $candidate=[regex]::Replace($candidate,'[\s。.!！]+\z','')
    # Numeric version separators are not sentence boundaries. Inspect a copy;
    # the query keeps the user's exact characters and spacing for display.
    $sentenceCheck=[regex]::Replace($candidate,'(?<=[0-9０-９])\s*[.．]\s*(?=[0-9０-９])','')
    if ($sentenceCheck -match '[。.!！．]') { return $null }
    # Recover a short ASR-corrupted greeting only before a complete switch
    # command. Never discard negation/questions or arbitrary preceding prose.
    $greeting=[regex]::Match($candidate,'\A你好[\p{IsCJKUnifiedIdeographs}]{0,4}[，,]\s*(?<command>(?:切换[到刀道]|切[到刀道]|把\s*(?:任务|对话|聊天)).+)\z')
    if ($greeting.Success -and $candidate -notmatch '\A你好声伴[，,]' -and $candidate -notmatch '(?:不|别|没|吗|么|呢|如何|怎么|如果|假设|只是|例如|比如)') {
        $recovered=Get-AssistantTaskVoiceCommand $greeting.Groups['command'].Value -AllowBareTitle:$AllowBareTitle
        if ($recovered -and $recovered.Action -eq 'switchTask') {
            $recovered | Add-Member -NotePropertyName RequiresConfirmation -NotePropertyValue $true
            return $recovered
        }
    }
    $prefix='\A(?:(?:你好[\s，,]*)?声伴(?:[\s，,]*你好)?[\s，,]*)?(?:(?:请|麻烦)(?:你)?[\s，,]*|劳驾[\s，,]*)?(?:(?:你)?(?:帮我|给我|替我)\s*)?(?:直接\s*)?'
    $candidate=[regex]::Replace($candidate,$prefix,'')
    $candidate=[regex]::Replace($candidate,'(?:\s*一下)?(?:\s*吧)?(?:\s*[，,]?\s*谢谢)?\z','').Trim()
    if (-not $candidate -or $candidate -match '[，,、]' -or $candidate -match '(?:不要|不用|别|不想|不需要|不能|不可以|不许|不准|是否|能否|可不可以|能不能)') { return $null }
    if ($candidate -match '(?:然后|接着|并且|同时|顺便|以及|或者|还是|(?:并|再|和|且)(?:帮我|给我|替我|请|切|打|关|显|隐|回|查|删|发|执行|总结|整理|保存|停止|开始|设置|运行|重启|继续|分析|生成|解释|修改|创建|新建|读|播放|朗读|调|写)|任务(?:帮我|给我|替我|请|之前|之后|以后|前|后))') { return $null }
    # "新开" is a supported create verb, not part of a compound switch target.
    if ($candidate -match '(?:并|再|和|且)\s*(?:帮我|给我|替我|请)?\s*新开') { return $null }
    if ($candidate -match '(?:比如|例如|如果|假设|只是|仅为|仅是|只作|只做|仅做|只用于|仅用于|用于测试|用来测试|用作测试|做个测试|做一次测试|测试一下|测试说明|测试口令|测试用|不实际|什么意思|怎么|如何|为什么)' -or $candidate -match '[吗么呢]\z') { return $null }
    $selection=[regex]::Match($candidate,'\A选择第\s*([一二三四五1-5])\s*个(?:任务)?\z')
    if ($selection.Success) {
        $numbers=@{'一'=1;'二'=2;'三'=3;'四'=4;'五'=5;'1'=1;'2'=2;'3'=3;'4'=4;'5'=5}
        return [pscustomobject]@{Action='chooseTask';Value=[int]$numbers[$selection.Groups[1].Value]}
    }
    if ($candidate -in @('取消任务切换','取消切换')) { return [pscustomobject]@{Action='cancelTaskSwitch';Value=$true} }
    if ($candidate -ceq '连接刚才的新任务') { return [pscustomobject]@{Action='resumeCreatedTask';Value=$true} }
    if ($candidate -ceq '放弃连接新任务') { return [pscustomobject]@{Action='cancelCreatedTaskConnection';Value=$true} }
    $switchVerb='(?:切换[到刀道]|切[到刀道]|换到)'
    # Object-between forms are equivalent to the existing object-first form.
    $candidate=[regex]::Replace($candidate,'\A(?:切换|切|换)\s*(任务|对话|聊天(?:内容)?)\s*[到刀道]\s*','把$1切到')
    # A locative task suffix belongs to the command, not the searched name.
    # Require an explicit switch verb and a concrete target before removing it.
    if ($candidate -match ('\A(?:把\s*(?:任务|对话|聊天(?:内容)?)\s*)?'+$switchVerb)) {
        $candidate=[regex]::Replace($candidate,'(?:的这个|这个|那个|的)?(?:任务|对话|聊天(?:内容)?)(?:里面|里边|里|中)\z','这个任务')
    }
    # Spoken object-first requests are explicitly about task binding, so they
    # do not need the trailing task noun or the bare-title settings fallback.
    # Keep the target's spelling/version exactly as heard; lookup owns failure.
    $switch=[regex]::Match($candidate,('\A把\s*(?:任务|对话|聊天(?:内容)?)\s*'+$switchVerb+'\s*(?<query>.+)\z'))
    $frontedTask=$switch.Success
    if (-not $switch.Success) {
        $switch=[regex]::Match($candidate,('\A'+$switchVerb+'\s*(?<query>.+?)(?:的这个|这个|的)?任务\z'))
    }
    # A version-qualified task title may omit "任务". Keep bare generic
    # "切换到台湾女声" in the settings parser and ordinary prose unchanged.
    if (-not $switch.Success) {
        $switch=[regex]::Match($candidate,('\A'+$switchVerb+'\s*(?<query>.+?[vVｖＶ]\s*[0-9０-９]+(?:\s*[.．]\s*[0-9０-９]+){2,})\z'))
    }
    $bareTitle=$false
    if (-not $switch.Success -and $AllowBareTitle) {
        $switch=[regex]::Match($candidate,('\A'+$switchVerb+'\s*(?<query>.+)\z'))
        $bareTitle=$switch.Success
    }
    if (-not $switch.Success) { return $null }
    $query=$switch.Groups['query'].Value.Trim()
    # Only explicit demonstratives/separators mark a conversational suffix;
    # keep actual names ending in 对话/聊天 intact (for example 语音对话).
    $query=[regex]::Replace($query,'(?:\s+|的这个|这个|那个|的)(?:任务|对话|聊天(?:内容)?)\z','').Trim()
    if ($frontedTask) {
        # A single colloquial demonstrative addresses the following concrete
        # name. Never turn "this/that task" alone into a guessed identity.
        $query=[regex]::Replace($query,'\A(?:这个|那个)\s*(?=\S)','')
        # The object already declares a task lookup. Only explicit separating
        # markers denote a trailing noun; keep names such as "语音对话" and
        # "新任务" intact instead of silently broadening them to another title.
        $query=[regex]::Replace($query,'(?:\s+|的这个|这个|的)(?:任务|对话|聊天(?:内容)?)\z','').Trim()
        if ($query -match '\A(?:(?:这|那|这个|那个|当前|之前|上一个|下一个)?(?:任务|对话|聊天(?:内容)?))\z') { return $null }
    }
    if (-not $query -or $query -match '\A(?:任务|这|那|这个|那个|当前|之前|刚才|刚才那个|刚才的|上一个|下一个)\z') { return $null }
    # Without the task noun there is no explicit end marker. Keep apparent
    # extra instructions and unresolved references out of this lookup route.
    if (($bareTitle -or $frontedTask) -and $query -match '(?:帮我|给我|替我|请|之前|之后|以后|刚才那个|刚才的|那个任务|这个任务)') { return $null }
    if ($query -notmatch '\A[\p{L}\p{N}\p{M}\s_\-－.．·]+\z') { return $null }
    return [pscustomobject]@{Action='switchTask';Value=$query}
}

function Test-UnresolvedTaskSwitchIntent([string]$Text) {
    # This is a non-executing safety net, not another permissive command parser.
    # A short, imperative-looking request with a target stays local on parse
    # failure; descriptions, quoted examples, negatives and questions stay chat.
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 120) { return $false }
    if ($Text -match '[?？:：;；“”‘’「」『』《》"`''\r\n\x00-\x1f]' -or
        $Text -match '(?:不|别|如果|假设|比如|例如|只是|他说|我说|刚才|解释|怎么|如何|为什么|什么意思|[吗么呢][。.!！\s]*$)') { return $false }
    $imperative='(?:切换|切|换)(?:(?:任务|对话|聊天)\s*)?[到刀道]\s*.+'
    $ordinary=[bool]($Text -match ('\A\s*(?:[\p{IsCJKUnifiedIdeographs}]{1,6}[，,]\s*)?(?:(?:请|麻烦你?|帮我|给我)\s*)?(?:把\s*(?:任务|对话|聊天)\s*)?'+$imperative))
    # A corrupted short greeting without punctuation is clarification-only.
    # It must still contain a politeness marker and an explicit task/version
    # target, so arbitrary preceding prose is never discarded or executed.
    $shortGreeting=[bool]($Text -match ('\A\s*你好[\p{IsCJKUnifiedIdeographs}]{0,4}(?:请|麻烦你?|帮我|给我)(?:把\s*(?:任务|对话|聊天)\s*)?'+$imperative))
    return [bool](($ordinary -or $shortGreeting) -and
        $Text -match '(?:任务|对话|[0-9０-９]\s*[.．]\s*[0-9０-９])')
}
