# Shared preference transaction for voice, WPF and tray actions. No chat I/O.
function Set-AssistantPreferences([hashtable]$Values) {
    if (-not $Values -or $Values.Count -eq 0) { throw '没有需要保存的设置。' }
    $before=@{}
    foreach ($name in $Values.Keys) {
        $value=$Values[$name]
        switch ($name) {
            'voiceId' { if ($value -isnot [string] -or @($script:voiceCatalog | Where-Object { $_.id -ceq $value }).Count -ne 1) { throw '这个声音暂时不可用。' } }
            'speechRate' { if ($value -isnot [int] -or $value -notin @(-20,0,20,50)) { throw '这个语速暂时不可用。' } }
            'waveStyle' { if ($value -isnot [string] -or $value -notin @('rays','halo','particles','minimal','bars','flow')) { throw '这个样式暂时不可用。' } }
            'waveSize' { if ($value -isnot [int] -or $value -lt 180 -or $value -gt 360) { throw '声波尺寸必须在 180 到 360 之间。' } }
            { $_ -in @('pinned','captionsVisible','floatingVisible','autoRead','autoSend','shortFollowUpEnabled') } {
                if ($value -isnot [bool]) { throw '设置开关必须是真或假。' }
            }
            default { throw '暂不支持这个设置。' }
        }
        $before[$name]=Get-Variable -Name $name -Scope Script -ValueOnly
    }
    try {
        foreach ($name in $Values.Keys) { Set-Variable -Name $name -Value $Values[$name] -Scope Script }
        if ($Values.ContainsKey('floatingVisible') -and $window) {
            if ($script:floatingVisible) { $window.Show() } else { $window.Hide() }
        }
        Sync-DesktopPreferences
        Save-Settings
    } catch {
        foreach ($name in $before.Keys) { Set-Variable -Name $name -Value $before[$name] -Scope Script }
        try {
            if ($Values.ContainsKey('floatingVisible') -and $window) {
                if ($script:floatingVisible) { $window.Show() } else { $window.Hide() }
            }
            Sync-DesktopPreferences
        } catch { }
        throw
    }
}

function Invoke-DesktopPreference([hashtable]$Values) {
    try { Set-AssistantPreferences $Values; return $true }
    catch {
        # Validation can fail before the transaction starts; restore the
        # initiating control too (for example, a stale voice catalog item).
        try { Sync-DesktopPreferences } catch { }
        $script:notice='设置没有完成，已保留原设置，请重试。'
        $script:localCommandMessage=$script:notice
        $script:localCommandNoticeUntil=[DateTime]::UtcNow.AddSeconds(8)
        return $false
    }
}
