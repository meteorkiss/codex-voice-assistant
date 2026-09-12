function ConvertTo-SpokenText([string]$Text) {
    # Work on the speech copy only. The transcript and answer box keep full text.
    # App display directives can contain JSON and private/local file paths.
    $Text = [regex]::Replace($Text, '\uE200[^\uE201]*(?:\uE201|$)', '')
    $Text = [regex]::Replace($Text, '::[a-z][\w-]*\{(?>"(?:\\.|[^"\\])*"|[^{}"]+|\{(?<ui>)|\}(?<-ui>))*(?(ui)(?!))\}', '')

    # Respect the opening fence length, including nested shorter fences.
    # An unfinished code block is never sent to the voice service either.
    $prose = New-Object 'System.Collections.Generic.List[string]'
    $fenceChar = ''; $fenceLength = 0; $listContentIndent = -1
    foreach ($line in [regex]::Split($Text, '\r?\n')) {
        $contentLine = [regex]::Replace($line, '^(?:[ \t]*>[ \t]?)+', '')
        if ($fenceLength -gt 0) {
            $closing = [regex]::Match($contentLine, '^[ \t]*(`{3,}|~{3,})[ \t]*$')
            if ($closing.Success -and $closing.Groups[1].Value[0].ToString() -eq $fenceChar -and
                $closing.Groups[1].Length -ge $fenceLength) {
                $fenceLength = 0
            }
            continue
        }
        $listPrefix = [regex]::Match($contentLine, '^[ \t]*(?:[-+*]|\d+[.)])[ \t]+')
        if ($listPrefix.Success) { $listContentIndent = $listPrefix.Length }
        $fenceLine = if ($listPrefix.Success) { $contentLine.Substring($listPrefix.Length) } else { $contentLine }
        $opening = [regex]::Match($fenceLine, '^[ \t]*(`{3,}|~{3,})')
        if ($opening.Success) {
            $fenceChar = $opening.Groups[1].Value[0].ToString()
            $fenceLength = $opening.Groups[1].Length
            $prose.Add('')
            continue
        }
        $indent = [regex]::Match($contentLine.Replace("`t", '    '), '^ *').Length
        if ($contentLine.Trim() -and -not $listPrefix.Success) {
            if ($indent -lt $listContentIndent) { $listContentIndent = -1 }
            $codeIndent = if ($listContentIndent -ge 0) { $listContentIndent + 4 } else { 4 }
            if ($indent -ge $codeIndent) { continue }
        }
        $prose.Add($contentLine)
    }
    $Text = $prose -join "`n"

    # Balance parentheses in destinations, so My Folder (v2) leaves no tail.
    # Keep semantic links within sentences, but omit reference-only lines and
    # citation links appended after a completed sentence. Preserve display text.
    $linkPattern = '(?<media>!?)\[(?<label>[^\]\r\n]*)\]\((?>[^()\r\n]+|\((?<depth>)|\)(?<-depth>))*(?(depth)(?!))\)'
    $linkLabels = New-Object 'System.Collections.Generic.List[string]'
    $linkPrefix = 'SPEECHLINK' + [Guid]::NewGuid().ToString('N') + 'N'
    $linkTokenPattern = [regex]::Escape($linkPrefix) + '(?<index>[0-9]+)END'
    $protectLink = [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        if ($match.Groups['media'].Value) { return '' }
        $label = $match.Groups['label'].Value
        if ($label.Trim() -match '^<?(?:[A-Za-z]:[\\/]|\\\\|/)') { return '' }
        # Remove URL labels while their Markdown boundary is still known. If
        # restored first, a bare-URL sweep could swallow adjacent Chinese prose.
        if ($label.Trim('` *_<>'.ToCharArray()) -match '(?i)^(?:https?://|file:/+|codex:|www\.)') { return '' }
        $index = $linkLabels.Count
        $linkLabels.Add($label)
        return $linkPrefix + $index + 'END'
    }
    # Shortcut references are links only when the answer defines their ID.
    # Keep ordinary bracketed prose such as [待确认] unchanged.
    $referenceDefinitionPattern = '(?m)^[ \t]{0,3}\[(?<reference>[^\]\r\n]+)\]:[^\r\n]*$'
    $referenceIds = @{}
    foreach ($definition in [regex]::Matches($Text, $referenceDefinitionPattern)) {
        $referenceId = [regex]::Replace($definition.Groups['reference'].Value.Trim(), '\s+', ' ')
        if ($referenceId -and -not $referenceId.StartsWith('^')) { $referenceIds[$referenceId] = $true }
    }
    $Text = [regex]::Replace($Text, $referenceDefinitionPattern, '')
    $Text = [regex]::Replace($Text, $linkPattern, $protectLink)
    $Text = [regex]::Replace($Text, '(?<media>!?)\[(?<label>[^\]\r\n]+)\]\[[^\]\r\n]*\]', $protectLink)
    $Text = [regex]::Replace($Text, '(?<!\\)(?<media>!?)\[(?<label>[^\[\]\r\n]+)\](?![\[(])', [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $referenceId = [regex]::Replace($match.Groups['label'].Value.Trim(), '\s+', ' ')
        if ($referenceIds.ContainsKey($referenceId)) { return $protectLink.Invoke($match) }
        return $match.Value
    })
    $Text = [regex]::Replace($Text, '\[\^[^\]\r\n]+\]', '')
    $speechLines = New-Object 'System.Collections.Generic.List[string]'
    $referenceHeading = '(?i)^[ \t]*(?:#{1,6}[ \t]+)?(?:\*\*|__)?(?:参考资料|参考链接|参考来源|资料来源|来源|References|Sources)[ \t]*(?:(?:\*\*|__)[ \t]*)?[:：]?[ \t]*(?:(?:\*\*|__)[ \t]*)?'
    $citationSeparators = '[\s·•、,，;；:：|/（）()【】\[\]。.!！?？*_]*'
    $citationInnerSeparators = '[ \t·•、,，;；:：|/【】\[\]*_]*'
    $citationSequence = $citationInnerSeparators + '(?:' + $linkTokenPattern + $citationInnerSeparators + ')+'
    $parentheticalCitation = '[ \t]*(?:（' + $citationSequence + '）|\(' + $citationSequence + '\))(?<ending>[ \t]*[。.!！?？]*[ \t]*)$'
    $semanticLinkLead = '(?i)(?:看|查看|阅读|打开|访问|参考|参见|点击|选择|选用|使用|下载|参照|包括|是|为)(?:一下)?[ \t]*[:：]?$|\b(?:see|read|open|visit|refer to|click|choose|use|download|is|are)[ \t]*[:：]?$'
    foreach ($line in [regex]::Split($Text, '\r?\n')) {
        $hasLinks = [regex]::IsMatch($line, $linkTokenPattern)
        $withoutLinks = [regex]::Replace($line, $linkTokenPattern, '')
        $withoutLinks = [regex]::Replace($withoutLinks, $referenceHeading, '')
        $withoutLinks = [regex]::Replace($withoutLinks, '^\s*\d+[.)]\s*', '')
        if (($hasLinks -or [regex]::IsMatch($line, $referenceHeading)) -and
            $withoutLinks -match '^[\s\p{P}\p{S}]*$') {
            $speechLines.Add('')
            continue
        }
        $line = [regex]::Replace($line, $parentheticalCitation, [Text.RegularExpressions.MatchEvaluator]{
            param($match)
            # A trailing all-link aside is a citation; an explicit read/open
            # instruction still needs its linked object to make sense aloud.
            $lead = $line.Substring(0, $match.Index).Replace('**', '').Replace('__', '').TrimEnd()
            if ($lead -match $semanticLinkLead) { return $match.Value }
            return $match.Groups['ending'].Value
        })
        $line = [regex]::Replace($line, '(?<=[。！？.!?])' + $citationSeparators + '(?:' + $linkTokenPattern + $citationSeparators + ')+$', '')
        $speechLines.Add($line)
    }
    $Text = [regex]::Replace(($speechLines -join "`n"), $linkTokenPattern, [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        return $linkLabels[[int]$match.Groups['index'].Value]
    })

    # Keep short labels such as GPT-6, while omitting inline commands/paths.
    $Text = [regex]::Replace($Text, '(?<ticks>`+)(?<code>[^`\r\n]+)\k<ticks>', [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $label = $match.Groups['code'].Value.Trim()
        if ($label -match '^[\p{L}\p{N}]+(?:[-\u2010-\u2015][\p{L}\p{N}]+)*$' -or
            $label -match '^GPT[ ]+[0-9]+(?:\.[0-9]+)?$' -or
            ($label -match '[\p{IsCJKUnifiedIdeographs}]' -and $label -match '^[\p{L}\p{N} ，。！？、：；（）“”‘’…\-\u2010-\u2015]+$')) { return $label }
        return ''
    })
    $Text = [regex]::Replace($Text, '<(?:https?://|file:/|codex:)[^>\r\n]*>', '')
    $Text = [regex]::Replace($Text, '(?i)(?<![A-Za-z0-9_])(?:https?://|file:/+|codex://|www\.)[^\s<>\u3000-\u303f\uff00-\uffef]+', '')
    $Text = [regex]::Replace($Text, '"(?:[A-Za-z]:[\\/]|\\\\)[^"\r\n]+"', '')
    $Text = [regex]::Replace($Text, '(?<![A-Za-z0-9_])(?:[A-Za-z]:[\\/]|\\\\)[^\s<>"\u3000-\u303f\uff00-\uffef]+', '')
    $Text = [regex]::Replace($Text, '(?<![A-Za-z0-9_/])/(?:[^\s/<>"\u3000-\u303f\uff00-\uffef]+/)+[^\s<>"\u3000-\u303f\uff00-\uffef]*', '')
    $Text = [regex]::Replace($Text, '(?m)^[ \t]*(#{1,6}[ \t]+|>[ \t]*|[-*+][ \t]+)', '')
    $Text = $Text.Replace('**', '').Replace('__', '').Replace('`', '')
    $Text = [regex]::Replace($Text, '(?m)^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$', '')
    $Text = [regex]::Replace($Text, '[ \t]+', ' ')
    $Text = [regex]::Replace($Text, '(?m)^[ \t]+|[ \t]+$', '')
    $Text = [regex]::Replace($Text, '\n{3,}', "`n`n")
    return $Text.Trim()
}

