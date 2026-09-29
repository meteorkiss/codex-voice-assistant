$script:secretaryPhase='off'
$script:secretaryGeneration=0L
$script:secretarySessionId=''
$script:secretaryStartedUtc=[DateTime]::MinValue
$script:secretaryIdleDeadlineUtc=[DateTime]::MinValue
$script:secretaryTurnCount=0
$script:secretaryHistory=New-Object 'Collections.Generic.List[object]'
$script:secretaryPendingConfirmation=$null
$script:secretaryAuthorizedAction=$null
$script:secretaryCurrentTurn=$null
$script:secretarySpeechGeneration=-1L
$script:secretarySpeechObserved=$false
$script:secretaryWork=$null
$script:modelJob=$null
$script:secretaryOperationStatus='本地操作状态：无待处理操作。'

function Initialize-SecretaryConversation {
    $script:secretaryPhase='off'
    $script:secretaryGeneration=0L
    $script:secretarySessionId=''
    $script:secretaryStartedUtc=[DateTime]::MinValue
    $script:secretaryIdleDeadlineUtc=[DateTime]::MinValue
    $script:secretaryTurnCount=0
    $script:secretaryHistory=New-Object 'Collections.Generic.List[object]'
    $script:secretaryPendingConfirmation=$null
    $script:secretaryAuthorizedAction=$null
    $script:secretaryCurrentTurn=$null
    $script:secretarySpeechGeneration=-1L
    $script:secretarySpeechObserved=$false
    $script:modelJob=$null
    Set-SecretaryOperationStatus '本地操作状态：无待处理操作。'
    Set-SecretaryConversationStatus '连续对话默认关闭。'
}

function Set-SecretaryConversationStatus([string]$Text) {
    if (Get-Variable -Name ConversationStateLabel -Scope Script -ErrorAction SilentlyContinue) {
        if ($script:ConversationStateLabel) { $script:ConversationStateLabel.Text=$Text }
    }
    $script:secretaryStatus=$Text
}

function Set-SecretaryOperationStatus([string]$Text) {
    $script:secretaryOperationStatus=([string]$Text).Trim()
    if (Get-Variable -Name ConversationOperationStatusLabel -Scope Script -ErrorAction SilentlyContinue) {
        if ($script:ConversationOperationStatusLabel) { $script:ConversationOperationStatusLabel.Text=$script:secretaryOperationStatus }
    }
}

function Set-SecretaryPhase([string]$Phase,[string]$Message='') {
    if ($Phase -notin @('off','listening','transcribing','thinking','speaking','paused','error')) { throw '连续对话状态无效。' }
    $script:secretaryPhase=$Phase
    if ($Message) { Set-SecretaryConversationStatus ($Phase+' · '+$Message) }
}

function Get-SecretaryConfigurationError {
    if ((Get-Variable -Name TestMode -Scope Script -ErrorAction SilentlyContinue) -and $script:TestMode) { return '测试模式不会连接真实文本或朗读服务。' }
    if ((Get-Variable -Name PreviewPath -Scope Script -ErrorAction SilentlyContinue) -and $script:PreviewPath) { return '预览模式不会连接真实文本或朗读服务。' }
    if ($script:modelDataConsent -ne $true) { return '请先同意向所配置的文本服务发送分句转写、少量对话和最小任务候选名称。' }
    if ([string]::IsNullOrWhiteSpace([string]$script:modelEndpoint)) { return '请先填写文本模型服务地址。' }
    if ([string]::IsNullOrWhiteSpace([string]$script:modelName)) { return '请先填写文本模型名称。' }
    if ($script:modelAuthMode -notin @('bearer','none')) { return '请选择 Bearer 或仅限本机的无鉴权模式。' }
    if ($script:modelAuthMode -eq 'bearer' -and [string]::IsNullOrWhiteSpace([string]$script:modelCredentialEnv)) { return '请填写凭据环境变量名；不要在设置中填写密钥本身。' }
    if ($script:modelAuthMode -eq 'bearer' -and [string]$script:modelCredentialEnv -cnotmatch '\A[A-Za-z_][A-Za-z0-9_]{0,127}\z') { return '凭据环境变量名格式无效。' }
    try {
        $uri=[Uri]([string]$script:modelEndpoint)
        if (-not $uri.IsAbsoluteUri) { return '文本模型服务地址格式无效。' }
        $loopback=$uri.IsLoopback
        if ($uri.Scheme -cne 'https' -and -not ($uri.Scheme -ceq 'http' -and $loopback)) { return '文本模型服务须使用 HTTPS；只有本机 loopback 可使用 HTTP。' }
        if ($script:modelAuthMode -eq 'none' -and -not $loopback) { return '无鉴权模式只允许本机 loopback 服务。' }
    } catch { return '文本模型服务地址格式无效。' }
    return ''
}

function Set-SecretaryCaptureMode([string]$Mode) {
    if (-not (Get-Command Set-NoWakeMode -ErrorAction SilentlyContinue)) { return $true }
    try { Set-NoWakeMode $Mode }
    catch {
        $script:noWakeGeneration++
        $script:noWakeMode='off'
        $script:noWakePhase='stopping'
        return $false
    }
    if ($Mode -eq 'conversation') { return [bool]($script:noWakeMode -eq 'conversation' -and $script:noWakePhase -ne 'stopping') }
    return [bool]($script:noWakeMode -eq 'off')
}

