param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$fixture=Join-Path $Root ('work\tests\draft-recovery-'+[Guid]::NewGuid().ToString('N'))
$script:stateDir=$fixture
$script:checks=0
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:checks++ }
function Assert-Throws([scriptblock]$Action,[string]$Message) {
    $failed=$false; try { & $Action } catch { $failed=$true }
    Assert $failed $Message
}
$module=Join-Path $Root 'src\DraftRecovery.ps1'
. $module
Assert (-not [IO.Directory]::Exists($fixture)) 'Import created the configured state directory.'
$draftDirectory=Join-Path $fixture 'recovery-drafts'
$ownedFiles=New-Object 'Collections.Generic.List[string]'
$nested=Join-Path $draftDirectory 'nested'
try {
    [void][IO.Directory]::CreateDirectory($fixture)
    Assert (@(Get-AssistantRecoveryDraftFiles).Count -eq 0) 'Empty catalog was not empty.'
    Assert (-not [IO.Directory]::Exists($draftDirectory)) 'Listing created a recovery directory.'
    $id='11111111-1111-4111-8111-111111111111'
    $original="  第一行保留缩进`r`n第二行：语音助手 🙂`n`n末行带空格  "
    $first=Save-AssistantRecoveryDraft $id '声伴 · 合成任务' $original '原任务已归档'
    $ownedFiles.Add($first)
    $bytes=[IO.File]::ReadAllBytes($first)
    Assert ($bytes.Length -gt 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'Recovery text is not UTF-8 BOM.'
    $content=[IO.File]::ReadAllText($first,(New-Object Text.UTF8Encoding($true)))
    $marker='----- 原文开始 -----'+[Environment]::NewLine
    $offset=$content.IndexOf($marker,[StringComparison]::Ordinal)+$marker.Length
    Assert ($offset -ge $marker.Length -and $content.Substring($offset) -ceq $original) 'Original Unicode, whitespace or line endings changed.'
    Assert ($content.Contains('原任务标题：声伴 · 合成任务') -and $content.Contains('原任务编号：'+$id) -and $content.Contains('保存原因：原任务已归档') -and $content.Contains('保存时间：')) 'Recovery ownership metadata is incomplete.'
    Assert ([IO.Path]::IsPathRooted($first) -and (Split-Path -Parent $first) -ceq [IO.Path]::GetFullPath($draftDirectory)) 'Returned path escaped the recovery directory.'
    $second=Save-AssistantRecoveryDraft $id '声伴 · 合成任务' $original '原任务已归档'
    $ownedFiles.Add($second)
    Assert ($second -cne $first -and [IO.File]::Exists($first)) 'Repeated save replaced the prior copy.'
    $unbound=Save-AssistantRecoveryDraft '' '' '未绑定草稿' '未绑定'
    $ownedFiles.Add($unbound)
    Assert ([IO.File]::ReadAllText($unbound).Contains('原任务编号：未绑定')) 'An unbound draft was not identified.'
    $before=@(Get-AssistantRecoveryDraftFiles).Count
    Assert-Throws { Save-AssistantRecoveryDraft 'not-a-guid' 'invalid' 'must remain' 'fixture' } 'Invalid ID was accepted.'
    Assert (@(Get-AssistantRecoveryDraftFiles).Count -eq $before) 'Invalid ID created a draft.'
    Assert-Throws { Save-AssistantRecoveryDraft $id 'invalid Unicode' ([string][char]0xd800) 'fixture' } 'Invalid Unicode was silently replaced.'
    Assert (@(Get-ChildItem -LiteralPath $draftDirectory -File -Filter '*.tmp').Count -eq 0 -and @(Get-AssistantRecoveryDraftFiles).Count -eq $before) 'Failed Unicode conversion left a temporary or destination file.'
    foreach($invalidState in @('', 'relative\data', 'C:relative', '\relative')) {
        $script:stateDir=$invalidState
        Assert-Throws { Save-AssistantRecoveryDraft $id 'invalid state' 'must remain' 'fixture' } 'A missing or relative state directory was accepted.'
    }
    $script:stateDir=$fixture
    $existing=Join-Path $draftDirectory 'existing-user-copy.txt'; $ownedFiles.Add($existing)
    [IO.File]::WriteAllText($existing,'existing synthetic draft')
    $stray=Join-Path $draftDirectory 'unrelated.tmp'; $ownedFiles.Add($stray)
    [IO.File]::WriteAllText($stray,'unrelated synthetic temporary file')
    function Write-AssistantRecoveryDraftStream { param([IO.FileStream]$Stream,[string]$Content) $Stream.WriteByte(42); throw 'Synthetic partial write failure.' }
    Assert-Throws { Save-AssistantRecoveryDraft $id 'write failure' 'must remain' 'fixture' } 'Partial write failure was hidden.'
    Assert ([IO.File]::ReadAllText($existing) -ceq 'existing synthetic draft' -and [IO.File]::ReadAllText($stray) -ceq 'unrelated synthetic temporary file') 'Failure touched a file outside this save.'
    Assert (@(Get-ChildItem -LiteralPath $draftDirectory -File -Filter '*.tmp').Count -eq 1) 'Partial write leaked its temporary file.'
    . $module
    $script:collision=''
    function Move-AssistantRecoveryDraftTemporary {
        param([string]$Temporary,[string]$Destination)
        $script:collision=$Destination; $ownedFiles.Add($Destination)
        [IO.File]::WriteAllText($Destination,'existing synthetic collision')
        [IO.File]::Move($Temporary,$Destination)
    }
    Assert-Throws { Save-AssistantRecoveryDraft $id 'move failure' 'must remain' 'fixture' } 'Destination collision was overwritten.'
    Assert ([IO.File]::ReadAllText($script:collision) -ceq 'existing synthetic collision') 'Move failure replaced the existing destination.'
    Assert (@(Get-ChildItem -LiteralPath $draftDirectory -File -Filter '*.tmp').Count -eq 1) 'Move failure leaked its temporary file.'
    . $module
    [void][IO.Directory]::CreateDirectory($nested)
    $nestedFile=Join-Path $nested 'hidden.txt'; $ownedFiles.Add($nestedFile)
    [IO.File]::WriteAllText($nestedFile,'nested synthetic text')
    $catalog=@(Get-AssistantRecoveryDraftFiles)
    Assert ($catalog.Count -eq 5 -and @($catalog | Where-Object {$_.FullName -eq $nestedFile -or $_.Extension -ine '.txt'}).Count -eq 0) 'Catalog included nested or non-text files.'
    Assert (@($catalog | Where-Object {$_ -isnot [IO.FileInfo] -or (Split-Path -Parent $_.FullName) -cne [IO.Path]::GetFullPath($draftDirectory)}).Count -eq 0) 'Catalog is not direct absolute file metadata.'
    Assert ([IO.File]::ReadAllText($first).EndsWith($original,[StringComparison]::Ordinal)) 'Later operations changed the first recovery copy.'
    @{ok=$true;checks=$script:checks;boundary='Synthetic owned directory and production recovery functions; no real drafts, Codex tasks, audio, sends or UI.'} | ConvertTo-Json -Compress
} finally {
    # Exact known synthetic files only, followed by empty fixture directories.
    $allowed=[IO.Path]::GetFullPath($fixture).TrimEnd('\')+'\'
    foreach($path in $ownedFiles) {
        $full=[IO.Path]::GetFullPath($path)
        if (-not $full.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup escaped its owned directory.' }
        if ([IO.File]::Exists($full)) { [IO.File]::Delete($full) }
    }
    foreach($path in @($nested,$draftDirectory,$fixture)) {
        if ([IO.Directory]::Exists($path) -and [IO.Directory]::GetFileSystemEntries($path).Count -eq 0) { [IO.Directory]::Delete($path) }
    }
}
