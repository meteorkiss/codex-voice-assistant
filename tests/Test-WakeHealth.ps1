$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$output=Join-Path $project 'work\tests\wake-health'
[void][IO.Directory]::CreateDirectory($output)
. (Join-Path $project 'src\AudioBootstrap.ps1')

# Reflection only supplies deterministic clock/pipe fixtures; production health
# and protocol methods are exercised without opening any microphone or speaker.
$testReflection=@'
using System;
using System.Diagnostics;
using System.Reflection;
public static class WakeHealthFixture {
    static BindingFlags flags=BindingFlags.NonPublic|BindingFlags.Instance;
    public static void Set(object target,string name,object value) {
        FieldInfo f=target.GetType().GetField(name,flags);
        if(value!=null && !f.FieldType.IsInstanceOfType(value)) value=Convert.ChangeType(value,f.FieldType);
        f.SetValue(target,value);
    }
    public static object Get(object target,string name) { return target.GetType().GetField(name,flags).GetValue(target); }
    public static void Age(object target,string name,int ms) { Set(target,name,Stopwatch.GetTimestamp()-(long)(ms*Stopwatch.Frequency/1000.0)); }
    public static void Line(object target,long run,string text) { target.GetType().GetMethod("HandleWorkerLine",flags).Invoke(target,new object[]{run,text}); }
    public static void Pcm(object target,long run,int byteCount) { target.GetType().GetMethod("AcceptEchoPcm",flags).Invoke(target,new object[]{new byte[byteCount],run,true}); }
}
'@
Add-Type -TypeDefinition $testReflection
$script:checks=New-Object 'Collections.Generic.List[string]'
$script:fakeListeners=New-Object 'Collections.Generic.List[object]'
function Assert-Health([bool]$Condition,[string]$Name) {
    if(-not $Condition) { throw $Name }
    $script:checks.Add($Name)
}
function New-HealthFixture {
    $item=New-Object WakeListener
    $script:fakeListeners.Add($item)
    foreach($name in @('listening','ready','echoMode')) { [WakeHealthFixture]::Set($item,$name,$true) }
    [WakeHealthFixture]::Set($item,'echoCapture',(New-Object EchoCapture))
    [WakeHealthFixture]::Set($item,'runVersion',7)
    foreach($name in @('runStartedTicks','lastCaptureTicks','lastProgressTicks')) { [WakeHealthFixture]::Age($item,$name,10) }
    foreach($name in @('capturedSamples','submittedSamples','processedSamples')) { [WakeHealthFixture]::Set($item,$name,16000) }
    $item
}
function Wait-Condition([scriptblock]$Condition,[int]$Milliseconds=8000) {
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while(-not (& $Condition)) {
        if($clock.ElapsedMilliseconds -gt $Milliseconds) { throw 'Timed out waiting for local file worker.' }
        Start-Sleep -Milliseconds 15
    }
}
function New-SilentWave([int]$Seconds) {
    $memory=New-Object IO.MemoryStream
    $writer=New-Object IO.BinaryWriter($memory)
    $data=New-Object byte[] (32000*$Seconds)
    $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $writer.Write([uint32](36+$data.Length))
    $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $writer.Write([uint32]16)
    $writer.Write([uint16]1); $writer.Write([uint16]1); $writer.Write([uint32]16000); $writer.Write([uint32]32000)
    $writer.Write([uint16]2); $writer.Write([uint16]16); $writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
    $writer.Write([uint32]$data.Length); $writer.Write($data); $writer.Flush()
    $result=$memory.ToArray(); $writer.Dispose(); $memory.Dispose(); return ,$result
}
$real=$null; $blocked=$null
try {
    $fresh=New-Object WakeListener
    Assert-Health ($fresh.GetHealthSnapshot().State -eq 'idle') 'Unused listener is idle'
    Assert-Health (-not $fresh.GetHealthSnapshot().NeedsRecovery) 'Idle is not failure'
    $fresh.Dispose()

    $good=New-HealthFixture
    Assert-Health ($good.GetHealthSnapshot().State -eq 'healthy') 'Fresh capture and completed model input are healthy'
    Assert-Health ($good.IsReady -and $good.FullDuplexReady) 'Healthy bound capture can be ready'
    [WakeHealthFixture]::Set($good,'echoCaptureId','fixture-capture-endpoint')
    Assert-Health ($good.CaptureEndpointId -eq 'fixture-capture-endpoint') 'Capture endpoint identity exposed'
    [WakeHealthFixture]::Set($good,'fixtureMode',$true)
    Assert-Health (-not $good.FullDuplexReady) 'File fixture cannot authorize duplex playback'
    [WakeHealthFixture]::Set($good,'submittedSamples',32000)
    [WakeHealthFixture]::Set($good,'capturedSamples',32000)
    [WakeHealthFixture]::Line($good,7,"PROGRESS`t24000")
    Assert-Health ($good.GetHealthSnapshot().ProcessedSamples -eq 24000) 'Valid monotonic progress counted'
    [WakeHealthFixture]::Line($good,6,"PROGRESS`t32000")
    Assert-Health ($good.GetHealthSnapshot().ProcessedSamples -eq 24000) 'Old run progress ignored'
    [WakeHealthFixture]::Line($good,6,"PROGRESS`tinvalid")
    Assert-Health ($good.GetHealthSnapshot().State -eq 'healthy') 'Old run invalid progress cannot poison new run'

    foreach($invalid in @('16000','0','-1','999999999999999999999','16001','not-a-number',' 16001','+16001','')) {
        $bad=New-HealthFixture
        [WakeHealthFixture]::Line($bad,7,("PROGRESS`t"+$invalid))
        $health=$bad.GetHealthSnapshot()
        Assert-Health ($health.State -eq 'error' -and $health.Reason -eq 'invalid-progress' -and $health.NeedsRecovery) ('Reject bad heartbeat: '+$invalid)
        Assert-Health ($health.ProcessedSamples -eq 16000 -and -not $bad.IsReady -and -not $bad.FullDuplexReady) 'Rejected heartbeat cannot refresh or grant playback readiness'
    }

    $starting=New-HealthFixture
    [WakeHealthFixture]::Set($starting,'lastCaptureTicks',0); [WakeHealthFixture]::Set($starting,'lastProgressTicks',0)
    Assert-Health ($starting.GetHealthSnapshot().State -eq 'starting' -and -not $starting.IsReady) 'First model READY alone remains starting'
    [WakeHealthFixture]::Age($starting,'runStartedTicks',10050)
    Assert-Health ($starting.GetHealthSnapshot().Reason -eq 'startup-timeout' -and $starting.GetHealthSnapshot().NeedsRecovery) 'Startup has bounded ten-second grace'
    Assert-Health ($starting.GetHealthSnapshot().CaptureAgeMs -eq -1) 'Missing first capture uses unavailable age'

    foreach($field in @('lastCaptureTicks','lastProgressTicks')) {
        $stale=New-HealthFixture; [WakeHealthFixture]::Age($stale,$field,3100)
        $expected=if($field -eq 'lastCaptureTicks'){'capture-stalled'}else{'progress-stalled'}
        Assert-Health ($stale.GetHealthSnapshot().Reason -eq $expected -and $stale.GetHealthSnapshot().NeedsRecovery) ($expected+' detected')
        Assert-Health (-not $stale.IsReady -and -not $stale.FullDuplexReady -and -not $stale.GetSnapshot().IsReady) 'All readiness paths withdraw stale permission'
    }
    $lag=New-HealthFixture
    [WakeHealthFixture]::Set($lag,'submittedSamples',65000); [WakeHealthFixture]::Set($lag,'capturedSamples',65000)
    Assert-Health ($lag.GetHealthSnapshot().Reason -eq 'progress-lag') 'Trickling progress cannot hide excessive input lag'
    $queued=New-HealthFixture
    for($index=0;$index -lt 75;$index++) { [WakeHealthFixture]::Pcm($queued,7,1280) }
    Assert-Health ($queued.GetHealthSnapshot().State -eq 'healthy') 'Exactly three seconds of queued audio stays at allowed boundary'
    [WakeHealthFixture]::Pcm($queued,7,1280)
    $queuedHealth=$queued.GetHealthSnapshot()
    Assert-Health ($queuedHealth.Reason -eq 'progress-lag' -and $queuedHealth.NeedsRecovery) 'Capture-to-consumer lag includes pending PCM outside worker pipe'
    Assert-Health (-not $queued.IsReady -and -not $queued.FullDuplexReady -and -not $queued.Error) 'Pending backlog revokes readiness before queue overflow'
    Assert-Health ([long][WakeHealthFixture]::Get($queued,'submittedSamples') -eq $queuedHealth.ProcessedSamples) 'Queued-audio regression has no pipe backlog'
    [WakeHealthFixture]::Set($queued,'fixtureMode',$true)
    Assert-Health ($queued.GetHealthSnapshot().State -eq 'healthy' -and -not $queued.FullDuplexReady) 'Accelerated fixture remains exempt from real-time queue lag'
    [WakeHealthFixture]::Set($queued,'fixtureMode',$false)
    [WakeHealthFixture]::Set($queued,'hasActivated',$true)
    Assert-Health ($queued.GetHealthSnapshot().State -eq 'healthy') 'Activated question no longer waits for one-shot worker consumption'

    $question=New-HealthFixture
    [WakeHealthFixture]::Set($question,'normalizedPhrase','你好声伴')
    [WakeHealthFixture]::Set($question,'phrase','你好，声伴')
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('你好声伴'))
    [WakeHealthFixture]::Line($question,7,("WAKE`t"+$encoded))
    Assert-Health ($question.HasQuestion -and $question.GetHealthSnapshot().HasActivated) 'Valid wake creates question handoff and activation health'
    [WakeHealthFixture]::Age($question,'lastProgressTicks',30000)
    Assert-Health ($question.GetHealthSnapshot().State -eq 'healthy') 'One-shot worker exit after wake is not processing failure'
    [WakeHealthFixture]::Line($question,7,("PROGRESS`tgarbage"))
    [WakeHealthFixture]::Line($question,7,("WAKE`t"+$encoded))
    Assert-Health ($question.GetHealthSnapshot().State -eq 'healthy' -and $question.ActivationVersion -eq 1) 'Late worker events cannot reactivate a question'
    [WakeHealthFixture]::Age($question,'lastCaptureTicks',3100)
    Assert-Health ($question.GetHealthSnapshot().Reason -eq 'capture-stalled') 'Question still requires fresh physical input'
    $question.RequestRecoveryStop()
    Assert-Health ($question.IsStopping -and $question.IsListening -and -not $question.IsReady) 'Recovery retains lifecycle flags until actual release'
    Assert-Health ($question.Error -and $question.GetHealthSnapshot().Reason -eq 'capture-stalled') 'Capture recovery preserves failure for question completion'
    $before=$question.GetHealthSnapshot().ProcessedSamples
    [WakeHealthFixture]::Line($question,7,"PROGRESS`t32000")
    Assert-Health ($question.GetHealthSnapshot().ProcessedSamples -eq $before) 'Stop ignores in-flight heartbeat'

    $real=New-Object WakeListener
    $real.Configure((Join-Path $project 'runtime\python\python.exe'),(Join-Path $project 'src\wake_worker.py'),(Join-Path $project 'runtime\models\wake'))
    $real.StartProcessedWaveForTest('你好声伴',(New-SilentWave 8))
    Wait-Condition { $real.GetHealthSnapshot().State -eq 'healthy' }
    $startSamples=$real.GetHealthSnapshot().ProcessedSamples
    Start-Sleep -Milliseconds 3200
    $healthy=$real.GetHealthSnapshot()
    Assert-Health ($healthy.State -eq 'healthy' -and $healthy.ProcessedSamples -gt $startSamples) 'Real worker processes continuing silence beyond watchdog interval'
    Assert-Health ($real.AudioLevel -eq 0 -and -not $healthy.HasActivated) 'Zero-energy input is healthy without false wake'
    Assert-Health ($real.IsReady -and -not $real.FullDuplexReady) 'Real processed fixture stays half-duplex for permission'
    $real.RequestRecoveryStop()
    Assert-Health ($real.StopAndWait(3000)) 'Recovery stops real file worker and capture handoff loop'
    Assert-Health (-not $real.IsListening -and -not $real.IsStopping) 'Released real worker publishes completed lifecycle'

    # READY with no stdin reads forces the host's synchronous pipe to block.
    # A large in-memory WAV plus this owned fake process requires no device.
    $fakeWorker=Join-Path $output 'blocked_worker.py'
    @'
