# Only this application's supplied WPF windows are managed. No external HWND is
# ever changed. Native foreground reads trigger at most one lift per change.
$script:DesktopTopmostSourceRoot=$PSScriptRoot

function Import-DesktopTopmostTypes {
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
    if (-not ('ShengBan.Desktop.DesktopTopmostManager' -as [type])) {
        Add-Type -Path (Join-Path $script:DesktopTopmostSourceRoot 'DesktopTopmost.cs') -ReferencedAssemblies @('PresentationFramework','PresentationCore','WindowsBase','System.Xaml')
    }
}

function Initialize-DesktopTopmost {
    param([Parameter(Mandatory=$true)][hashtable]$Shell)
    if ($Shell.TopmostManager -and -not $Shell.TopmostManager.IsDisposed) { return $Shell.TopmostManager }
    if (-not $Shell.Window) { throw 'Desktop topmost requires the application main window.' }
    Import-DesktopTopmostTypes
    $Shell.TopmostManager=New-Object ShengBan.Desktop.DesktopTopmostManager($Shell.Window,$Shell.CaptionWindow,$Shell.SettingsWindow,$Shell.Menu)
    return $Shell.TopmostManager
}

function Set-DesktopPinned {
    param([Parameter(Mandatory=$true)][hashtable]$Shell,[bool]$Pinned)
    $manager=Initialize-DesktopTopmost $Shell
    $manager.SetPinned($Pinned)
}

function Get-DesktopTopmostStatus {
    param([Parameter(Mandatory=$true)][hashtable]$Shell)
    if (-not $Shell.TopmostManager) { return $null }
    return $Shell.TopmostManager.GetStatus()
}

function Close-DesktopTopmost {
    param([AllowNull()][hashtable]$Shell)
    if ($Shell -and $Shell.TopmostManager) { $Shell.TopmostManager.Dispose() }
}