function Get-CompletedAnswer($Tail, [string]$Line) {
    if (-not $Line.Contains('task_complete') -and -not $Line.Contains('task_started')) { return }
    try { $event = $Line.TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop }
    catch { return }
    if ($event.type -ne 'event_msg') { return }
    if ($event.payload.type -eq 'task_started') { $Tail.UserTurnVersion++; return }
    if ($event.payload.type -ne 'task_complete') { return }
    $turnId = [string]$event.payload.turn_id
    $answer = [string]$event.payload.last_agent_message
    if ([string]::IsNullOrWhiteSpace($turnId) -or [string]::IsNullOrWhiteSpace($answer)) { return }
    if (-not $Tail.Seen.Add($turnId)) { return }
    return [pscustomobject]@{ TurnId = $turnId; Text = $answer; UserTurnVersion = $Tail.UserTurnVersion }
}

function New-TranscriptTail([string]$Path) {
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    $tail = @{
        Path = $file.FullName
        Offset = [long]$file.Length
        CreationTicks = $file.CreationTimeUtc.Ticks
        Pending = [byte[]]@()
        Anchor = [byte[]]@()
        Seen = New-Object 'System.Collections.Generic.HashSet[string]'
        Latest = ''
        UserTurnVersion = 0
    }
    # Recent history is available for the Replay button; startup never speaks it.
    $stream = [IO.File]::Open($tail.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $start = [Math]::Max(0, $tail.Offset - 4MB)
        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $bytes = New-Object byte[] ([int]($tail.Offset - $start))
        $read = 0
        while ($read -lt $bytes.Length) {
            $n = $stream.Read($bytes, $read, $bytes.Length - $read)
            if ($n -eq 0) { break }
            $read += $n
        }
        $history = [Text.Encoding]::UTF8.GetString($bytes, 0, $read)
        $anchorLength = [int][Math]::Min(256, $read)
        $tail.Anchor = New-Object byte[] $anchorLength
        [Array]::Copy($bytes, $read - $anchorLength, $tail.Anchor, 0, $anchorLength)
        $lines = $history.Split([char]10)
        for ($i = $(if ($start -gt 0) { 1 } else { 0 }); $i -lt $lines.Length - 1; $i++) {
            $completed = Get-CompletedAnswer $tail $lines[$i]
            if ($null -ne $completed) { $tail.Latest = $completed.Text }
        }
        # A partial line present at startup is intentionally discarded.
        $tail.DropInitialPartial = ($read -gt 0 -and $bytes[$read - 1] -ne 10)
    } finally { $stream.Dispose() }
    return $tail
}