function Start-SecretaryConversation([DateTime]$Now=[DateTime]::UtcNow) {
    $error=Get-SecretaryConfigurationError
    if ($error) {
        $script:continuousConversationEnabled=$false
        Set-SecretaryPhase 'error' $error
        [void](Set-SecretaryCaptureMode off)
        return $false
    }
    if ($script:secretaryPhase -notin @('off','paused','error')) { return $true }
    if (-not $script:secretarySessionId -or $script:secretaryPhase -eq 'off') {
        $script:secretarySessionId=[Guid]::NewGuid().ToString('N')
        $script:secretaryStartedUtc=$Now
        $script:secretaryTurnCount=0
        $script:secretaryHistory.Clear()
        $script:secretaryCurrentTurn=$null
    }
    $script:secretaryGeneration++
    $script:secretaryPendingConfirmation=$null
    $script:secretaryAuthorizedAction=$null
    $script:continuousConversationEnabled=$true
    $idle=[Math]::Max(30,[Math]::Min(600,[int]$script:conversationIdleSeconds))
    $script:secretaryIdleDeadlineUtc=$Now.AddSeconds($idle)
    Set-SecretaryPhase 'listening' ('连续对话正在听；空闲 '+$idle+' 秒后退出。')
    if (-not (Set-SecretaryCaptureMode conversation)) {
        Set-SecretaryPhase 'error' '连续收音未能安全启动；旧采集仍在释放。'
        $script:continuousConversationEnabled=$false
        return $false
    }
    if ((Get-Variable -Name noWakePhase -Scope Script -ErrorAction SilentlyContinue) -and $script:noWakePhase -eq 'stopping') {
        Set-SecretaryPhase 'error' '连续收音未能安全启动；旧采集仍在释放。'
        $script:continuousConversationEnabled=$false
        return $false
    }
    return $true
}

function Stop-SecretaryModelJob {
    if (-not $script:modelJob) { return }
    $job=$script:modelJob;$script:modelJob=$null
    if (Get-Command Close-Job -ErrorAction SilentlyContinue) { Close-Job $job -Kill }
}

function Pause-SecretaryConversation([string]$Reason='连续对话已暂停。') {
    if ($script:secretaryPhase -eq 'off') { return }
    $script:secretaryGeneration++
    Stop-SecretaryModelJob
    $script:secretaryPendingConfirmation=$null
    $script:secretaryAuthorizedAction=$null
    $script:secretarySpeechObserved=$false
    [void](Set-SecretaryCaptureMode off)
    Set-SecretaryPhase 'paused' $Reason
}

function Resume-SecretaryConversation([DateTime]$Now=[DateTime]::UtcNow) {
    if ($script:secretaryPhase -ne 'paused') { return $false }
    return Start-SecretaryConversation -Now $Now
}

function Stop-SecretaryConversation([string]$Reason='连续对话已关闭。') {
    $script:secretaryGeneration++
    Stop-SecretaryModelJob
    $script:secretaryPendingConfirmation=$null
    $script:secretaryAuthorizedAction=$null
    $script:secretaryCurrentTurn=$null
    $script:secretarySpeechObserved=$false
    $script:continuousConversationEnabled=$false
    [void](Set-SecretaryCaptureMode off)
    Set-SecretaryPhase 'off' $Reason
    try { if (Get-Command Save-Settings -ErrorAction SilentlyContinue) { Save-Settings } } catch { }
}

function Write-SecretaryLine([string]$Speaker,[string]$Text) {
    $clean=([string]$Text).Trim()
    if (-not $clean) { return }
    if ($script:ConversationBox) {
        $prefix=if ([string]::IsNullOrWhiteSpace([string]$script:ConversationBox.Text)) { '' } else { [Environment]::NewLine+[Environment]::NewLine }
        $script:ConversationBox.Text=[string]$script:ConversationBox.Text+$prefix+$Speaker+'：'+$clean
        try { $script:ConversationBox.ScrollToEnd() } catch { }
    }
}

function Add-SecretaryHistory([string]$Role,[string]$Content) {
    if ($Role -notin @('user','assistant') -or [string]::IsNullOrWhiteSpace($Content)) { return }
    [void]$script:secretaryHistory.Add([pscustomobject]@{role=$Role;content=$Content.Trim()})
    while ($script:secretaryHistory.Count -gt 8) { $script:secretaryHistory.RemoveAt(0) }
}

function Get-SecretaryModelHistory([string]$CurrentTranscript) {
    $items=@($script:secretaryHistory.ToArray())
    if ($items.Count -gt 0 -and [string]$items[$items.Count-1].role -ceq 'user' -and [string]$items[$items.Count-1].content -ceq $CurrentTranscript.Trim()) {
        if ($items.Count -eq 1) { return @() }
        return @($items[0..($items.Count-2)])
    }
    return $items
}

function Begin-SecretaryTurn([string]$Text,[DateTime]$Now=[DateTime]::UtcNow,[switch]$AlreadyDisplayed,[switch]$AlreadyCounted) {
    if (-not $script:continuousConversationEnabled -or $script:secretaryPhase -ne 'listening') { return $null }
    $text=$Text.Trim()
    if (-not $text) { return $null }
    $maxTurns=[Math]::Max(1,[Math]::Min(100,[int]$script:conversationMaxTurns))
    if ($script:secretaryTurnCount -ge $maxTurns) { Stop-SecretaryConversation ('连续对话已达到 '+$maxTurns+' 轮上限，请重新开启。'); return $null }
    if (-not $AlreadyCounted) { $script:secretaryTurnCount++ }
    $turn=[pscustomobject]@{SessionId=$script:secretarySessionId;Generation=$script:secretaryGeneration;
        TurnId=[Guid]::NewGuid().ToString('N');Number=$script:secretaryTurnCount;StartedUtc=$Now.ToString('o');Transcript=$text}
    $script:secretaryCurrentTurn=$turn
    $script:secretaryIdleDeadlineUtc=$Now.AddSeconds([Math]::Max(30,[Math]::Min(600,[int]$script:conversationIdleSeconds)))
    if (-not $AlreadyDisplayed) { Write-SecretaryLine '你' $text;Add-SecretaryHistory 'user' $text }
    Set-SecretaryPhase 'thinking' '声伴正在理解这句话…'
    [void](Set-SecretaryCaptureMode off)
    return $turn
}

