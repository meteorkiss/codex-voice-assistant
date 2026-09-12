param([string]$SourceRoot=(Join-Path (Split-Path $PSScriptRoot -Parent) 'src'))

# Windows PowerShell 5.1 -STA. Shows only small windows created by this test;
# never activates, changes, or reads content from unrelated applications.
# No production restart, microphone, playback, settings writes, or Codex calls.
$ErrorActionPreference='Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run this test with powershell.exe -STA.' }
. (Join-Path $SourceRoot 'DesktopTopmost.ps1')
Import-DesktopTopmostTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TopmostTestNative {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll",EntryPoint="GetWindowLongW")] static extern int GetWindowLong(IntPtr hwnd,int index);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hwnd,uint command);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint processId);
    [DllImport("user32.dll",SetLastError=true)] static extern bool SetWindowPos(IntPtr hwnd,IntPtr after,int x,int y,int w,int h,uint flags);
    public static bool IsTopmost(IntPtr hwnd) { return hwnd!=IntPtr.Zero && (GetWindowLong(hwnd,-20)&8)!=0; }
    public static void SetOwnedTopmost(IntPtr hwnd,bool value) {
        uint owner; GetWindowThreadProcessId(hwnd,out owner);
        if(owner!=(uint)System.Diagnostics.Process.GetCurrentProcess().Id) throw new InvalidOperationException("Test may only change its own windows.");
        if(!SetWindowPos(hwnd,new IntPtr(value?-1:-2),0,0,0,0,0x213)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    public static bool IsAbove(IntPtr first,IntPtr second) {
        IntPtr next=GetWindow(second,3);
        for(int count=0;next!=IntPtr.Zero && count<10000;count++,next=GetWindow(next,3)) if(next==first)return true;
        return false;
    }
}
'@

$script:checks=0
$script:ownedWindows=New-Object 'System.Collections.Generic.List[Windows.Window]'
$script:closedWindows=New-Object 'System.Collections.Generic.HashSet[Windows.Window]'
$shell=$null
$manager=$null
function Assert-That([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Handle($Window) { return (New-Object Windows.Interop.WindowInteropHelper($Window)).Handle }
function Pump([int]$Milliseconds=60) {
    $frame=New-Object Windows.Threading.DispatcherFrame
    $stopper=New-Object Windows.Threading.DispatcherTimer
    $stopper.Interval=[TimeSpan]::FromMilliseconds($Milliseconds)
    $stopper.Tag=$frame
    $stopper.Add_Tick({param($sender,$args) $sender.Stop(); $sender.Tag.Continue=$false})
    $stopper.Start()
    try { [Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $stopper.Stop() }
}
function New-TestWindow([string]$Name,[int]$Offset) {
    $view=New-Object Windows.Window
    $view.Name=$Name; $view.Title='ShengBan topmost test: '+$Name
    $view.Width=180; $view.Height=105; $view.Left=20+$Offset; $view.Top=20+$Offset
    $view.ShowInTaskbar=$false; $view.ShowActivated=$false
    $view.Content=New-Object Windows.Controls.TextBlock
    $view.Content.Text='ShengBan owned test window'; $view.Content.Margin='8'
    $view.Add_Closed({param($sender,$args) [void]$script:closedWindows.Add($sender)})
    $script:ownedWindows.Add($view)
    return $view
}
function Assert-ManagedTopmost([bool]$Expected) {
    foreach ($view in @($shell.Window,$shell.CaptionWindow,$shell.SettingsWindow)) {
        Assert-That ($view.Topmost -eq $Expected) ($view.Name+' WPF Topmost disagrees with the preference.')
        Assert-That ([TopmostTestNative]::IsTopmost((Handle $view)) -eq $Expected) ($view.Name+' native WS_EX_TOPMOST disagrees with the preference.')
    }
}

try {
    $main=New-TestWindow 'Main' 0
    $caption=New-TestWindow 'Caption' 25
    $settings=New-TestWindow 'Settings' 50
    $normal=New-TestWindow 'NormalApplicationFixture' 75
    $peer=New-TestWindow 'OtherTopmostFixture' 100
    $menu=New-Object Windows.Controls.ContextMenu
    [void]$menu.Items.Add('Owned test menu')
    $menu.PlacementTarget=$main.Content
    $main.Content.ContextMenu=$menu
    $shell=@{Window=$main;CaptionWindow=$caption;SettingsWindow=$settings;Menu=$menu}

    # Lazy initialization before HWND creation must configure future windows.
    Set-DesktopPinned $shell $true
    $manager=$shell.TopmostManager
    Assert-That ($manager -and -not $manager.TimerRunning) 'An invisible shell should initialize without running a watchdog.'
    $main.Show(); $caption.Owner=$main; $settings.Owner=$main
    $caption.Show(); $settings.Show(); $normal.Show()
    $peer.Owner=$normal
    Pump
    Assert-ManagedTopmost $true
    Assert-That $manager.TimerRunning 'Visible pinned windows should start the watchdog.'
    Assert-That ([TopmostTestNative]::IsAbove((Handle $settings),(Handle $main))) 'Owned settings must remain above the floating owner.'
    Assert-That ([TopmostTestNative]::IsAbove((Handle $caption),(Handle $main))) 'Owned captions must remain above the floating owner.'
    [void]$normal.Activate(); Pump
    $normalForeground=([TopmostTestNative]::GetForegroundWindow() -eq (Handle $normal))
    # Windows may deny a background test process foreground permission. Do not
    # bypass that policy with input-queue attachment or foreign-window focus.
    # Report the boundary while still checking actual z-order and preservation
    # of whichever window Windows has kept in the foreground.
    $focus=[TopmostTestNative]::GetForegroundWindow()
    Set-DesktopPinned $shell $true
    Assert-That ([TopmostTestNative]::GetForegroundWindow() -eq $focus) 'Reapplying the pin preference stole focus.'
    Assert-That ([TopmostTestNative]::IsAbove((Handle $main),(Handle $normal))) 'The floating window is behind this test normal foreground window.'

    # Native state may diverge from WPF while the checkbox remains checked.
    [TopmostTestNative]::SetOwnedTopmost((Handle $main),$false)
    Assert-That ($main.Topmost -and -not [TopmostTestNative]::IsTopmost((Handle $main))) 'Native drift fixture did not preserve the checked WPF preference.'
    $before=$manager.GetStatus().Checks
    Pump 1150
    Assert-That ($manager.GetStatus().Checks -gt $before) 'The one-second watchdog did not execute.'
    Assert-ManagedTopmost $true
    Assert-That ([TopmostTestNative]::GetForegroundWindow() -eq $focus) 'Repairing native drift stole focus.'

    # Healthy state must not continuously fight another owned topmost window.
    $peer.Topmost=$true; $peer.Show(); Pump
    Assert-That ([TopmostTestNative]::IsAbove((Handle $peer),(Handle $main))) 'The other topmost fixture was not above the floating window.'
    $before=$manager.GetStatus().NativeUpdates
    foreach ($unused in 1..4) { $manager.Refresh() }
    Assert-That ($manager.GetStatus().NativeUpdates -eq $before) 'Healthy native state repeatedly reordered topmost windows.'
    Assert-That ([TopmostTestNative]::IsAbove((Handle $peer),(Handle $main))) 'An unchanged foreground caused z-order fighting with another topmost window.'

    $caption.Hide(); $settings.Hide(); $main.Hide(); Pump
    Assert-That (-not $manager.TimerRunning) 'The watchdog kept running after all managed windows were hidden.'
    $focus=[TopmostTestNative]::GetForegroundWindow()
    $main.Show(); $caption.Show(); $settings.Show(); Pump
    Assert-ManagedTopmost $true
    Assert-That ($manager.TimerRunning -and [TopmostTestNative]::GetForegroundWindow() -eq $focus) 'Hide/show failed to restore the pinned state without activating the shell.'

    # Simulate foreground notifications with this test's handles. The injected
    # process id is classification data only; native writes still target only
    # main/caption/settings supplied above. No foreign window is manipulated.
    $manager.Dispose()
    $script:foregroundSnapshot=New-Object ShengBan.Desktop.TopmostForeground((Handle $normal),[uint32]$PID)
    $reader=[Func[ShengBan.Desktop.TopmostForeground]]{ return $script:foregroundSnapshot }
    $manager=New-Object ShengBan.Desktop.DesktopTopmostManager($main,$caption,$settings,$menu,$reader)
    $shell.TopmostManager=$manager
    $manager.SetPinned($true)
    [TopmostTestNative]::SetOwnedTopmost((Handle $peer),$true)
    $focus=[TopmostTestNative]::GetForegroundWindow()
    $baseline=$manager.GetStatus().NativeUpdates
    $script:foregroundSnapshot=New-Object ShengBan.Desktop.TopmostForeground((Handle $normal),[uint32]($PID+100000))
    $manager.Refresh()
    Assert-That ($manager.GetStatus().ForegroundRepairs -eq 1 -and $manager.GetStatus().NativeUpdates -gt $baseline) 'A changed foreign foreground did not cause one native group lift.'
    Assert-That ([TopmostTestNative]::IsAbove((Handle $main),(Handle $peer))) 'The bounded foreground lift did not raise the floating window above the test topmost peer.'
    Assert-That ([TopmostTestNative]::IsAbove((Handle $settings),(Handle $caption))) 'The group lift placed the caption over settings.'
    Assert-That ([TopmostTestNative]::GetForegroundWindow() -eq $focus) 'The bounded foreground lift stole focus.'
    $baseline=$manager.GetStatus().NativeUpdates
    foreach ($unused in 1..4) { $manager.Refresh() }
    Assert-That ($manager.GetStatus().NativeUpdates -eq $baseline -and $manager.GetStatus().ForegroundRepairs -eq 1) 'An unchanged foreign foreground was lifted repeatedly.'
    $script:foregroundSnapshot=New-Object ShengBan.Desktop.TopmostForeground((Handle $settings),[uint32]$PID)
    $manager.Refresh()
    Assert-That ($manager.GetStatus().NativeUpdates -eq $baseline) 'A change to our own settings unnecessarily reordered windows.'

    $menu.IsOpen=$true; Pump
    $script:foregroundSnapshot=New-Object ShengBan.Desktop.TopmostForeground((Handle $peer),[uint32]($PID+100000))
    $manager.Refresh()
    Assert-That ($manager.GetStatus().NativeUpdates -eq $baseline) 'The watchdog competed with our open context menu.'
    $menu.IsOpen=$false; Pump 300
    Assert-That ($manager.GetStatus().ForegroundRepairs -eq 2) ('Closing the menu did not apply the deferred foreground transition exactly once. '+($manager.GetStatus() | ConvertTo-Json -Compress))

    $focus=[TopmostTestNative]::GetForegroundWindow()
    Set-DesktopPinned $shell $false
    Assert-ManagedTopmost $false
    Assert-That (-not $manager.TimerRunning) 'Unpin did not stop the watchdog.'
    Assert-That ([TopmostTestNative]::GetForegroundWindow() -eq $focus) 'Unpinning stole focus.'
    Assert-That ([TopmostTestNative]::IsTopmost((Handle $peer))) 'Unpinning the assistant modified the unrelated test topmost peer.'
    $baseline=$manager.GetStatus().NativeUpdates
    $manager.Refresh()
    Assert-That ($manager.GetStatus().NativeUpdates -eq $baseline) 'An unpinned shell still performed native repairs.'

    Set-DesktopPinned $shell $true
    Assert-ManagedTopmost $true
    Assert-That (-not (Get-DesktopTopmostStatus $shell).LastError) 'Native topmost status reports an error.'
    $main.Close(); Pump
    Assert-That ($manager.IsDisposed -and -not $manager.TimerRunning) 'Closing the main window did not dispose the timer and lifecycle handlers.'
    $baseline=$manager.GetStatus().Checks
    Pump 1100
    Assert-That ($manager.GetStatus().Checks -eq $baseline) 'The closed shell still received watchdog work.'
    Close-DesktopTopmost $shell
    Close-DesktopTopmost $shell
    Assert-That $manager.IsDisposed 'Cleanup is not idempotent.'
    [pscustomobject]@{ok=$true;checks=$script:checks;testWindowsShown=$true;nativeStyleVerified=$true;normalForegroundVerified=$normalForeground;foregroundTransitionSource='injected own test handles';focusPreserved=$true;productionWindowMutations=0;codexRequests=0} | ConvertTo-Json -Compress
} finally {
    if ($manager) { $manager.Dispose() }
    if ($menu) { $menu.IsOpen=$false }
    for ($index=$script:ownedWindows.Count-1;$index -ge 0;$index--) {
        $view=$script:ownedWindows[$index]
        if (-not $script:closedWindows.Contains($view)) { $view.Close() }
    }
}
