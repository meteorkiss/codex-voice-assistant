$ErrorActionPreference='Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'src\PendingSends.ps1')
$stateDir=Join-Path (Join-Path $projectRoot 'work\tests') ('pending-test-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($stateDir)
$script:pendingPath=Join-Path $stateDir 'pending-sends.json'
$script:pendingSends=@{}
$script:threadId=[Guid]::NewGuid().ToString()
$other=[Guid]::NewGuid().ToString()
$request=[Guid]::NewGuid().ToString()
$receiptPath=Join-Path $stateDir 'result.json'
$pending=@{threadId=$script:threadId;requestId=$request;text='用户原文';outputPath=$receiptPath;createdUtc=[DateTime]::UtcNow.ToString('o')}
Set-PendingSend $pending
if ($script:pendingUncertain -ne $request) { throw 'Dispatch was not locked before sending' }
$script:pendingSends=@{}; $script:pendingUncertain=''
Initialize-PendingSends
if ($script:pendingUncertain -ne $request -or $script:pendingSends[$script:threadId].text -ne '用户原文') { throw 'Pending envelope did not survive restart' }
$originalThread=$script:threadId; $script:threadId=$other; Sync-PendingSend
if ($script:pendingUncertain) { throw 'Other task was blocked' }
$script:threadId=$originalThread; Sync-PendingSend
if ($script:pendingUncertain -ne $request) { throw 'Switching tasks cleared pending dispatch' }
$uncertain=[pscustomobject]@{ok=$false;error=[pscustomobject]@{uncertain=$true;message='timeout'}}
if ((Get-SendReceiptState $uncertain $originalThread $request) -ne 'unknown') { throw 'Nested uncertain receipt was not protected' }
$uncertain | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
Reconcile-PendingSends
if (-not $script:pendingUncertain) { throw 'Unknown receipt unlocked send' }
$accept=[pscustomobject]@{ok=$true;accepted=$true;threadId=$originalThread;requestId=$request}
$accept | ConvertTo-Json | Set-Content -LiteralPath $receiptPath -Encoding UTF8
Reconcile-PendingSends
if ($script:pendingUncertain -or $script:pendingSends.ContainsKey($originalThread)) { throw 'Accepted receipt did not clear pending' }
Set-PendingSend $pending
$reject=[pscustomobject]@{ok=$false;error=[pscustomobject]@{uncertain=$false;message='not accepted'}}
$reject | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
Reconcile-PendingSends
if ($script:pendingUncertain) { throw 'Explicit rejection did not clear pending' }
if (-not (Test-PendingSendRunning @{createdUtc=[DateTime]::UtcNow.ToString('o')})) { throw 'Fresh dispatch without persisted PID should stay locked' }
$current=Get-Process -Id $PID
if (-not (Test-PendingSendRunning @{processId=$PID;processStartedUtc=$current.StartTime.ToUniversalTime().ToString('o')})) { throw 'Live dispatch process detection failed' }
'Pending-send UI checks passed: restart, task switch, nested uncertainty, late accepted/rejected receipt, active process.'
