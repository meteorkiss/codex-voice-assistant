param([string]$Root=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
# Exercise production route policy using metadata only; no real audio devices.
$tokens=$null;$errors=$null
$tree=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'src/Assistant.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors[0].Message}
foreach($name in @('Test-WakeRecoveryRouteChanged','Reset-WakeRecoveryAudioRoute')) {
    $node=$tree.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($node.Extent.Text))
}
Add-Type -TypeDefinition @'
namespace CodexReader {
    public static class AudioPlayer {
        public static string State="closed", RenderEndpointId="old-render";
        public static int SelectCalls;
        public static void SelectEndpoint(string id) {
            if(id!="") throw new System.Exception("Recovery must follow the default output");
            SelectCalls++; RenderEndpointId="new-render";
        }
    }
}
'@
$script:checks=0
function Check([bool]$Value,[string]$Message) { if(-not $Value){throw $Message};$script:checks++ }
function Reset-Fixture {
    $script:recMode='idle'
    $script:recorder=[pscustomobject]@{IsRecording=$false;IsStopping=$false}
    $script:wakeListener=[pscustomobject]@{IsListening=$true;IsStopping=$false;CaptureEndpointId='capture';RenderEndpointId='render'}
    $script:mic=[pscustomobject]@{Ready=$true;LastError='';AnyCaptureActive=$false;DefaultEndpointAgeMs=100;DefaultCaptureEndpointId='capture';DefaultRenderEndpointId='render'}
    [CodexReader.AudioPlayer]::SelectCalls=0
    [CodexReader.AudioPlayer]::State='closed'
}
Reset-Fixture
Check (-not (Test-WakeRecoveryRouteChanged)) 'Unchanged endpoints requested recovery.'
$script:mic.DefaultCaptureEndpointId='new-capture'
Check (Test-WakeRecoveryRouteChanged) 'Changed microphone was missed.'
Reset-Fixture;$script:mic.DefaultRenderEndpointId='new-render'
Check (Test-WakeRecoveryRouteChanged) 'Changed output was missed.'
Check ([CodexReader.AudioPlayer]::SelectCalls -eq 0) 'The route check mutated output.'
foreach($age in @(-1,3001)) {
    $script:mic.DefaultEndpointAgeMs=$age
    Check (-not (Test-WakeRecoveryRouteChanged)) 'Unavailable/stale metadata changed route.'
}
Reset-Fixture;$script:mic.DefaultCaptureEndpointId='';$script:mic.DefaultRenderEndpointId=''
Check (-not (Test-WakeRecoveryRouteChanged)) 'Missing metadata invented an endpoint.'
Reset-Fixture;$script:mic.DefaultRenderEndpointId='new-render';$script:wakeListener.IsStopping=$true
Check (-not (Test-WakeRecoveryRouteChanged)) 'A stopping stream was refreshed early.'
foreach($case in @('live','stopping','recording','recorder-stopping','playing','paused','mic-unready','mic-error','mic-active','stale','missing-capture')) {
    Reset-Fixture;$script:wakeListener.IsListening=$false
    switch($case) {
        live {$script:wakeListener.IsListening=$true}
        stopping {$script:wakeListener.IsStopping=$true}
        recording {$script:recMode='listening'}
        recorder-stopping {$script:recorder.IsStopping=$true}
        playing {[CodexReader.AudioPlayer]::State='playing'}
        paused {[CodexReader.AudioPlayer]::State='paused'}
        mic-unready {$script:mic.Ready=$false}
        mic-error {$script:mic.LastError='metadata failed'}
        mic-active {$script:mic.AnyCaptureActive=$true}
        stale {$script:mic.DefaultEndpointAgeMs=5000}
        missing-capture {$script:mic.DefaultCaptureEndpointId=''}
    }
    $failed=$false;try {$null=Reset-WakeRecoveryAudioRoute}catch{$failed=$true}
    Check $failed ('Unsafe route reset was accepted: '+$case)
    Check ([CodexReader.AudioPlayer]::SelectCalls -eq 0) ('Unsafe route reset touched output: '+$case)
}
Reset-Fixture;$script:wakeListener.IsListening=$false
$route=Reset-WakeRecoveryAudioRoute
Check ($route.CaptureEndpointId -eq 'capture' -and $route.RenderEndpointId -eq 'new-render') 'Recovery did not return the exact input and newly selected output.'
Check ([CodexReader.AudioPlayer]::SelectCalls -eq 1) 'Safe reset did not refresh output exactly once.'
$result=@{passed=$true;checks=$script:checks;powershell=$PSVersionTable.PSVersion.ToString();boundaries='Production route functions with fake metadata/player. No microphone, playback, enumeration or Codex activity.'}
$output=Join-Path $Root 'work/tests/wake-recovery-routes'
[void][IO.Directory]::CreateDirectory($output)
[IO.File]::WriteAllText((Join-Path $output 'result.json'),($result|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
$result|ConvertTo-Json
