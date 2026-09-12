# Atomic JSON writes preserve the last valid file on failure. Temporary files
# belong to this call and are removed even when serialization or replacement fails.
function Write-AtomicJson {
    param([string]$Path, $Value, [int]$Depth=8)
    $destination=[IO.Path]::GetFullPath($Path)
    $temporary=$destination+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try {
        $content=$Value | ConvertTo-Json -Depth $Depth
        [IO.File]::WriteAllText($temporary,$content,(New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $destination) { [IO.File]::Replace($temporary,$destination,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$destination) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}