import time
print('READY', flush=True)
time.sleep(60)
'@ | Set-Content -LiteralPath $fakeWorker -Encoding ASCII
    $blocked=New-Object WakeListener
    $blocked.Configure((Join-Path $project 'runtime\python\python.exe'),$fakeWorker,$output)
    $blocked.StartWaveBytes('你好声伴',(New-SilentWave 20))
    Wait-Condition { [long][WakeHealthFixture]::Get($blocked,'submittedSamples') -gt 0 }
    Start-Sleep -Milliseconds 100
    [WakeHealthFixture]::Age($blocked,'runStartedTicks',11000)
    Assert-Health ($blocked.GetHealthSnapshot().State -eq 'stalled') 'Non-consuming worker cannot remain ready'
    $owned=[WakeHealthFixture]::Get($blocked,'ownedWorker')
    $ownedId=$owned.Id
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $blocked.RequestRecoveryStop()
    Assert-Health ($timer.ElapsedMilliseconds -lt 200) 'Recovery stop does not wait on process or pipe on caller thread'
    Assert-Health ($blocked.StopAndWait(3000)) 'Recovery kills own blocked worker and releases synchronous pipe'
    Assert-Health (-not $blocked.IsListening -and -not $blocked.IsStopping) 'Blocked pipe recovery publishes completion only after cleanup'
    Assert-Health ($null -eq (Get-Process -Id $ownedId -ErrorAction SilentlyContinue)) 'Only saved test worker has exited'
    $blocked.Configure((Join-Path $project 'runtime\python\python.exe'),(Join-Path $project 'src\wake_worker.py'),(Join-Path $project 'runtime\models\wake'))
    $blocked.StartWaveFile('你好声伴',(Join-Path $PSScriptRoot 'fixtures\wake\positive-taiwan-chen.wav'))
    Wait-Condition { -not $blocked.IsListening }
    Assert-Health ($blocked.ActivationVersion -eq 1 -and -not $blocked.Error) 'New run works after blocked-worker recovery without stale kill'

    $report=[pscustomobject]@{Passed=$script:checks.Count;Checks=$script:checks.ToArray();DevicesOpened=$false;RealWorkerSilentSamples=$healthy.ProcessedSamples;BlockedWorkerPid=$ownedId;PowerShell=$PSVersionTable.PSVersion.ToString()}
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'health-result.json') -Encoding UTF8
    $report | ConvertTo-Json -Depth 5
} finally {
    if($real) { $real.RequestRecoveryStop(); $real.Dispose() }
    if($blocked) { $blocked.RequestRecoveryStop(); $blocked.Dispose() }
    foreach($fixture in $script:fakeListeners) {
        [WakeHealthFixture]::Set($fixture,'listening',$false)
        [WakeHealthFixture]::Set($fixture,'stopping',$false)
        [WakeHealthFixture]::Set($fixture,'echoCapture',$null)
        $fixture.Dispose()
    }
}
