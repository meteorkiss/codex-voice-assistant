# Pure parsing only. Preserve every name as spoken; the bridge resolves identities.
function New-AssistantDesktopActionCommand {
    param([string]$Operation,[hashtable]$Arguments=@{})
    $value=[ordered]@{operation=$Operation}
    foreach($key in $Arguments.Keys) { $value[$key]=$Arguments[$key] }
    return [pscustomobject]@{Action='desktopAction';Value=[pscustomobject]$value}
}

function Test-AssistantDesktopCommandName {
    param([AllowEmptyString()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 80) { return $false }
    if ($Name -notmatch '\A[\p{L}\p{N}\p{M}\s_\-－]+\z') { return $false }
    # An apparent name containing another complete action is ambiguous.
    if ($Name -match '(?:新建|创建|新开|打开|归档|恢复|删除|固定|置顶|改名|重命名|暂停朗读|继续朗读|重读|移到|移动到|放到|放入).*(?:任务|对话|聊天|分组|项目)' -or $Name -match '(?:和|加)(?:一)?个' -or $Name -match '(?:任务|对话|聊天|分组|项目)\s*(?:和|与|及|加|再|新建|创建|打开|归档|恢复|删除|固定|置顶|改名|重命名|移到|移动到|放到|放入)') { return $false }
    return $true
}

function ConvertTo-AssistantDesktopCommandTarget {
    param([AllowEmptyString()][string]$Name)
    $nameValue=$Name.Trim()
    if ($nameValue -ceq '当前' -or $nameValue -ceq '这个') { return 'current' }
    if ($nameValue -match '\A(?:这|那|那个|此|本|上一个|下一个|之前|刚才|刚才的新|另一个|一个|个|某个|一个新|一个新的|个新|个新的|新|新的(?:\s+Codex)?)\z') { return $null }
    if (-not (Test-AssistantDesktopCommandName $nameValue)) { return $null }
    return $nameValue
}

function Get-AssistantDesktopActionVoiceCommand {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 120) { return $null }
    $candidate=$Text.Trim()
    if ($candidate -match '[:：;；“”‘’「」『』《》〈〉"`''\\/\[\]{}<>=|#\r\n]' -or $candidate -match '[\x00-\x1f]') { return $null }
    $candidate=[regex]::Replace($candidate,'[\s。.!！]+\z','')
    if ($candidate -match '[。.!！]') { return $null }
    $prefix='\A(?:(?:你好[\s，,]*)?声伴(?:[\s，,]*你好)?[\s，,]*)?(?:(?:请|麻烦)(?:你)?[\s，,]*|劳驾[\s，,]*)?(?:(?:(?:你)?(?:帮我|给我|替我)|我(?:想要|想|要))\s*)?(?:直接\s*)?'
    $candidate=[regex]::Replace($candidate,$prefix,'')
    if ($candidate -match '\A(?:他说|她说|我说|我刚才|刚才说|测试|解释|说明|讨论|知道|了解|请问|询问)') { return $null }
    # Discussion, examples and compound requests remain ordinary chat.
    $unsafe='(?:不要|不用|别|不想|不需要|不能|不可以|不许|不准|是否|能否|可不可以|能不能|怎么|如何|为什么|什么意思|(?:之前|之后|以后)(?:先|再)|然后|接着|并且|同时|顺便|以及|或者|还是|比如|例如|如果|假设|只是|仅为|仅是|只作|只做|仅做|只用于|仅用于|用于测试|用来测试|用作测试|做个测试|做一次测试|测试一下|测试说明|测试口令|测试用|不实际|这是(?:一个)?测试|这个是(?:一个)?测试|(?:并|再|和|且)(?:帮我|给我|替我|请|切|打|关|显|隐|回|查|删|发|执行|总结|整理|保存|停止|开始|设置|运行|重启|继续|分析|生成|解释|修改|创建|新建|新开|归档|固定|置顶|移|放|读|播放|朗读|调|写)|(?:任务|对话|聊天|分组)(?:帮我|给我|替我|请|之前|之后|以后|前|后))'
    if (-not $candidate -or $candidate -match $unsafe) { return $null }
    $end='(?:\s*一下)?(?:\s*(?:吧|啊|呀))?(?:\s*[，,]?\s*谢谢)?\z'
    $thread='(?<target>.+?)\s*(?:任务|对话|聊天)'
    $section='(?<section>.+?)\s*(?:侧栏)?分组'

    # Only these explicit, read-only question forms are interpreted locally.
    $status=[regex]::Match($candidate,('\A'+$thread+'(?:做完了|完成了|结束了)吗[?？]?\z'))
    if ($status.Success) {
        $target=ConvertTo-AssistantDesktopCommandTarget $status.Groups['target'].Value
        if ($target) { return (New-AssistantDesktopActionCommand 'status_thread' @{target=$target}) }
        return $null
    }
    foreach($item in @(@('任务','list_threads'),@('对话','list_threads'),@('分组','list_sections'),@('项目','list_projects'))) {
        if ($candidate -match ('\A(?:有哪(?:些|几个)'+$item[0]+'[?？]?|(?:列出|显示|查看)(?:所有|全部)?'+$item[0]+')'+$end)) {
            return (New-AssistantDesktopActionCommand $item[1])
        }
    }
    if ($candidate -match '[?？]' -or $candidate -match '[吗么呢]\z') { return $null }
    foreach($item in @(@('暂停朗读','pause'),@('继续(?:朗读|读)','resume'),@('重读(?:一下)?(?:上一条|最后一条)(?:回答|回复)?','replay'))) {
        if ($candidate -match ('\A'+$item[0]+$end)) { return [pscustomobject]@{Action='playback';Value=$item[1]} }
    }

    # Terminal names have no politeness cleanup: 谢谢 and 天气吧 are names.
    $createPrefix='\A(?:新建|创建|新开)\s*(?:(?:一)?个\s*)?'
    $created=[regex]::Match($candidate,($createPrefix+'(?:侧栏)?分组\s*(?:叫|名叫|名称为)\s*(?<name>.+)\z'))
    if (-not $created.Success) { $created=[regex]::Match($candidate,($createPrefix+'叫\s*(?<name>.+?)\s*的\s*(?:侧栏)?分组'+$end)) }
    if ($created.Success) {
        $name=$created.Groups['name'].Value.Trim()
        if (Test-AssistantDesktopCommandName $name) { return (New-AssistantDesktopActionCommand 'create_section' @{name=$name}) }
        return $null
    }
    foreach($item in @(@('rename_section',$section),@('rename_thread',$thread))) {
        $renamed=[regex]::Match($candidate,('\A(?:把\s*)?'+$item[1]+'\s*(?:改名为|改名叫|改名成|重命名为)\s*(?<name>.+)\z'))
        if ($renamed.Success) {
            $name=$renamed.Groups['name'].Value.Trim()
            if (-not (Test-AssistantDesktopCommandName $name)) { return $null }
            if ($item[0] -eq 'rename_section') {
                $sectionName=$renamed.Groups['section'].Value.Trim()
                if (-not (Test-AssistantDesktopCommandName $sectionName)) { return $null }
                return (New-AssistantDesktopActionCommand 'rename_section' @{section=$sectionName;newName=$name})
            }
            $target=ConvertTo-AssistantDesktopCommandTarget $renamed.Groups['target'].Value
            if ($target) { return (New-AssistantDesktopActionCommand 'rename_thread' @{target=$target;name=$name}) }
            return $null
        }
    }

    $moved=[regex]::Match($candidate,('\A(?:把\s*)?'+$thread+'\s*(?:移到|移动到|放到|放入|移入)\s*(?<destination>.+?)\s*(?<kind>分组|项目)(?:里|里面)?'+$end))
    if ($moved.Success) {
        $target=ConvertTo-AssistantDesktopCommandTarget $moved.Groups['target'].Value
        $destination=$moved.Groups['destination'].Value.Trim()
        if (-not $target -or -not (Test-AssistantDesktopCommandName $destination)) { return $null }
        if ($moved.Groups['kind'].Value -ceq '项目') { return (New-AssistantDesktopActionCommand 'unsupported_project_move' @{target=$target;project=$destination}) }
        return (New-AssistantDesktopActionCommand 'move_thread' @{target=$target;section=$destination})
    }

    $pinEnd='(?:\s*到(?:侧栏)?(?:顶部|最上面))?'
    foreach($item in @(
        @('unpin_thread','(?:取消固定|取消置顶)',$end),
        @('pin_thread','(?:固定|置顶)',($pinEnd+$end)),
        @('archive_thread','归档',$end),@('restore_thread','(?:恢复|取消归档)',$end),
        @('open_thread','打开',$end)
    )) {
        $found=[regex]::Match($candidate,('\A'+$item[1]+'\s*'+$thread+$item[2]))
        if (-not $found.Success) { $found=[regex]::Match($candidate,('\A把\s*'+$thread+'\s*'+$item[1]+$item[2])) }
        if ($found.Success) {
            $target=ConvertTo-AssistantDesktopCommandTarget $found.Groups['target'].Value
            if ($target) { return (New-AssistantDesktopActionCommand $item[0] @{target=$target}) }
            return $null
        }
    }
    $read=[regex]::Match($candidate,('\A(?:读|朗读)(?:一下)?\s*'+$thread+'的(?:最新|最后一条|上一条)(?:回答|回复)'+$end))
    if ($read.Success) {
        $target=ConvertTo-AssistantDesktopCommandTarget $read.Groups['target'].Value
        if ($target) { return (New-AssistantDesktopActionCommand 'read_thread' @{target=$target}) }
        return $null
    }
    foreach($item in @(
        @('delete_section',('\A删除\s*'+$section+$end)),
        @('section_to_top',('\A(?:把\s*)?'+$section+'\s*(?:移到|移动到|放到)(?:侧栏)?(?:最上面|顶部)'+$end))
    )) {
        $found=[regex]::Match($candidate,$item[1])
        if ($found.Success) {
            $sectionName=$found.Groups['section'].Value.Trim()
            if (Test-AssistantDesktopCommandName $sectionName) { return (New-AssistantDesktopActionCommand $item[0] @{section=$sectionName}) }
            return $null
        }
    }
    return $null
}
