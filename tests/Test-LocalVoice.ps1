param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $Root 'src\LocalVoice.ps1')
$resultRoot=Join-Path $Root 'work\tests\local-voice'
$runRoot=Join-Path $resultRoot ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
$script:checks=0;$script:fixtureNumber=0;$script:results=New-Object Collections.ArrayList
function Assert-That([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Assert-Throws([scriptblock]$Body,[string]$Message){$threw=$false;try{& $Body}catch{$threw=$true};Assert-That $threw $Message}
function New-FakeProcess {
    $process=[pscustomobject]@{HasExited=$false;KillCalls=0;WaitCalls=0;DisposeCalls=0;WaitSucceeds=$true;Id=900000+$script:fixtureNumber}
    $process | Add-Member ScriptMethod Kill {$this.KillCalls++}
    $process | Add-Member ScriptMethod WaitForExit {param($Timeout);$this.WaitCalls++;$script:lastWaitTimeout=$Timeout;if($this.WaitSucceeds){$this.HasExited=$true};return $this.WaitSucceeds}
    $process | Add-Member ScriptMethod Dispose {$this.DisposeCalls++}
    return $process
}
function Start-Worker([string]$Interpreter,[string]$Script,[string[]]$Arguments){
    [void]$script:starts.Add(@{Interpreter=$Interpreter;Script=$Script;Arguments=$Arguments})
    if($script:throwOnStart){throw 'simulated process startup failure'}
    $process=New-FakeProcess;$script:lastProcess=$process;return $process
}
function Write-FakeConfig {
    $json=$script:config | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText((Join-Path $workspace 'runtime\voice-design\config.json'),$json,(New-Object Text.UTF8Encoding($false)))
}
function Reset-Fixture {
    $script:fixtureNumber++
    $script:workspace=Join-Path $runRoot ('workspace-'+$script:fixtureNumber)
    $script:runtime=Join-Path $workspace 'data\run-test'
    foreach($directory in @('runtime\voice-design\venv\Scripts','runtime\voice-design\models\Qwen3-TTS-12Hz-1.7B-VoiceDesign','assets\local-voices','src','data\run-test')){[void][IO.Directory]::CreateDirectory((Join-Path $workspace $directory))}
    foreach($file in @('runtime\voice-design\venv\Scripts\python.exe','assets\local-voices\profiles.json','src\local_tts_server.py')){[IO.File]::WriteAllText((Join-Path $workspace $file),'fixture only')}
    [IO.File]::WriteAllText((Join-Path $workspace 'assets\local-voices\profiles.json'),(@{profiles=@(@{id='local-tw-natural';instruct='自然亲切的台湾女声，语气平稳。';seed=37})} | ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
    $script:config=@{python='runtime/voice-design/venv/Scripts/python.exe';model='runtime/voice-design/models/Qwen3-TTS-12Hz-1.7B-VoiceDesign';profiles='assets/local-voices/profiles.json'}
    Write-FakeConfig
    $script:voiceCatalog=@([pscustomobject]@{id='local-tw-natural';name='台湾女声';provider='qwen-local'},[pscustomobject]@{id='zh-TW-HsiaoChenNeural';name='在线台湾女声';provider='edge'})
    $script:voiceId='zh-TW-HsiaoChenNeural';$script:localVoiceService=$null;$script:starts=New-Object Collections.ArrayList;$script:throwOnStart=$false;$script:lastWaitTimeout=0;$script:lastProcess=$null
}
function Assert-PreferencesUntouched{Assert-That ($script:voiceId -ceq 'zh-TW-HsiaoChenNeural') 'Service lifecycle changed the selected voice.'}
function Test-Case([string]$Name,[scriptblock]$Body){Reset-Fixture;try{& $Body;Assert-PreferencesUntouched;[void]$script:results.Add(@{name=$Name;passed=$true})}catch{[void]$script:results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message})}}

Test-Case 'profile lookup is exact unique and provider-specific' {
    Assert-That ([object]::ReferenceEquals((Get-AssistantVoiceProfile 'local-tw-natural'),$script:voiceCatalog[0])) 'Exact local profile was not returned.'
    Assert-That ((Test-LocalVoiceProfile 'local-tw-natural') -and -not (Test-LocalVoiceProfile 'zh-TW-HsiaoChenNeural')) 'Provider detection is wrong.'
    Assert-That ($null -eq (Get-AssistantVoiceProfile 'LOCAL-TW-NATURAL') -and -not (Test-LocalVoiceProfile '../unknown')) 'Unknown or differently cased ID was accepted.'
    $script:voiceCatalog=@($script:voiceCatalog[0],$script:voiceCatalog[0])
    Assert-That ($null -eq (Get-AssistantVoiceProfile 'local-tw-natural')) 'Duplicate profile IDs were accepted.'
    $script:voiceCatalog=,@([pscustomobject]@{id='local-tw-natural';provider='qwen-local'},[pscustomobject]@{id='other';provider='edge'})
    Assert-That (-not (Test-LocalVoiceProfile 'local-tw-natural')) 'A nested profile array was mistaken for one exact voice.'
}
Test-Case 'acknowledgements prefer mp3 then wav and reject traversal' {
    $wav=Join-Path $workspace 'assets\ack-local-tw-natural.wav';[IO.File]::WriteAllText($wav,'test wav')
    Assert-That ((Get-VoiceAcknowledgementPath 'local-tw-natural') -eq $wav) 'Local WAV acknowledgement was not found.'
    $mp3=Join-Path $workspace 'assets\ack-local-tw-natural.mp3';[IO.File]::WriteAllText($mp3,'test mp3')
    Assert-That ((Get-VoiceAcknowledgementPath 'local-tw-natural') -eq $mp3) 'Existing MP3 acknowledgement did not retain priority.'
    Assert-That ($null -eq (Get-VoiceAcknowledgementPath 'unknown') -and $null -eq (Get-VoiceAcknowledgementPath '..\outside') -and $null -eq (Get-VoiceAcknowledgementPath 'C:\outside')) 'Missing or unsafe acknowledgement ID was accepted.'
    Assert-That ($script:starts.Count -eq 0) 'Looking up an acknowledgement started the GPU service.'
}
Test-Case 'async startup passes validated paths and only removes stale readiness' {
    $state=Join-Path $runtime 'local-voice';[void][IO.Directory]::CreateDirectory($state)
    [IO.File]::WriteAllText((Join-Path $state 'ready.json'),'stale')
    [IO.File]::WriteAllText((Join-Path $state 'pending-request.json'),'preserve')
    $actual=Ensure-LocalVoiceServer
    Assert-That ($actual -eq $state -and $script:starts.Count -eq 1) 'Service did not start once in the current run directory.'
    $call=$script:starts[0]
    Assert-That ($call.Interpreter -eq (Join-Path $workspace 'runtime\voice-design\venv\Scripts\python.exe') -and $call.Script -eq (Join-Path $workspace 'src\local_tts_server.py')) 'Validated interpreter or server script was not used.'
    $args=$call.Arguments
    Assert-That ($args.Count -eq 10 -and $args[0] -eq '--workspace' -and $args[1] -eq $workspace -and $args[2] -eq '--state-dir' -and $args[3] -eq $state -and $args[4] -eq '--parent-pid' -and $args[5] -eq [string]$PID -and $args[6] -eq '--model-path' -and $args[7] -eq (Join-Path $workspace 'runtime\voice-design\models\Qwen3-TTS-12Hz-1.7B-VoiceDesign') -and $args[8] -eq '--profiles-path' -and $args[9] -eq (Join-Path $workspace 'assets\local-voices\profiles.json')) 'Service command-line protocol changed.'
    Assert-That (-not (Test-Path -LiteralPath (Join-Path $state 'ready.json')) -and [IO.File]::ReadAllText((Join-Path $state 'pending-request.json')) -eq 'preserve') 'Restart did not clear only stale readiness.'
    Assert-That ($script:localVoiceService.OwnerPid -eq $PID -and [object]::ReferenceEquals($script:localVoiceService.Process,$script:lastProcess) -and $script:lastProcess.WaitCalls -eq 0) 'Startup waited for model loading or failed to retain ownership.'
    $profiles=Get-Content -LiteralPath $args[9] -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-That ($profiles.profiles[0].id -eq 'local-tw-natural' -and $profiles.profiles[0].instruct -and $profiles.profiles[0].seed -eq 37 -and @($profiles.profiles[0].PSObject.Properties).Count -eq 3) 'VoiceDesign fixture must use id/instruct/seed without reference audio or training.'
    $helperText=(Get-Content -LiteralPath (Join-Path $Root 'src\WorkerLifecycle.ps1') -Raw -Encoding UTF8)
    Assert-That ($helperText -match '\$info\.CreateNoWindow\s*=\s*\$true') 'Production Start-Worker no longer hides worker consoles.'
}
Test-Case 'live service is reused and dead service restarts without stale readiness' {
    $state=Ensure-LocalVoiceServer;$first=$script:lastProcess
    [IO.File]::WriteAllText((Join-Path $state 'ready.json'),'current')
    [IO.File]::WriteAllText((Join-Path $workspace 'runtime\voice-design\config.json'),'temporarily invalid')
    Assert-That ((Ensure-LocalVoiceServer) -eq $state -and $script:starts.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $state 'ready.json'))) 'Running service was restarted or its readiness removed.'
    $first.HasExited=$true;Write-FakeConfig
    Assert-That ((Ensure-LocalVoiceServer) -eq $state -and $script:starts.Count -eq 2 -and $first.DisposeCalls -eq 1 -and $first.KillCalls -eq 0) 'Exited service was not cleanly replaced.'
    Assert-That (-not (Test-Path -LiteralPath (Join-Path $state 'ready.json')) -and -not [object]::ReferenceEquals($first,$script:localVoiceService.Process)) 'New worker inherited old readiness or the dead process record.'
}
Test-Case 'missing malformed and escaping config paths cannot launch a service' {
    foreach($entry in @(@{field='python';value='C:\Windows\python.exe'},@{field='python';value='runtime\voice-design\missing.exe'},@{field='model';value='..\outside-model'},@{field='profiles';value='assets\local-voices\..\..\..\outside.json'},@{field='profiles';value='assets\local-voices\profiles.json:stream'},@{field='model';value=@('runtime/models')},@{field='python';value=''})){
        Reset-Fixture;$script:config[$entry.field]=$entry.value;Write-FakeConfig
        Assert-Throws {Ensure-LocalVoiceServer} ('Invalid '+$entry.field+' was accepted.')
        Assert-That ($script:starts.Count -eq 0 -and $null -eq $script:localVoiceService) 'Invalid config started a worker.'
    }
    Reset-Fixture;[IO.File]::WriteAllText((Join-Path $workspace 'runtime\voice-design\config.json'),'{')
    Assert-Throws {Ensure-LocalVoiceServer} 'Malformed JSON started a worker.'
    Reset-Fixture;$script:runtime=Join-Path $runRoot 'outside-workspace'
    Assert-Throws {Ensure-LocalVoiceServer} 'A state directory outside the workspace was accepted.'
}
Test-Case 'directory junctions cannot escape the configured model root' {
    $outside=Join-Path $runRoot 'junction-target';[void][IO.Directory]::CreateDirectory($outside)
    $junction=Join-Path $workspace 'runtime\voice-design\models\linked'
    [void](New-Item -ItemType Junction -Path $junction -Value $outside)
    $script:config.model='runtime\voice-design\models\linked';Write-FakeConfig
    Assert-Throws {Ensure-LocalVoiceServer} 'A model path through a Windows junction was accepted.'
    Assert-That ($script:starts.Count -eq 0 -and (Test-Path -LiteralPath $outside -PathType Container)) 'Junction rejection started a worker or changed its target.'
}
Test-Case 'close kills and disposes only the owned process and is idempotent' {
    [void](Ensure-LocalVoiceServer);$owned=$script:lastProcess;$unrelated=New-FakeProcess
    Close-LocalVoiceServer;Close-LocalVoiceServer
    Assert-That ($owned.KillCalls -eq 1 -and $owned.WaitCalls -eq 1 -and $owned.DisposeCalls -eq 1 -and $script:lastWaitTimeout -eq 1500 -and $null -eq $script:localVoiceService) 'Owned service did not close idempotently.'
    Assert-That ($unrelated.KillCalls -eq 0 -and $unrelated.DisposeCalls -eq 0) 'An unrelated process was touched.'
    $script:localVoiceService=@{Process=$unrelated;StateDir='foreign';OwnerPid=($PID+1)}
    Close-LocalVoiceServer
    Assert-That ($unrelated.KillCalls -eq 0 -and $unrelated.DisposeCalls -eq 0) 'A foreign service record was killed.'
    Assert-Throws {Ensure-LocalVoiceServer} 'A foreign process record was silently reused.'
}
Test-Case 'startup failure and delayed exit retain safe retry behavior' {
    $script:throwOnStart=$true
    Assert-Throws {Ensure-LocalVoiceServer} 'Process startup failure was hidden.'
    Assert-That ($null -eq $script:localVoiceService) 'Failed startup retained a false running service.'
    $script:throwOnStart=$false;[void](Ensure-LocalVoiceServer);$owned=$script:lastProcess;$owned.WaitSucceeds=$false
    Assert-Throws {Close-LocalVoiceServer} 'Exit timeout was incorrectly reported as cleanup success.'
    Assert-That ([object]::ReferenceEquals($script:localVoiceService.Process,$owned) -and $owned.DisposeCalls -eq 0) 'Failed exit lost the only owned process handle.'
    $owned.WaitSucceeds=$true;Close-LocalVoiceServer
    Assert-That ($null -eq $script:localVoiceService -and $owned.DisposeCalls -eq 1) 'Owned process could not be cleaned on retry.'
}
Test-Case 'missing optional config retains Microsoft voices without starting a model' {
    $microsoft=$script:voiceCatalog[1]
    Remove-Item -LiteralPath (Join-Path $workspace 'runtime\voice-design\config.json') -Force
    $available=@(Get-AvailableVoiceProfiles -Catalog $script:voiceCatalog)
    Assert-That ($available.Count -eq 1 -and [object]::ReferenceEquals($available[0],$microsoft)) 'Missing optional config changed or removed the Microsoft profile.'
    Assert-That ($script:starts.Count -eq 0 -and $null -eq $script:localVoiceService) 'Voice filtering started the optional model service.'
}
Test-Case 'invalid optional config or missing runtime files never break Microsoft listing' {
    foreach($invalid in @('json','escape','missing-model','missing-server')){
        Reset-Fixture;$microsoft=$script:voiceCatalog[1]
        switch($invalid){
            'json'{[IO.File]::WriteAllText((Join-Path $workspace 'runtime\voice-design\config.json'),'{')}
            'escape'{$script:config.model='..\outside';Write-FakeConfig}
            'missing-model'{$script:config.model='runtime\voice-design\models\not-installed';Write-FakeConfig}
            'missing-server'{Remove-Item -LiteralPath (Join-Path $workspace 'src\local_tts_server.py') -Force}
        }
        $available=@(Get-AvailableVoiceProfiles -Catalog $script:voiceCatalog)
        Assert-That ($available.Count -eq 1 -and [object]::ReferenceEquals($available[0],$microsoft) -and $script:starts.Count -eq 0) 'Broken optional installation escaped the filter or changed Microsoft availability.'
    }
}
Test-Case 'complete local package is checked once and each voice still needs its cached acknowledgement' {
    $microsoft=$script:voiceCatalog[1]
    $sweet=[pscustomobject]@{id='local-tw-sweet';provider='qwen-local';name='轻甜'}
    $natural=$script:voiceCatalog[0]
    $script:voiceCatalog=@($microsoft,$sweet,$natural)
    [IO.File]::WriteAllText((Join-Path $workspace 'assets\ack-local-tw-sweet.wav'),'fixture wav')
    $originalInstallation=${function:Get-LocalVoiceInstallation}
    $script:installationChecks=0
    function Get-LocalVoiceInstallation {$script:installationChecks++; & $originalInstallation}
    try{
        $available=@(Get-AvailableVoiceProfiles -Catalog $script:voiceCatalog)
        Assert-That ($available.Count -eq 2 -and [object]::ReferenceEquals($available[0],$microsoft) -and [object]::ReferenceEquals($available[1],$sweet)) 'A local voice without a cached acknowledgement remained selectable.'
        Assert-That ($script:installationChecks -eq 1) 'Common local config was checked separately for every voice.'
        [IO.File]::WriteAllText((Join-Path $workspace 'assets\ack-local-tw-natural.mp3'),'fixture mp3')
        $script:installationChecks=0
        $available=@(Get-AvailableVoiceProfiles -Catalog $script:voiceCatalog)
        Assert-That ($available.Count -eq 3 -and [object]::ReferenceEquals($available[2],$natural) -and $script:installationChecks -eq 1) 'Complete local profiles were not returned unchanged after one config check.'
        $script:installationChecks=0
        $onlineOnly=@(Get-AvailableVoiceProfiles -Catalog @($microsoft))
        Assert-That ($onlineOnly.Count -eq 1 -and $script:installationChecks -eq 0) 'An all-online catalog needlessly read optional local model config.'
        Assert-That ($script:starts.Count -eq 0 -and $null -eq $script:localVoiceService) 'Availability filtering allocated a local service.'
    }finally{Set-Item -Path Function:\Get-LocalVoiceInstallation -Value $originalInstallation}
}
$failed=@($script:results | Where-Object {-not $_.passed})
@{ok=($failed.Count -eq 0);checks=$script:checks;cases=@($script:results);fixtures=$runRoot;realServerStarts=0;gpuLoads=0;microphones=0;codexRequests=0} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $resultRoot 'result.json') -Encoding UTF8
Write-Output ($script:results.Count.ToString()+' local-voice scenarios, '+$script:checks+' checks, '+$failed.Count+' failed; no GPU, server, microphone or Codex requests.')
foreach($failure in $failed){Write-Output ($failure.name+': '+$failure.error)}
if($failed.Count){exit 1}