function Start-SecretaryModel($Turn) {
    if (-not $Turn -or $script:modelJob -or $Turn.SessionId -cne $script:secretarySessionId -or
        [long]$Turn.Generation -ne $script:secretaryGeneration -or $script:secretaryPhase -ne 'thinking' -or -not $Turn.Snapshot) { return $false }
    $id=[Guid]::NewGuid().ToString('N')
    $inputPath=Join-Path $runtime ($id+'.secretary.json')
    $outputPath=Join-Path $runtime ($id+'.secretary-result.json')
    $request=[ordered]@{endpoint=$script:modelEndpoint;model=$script:modelName;authMode=$script:modelAuthMode;
        credentialEnv=$script:modelCredentialEnv;consent=[bool]$script:modelDataConsent;timeoutSeconds=20;
        transcript=$Turn.Transcript;history=@(Get-SecretaryModelHistory $Turn.Transcript);generation=$Turn.Generation;turnId=$Turn.TurnId;
        candidateCatalogComplete=[bool]$Turn.Snapshot.CatalogComplete;candidates=@($Turn.Snapshot.Candidates|ForEach-Object{[ordered]@{candidateKey=$_.candidateKey;displayName=$_.title}})}
    try {
        [IO.File]::WriteAllText($inputPath,($request|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
        $proc=Start-Worker $python (Join-Path $PSScriptRoot 'secretary_model_client.py') @('--request',$inputPath,'--output',$outputPath)
        $script:modelJob=@{Process=$proc;Output=$outputPath;Files=@($inputPath,$outputPath,$outputPath+'.tmp');Turn=$Turn;Generation=$Turn.Generation;
            SessionId=$Turn.SessionId;Started=[DateTime]::UtcNow}
        return $true
    } catch {
        Remove-OwnedFiles @($inputPath,$outputPath)
        Set-SecretaryPhase 'error' '文本模型请求未能启动；没有发送或重试。'
        return $false
    }
}

function Test-SecretaryExactProperties($Value,[string[]]$Names) {
    if ($null -eq $Value) { return $false }
    $actual=if($Value -is [Collections.IDictionary]){@($Value.Keys|ForEach-Object{[string]$_})}else{@($Value.PSObject.Properties.Name)}
    if ($actual.Count -ne $Names.Count) { return $false }
    foreach($name in $Names){if($actual -cnotcontains $name){return $false}}
    return $true
}

function Get-SecretarySnapshotFingerprint($Snapshot) {
    $candidates=@()
    foreach($candidate in @($Snapshot.Candidates)){
        $candidates+=,[ordered]@{candidateKey=[string]$candidate.candidateKey;threadId=[string]$candidate.threadId;title=[string]$candidate.title}
    }
    $canonical=[ordered]@{SessionId=[string]$Snapshot.SessionId;ConversationGeneration=[long]$Snapshot.ConversationGeneration;
        ProposalTurnId=[string]$Snapshot.ProposalTurnId;SnapshotId=[string]$Snapshot.SnapshotId;ExpiresAt=[string]$Snapshot.ExpiresAt;
        OriginalBindingGeneration=[long]$Snapshot.OriginalBindingGeneration;CatalogComplete=[bool]$Snapshot.CatalogComplete;Candidates=$candidates}
    $bytes=[Text.Encoding]::UTF8.GetBytes(($canonical|ConvertTo-Json -Depth 8 -Compress))
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}

function New-SecretaryOpaqueKey {
    $bytes=New-Object byte[] 18
    $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return 'cand_'+[Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function ConvertTo-SecretaryCandidateTitle($Value) {
    $title=([string]$Value).Trim()
    if (-not $title -or $title.Length -gt 120 -or $title -match '[\x00-\x1f\x7f-\x9f]') { return '' }
    return [Text.RegularExpressions.Regex]::Replace($title,'\s+',' ')
}

function New-SecretaryCandidateSnapshot {
    param($Candidates,$Turn,[bool]$CatalogComplete,[DateTime]$Now=[DateTime]::UtcNow)
    $normalized=New-Object 'Collections.Generic.List[object]';$keys=New-Object 'Collections.Generic.HashSet[string]';$ids=New-Object 'Collections.Generic.HashSet[string]';$titles=New-Object 'Collections.Generic.List[string]'
    $complete=$CatalogComplete
    foreach($candidate in @($Candidates)){
        $id=[Guid]::Empty;$key=[string]$candidate.candidateKey;if(-not $key){$key=New-SecretaryOpaqueKey};$title=ConvertTo-SecretaryCandidateTitle $candidate.title
        $local=($null -eq $candidate.PSObject.Properties['hostId'] -or [string]$candidate.hostId -eq 'local')
        if (-not $key -or -not $keys.Add($key) -or -not [Guid]::TryParse([string]$candidate.threadId,[ref]$id) -or
            -not $ids.Add($id.ToString()) -or -not $local -or -not $title) { $complete=$false;continue }
        if ($titles.Contains($title)) { $complete=$false }
        else { [void]$titles.Add($title) }
        [void]$normalized.Add([pscustomobject]@{candidateKey=$key;threadId=$id.ToString();title=$title})
    }
    if ($normalized.Count -gt 40) { $complete=$false; while($normalized.Count -gt 40){$normalized.RemoveAt($normalized.Count-1)} }
    $snapshot=[pscustomobject]@{SessionId=[string]$Turn.SessionId;ConversationGeneration=[long]$Turn.Generation;
        ProposalTurnId=[string]$Turn.TurnId;SnapshotId=[Guid]::NewGuid().ToString('N');ExpiresAt=$Now.AddSeconds(45).ToString('o');
        OriginalBindingGeneration=[long]$script:bindingGeneration;CatalogComplete=[bool]$complete;Candidates=$normalized.ToArray();Fingerprint=''}
    $snapshot.Fingerprint=Get-SecretarySnapshotFingerprint $snapshot
    return $snapshot
}

function Get-SecretaryActionFingerprint($Action) {
    $canonical=[ordered]@{SessionId=[string]$Action.SessionId;ConversationGeneration=[long]$Action.ConversationGeneration;
        ProposalTurnId=[string]$Action.ProposalTurnId;ConfirmationTurnId=[string]$Action.ConfirmationTurnId;
        SnapshotId=[string]$Action.SnapshotId;ExpiresAt=[string]$Action.ExpiresAt;OriginalBindingGeneration=[long]$Action.OriginalBindingGeneration;
        Action=[string]$Action.Action;CandidateKey=[string]$Action.CandidateKey;ThreadId=[string]$Action.ThreadId;
        Title=[string]$Action.Title;WorkText=if($null -eq $Action.WorkText){$null}else{[string]$Action.WorkText};
        CandidateSnapshotFingerprint=[string]$Action.Snapshot.Fingerprint}
    $bytes=[Text.Encoding]::UTF8.GetBytes(($canonical|ConvertTo-Json -Depth 8 -Compress))
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}

function Test-SecretaryActionCurrent($Action,[DateTime]$Now=[DateTime]::UtcNow,[switch]$RequireConfirmation) {
    $names=@('Kind','Action','CandidateKey','ThreadId','Title','WorkText','SessionId','ConversationGeneration','ProposalTurnId','ConfirmationTurnId','SnapshotId','ExpiresAt','OriginalBindingGeneration','Snapshot','Fingerprint')
    if (-not $Action -or -not (Test-SecretaryExactProperties $Action $names) -or -not (Test-SecretarySnapshotCurrent $Action.Snapshot $Now)) { return $false }
    if ([string]$Action.Kind -cne 'action' -or [string]$Action.Action -notin @('switch_task','delegate_work') -or
        [string]$Action.SessionId -cne [string]$Action.Snapshot.SessionId -or [long]$Action.ConversationGeneration -ne [long]$Action.Snapshot.ConversationGeneration -or
        [string]$Action.ProposalTurnId -cne [string]$Action.Snapshot.ProposalTurnId -or [string]$Action.SnapshotId -cne [string]$Action.Snapshot.SnapshotId -or
        [string]$Action.ExpiresAt -cne [string]$Action.Snapshot.ExpiresAt -or [long]$Action.OriginalBindingGeneration -ne [long]$Action.Snapshot.OriginalBindingGeneration) { return $false }
    if ($RequireConfirmation) {
        $confirm=[Guid]::Empty
        if (-not [Guid]::TryParse([string]$Action.ConfirmationTurnId,[ref]$confirm) -or [string]$Action.ConfirmationTurnId -ceq [string]$Action.ProposalTurnId) { return $false }
    } elseif (-not [string]::IsNullOrEmpty([string]$Action.ConfirmationTurnId)) { return $false }
    $matches=@($Action.Snapshot.Candidates|Where-Object{$_.candidateKey -ceq [string]$Action.CandidateKey -and $_.threadId -ceq [string]$Action.ThreadId -and $_.title -ceq [string]$Action.Title})
    if ($matches.Count -ne 1) { return $false }
    return ([string]$Action.Fingerprint -ceq (Get-SecretaryActionFingerprint $Action))
}

function Test-SecretarySnapshotCurrent($Snapshot,[DateTime]$Now=[DateTime]::UtcNow) {
    if (-not $Snapshot -or -not (Test-SecretaryExactProperties $Snapshot @('SessionId','ConversationGeneration','ProposalTurnId','SnapshotId','ExpiresAt','OriginalBindingGeneration','CatalogComplete','Candidates','Fingerprint'))) { return $false }
    $expires=[DateTime]::MinValue
    if (-not [DateTime]::TryParse([string]$Snapshot.ExpiresAt,[ref]$expires)) { return $false }
    if ([string]$Snapshot.SessionId -cne $script:secretarySessionId -or [long]$Snapshot.ConversationGeneration -ne $script:secretaryGeneration -or
        [string]::IsNullOrWhiteSpace([string]$Snapshot.ProposalTurnId) -or [string]::IsNullOrWhiteSpace([string]$Snapshot.SnapshotId) -or
        $expires.ToUniversalTime() -le $Now.ToUniversalTime() -or [long]$Snapshot.OriginalBindingGeneration -ne [long]$script:bindingGeneration) { return $false }
    if (-not $script:secretaryCurrentTurn -or [string]$Snapshot.ProposalTurnId -cne [string]$script:secretaryCurrentTurn.TurnId) { return $false }
    return ([string]$Snapshot.Fingerprint -ceq (Get-SecretarySnapshotFingerprint $Snapshot))
}

function Resolve-SecretaryProposal($Proposal,$Snapshot,[DateTime]$Now=[DateTime]::UtcNow) {
    if (-not (Test-SecretaryExactProperties $Proposal @('chatText','clarification','actionProposal'))) { return $null }
    $present=@(@('chatText','clarification','actionProposal')|Where-Object{$null -ne $Proposal.$_})
    if ($present.Count -ne 1) { return $null }
    if ($null -ne $Proposal.chatText) { if($Proposal.chatText -isnot [string] -or [string]::IsNullOrWhiteSpace($Proposal.chatText) -or $Proposal.chatText.Length -gt 2000){return $null};return [pscustomobject]@{Kind='chat';Text=$Proposal.chatText.Trim()} }
    if ($null -ne $Proposal.clarification) { if($Proposal.clarification -isnot [string] -or [string]::IsNullOrWhiteSpace($Proposal.clarification) -or $Proposal.clarification.Length -gt 2000){return $null};return [pscustomobject]@{Kind='clarify';Text=$Proposal.clarification.Trim()} }
    $action=$Proposal.actionProposal
    if (-not (Test-SecretaryExactProperties $action @('action','candidateKey','workText')) -or -not (Test-SecretarySnapshotCurrent $Snapshot $Now) -or -not $Snapshot.CatalogComplete) { return $null }
    if ($action.action -notin @('switch_task','delegate_work') -or $action.candidateKey -isnot [string]) { return $null }
    if ($action.action -eq 'switch_task' -and $null -ne $action.workText) { return $null }
    if ($action.action -eq 'delegate_work' -and ($action.workText -isnot [string] -or [string]::IsNullOrWhiteSpace($action.workText) -or $action.workText.Length -gt 6000)) { return $null }
    $matches=@($Snapshot.Candidates|Where-Object{$_.candidateKey -ceq [string]$action.candidateKey})
    if ($matches.Count -ne 1) { return $null }
    $resolved=[pscustomobject]@{Kind='action';Action=[string]$action.action;CandidateKey=[string]$action.candidateKey;
        ThreadId=[string]$matches[0].threadId;Title=[string]$matches[0].title;WorkText=if($null -eq $action.workText){$null}else{[string]$action.workText};
        SessionId=$Snapshot.SessionId;ConversationGeneration=$Snapshot.ConversationGeneration;ProposalTurnId=$Snapshot.ProposalTurnId;ConfirmationTurnId='';
        SnapshotId=$Snapshot.SnapshotId;ExpiresAt=$Snapshot.ExpiresAt;OriginalBindingGeneration=$Snapshot.OriginalBindingGeneration;Snapshot=$Snapshot;Fingerprint=''}
    $resolved.Fingerprint=Get-SecretaryActionFingerprint $resolved
    if (-not (Test-SecretaryActionCurrent $resolved $Now)) { return $null }
    return $resolved
}

function Write-SecretaryReply([string]$Text,[switch]$LocalOnly) {
    Set-SecretaryOperationStatus $Text
    Write-SecretaryLine '声伴状态' $Text
    if (-not $LocalOnly -and $script:conversationTtsConsent -eq $true -and $script:continuousConversationEnabled -and $script:secretaryPhase -notin @('off','paused','error')) {
        if (Get-Command Stop-AssistantOutput -ErrorAction SilentlyContinue) { Stop-AssistantOutput }
        Queue-AnswerSpeech $Text
        $script:secretarySpeechGeneration=$script:secretaryGeneration
        $script:secretarySpeechObserved=$false
        Set-SecretaryPhase 'speaking' '声伴正在说话；收音已暂停。'
    } elseif ($script:continuousConversationEnabled -and $script:secretaryPhase -notin @('off','paused','error')) {
        Set-SecretaryPhase 'listening' '连续对话正在听。'
        if (-not (Set-SecretaryCaptureMode conversation)) { Set-SecretaryPhase 'error' '连续收音未能恢复；本轮保持停止。' }
    }
}

function Write-SecretaryModelReply([string]$Text) {
    $clean=([string]$Text).Trim()
    if (-not $clean) { return $false }
    Write-SecretaryLine '模型答复（未执行操作）' $clean
    Add-SecretaryHistory 'assistant' $clean
    if ($script:conversationTtsConsent -eq $true -and $script:continuousConversationEnabled -and $script:secretaryPhase -eq 'thinking' -and
        -not $script:secretaryPendingConfirmation -and (-not $script:secretaryWork -or $script:secretaryWork.State -notin @('dispatching','unknown'))) {
        if (Get-Command Stop-AssistantOutput -ErrorAction SilentlyContinue) { Stop-AssistantOutput }
        Queue-AnswerSpeech ('以下是模型答复，不代表已执行任务操作。'+$clean)
        $script:secretarySpeechGeneration=$script:secretaryGeneration
        $script:secretarySpeechObserved=$false
        return $true
    }
    return $false
}

function Complete-SecretaryModel($Result,$Turn,[DateTime]$Now=[DateTime]::UtcNow) {
    if (-not $Turn -or $script:secretaryPhase -ne 'thinking' -or -not $script:continuousConversationEnabled -or
        $script:secretaryPendingConfirmation -or $script:secretaryAuthorizedAction -or ($script:secretaryWork -and $script:secretaryWork.State -in @('dispatching','unknown')) -or
        $Turn.SessionId -cne $script:secretarySessionId -or [long]$Turn.Generation -ne $script:secretaryGeneration -or
        -not $Result -or $Result.ok -ne $true -or [string]$Result.turnId -cne [string]$Turn.TurnId -or [long]$Result.generation -ne [long]$Turn.Generation) { return $false }
    $snapshot=$Turn.Snapshot
    if (-not (Test-SecretarySnapshotCurrent $snapshot $Now)) { Set-SecretaryPhase 'error' '本轮任务候选快照已失效，没有执行任何动作。';return $false }
    $resolved=Resolve-SecretaryProposal $Result.proposal $snapshot $Now
    if (-not $resolved) { Set-SecretaryPhase 'error' '模型返回无法验证，本轮没有执行任何动作。';return $false }
    if ($resolved.Kind -in @('chat','clarify')) {
        $queued=Write-SecretaryModelReply $resolved.Text
        if ($queued) { Set-SecretaryPhase 'speaking' '声伴正在说模型答复；收音已暂停。' }
        elseif ($script:continuousConversationEnabled -and $script:secretaryPhase -eq 'thinking') {
            Set-SecretaryPhase 'listening' '连续对话正在听。'
            if (-not (Set-SecretaryCaptureMode conversation)) { Set-SecretaryPhase 'error' '连续收音未能恢复；本轮保持停止。' }
        }
        return $true
    }
    $script:secretaryPendingConfirmation=$resolved
    $prompt=if($resolved.Action -eq 'switch_task'){'你要我切换到《'+$resolved.Title+'》吗？请说“是的”或“取消”。'}else{'你要我把“'+$resolved.WorkText+'”交给《'+$resolved.Title+'》吗？请说“是的”或“取消”。'}
    Write-SecretaryReply $prompt
    return $true
}

function Consume-SecretaryConfirmation([string]$Text,[DateTime]$Now=[DateTime]::UtcNow,[string]$ConfirmationTurnId='') {
    $pending=$script:secretaryPendingConfirmation
    if (-not $pending -or -not $script:continuousConversationEnabled -or $script:secretaryPhase -in @('off','paused','error')) { return [pscustomobject]@{Disposition='none'} }
    if (-not (Test-SecretaryActionCurrent $pending $Now)) {
        $script:secretaryPendingConfirmation=$null
        return [pscustomobject]@{Disposition='expired'}
    }
    $answer=$Text.Trim()
    if ($answer -in @('是','是的','对','对的','确认','可以','好','好的')) {
        $script:secretaryPendingConfirmation=$null
        if (-not $ConfirmationTurnId) { $ConfirmationTurnId=[Guid]::NewGuid().ToString('N') }
        $authorized=[pscustomobject]@{Kind=$pending.Kind;Action=$pending.Action;CandidateKey=$pending.CandidateKey;ThreadId=$pending.ThreadId;Title=$pending.Title;
            WorkText=$pending.WorkText;SessionId=$pending.SessionId;ConversationGeneration=$pending.ConversationGeneration;ProposalTurnId=$pending.ProposalTurnId;
            ConfirmationTurnId=$ConfirmationTurnId;SnapshotId=$pending.SnapshotId;ExpiresAt=$pending.ExpiresAt;OriginalBindingGeneration=$pending.OriginalBindingGeneration;
            Snapshot=$pending.Snapshot;Fingerprint=''}
        $authorized.Fingerprint=Get-SecretaryActionFingerprint $authorized
        if (-not (Test-SecretaryActionCurrent $authorized $Now -RequireConfirmation)) { return [pscustomobject]@{Disposition='expired'} }
        $script:secretaryAuthorizedAction=$authorized
        Set-SecretaryPhase 'thinking' '正在核对真实任务状态…'
        [void](Set-SecretaryCaptureMode off)
        return [pscustomobject]@{Disposition='confirmed';Action=$authorized}
    }
    if ($answer -in @('不是','不对','不要','取消','算了')) {
        $script:secretaryPendingConfirmation=$null
        Write-SecretaryReply '已取消，任务和工作内容都没有改变。'
        return [pscustomobject]@{Disposition='cancelled'}
    }
    $script:secretaryPendingConfirmation=$null
    return [pscustomobject]@{Disposition='new-topic'}
}

function Handle-SecretaryTranscript([string]$Text,[DateTime]$Now=[DateTime]::UtcNow) {
    if ($Text.Trim() -in @('暂停对话','停止对话','结束对话','先别听了')) {
        Write-SecretaryLine '你' $Text
        Stop-SecretaryConversation '连续对话已按本地明确口令停止；已接收或未知的工作不受影响。'
        return $true
    }
    if ($script:secretaryPendingConfirmation) {
        $maxTurns=[Math]::Max(1,[Math]::Min(100,[int]$script:conversationMaxTurns))
        if ($script:secretaryTurnCount -ge $maxTurns) { Stop-SecretaryConversation ('连续对话已达到 '+$maxTurns+' 轮上限，请重新开启。');return $false }
        $script:secretaryTurnCount++
        $script:secretaryIdleDeadlineUtc=$Now.AddSeconds([Math]::Max(30,[Math]::Min(600,[int]$script:conversationIdleSeconds)))
        Write-SecretaryLine '你' $Text
        Add-SecretaryHistory 'user' $Text
        $confirmation=Consume-SecretaryConfirmation $Text $Now ([Guid]::NewGuid().ToString('N'))
        if ($confirmation.Disposition -eq 'confirmed') { return Start-SecretaryAuthorizedAction $confirmation.Action }
        if ($confirmation.Disposition -in @('cancelled','expired')) { return $true }
        $turn=Begin-SecretaryTurn $Text $Now -AlreadyDisplayed -AlreadyCounted
        if (-not $turn) { return $false }
        return Start-SecretaryCandidateList $turn
    }
    $turn=Begin-SecretaryTurn $Text $Now
    if (-not $turn) { return $false }
    return Start-SecretaryCandidateList $turn
}

function Start-SecretaryCandidateList($Turn) {
    if (-not $Turn -or $script:bridgeJob -or $Turn.SessionId -cne $script:secretarySessionId -or [long]$Turn.Generation -ne $script:secretaryGeneration) { return $false }
    try { $started=Start-Bridge @{action='list'} 'secretary-list' } catch { $started=$false }
    if (-not $started) { Set-SecretaryPhase 'error' '本机任务候选读取未能启动，没有发送模型请求。';return $false }
    $script:bridgeJob.SecretaryTurnContext=$Turn
    return $true
}

function Complete-SecretaryCandidateList($Result,$Turn,[DateTime]$Now=[DateTime]::UtcNow) {
    if (-not $Turn -or $Turn.SessionId -cne $script:secretarySessionId -or [long]$Turn.Generation -ne $script:secretaryGeneration -or
        -not $script:continuousConversationEnabled -or -not $Result -or $Result.ok -ne $true -or
        $null -eq $Result.PSObject.Properties['threads']) {
        Set-SecretaryPhase 'error' '本机任务候选不可用，没有发送模型请求。'
        return $false
    }
    $complete=(-not [string]$Result.warning -and [int]$Result.missingTitleCount -eq 0)
    $snapshot=New-SecretaryCandidateSnapshot -Candidates @($Result.threads) -Turn $Turn -CatalogComplete $complete -Now $Now
    Add-Member -InputObject $Turn -NotePropertyName Snapshot -NotePropertyValue $snapshot -Force
    return Start-SecretaryModel $Turn
}

function Start-SecretaryAuthorizedAction($Action) {
    if (-not $Action -or $Action.SnapshotId -cne $script:secretaryAuthorizedAction.SnapshotId -or
        $Action.Fingerprint -cne $script:secretaryAuthorizedAction.Fingerprint -or
        -not (Test-SecretaryActionCurrent $Action ([DateTime]::UtcNow) -RequireConfirmation)) { Set-SecretaryPhase 'error' '确认快照已失效，没有执行动作。';return $false }
    if ($script:manualTaskBinding -or $script:voiceTaskSwitch -or
        ((Get-Command Test-VoiceTaskCreateBlocksCurrentVoice -ErrorAction SilentlyContinue) -and (Test-VoiceTaskCreateBlocksCurrentVoice))) {
        Set-SecretaryPhase 'error' '另一项任务连接或创建仍待处理，没有执行或重复派发。'
        return $false
    }
    if ($script:bridgeJob) { Set-SecretaryPhase 'error' '另一项 Codex 操作仍在处理，没有重复执行。';return $false }
    try { $started=Start-Bridge @{action='read';threadId=$Action.ThreadId} 'secretary-validate' } catch { $started=$false }
    if (-not $started) { Set-SecretaryPhase 'error' '真实任务核对未能启动，没有执行动作。';return $false }
    $script:bridgeJob.SecretaryActionContext=$Action
    return $true
}

function Test-SecretaryLiveCandidate($Candidate,$Result) {
    return [bool]($Candidate -and $Result -and $Result.ok -eq $true -and $Result.threadId -is [string] -and
        $Result.threadId -ceq [string]$Candidate.ThreadId -and $Result.title -is [string] -and
        [string]::Equals((ConvertTo-SecretaryCandidateTitle $Result.title),(ConvertTo-SecretaryCandidateTitle $Candidate.Title),[StringComparison]::Ordinal) -and
        $Result.archived -ne $true -and $Result.bindingState -notin @('archived','missing') -and (-not $Result.hostId -or $Result.hostId -eq 'local'))
}

function Complete-SecretaryLiveAction($Result,$Action,[DateTime]$Now=[DateTime]::UtcNow) {
    if (-not $Action -or -not (Test-SecretaryActionCurrent $Action $Now -RequireConfirmation) -or
        [long]$Action.OriginalBindingGeneration -ne [long]$script:bindingGeneration -or -not (Test-SecretaryLiveCandidate $Action $Result)) {
        Set-SecretaryPhase 'error' '目标任务已变化、归档或失效，没有执行动作。'
        return $false
    }
    if ($script:InputBox -and $script:InputBox.Text.Trim()) { Set-SecretaryPhase 'error' '工作区有未发送草稿，已保留草稿并停止本次动作。';return $false }
    try { Invoke-TaskBindingCommit $Result $Action.ThreadId }
    catch { Set-SecretaryPhase 'error' '任务绑定没有保存成功，仍使用原任务。';return $false }
    if ($Action.Action -eq 'switch_task') {
        $script:secretaryAuthorizedAction=$null
        Write-SecretaryReply ('已切换到《'+$Action.Title+'》。')
        return $true
    }
    if ($Action.Action -ne 'delegate_work') { Set-SecretaryPhase 'error' '动作类型无效，没有执行。';return $false }
    $script:InputBox.Text=$Action.WorkText
    try { Send-Text 'secretary' }
    catch { Set-SecretaryPhase 'error' '工作发送事务未能启动，文字已保留供核对；不会自动重试。';return $false }
    if (-not $script:bridgeJob -or $script:bridgeJob.Purpose -ne 'send' -or $script:bridgeJob.Request.text -cne $Action.WorkText) {
        Set-SecretaryPhase 'error' '工作没有进入发送事务，文字已保留供核对。'
        return $false
    }
    $work=@{RequestId=[string]$script:bridgeJob.Request.requestId;ThreadId=[string]$Action.ThreadId;Title=[string]$Action.Title;
        WorkText=[string]$Action.WorkText;State='dispatching';SessionId=[string]$Action.SessionId;Generation=[long]$Action.ConversationGeneration}
    $script:secretaryWork=$work
    $script:bridgeJob.SecretaryWorkContext=$work.Clone()
    $script:secretaryAuthorizedAction=$null
    Set-SecretaryPhase 'thinking' ('正在等待《'+$Action.Title+'》的真实接收回执…')
    return $true
}

function Complete-SecretaryWorkReceipt($Job,[string]$ReceiptState) {
    if (-not $Job -or -not $Job.SecretaryWorkContext) { return $false }
    $context=$Job.SecretaryWorkContext
    if (-not $script:secretaryWork -or [string]$script:secretaryWork.RequestId -cne [string]$context.RequestId -or $script:secretaryWork.State -ne 'dispatching') { return $false }
    $active=[bool]($script:continuousConversationEnabled -and $script:secretaryPhase -eq 'thinking' -and
        [string]$context.SessionId -ceq [string]$script:secretarySessionId -and [long]$context.Generation -eq [long]$script:secretaryGeneration)
    if ($ReceiptState -eq 'accepted') {
        $script:secretaryWork.State='accepted'
        $message='已交付给《'+$context.Title+'》。'
        if ($active) { Write-SecretaryReply $message }
        else { Set-SecretaryOperationStatus $message;Write-SecretaryLine '声伴状态' $message }
    } elseif ($ReceiptState -eq 'rejected') {
        $script:secretaryWork.State='rejected'
        $message='《'+$context.Title+'》没有接收这项工作，未自动重试。'
        Set-SecretaryOperationStatus $message;Write-SecretaryLine '声伴状态' $message
        if ($active) {
            Set-SecretaryPhase 'listening' '工作未被接收；连续对话仍在听。'
            if (-not (Set-SecretaryCaptureMode conversation)) { Set-SecretaryPhase 'error' '连续收音未能恢复；工作没有自动重派。' }
        }
    } else {
        $script:secretaryWork.State='unknown'
        $message='《'+$context.Title+'》的接收结果未知，请到 Codex 核对；不会自动重派。'
        Set-SecretaryOperationStatus $message;Write-SecretaryLine '声伴状态' $message
        if ($active) { Set-SecretaryPhase 'error' '工作接收结果未知；已暂停连续对话，避免重复派发。' }
    }
    return $true
}

function Get-SecretaryPlaybackActive {
    if ($script:ttsJob -or $script:speechQueue.Count -gt 0 -or $script:audioPath) { return $true }
    $type='CodexReader.AudioPlayer' -as [type]
    if ($type) { return ([CodexReader.AudioPlayer]::State -in @('playing','paused')) }
    return $false
}

function Cancel-SecretarySpeech([string]$Reason='秘书朗读已停止；连续对话保持暂停。') {
    if ($script:secretaryPhase -ne 'speaking') { return }
    Pause-SecretaryConversation $Reason
}

function Stop-SecretaryExpiredModelJob([DateTime]$Now=[DateTime]::UtcNow) {
    $job=$script:modelJob
    if (-not $job) { return $false }
    try { if ($job.Process.HasExited) { return $false } } catch { }
    if (($Now-$job.Started).TotalSeconds -lt 25) { return $false }
    $script:modelJob=$null
    if (Get-Command Close-Job -ErrorAction SilentlyContinue) { Close-Job $job -Kill }
    if ($job.SessionId -ceq $script:secretarySessionId -and [long]$job.Generation -eq $script:secretaryGeneration -and $script:continuousConversationEnabled) {
        Set-SecretaryPhase 'error' '文本模型超过本地总等待上限，已终止；未自动重试或执行动作。'
    }
    return $true
}

function Update-SecretaryConversation([DateTime]$Now=[DateTime]::UtcNow) {
    if (Stop-SecretaryExpiredModelJob $Now) { return }
    if (-not $script:continuousConversationEnabled -or $script:secretaryPhase -in @('off','paused','error')) { return }
    $maxSeconds=[Math]::Max(60,[Math]::Min(3600,[int]$script:conversationMaxSeconds))
    if (($Now-$script:secretaryStartedUtc).TotalSeconds -ge $maxSeconds) { Stop-SecretaryConversation ('连续对话已达到 '+$maxSeconds+' 秒上限，请重新开启。');return }
    if ($script:secretaryTurnCount -ge [Math]::Max(1,[Math]::Min(100,[int]$script:conversationMaxTurns)) -and $script:secretaryPhase -eq 'listening') { Stop-SecretaryConversation '连续对话已达到轮数上限，请重新开启。';return }
    if ($Now -ge $script:secretaryIdleDeadlineUtc -and $script:secretaryPhase -eq 'listening') { Stop-SecretaryConversation '连续对话空闲超时，已安全退出；原唤醒入口仍可使用。';return }
    if ($script:secretaryPhase -eq 'speaking') {
        $active=Get-SecretaryPlaybackActive
        if ($active) { $script:secretarySpeechObserved=$true;return }
        if ($script:secretarySpeechObserved -and $script:secretarySpeechGeneration -eq $script:secretaryGeneration) {
            $script:secretarySpeechObserved=$false
            Set-SecretaryPhase 'listening' '朗读已自然结束，连续对话继续听取。'
            if (-not (Set-SecretaryCaptureMode conversation)) { Set-SecretaryPhase 'error' '朗读结束后收音未能恢复；会话保持停止。' }
        }
    }
}