function Find-RelocatedTranscript([string]$Path) {
    # Codex archives/restores by moving the same rollout. Only accept the
    # exact filename under the same Codex root, never another task or a scan.
    $full=[IO.Path]::GetFullPath($Path)
    $match=[regex]::Match($full,'\A(?<root>.+)[\\/](?:sessions[\\/]\d{4}[\\/]\d{2}[\\/]\d{2}|archived_sessions)[\\/](?<name>rollout-(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})T[^\\/]+-[0-9a-fA-F-]{36}\.jsonl)\z')
    if (-not $match.Success) { return '' }
    $root=$match.Groups['root'].Value
    $name=$match.Groups['name'].Value
    $active=Join-Path $root ('sessions\'+$match.Groups['year'].Value+'\'+$match.Groups['month'].Value+'\'+$match.Groups['day'].Value+'\'+$name)
    $archived=Join-Path $root ('archived_sessions\'+$name)
    foreach ($candidate in @($active,$archived)) {
        if ($candidate -ine $full -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return ''
}

function Read-NewCompletedAnswers($Tail) {
    if (-not (Test-Path -LiteralPath $Tail.Path -PathType Leaf)) {
        $relocated=Find-RelocatedTranscript $Tail.Path
        # Preserve offset, partial bytes and turn deduplication across a move.
        if ($relocated) { $Tail.Path=$relocated }
    }
    $file = Get-Item -LiteralPath $Tail.Path -ErrorAction Stop
    if ($file.Length -lt $Tail.Offset -or $file.CreationTimeUtc.Ticks -ne $Tail.CreationTicks) {
        # Replaced history is treated like reopening the reader: don't replay it.
        $fresh = New-TranscriptTail $Tail.Path
        foreach ($key in @($fresh.Keys)) { $Tail[$key] = $fresh[$key] }
        return
    }
    if ($file.Length -eq $Tail.Offset) { return }
    $stream = [IO.File]::Open($Tail.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        # Length and creation time alone miss truncate-and-regrow between polls.
        if ($Tail.Anchor.Length -gt 0) {
            [void]$stream.Seek($Tail.Offset - $Tail.Anchor.Length, [IO.SeekOrigin]::Begin)
            $currentAnchor = New-Object byte[] $Tail.Anchor.Length
            $anchorRead = $stream.Read($currentAnchor, 0, $currentAnchor.Length)
            if ($anchorRead -ne $Tail.Anchor.Length -or
                [Convert]::ToBase64String($currentAnchor) -ne [Convert]::ToBase64String($Tail.Anchor)) {
                $fresh = New-TranscriptTail $Tail.Path
                foreach ($key in @($fresh.Keys)) { $Tail[$key] = $fresh[$key] }
                return
            }
        }
        [void]$stream.Seek($Tail.Offset, [IO.SeekOrigin]::Begin)
        $count = [int][Math]::Min(4MB, $stream.Length - $Tail.Offset)
        if ($count -le 0) { return }
        $chunk = New-Object byte[] $count
        $read = $stream.Read($chunk, 0, $count)
        $Tail.Offset += $read
    } finally { $stream.Dispose() }
    $anchorSource = New-Object byte[] ($Tail.Anchor.Length + $read)
    [Array]::Copy($Tail.Anchor, 0, $anchorSource, 0, $Tail.Anchor.Length)
    [Array]::Copy($chunk, 0, $anchorSource, $Tail.Anchor.Length, $read)
    $anchorLength = [int][Math]::Min(256, $anchorSource.Length)
    $Tail.Anchor = New-Object byte[] $anchorLength
    [Array]::Copy($anchorSource, $anchorSource.Length - $anchorLength, $Tail.Anchor, 0, $anchorLength)
    $all = New-Object byte[] ($Tail.Pending.Length + $read)
    [Array]::Copy($Tail.Pending, 0, $all, 0, $Tail.Pending.Length)
    [Array]::Copy($chunk, 0, $all, $Tail.Pending.Length, $read)
    $lastNewline = [Array]::LastIndexOf($all, [byte]10)
    if ($lastNewline -lt 0) { $Tail.Pending = $all; return }
    $completeText = [Text.Encoding]::UTF8.GetString($all, 0, $lastNewline + 1)
    $rest = New-Object byte[] ($all.Length - $lastNewline - 1)
    [Array]::Copy($all, $lastNewline + 1, $rest, 0, $rest.Length)
    $Tail.Pending = $rest
    $lines = $completeText.Split([char]10)
    $startLine = 0
    if ($Tail.DropInitialPartial) { $startLine = 1; $Tail.DropInitialPartial = $false }
    for ($i = $startLine; $i -lt $lines.Length - 1; $i++) {
        $completed = Get-CompletedAnswer $Tail $lines[$i]
        if ($null -ne $completed) { $Tail.Latest = $completed.Text; $completed }
    }
}
