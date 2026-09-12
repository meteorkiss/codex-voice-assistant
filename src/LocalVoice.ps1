# Optional local voice service. The caller owns voice selection and UI status.
function Get-AssistantVoiceProfile {
    param([AllowNull()][AllowEmptyString()][string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    $matches=@($script:voiceCatalog | Where-Object {
        $_.id -is [string] -and [string]::Equals($_.id,$Id,[StringComparison]::Ordinal)
    })
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Test-LocalVoiceProfile {
    param([AllowNull()][AllowEmptyString()][string]$Id)
    $profile=Get-AssistantVoiceProfile $Id
    return ($null -ne $profile -and $profile.provider -is [string] -and [string]::Equals($profile.provider,'qwen-local',[StringComparison]::Ordinal))
}

function Resolve-LocalVoiceWorkspacePath {
    param([string]$WorkspacePath,[AllowNull()][AllowEmptyString()][string]$RelativePath,[ValidateSet('File','Directory','Any')][string]$Kind='Any',[switch]$AllowMissing)
    if ([string]::IsNullOrWhiteSpace($WorkspacePath) -or [string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains(':')) { throw '本地语音配置必须使用工作目录内的相对路径。' }
    $rootPath=[IO.Path]::GetFullPath($WorkspacePath).TrimEnd([char[]]'\/')
    $path=[IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath))
    if (-not $path.StartsWith($rootPath+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw '本地语音配置路径不能超出工作目录。' }
    # ResolvePath alone does not resolve Windows junctions. Reject reparse-point
    # ancestors so a relative config value cannot silently leave the workspace.
    $probe=$path
    while ($probe -and $probe.Length -ge $rootPath.Length) {
        if (Test-Path -LiteralPath $probe) {
            $item=Get-Item -LiteralPath $probe -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '本地语音路径不能经过符号链接或目录联接。' }
        }
        if ([string]::Equals($probe,$rootPath,[StringComparison]::OrdinalIgnoreCase)) { break }
        $probe=[IO.Path]::GetDirectoryName($probe)
    }
    if (-not $AllowMissing) {
        $pathType=if($Kind -eq 'File'){'Leaf'}elseif($Kind -eq 'Directory'){'Container'}else{'Any'}
        if (-not (Test-Path -LiteralPath $path -PathType $pathType)) { throw ('本地语音文件尚未准备好：'+$RelativePath) }
    }
    return $path
}

function Get-LocalVoiceInstallation {
    $rootPath=[IO.Path]::GetFullPath($workspace).TrimEnd([char[]]'\/')
    $configPath=Resolve-LocalVoiceWorkspacePath $rootPath 'runtime\voice-design\config.json' 'File'
    $config=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach($field in @('python','model','profiles')) {
        if ($config.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($config.$field)) { throw ('本地语音配置缺少有效字段：'+$field) }
    }
    $pythonPath=Resolve-LocalVoiceWorkspacePath $rootPath $config.python 'File'
    $modelPath=Resolve-LocalVoiceWorkspacePath $rootPath $config.model 'Directory'
    $profilesPath=Resolve-LocalVoiceWorkspacePath $rootPath $config.profiles 'File'
    $serverPath=Resolve-LocalVoiceWorkspacePath $rootPath 'src\local_tts_server.py' 'File'
    return @{Workspace=$rootPath;Python=$pythonPath;Model=$modelPath;Profiles=$profilesPath;Server=$serverPath}
}

function Get-AvailableVoiceProfiles {
    param([AllowNull()][object[]]$Catalog)
    $checkedLocal=$false;$localInstalled=$false
    foreach($profile in @($Catalog)) {
        if ($null -eq $profile -or $profile.id -isnot [string] -or [string]::IsNullOrWhiteSpace($profile.id)) { continue }
        if (-not ($profile.provider -is [string] -and [string]::Equals($profile.provider,'qwen-local',[StringComparison]::Ordinal))) {
            $profile
            continue
        }
        if (-not $checkedLocal) {
            $checkedLocal=$true
            try { $installation=Get-LocalVoiceInstallation; $localInstalled=($null -ne $installation) } catch { $localInstalled=$false }
        }
        if (-not $localInstalled) { continue }
        try {
            if (Get-VoiceAcknowledgementPath $profile.id) { $profile }
        } catch { }
    }
}

function Ensure-LocalVoiceServer {
    $record=Get-Variable -Name localVoiceService -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($record) {
        if ($record.OwnerPid -ne $PID) { throw '本地语音服务记录不属于当前助手。' }
        if ($record.Process -and -not $record.Process.HasExited) { return [string]$record.StateDir }
        Close-LocalVoiceServer
    }
    $installation=Get-LocalVoiceInstallation
    $rootPath=$installation.Workspace;$pythonPath=$installation.Python;$modelPath=$installation.Model;$profilesPath=$installation.Profiles;$serverPath=$installation.Server
    $runPath=[IO.Path]::GetFullPath($runtime)
    if (-not $runPath.StartsWith($rootPath+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw '本地语音运行目录不能超出工作目录。' }
    $relativeState=Join-Path ($runPath.Substring($rootPath.Length+1)) 'local-voice'
    $serviceState=Resolve-LocalVoiceWorkspacePath $rootPath $relativeState 'Directory' -AllowMissing
    [void][IO.Directory]::CreateDirectory($serviceState)
    $readyPath=Join-Path $serviceState 'ready.json'
    if (Test-Path -LiteralPath $readyPath) {
        if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) { throw '本地语音就绪状态文件不可用。' }
        Remove-Item -LiteralPath $readyPath -Force -ErrorAction Stop
    }
    $process=Start-Worker $pythonPath $serverPath @('--workspace',$rootPath,'--state-dir',$serviceState,'--parent-pid',[string]$PID,'--model-path',$modelPath,'--profiles-path',$profilesPath)
    if (-not $process) { throw '本地语音服务未能启动。' }
    $script:localVoiceService=@{Process=$process;StateDir=$serviceState;OwnerPid=$PID;StartedUtc=[DateTime]::UtcNow}
    # The service writes readiness after loading on its own thread/process. Never
    # wait for model loading or poll a GPU/HTTP endpoint on the WPF dispatcher.
    return $serviceState
}

function Close-LocalVoiceServer {
    $record=Get-Variable -Name localVoiceService -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if (-not $record) { return }
    if ($record.OwnerPid -ne $PID) { return }
    $process=$record.Process
    if ($process) {
        if (-not $process.HasExited) {
            $process.Kill()
            if (-not $process.WaitForExit(1500)) { throw '本地语音服务尚未退出，请稍后重试。' }
        }
        $process.Dispose()
    }
    $script:localVoiceService=$null
}

function Get-VoiceAcknowledgementPath {
    param([AllowNull()][AllowEmptyString()][string]$Id)
    if (-not $Id -or $Id -notmatch '\A[A-Za-z0-9][A-Za-z0-9_.-]*\z') { return $null }
    foreach($extension in @('mp3','wav')) {
        $relative='assets\ack-'+$Id+'.'+$extension
        $candidate=Resolve-LocalVoiceWorkspacePath $workspace $relative 'File' -AllowMissing
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}
