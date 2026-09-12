function Start-Bridge($Request, [string]$Purpose) {
    Assert-CodexBridgeRequest $Request $Purpose
    if ($script:bridgeJob) { $script:notice='正在连接 Codex，请稍等…'; return $false }
    if ($Purpose -eq 'send' -and $script:pendingSends.ContainsKey($Request.threadId)) {
        $script:notice='上次发送状态待确认，请先在 Codex 查看。'; return $false
    }
    $id=[Guid]::NewGuid().ToString('N')
    $inputPath=Join-Path $runtime ($id+'.bridge.json')
    $outputPath=Join-Path $runtime ($id+'.bridge-result.json')
    $Request.stateDir=$stateDir
    $prepared=$false
    try {
        [IO.File]::WriteAllText($inputPath,($Request | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
        if ($Purpose -eq 'send') {
            Set-PendingSend @{threadId=$Request.threadId;requestId=$Request.requestId;text=$Request.text;outputPath=$outputPath;createdUtc=[DateTime]::UtcNow.ToString('o')}
            $prepared=$true
        }
        $proc=Start-Worker $python (Join-Path $PSScriptRoot 'codex_bridge.py') @('--request',$inputPath,'--output',$outputPath)
    } catch {
        # No worker was returned: clean only this request's files. If ledger
        # rollback fails, leave its lock intact rather than permit duplication.
        try { if ($prepared) { Clear-PendingSend $Request.threadId } }
        finally { Remove-OwnedFiles @($inputPath,$outputPath) }
        throw
    }
    $script:bridgeJob=@{Process=$proc;Files=@($inputPath,$outputPath);Output=$outputPath;Purpose=$Purpose;Request=$Request;Started=[DateTime]::UtcNow;
        BindingGeneration=$script:bindingGeneration;InputGeneration=$script:voiceGeneration}
    if ($Purpose -eq 'send') {
        $pending=@{}; foreach ($key in $script:pendingSends[$Request.threadId].Keys) { $pending[$key]=$script:pendingSends[$Request.threadId][$key] }
        try {
            $pending.processId=$proc.Id; $pending.processStartedUtc=$proc.StartTime.ToUniversalTime().ToString('o')
            Set-PendingSend $pending
        } catch { $script:workerWarning='发送已启动，但进程状态保存失败；保留发送锁并等待原回执，不会重发。' }
    }
    return $true
}

# Validate local dispatch before creating request files or touching a ledger.
# Python still validates live capabilities and exact destination ownership.
function Assert-CodexBridgeRequest($Request,[string]$Purpose) {
    $actions=@{list='list';'voice-find'='find';bind='read';'voice-bind'='read';'voice-create-bind'='read';
        open='open';send='send';'voice-create'='create';'voice-create-status'='create-status';'voice-manage'='manage'}
    if ($Request -isnot [hashtable] -or -not $actions.ContainsKey($Purpose) -or
        $Request.action -isnot [string] -or $Request.action -cne $actions[$Purpose]) { throw '本地操作与连接请求不匹配。' }
    $fields=@()
    if ($Request.action -notin @('list','find')) { $fields+='threadId' }
    if ($Request.action -in @('send','create','create-status','manage')) { $fields+='requestId' }
    foreach ($field in $fields) {
        if ($Request[$field] -isnot [string] -or $Request[$field] -cnotmatch '\A[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z') { throw '任务或请求编号格式无效。' }
    }
    if ($Request.action -eq 'send' -and ($Request.text -isnot [string] -or [string]::IsNullOrWhiteSpace($Request.text))) { throw '没有可以发送的文字。' }
}

function Get-CodexOperationReceipt($Result,[string]$RequestId,[string]$Operation) {
    if ($Result -and $Result.ok -is [bool] -and $Result.ok -eq $true -and
        $Result.requestId -is [string] -and $Result.requestId -ceq $RequestId -and
        $Result.operation -is [string] -and $Result.operation -ceq $Operation -and
        $Result.message -is [string] -and -not [string]::IsNullOrWhiteSpace($Result.message)) { return 'complete' }
    if ($Result -and $Result.ok -is [bool] -and $Result.ok -eq $false -and
        $Result.error -and $Result.error.uncertain -is [bool] -and $Result.error.uncertain -eq $false) { return 'failed' }
    return 'unknown'
}
