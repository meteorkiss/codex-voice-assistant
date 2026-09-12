# Local recovery copies only. Importing this file creates or reads nothing.
function Get-AssistantRecoveryDraftDirectory {
    param([switch]$Create)
    $configured=Get-Variable -Name stateDir -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($configured -isnot [string] -or [string]::IsNullOrWhiteSpace($configured) -or
        $configured -notmatch '\A[A-Za-z]:[\\/]') { throw '尚未明确本机数据目录，不能保存恢复草稿。' }
    $base=[IO.Path]::GetFullPath($configured)
    if (-not [IO.Directory]::Exists($base)) { throw '数据目录尚未准备好，原草稿保持不变。' }
    $directory=[IO.Path]::GetFullPath((Join-Path $base 'recovery-drafts'))
    if ([IO.File]::Exists($directory)) { throw '恢复草稿目录不可用，原草稿保持不变。' }
    if ([IO.Directory]::Exists($directory)) {
        if (([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw '恢复草稿目录不能是链接，原草稿保持不变。'
        }
    } elseif ($Create) { [void][IO.Directory]::CreateDirectory($directory) }
    return $directory
}

function Write-AssistantRecoveryDraftStream {
    param([IO.FileStream]$Stream,[string]$Content)
    # Reject invalid UTF-16 rather than silently replacing original characters.
    $encoding=New-Object Text.UTF8Encoding($true,$true)
    $preamble=$encoding.GetPreamble(); $bytes=$encoding.GetBytes($Content)
    $Stream.Write($preamble,0,$preamble.Length)
    $Stream.Write($bytes,0,$bytes.Length)
    $Stream.Flush($true)
}

function Move-AssistantRecoveryDraftTemporary {
    param([string]$Temporary,[string]$Destination)
    # File.Move refuses an existing destination; recovery never replaces a copy.
    [IO.File]::Move($Temporary,$Destination)
}

function Save-AssistantRecoveryDraft {
    param([AllowEmptyString()][string]$ThreadId,[AllowEmptyString()][string]$Title,
          [AllowEmptyString()][string]$Text,[AllowEmptyString()][string]$Reason)
    $id=[Guid]::Empty
    if ($ThreadId -and -not [Guid]::TryParse($ThreadId,[ref]$id)) { throw '原任务编号无效，原草稿保持不变。' }
    $directory=Get-AssistantRecoveryDraftDirectory -Create
    $now=[DateTimeOffset]::Now
    $stem='draft-'+$now.ToString('yyyyMMdd-HHmmss-fff')+'-'+[Guid]::NewGuid().ToString('N')
    $destination=Join-Path $directory ($stem+'.txt')
    $temporary=Join-Path $directory ($stem+'.tmp')
    $newline=[Environment]::NewLine
    $source=if ($ThreadId) { $ThreadId } else { '未绑定' }
    $content='声伴恢复草稿'+$newline+'原任务标题：'+$Title+$newline+'原任务编号：'+$source+$newline+
        '保存时间：'+$now.ToString('o')+$newline+'保存原因：'+$Reason+$newline+
        '以下为原文（不会自动发送或填入其它任务）：'+$newline+'----- 原文开始 -----'+$newline+$Text
    $stream=$null; $ownsTemporary=$false
    try {
        $stream=New-Object IO.FileStream($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $ownsTemporary=$true
        Write-AssistantRecoveryDraftStream $stream $content
        $stream.Dispose(); $stream=$null
        Move-AssistantRecoveryDraftTemporary $temporary $destination
        return [IO.Path]::GetFullPath($destination)
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($ownsTemporary -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Get-AssistantRecoveryDraftFiles {
    $directory=Get-AssistantRecoveryDraftDirectory
    if (-not [IO.Directory]::Exists($directory)) { return }
    # Metadata only, direct children only. Never follow a link or open draft text.
    Get-ChildItem -LiteralPath $directory -File -Filter '*.txt' -ErrorAction Stop |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and $_.Extension -ieq '.txt' } |
        Sort-Object LastWriteTimeUtc,Name -Descending
}
