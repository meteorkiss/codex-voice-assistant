# A worker owns files only beneath this assistant run. Resolve traversal and
# reject reparse points before removing any regular file.
function Remove-OwnedFiles($Paths) {
    $base=[IO.Path]::GetFullPath($runtime).TrimEnd('\')+'\'
    foreach ($path in @($Paths)) {
        if (-not $path) { continue }
        try {
            $full=[IO.Path]::GetFullPath([string]$path)
            if (-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            $cursor=$full; $linked=$false
            while ($cursor -and $cursor.Length -ge $base.TrimEnd('\').Length) {
                if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $linked=$true; break }
                $cursor=[IO.Path]::GetDirectoryName($cursor)
            }
            if (-not $linked) { [IO.File]::Delete($full) }
        } catch { $script:workerWarning='部分临时文件仍被占用，将保留供当前操作使用。' }
    }
}
function Close-Job($Job, [switch]$Kill) {
    if ($null -eq $Job) { return }
    try {
        if (-not $Job.Process.HasExited) {
            if (-not $Kill) { return }
            if ($Job.Purpose -in @('send','voice-create','voice-manage')) {
                $script:workerWarning='已派发的写操作仍在等待回执，保留进程和记录。'
                return
            }
            $Job.Process.Kill()
            if (-not $Job.Process.WaitForExit(1500) -or -not $Job.Process.HasExited) {
                $script:workerWarning='后台进程尚未退出，相关文件暂时保留。'
                return
            }
        }
        $Job.Process.Dispose()
    } catch { $script:workerWarning='后台进程释放未完成，相关文件暂时保留。'; return }
    Remove-OwnedFiles $Job.Files
    if ($Kill) { Remove-OwnedFiles @($Job.Audio) }
}
function Start-Worker([string]$Interpreter, [string]$Script, [string[]]$Arguments) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Interpreter
    $allArgs = @($Script) + $Arguments
    foreach ($value in $allArgs) { if ($value.Contains('"')) { throw '无效的本地参数路径。' } }
    $info.Arguments = (($allArgs | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process=[Diagnostics.Process]::Start($info)
    if (-not $process) { throw 'Windows 未能启动后台进程。' }
    return $process
}
