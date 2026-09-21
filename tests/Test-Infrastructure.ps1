param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
foreach ($name in @('Persistence.ps1','PendingSends.ps1','WorkerLifecycle.ps1','CodexAdapter.ps1','Version.ps1','Settings.ps1','PreferenceActions.ps1')) { . (Join-Path $Root ('src\'+$name)) }
$run=Join-Path $Root ('work\tests\infrastructure-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($run)
$script:runtime=Join-Path $run 'runtime';[void][IO.Directory]::CreateDirectory($runtime)
$script:stateDir=$run;$script:checks=0
function Assert([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message };$script:checks++ }
function Fake-Process {
    $p=[pscustomobject]@{HasExited=$false;KillWorks=$true;ThrowKill=$false;Kills=0;Disposed=$false;Id=9999;StartTime=[DateTime]::Now}
    $p|Add-Member ScriptMethod Kill { $this.Kills++;if($this.ThrowKill){throw 'Simulated access failure'};if($this.KillWorks){$this.HasExited=$true} }
    $p|Add-Member ScriptMethod WaitForExit { param($timeout) return $this.HasExited }
    $p|Add-Member ScriptMethod Dispose { $this.Disposed=$true }
    return $p
}
try {
    $path=Join-Path $run 'settings.json'
    Write-AtomicJson $path @{version=6;text='中文设置'}
    Write-AtomicJson $path @{version=6;text='更新设置'}
    Assert ((Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json).text -ceq '更新设置') 'Atomic create/update lost UTF-8 text.'
    Assert (@(Get-ChildItem -LiteralPath $run -Filter '*.tmp').Count -eq 0) 'Successful write leaked a temporary file.'
    $lock=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $rejected=$false
        try { Write-AtomicJson $path @{text='must not replace'} } catch { $rejected=$true }
        Assert $rejected 'Locked replacement should fail.'
        Assert ((Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json).text -ceq '更新设置') 'Failed replacement damaged old settings.'
        Assert (@(Get-ChildItem -LiteralPath $run -Filter '*.tmp').Count -eq 0) 'Failed replacement leaked a temporary file.'
    } finally { $lock.Dispose() }

    $script:settingsPath=$path;$script:voiceCatalog=@([pscustomobject]@{id='fixture-voice'})
    $script:voiceId='fixture-voice';$script:speechRate=0;$script:waveStyle='rays';$script:waveSize=260
    $script:pinned=$false;$script:floatingVisible=$false;$script:captionsVisible=$false
    $script:autoRead=$true;$script:autoSend=$false;$script:preferenceSyncs=0
    $script:window=[pscustomobject]@{Visible=$false;Left=20.0;Top=20.0}
    $script:window | Add-Member ScriptMethod Show {$this.Visible=$true}
    $script:window | Add-Member ScriptMethod Hide {$this.Visible=$false}
    function Sync-DesktopPreferences {$script:preferenceSyncs++}
    Save-Settings
    $oldSettings=[IO.File]::ReadAllText($path)
    $lock=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $failed=$false
        try { Set-AssistantPreferences @{floatingVisible=$true;captionsVisible=$true;pinned=$true} } catch {$failed=$true}
        Assert ($failed -and -not $script:floatingVisible -and -not $script:captionsVisible -and -not $script:pinned -and -not $window.Visible) 'A compound preference failure was only partly rolled back.'
        Assert ([IO.File]::ReadAllText($path) -ceq $oldSettings) 'A failed compound preference changed the saved settings.'
        Assert (@(Get-ChildItem -LiteralPath $run -Filter '*.tmp').Count -eq 0) 'Preference failure left temporary files.'
    } finally {$lock.Dispose()}
    $before=$script:preferenceSyncs
    Set-AssistantPreferences @{floatingVisible=$true;captionsVisible=$true}
    $savedSettings=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
    Assert ($savedSettings.floatingVisible -and $savedSettings.captionsVisible -and $window.Visible -and $script:preferenceSyncs -eq $before+1) 'Compound preference did not apply as one transaction.'
    foreach($invalid in @(@{pinned='false'},@{speechRate=17},@{voiceId='missing'},@{waveStyle='missing'},@{waveSize=100},@{threadId='unapproved';pinned=$true})) {
        $snapshot=[IO.File]::ReadAllText($path);$failed=$false
        try {Set-AssistantPreferences $invalid}catch{$failed=$true}
        Assert ($failed -and -not $script:pinned -and [IO.File]::ReadAllText($path) -ceq $snapshot) 'Invalid preference reached memory or disk.'
    }

    function Set-NoWakeMode([string]$Mode) { if($Mode -eq 'context'){$script:noWakeMode='off'}else{$script:noWakeMode=$Mode} }
    $script:noWakeMode='observe';$script:noWakePhase='stopping'
    $snapshot=[IO.File]::ReadAllText($path);$failed=$false
    try { Set-AssistantPreferences @{noWakeMode='context'} } catch { $failed=$true }
    Assert ($failed -and $script:noWakeMode -eq 'observe' -and [IO.File]::ReadAllText($path) -ceq $snapshot) 'A fail-closed no-wake switch was reported or saved as successful.'

    $target='11111111-1111-4111-8111-111111111111';$requestId=[Guid]::NewGuid().ToString()
    foreach($entry in @(@('list','list'),@('find','voice-find'),@('read','bind'),@('read','voice-bind'),@('read','voice-create-bind'),@('open','open'),@('send','send'),@('create','voice-create'),@('create-status','voice-create-status'),@('manage','voice-manage'))) {
        Assert-CodexBridgeRequest @{action=$entry[0];threadId=$target;requestId=$requestId;text='fixture'} $entry[1]
        $script:checks++
    }
    foreach($kind in @('purpose','action','case','target','newline','request','empty','wrongType')) {
        $request=@{action='send';threadId=$target;requestId=$requestId;text='fixture'};$purpose='send'
        switch($kind) {
            'purpose' {$purpose='open'}
            'action' {$request.action='unknown'}
            'case' {$request.action='SEND'}
            'target' {$request.threadId='unknown'}
            'newline' {$request.threadId=$target+"`n"}
            'request' {$request.requestId=$null}
            'empty' {$request.text=' '}
            'wrongType' {$request.text=@('fixture')}
        }
        $failed=$false;try {Assert-CodexBridgeRequest $request $purpose}catch{$failed=$true}
        Assert $failed ('Invalid adapter request was accepted: '+$kind)
    }

    $owned=Join-Path $runtime 'owned.txt';$outside=Join-Path $run 'outside.txt'
    [IO.File]::WriteAllText($owned,'owned');[IO.File]::WriteAllText($outside,'outside')
    Remove-OwnedFiles @((Join-Path $runtime '..\outside.txt'),$outside,$runtime)
    Assert ((Test-Path -LiteralPath $outside) -and (Test-Path -LiteralPath $runtime -PathType Container)) 'Cleanup escaped runtime or removed a directory.'
    Remove-OwnedFiles @($owned)
    Assert (-not (Test-Path -LiteralPath $owned)) 'Owned completed file was not removed.'

    $cleanupRoot=Join-Path $run 'cleanup-state';[void][IO.Directory]::CreateDirectory($cleanupRoot)
    $oldRun=Join-Path $cleanupRoot ('run-'+[Guid]::NewGuid().ToString('N'))
    $currentRun=Join-Path $cleanupRoot ('run-'+[Guid]::NewGuid().ToString('N'))
    $invalidRun=Join-Path $cleanupRoot 'run-user-files'
    foreach($directory in @($oldRun,$currentRun,$invalidRun)){[void][IO.Directory]::CreateDirectory($directory);[IO.File]::WriteAllText((Join-Path $directory 'receipt.json'),'preserve')}
    $oldNoWake=Join-Path $oldRun (([Guid]::NewGuid().ToString('N'))+'.nowake.wav')
    $oldNoWakeTemp=Join-Path $oldRun (([Guid]::NewGuid().ToString('N'))+'.nowake.asr.json.tmp')
    $ordinaryTemp=Join-Path $oldRun 'receipt.json.tmp'
    $currentNoWake=Join-Path $currentRun (([Guid]::NewGuid().ToString('N'))+'.nowake.asr.json')
    foreach($privateFile in @($oldNoWake,$oldNoWakeTemp,$currentNoWake)){[IO.File]::WriteAllText($privateFile,'private fixture')}
    [IO.File]::WriteAllText($ordinaryTemp,'preserve')
    Remove-StaleNoWakeFiles $cleanupRoot $currentRun
    Assert ((Test-Path -LiteralPath $oldRun) -and -not (Test-Path -LiteralPath $oldNoWake) -and -not (Test-Path -LiteralPath $oldNoWakeTemp) -and (Test-Path -LiteralPath (Join-Path $oldRun 'receipt.json')) -and (Test-Path -LiteralPath $ordinaryTemp)) 'Stale cleanup removed a receipt/run/ordinary temp or retained an owned no-wake file.'
    Assert ((Test-Path -LiteralPath $currentNoWake) -and (Test-Path -LiteralPath $invalidRun)) 'Stale cleanup touched the current or an unowned directory.'
    Assert (-not (Remove-NoWakeFilesFromRun $run $currentRun)) 'No-wake cleanup accepted a directory through the wrong state root.'
    Assert ((Remove-NoWakeFilesFromRun $cleanupRoot $currentRun) -and -not (Test-Path -LiteralPath $currentNoWake) -and (Test-Path -LiteralPath (Join-Path $currentRun 'receipt.json'))) 'Current no-wake cleanup removed a receipt or retained its owned file.'

    foreach ($kind in @('completed','cancelled','running','timeout','killFailure','send','voice-create','voice-manage')) {
        $file=Join-Path $runtime ($kind+'.input');[IO.File]::WriteAllText($file,'fixture')
        $audio=Join-Path $runtime ($kind+'.audio');[IO.File]::WriteAllText($audio,'fixture')
        $process=Fake-Process
        if($kind -eq 'completed'){$process.HasExited=$true}
        if($kind -eq 'timeout'){$process.KillWorks=$false}
        if($kind -eq 'killFailure'){$process.ThrowKill=$true}
        $purpose=if($kind -in @('send','voice-create','voice-manage')){$kind}else{'read'}
        $job=@{Process=$process;Purpose=$purpose;Files=@($file);Audio=$audio}
        Close-Job $job -Kill:($kind -ne 'running')
        $expectedRemoved=$kind -in @('completed','cancelled')
        Assert ((-not (Test-Path -LiteralPath $file)) -eq $expectedRemoved) ('Wrong cleanup state: '+$kind)
        Assert ($process.Disposed -eq $expectedRemoved) ('Process disposed before exit: '+$kind)
        Assert ((-not (Test-Path -LiteralPath $audio)) -eq $expectedRemoved) ('Audio removed before worker exit: '+$kind)
        if($kind -in @('running','send','voice-create','voice-manage')) { Assert ($process.Kills -eq 0) ('Active mutation was terminated: '+$kind) }
    }

    $versionRoot=Join-Path $run 'versions';[void][IO.Directory]::CreateDirectory($versionRoot)
    foreach($value in @('0.6.14','1.2.3','01.2.3','1.2','1.2.3.4','1.2.65535','1.2.999999999999','1.2.3"')) {
        [IO.File]::WriteAllText((Join-Path $versionRoot 'VERSION'),$value)
        $valid=$true;try {$result=Get-AssistantVersion $versionRoot}catch{$valid=$false}
        Assert ($valid -eq ($value -in @('0.6.14','1.2.3'))) ('Unexpected version acceptance: '+$value)
    }

    # Exercise the actual bridge dispatcher and durable ledger; only process
    # launch is replaced. No Codex pipe, microphone or speaker is touched.
    $script:pendingPath=Join-Path $run 'pending-sends.json'
    $script:threadId='11111111-1111-4111-8111-111111111111'
    $script:python='unused-interpreter'
    function Start-Worker {
        param($Interpreter,$Script,$Arguments)
        $script:starts++
        Assert (Test-Path -LiteralPath $script:pendingPath) 'Worker started without a durable send envelope.'
        $saved=Get-Content -LiteralPath $script:pendingPath -Raw -Encoding UTF8|ConvertFrom-Json
        Assert (@($saved.sends|Where-Object {$_.requestId -eq $request.requestId}).Count -eq 1) 'Durable envelope does not belong to this request.'
        if($script:launchFails){throw 'Simulated launch failure'}
        return $script:fakeWorker
    }
    function Save-PendingSends {
        $script:writes++
        if($script:failWrite -eq $script:writes){throw 'Simulated ledger failure'}
        Write-AtomicJson $script:pendingPath @{version=1;sends=@($script:pendingSends.Values)}
    }
    foreach($kind in @('normal','alreadyPending','prepareFailure','launchFailure','pidSaveFailure')) {
        $script:bridgeJob=$null;$script:pendingSends=@{};$script:pendingUncertain='';$script:workerWarning=''
        $script:starts=0;$script:writes=0;$script:failWrite=0;$script:launchFails=($kind -eq 'launchFailure');$script:fakeWorker=Fake-Process
        if($kind -eq 'prepareFailure'){$script:failWrite=1}
        if($kind -eq 'pidSaveFailure'){$script:failWrite=2}
        if($kind -eq 'alreadyPending'){$script:pendingSends[$script:threadId]=@{requestId='existing'}}
        $count=@(Get-ChildItem -LiteralPath $runtime -File).Count
        $request=@{action='send';threadId=$script:threadId;requestId=[Guid]::NewGuid().ToString();text='Synthetic test words'}
        $threw=$false;$started=$false
        try{$started=Start-Bridge $request 'send'}catch{$threw=$true}
        if($kind -in @('normal','pidSaveFailure')) {
            Assert ($started -and -not $threw -and $script:starts -eq 1 -and $script:bridgeJob) ('Dispatched request was lost: '+$kind)
            Assert ($script:pendingSends.ContainsKey($script:threadId) -and $script:pendingUncertain) ('Dispatched request was unlocked: '+$kind)
            if($kind -eq 'pidSaveFailure') {
                Assert ($script:workerWarning -and -not $script:pendingSends[$script:threadId].processId) 'PID-save failure did not preserve the original locked envelope.'
            }
            $script:fakeWorker.HasExited=$true;Close-Job $script:bridgeJob
        } else {
            Assert (-not $started -and -not $script:bridgeJob) ('Unstarted request acquired a job: '+$kind)
            Assert (@(Get-ChildItem -LiteralPath $runtime -File).Count -eq $count) ('Prelaunch failure leaked request files: '+$kind)
            if($kind -eq 'alreadyPending') { Assert ($script:starts -eq 0 -and -not $threw) 'Existing receipt caused a second launch.' }
            else { Assert ($threw -and -not $script:pendingSends.ContainsKey($script:threadId)) ('Known unstarted failure kept a new envelope: '+$kind) }
        }
    }
    @{ok=$true;checks=$script:checks;devices=0;codexRequests=0}|ConvertTo-Json -Compress
} finally {
    $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $run).Path)
    $allowed=[IO.Path]::GetFullPath((Join-Path $Root 'work\tests')).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^infrastructure-[0-9a-f]{32}$') { throw 'Unexpected test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
