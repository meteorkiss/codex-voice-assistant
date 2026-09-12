param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
# Compile only a disposable launcher. Never launch it or copy personal data.
$run=Join-Path $Root ('work\tests\version-build-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($run)
$script:checks=0
function Assert([bool]$Condition,[string]$Message) { if(-not $Condition){throw $Message};$script:checks++ }
try {
    foreach($folder in @('src','tools','assets')) { [void][IO.Directory]::CreateDirectory((Join-Path $run $folder)) }
    foreach($relative in @('src\Version.ps1','src\Launcher.cs','tools\Build-Launcher.ps1','assets\shengban.ico')) {
        Copy-Item -LiteralPath (Join-Path $Root $relative) -Destination (Join-Path $run $relative)
    }
    $readme=Join-Path $run 'README.md';$changelog=Join-Path $run 'CHANGELOG.md';$version=Join-Path $run 'VERSION'
    $launcher=Join-Path $run '声伴.exe';$source=Join-Path $run 'src\Launcher.cs'
    $powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    function Build-Fixture {
        $prior=$ErrorActionPreference
        try {
            $ErrorActionPreference='Continue'
            $output=@(& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $run 'tools\Build-Launcher.ps1') 2>&1)
            $exitCode=$LASTEXITCODE
        } finally {$ErrorActionPreference=$prior}
        return $exitCode
    }
    function Reset-VersionFiles {
        [IO.File]::WriteAllText($readme,'当前开发版 **v6 / 2.3.4**')
        [IO.File]::WriteAllText($changelog,"# Updates`n`n## 2.3.4 · fixture`n")
        [IO.File]::WriteAllText($version,"2.3.4`n")
    }
    Reset-VersionFiles
    Assert ((Build-Fixture) -eq 0) 'Valid version did not build.'
    Assert ([Diagnostics.FileVersionInfo]::GetVersionInfo($launcher).FileVersion -eq '2.3.4.0') 'File version did not come from VERSION.'
    Assert ([Reflection.AssemblyName]::GetAssemblyName($launcher).Version.ToString() -eq '2.3.4.0') 'Assembly version did not come from VERSION.'
    Assert ((Build-Fixture) -eq 0) 'Replacing a previous launcher failed.'
    $hash=(Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash
    foreach($failure in @('readme','changelog','invalidVersion','compiler')) {
        Reset-VersionFiles
        switch($failure) {
            'readme' { [IO.File]::WriteAllText($readme,'当前开发版 **v6 / 2.3.3**') }
            'changelog' { [IO.File]::WriteAllText($changelog,"## 2.3.3`n## 2.3.4") }
            'invalidVersion' { [IO.File]::WriteAllText($version,'2.3.4.5') }
            'compiler' { [IO.File]::AppendAllText($source,"`nInvalid C sharp fixture") }
        }
        Assert ((Build-Fixture) -ne 0) ('Invalid build accepted: '+$failure)
        Assert ((Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash -eq $hash) ('Failed build replaced working launcher: '+$failure)
        Assert (@(Get-ChildItem -LiteralPath (Join-Path $run 'work\build') -File).Count -eq 0) ('Generated files leaked: '+$failure)
    }
    @{ok=$true;checks=$script:checks;launches=0}|ConvertTo-Json -Compress
} finally {
    $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $run).Path)
    $allowed=[IO.Path]::GetFullPath((Join-Path $Root 'work\tests')).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^version-build-[0-9a-f]{32}$') {throw 'Unexpected build test cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
