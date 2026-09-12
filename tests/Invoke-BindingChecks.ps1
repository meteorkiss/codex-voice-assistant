param([string]$Root=(Split-Path -Parent $PSScriptRoot))

# Fixed offline suite. Tests run against a disposable source copy, never daily
# settings or a historical test status directory. Generated files are removed
# on success and failure; keep reusable test code and the console summary.
$ErrorActionPreference='Stop'
$rootPath=[IO.Path]::GetFullPath($Root)
$parent=Join-Path $rootPath 'work\tests'
[void][IO.Directory]::CreateDirectory($parent)
$runPath=Join-Path $parent ('binding-suite-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runPath)
$failed=New-Object 'Collections.Generic.List[string]'
$scripts=@('Test-TaskSwitch.ps1','Test-TaskSwitchIntegration.ps1','Test-TaskCreate.ps1',
    'Test-TaskCreateIntegration.ps1','Test-DesktopController.ps1','Test-LocalCommands.ps1',
    'Test-PlaybackCancellation.ps1','Test-HandsFree.ps1','Test-DesktopActions.ps1','Test-VoicePlaybackResume.ps1','Test-StartupSettings.ps1','test_pending_ui.ps1',
    'Test-Infrastructure.ps1','Test-WakePhraseSettings.ps1','Test-VersionBuild.ps1','Test-AudioOutput.ps1','Test-ShortFollowUpCapture.ps1','Test-TranscriptRecovery.ps1',
    'Test-DraftRecovery.ps1','Test-BindingRecovery.ps1','Test-WakeRecovery.ps1')
try {
    foreach ($folder in @('src','tests')) {
        $destination=Join-Path $runPath $folder
        [void][IO.Directory]::CreateDirectory($destination)
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $rootPath $folder) -File) {
            if ($file.Extension -in @('.ps1','.py','.cs','.xaml','.md')) { Copy-Item -LiteralPath $file.FullName -Destination $destination }
        }
    }
    Copy-Item -LiteralPath (Join-Path $rootPath 'VERSION') -Destination $runPath
    $toolDir=Join-Path $runPath 'tools';[void][IO.Directory]::CreateDirectory($toolDir)
    Copy-Item -LiteralPath (Join-Path $rootPath 'tools\Build-Launcher.ps1') -Destination $toolDir
    $assets=Join-Path $runPath 'assets';[void][IO.Directory]::CreateDirectory($assets)
    Copy-Item -LiteralPath (Join-Path $rootPath 'assets\voices.json') -Destination $assets
    Copy-Item -LiteralPath (Join-Path $rootPath 'assets\shengban.ico') -Destination $assets
    foreach ($clip in Get-ChildItem -LiteralPath (Join-Path $rootPath 'assets') -Filter 'ack-*.mp3' -File) {
        Copy-Item -LiteralPath $clip.FullName -Destination $assets
    }
    $powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    foreach ($name in $scripts) {
        Write-Output ('RUN '+$name)
        $priorPreference=$ErrorActionPreference
        try {
            $ErrorActionPreference='Continue'
            $output=@(& $powershell -NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File (Join-Path $runPath ('tests\'+$name)) 2>&1)
            $exitCode=$LASTEXITCODE
        } finally { $ErrorActionPreference=$priorPreference }
        if ($exitCode -ne 0) { $failed.Add($name); $output | Write-Output }
        else {
            $summary=$output -join ' '
            if ($summary -match '"checks"\s*:\s*(\d+)') { Write-Output ('PASS '+$name+': '+$Matches[1]+' checks') }
            elseif ($summary -match '"passed"\s*:\s*(\d+)') { Write-Output ('PASS '+$name+': '+$Matches[1]+' scenarios') }
            else { Write-Output ('PASS '+$name) }
        }
    }
} finally {
    # Verify both the generated name and resolved absolute containment before
    # removing this run. No computed delete targets outside work/tests.
    $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $runPath).Path)
    $allowed=[IO.Path]::GetFullPath($parent).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^binding-suite-[0-9a-f]{32}$') { throw 'Refusing cleanup outside the generated run directory.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
    Write-Output 'CLEANED disposable binding test files.'
}
if ($failed.Count) { throw ('Binding checks failed: '+($failed -join ', ')) }
Write-Output ('PASS '+$scripts.Count+' offline suites; temporary data removed; no device or Codex operations.')
