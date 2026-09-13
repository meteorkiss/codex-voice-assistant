using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Threading;

namespace ShengBan.Desktop
{
    public sealed class TopmostForeground
    {
        public IntPtr Handle { get; private set; }
        public uint ProcessId { get; private set; }
        public TopmostForeground(IntPtr handle, uint processId) { Handle = handle; ProcessId = processId; }
    }

    public sealed class TopmostWindowStatus
    {
        public string Role { get; set; }
        public bool Visible { get; set; }
        public bool ManagedTopmost { get; set; }
        public bool NativeTopmost { get; set; }
        public bool HasHandle { get; set; }
    }

    public sealed class DesktopTopmostStatus
    {
        public bool Pinned { get; set; }
        public bool TimerRunning { get; set; }
        public bool Disposed { get; set; }
        public long NativeUpdates { get; set; }
        public long ForegroundRepairs { get; set; }
        public long Checks { get; set; }
        public string LastError { get; set; }
        public TopmostWindowStatus[] Windows { get; set; }
    }

    // This manager only changes handles obtained from the supplied WPF windows
    // and verifies that each handle belongs to this process. It never activates
    // a window, changes another application's window, or flips topmost off/on.
    public sealed class DesktopTopmostManager : IDisposable
    {
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
        private static extern int GetWindowLong(IntPtr window, int index);
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        private static extern bool IsWindow(IntPtr window);

        // Microsoft SetWindowPos: NOACTIVATE preserves focus; NOOWNERZORDER
        // preserves the owner when an owned caption window is raised.
        // https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-setwindowpos
        private const uint PositionFlags = 0x0001 | 0x0002 | 0x0010 | 0x0200;
        private readonly Window[] windows;
        private readonly string[] roles = { "main", "caption", "settings" };
        private readonly HashSet<Window> closed = new HashSet<Window>();
        private readonly ContextMenu menu;
        private readonly DispatcherTimer timer;
        private readonly Func<TopmostForeground> foregroundReader;
        private readonly uint processId = (uint)Process.GetCurrentProcess().Id;
        private TopmostForeground lastForeground;
        private bool configured, pinned, disposed, applying;
        private long nativeUpdates, foregroundRepairs, checks;
        private string lastError = "";

        public DesktopTopmostManager(Window main, Window caption, Window settings, ContextMenu contextMenu)
            : this(main, caption, settings, contextMenu, ReadForeground) { }

        // A supplied read-only foreground source permits deterministic tests
        // using only this test process's own windows. Production uses Win32.
        public DesktopTopmostManager(Window main, Window caption, Window settings, ContextMenu contextMenu,
            Func<TopmostForeground> readForeground)
        {
            if (main == null) throw new ArgumentNullException("main");
            main.Dispatcher.VerifyAccess();
            if (readForeground == null) throw new ArgumentNullException("readForeground");
            windows = new[] { main, caption, settings };
            foreach (Window window in windows)
            {
                if (window == null) continue;
                if (window.Dispatcher != main.Dispatcher) throw new ArgumentException("Windows must share the UI dispatcher.");
                window.SourceInitialized += OnSourceInitialized;
                window.IsVisibleChanged += OnVisibilityChanged;
                window.StateChanged += OnStateChanged;
                window.Closed += OnClosed;
            }
            menu = contextMenu;
            if (menu != null) menu.Closed += OnMenuClosed;
            foregroundReader = readForeground;
            lastForeground = foregroundReader();
            timer = new DispatcherTimer(DispatcherPriority.Background, main.Dispatcher);
            timer.Interval = TimeSpan.FromSeconds(1);
            timer.Tick += OnTick;
        }

        public bool IsDisposed { get { return disposed; } }
        public bool TimerRunning { get { return timer.IsEnabled; } }

        private static TopmostForeground ReadForeground()
        {
            IntPtr handle = GetForegroundWindow();
            uint owner = 0;
            if (handle != IntPtr.Zero) GetWindowThreadProcessId(handle, out owner);
            return new TopmostForeground(handle, owner);
        }

        private bool Live(Window window) { return window != null && !closed.Contains(window); }
        private bool Visible(Window window) { return Live(window) && window.IsVisible && window.WindowState != WindowState.Minimized; }
        private bool DesiredTopmost(Window window) { return window != windows[2] && pinned; }
        private bool AnyPinnedVisible()
        {
            foreach (Window window in windows) if (DesiredTopmost(window) && Visible(window)) return true;
            return false;
        }

        private IntPtr OwnedHandle(Window window)
        {
            if (!Live(window)) return IntPtr.Zero;
            IntPtr handle = new WindowInteropHelper(window).Handle;
            if (handle == IntPtr.Zero || !IsWindow(handle)) return IntPtr.Zero;
            uint owner;
            GetWindowThreadProcessId(handle, out owner);
            if (owner != processId) throw new InvalidOperationException("Refusing to change a window outside this process.");
            return handle;
        }

        private static bool NativeTopmost(IntPtr handle)
        {
            return handle != IntPtr.Zero && (GetWindowLong(handle, -20) & 0x00000008) != 0;
        }

        public void SetPinned(bool value)
        {
            windows[0].Dispatcher.VerifyAccess();
            if (disposed) return;
            bool changed = !configured || pinned != value;
            pinned = value;
            configured = true;
            // Pinning applies only to the floating window and captions. Settings
            // are an independent normal window, including at native HWND level.
            Apply(changed, true);
            UpdateTimer();
        }

        private void Apply(bool raiseVisible, bool includeHidden)
        {
            if (disposed || !configured || applying) return;
            applying = true;
            var errors = new List<string>();
            try
            {
                // A topmost owner propagates native topmost to its owned windows
                // even if their WPF Topmost property is false. Keep settings
                // independent before applying the floating/caption preference.
                Window settings = windows[2];
                if (Live(settings) && settings.Owner != null)
                {
                    try { settings.Owner = null; }
                    catch (Exception error) { errors.Add(error.Message); }
                }
                foreach (Window window in windows)
                {
                    if (!Live(window) || (!includeHidden && !Visible(window))) continue;
                    bool desired = DesiredTopmost(window);
                    try { if (window.Topmost != desired) window.Topmost = desired; }
                    catch (Exception error) { errors.Add(error.Message); }
                }
                foreach (Window window in windows)
                {
                    if (!Live(window) || (!includeHidden && !Visible(window))) continue;
                    try
                    {
                        IntPtr handle = OwnedHandle(window);
                        if (handle == IntPtr.Zero) continue;
                        bool desired = DesiredTopmost(window);
                        bool needsChange = NativeTopmost(handle) != desired;
                        if (!needsChange && !(desired && raiseVisible && Visible(window))) continue;
                        if (!SetWindowPos(handle, new IntPtr(desired ? -1 : -2), 0, 0, 0, 0, PositionFlags))
                            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                        nativeUpdates++;
                    }
                    catch (Exception error) { errors.Add(error.Message); }
                }
                lastError = String.Join("; ", errors.ToArray());
            }
            finally { applying = false; }
        }

        // One bounded lift on a change to another process's foreground window.
        // An unchanged foreground does not repeatedly compete with another
        // topmost app, Windows UI, or this app's settings/context menus.
        public void Refresh()
        {
            windows[0].Dispatcher.VerifyAccess();
            if (disposed || !configured || !pinned || !AnyPinnedVisible()) { UpdateTimer(); return; }
            checks++;
            if (menu != null && menu.IsOpen) return;
            try
            {
                TopmostForeground current = foregroundReader();
                bool changed = current != null && (lastForeground == null || current.Handle != lastForeground.Handle || current.ProcessId != lastForeground.ProcessId);
                bool foreign = current != null && current.Handle != IntPtr.Zero && current.ProcessId != 0 && current.ProcessId != processId;
                lastForeground = current;
                if (changed && foreign) foregroundRepairs++;
                Apply(changed && foreign, false);
            }
            catch (Exception error) { lastError = error.Message; }
        }

        private void UpdateTimer()
        {
            if (!disposed && configured && pinned && AnyPinnedVisible()) timer.Start();
            else timer.Stop();
        }
        private void OnTick(object sender, EventArgs args) { Refresh(); }
        private void OnSourceInitialized(object sender, EventArgs args) { Apply(sender != windows[2], true); UpdateTimer(); }
        private void OnVisibilityChanged(object sender, DependencyPropertyChangedEventArgs args)
        {
            if (menu == null || !menu.IsOpen) Apply(sender != windows[2] && (bool)args.NewValue, true);
            UpdateTimer();
        }
        private void OnStateChanged(object sender, EventArgs args)
        {
            if (menu == null || !menu.IsOpen) Apply(sender != windows[2] && Visible(sender as Window), true);
            UpdateTimer();
        }
        private void OnMenuClosed(object sender, RoutedEventArgs args) { Refresh(); }
        private void OnClosed(object sender, EventArgs args)
        {
            Window window = sender as Window;
            closed.Add(window);
            if (window == windows[0]) Dispose();
            else UpdateTimer();
        }

        public DesktopTopmostStatus GetStatus()
        {
            windows[0].Dispatcher.VerifyAccess();
            var details = new List<TopmostWindowStatus>();
            for (int index = 0; index < windows.Length; index++)
            {
                Window window = windows[index];
                IntPtr handle = OwnedHandle(window);
                details.Add(new TopmostWindowStatus { Role = roles[index], Visible = Visible(window),
                    ManagedTopmost = Live(window) && window.Topmost, NativeTopmost = NativeTopmost(handle), HasHandle = handle != IntPtr.Zero });
            }
            return new DesktopTopmostStatus { Pinned = pinned, TimerRunning = timer.IsEnabled, Disposed = disposed,
                NativeUpdates = nativeUpdates, ForegroundRepairs = foregroundRepairs, Checks = checks,
                LastError = lastError, Windows = details.ToArray() };
        }

        public void Dispose()
        {
            windows[0].Dispatcher.VerifyAccess();
            if (disposed) return;
            disposed = true;
            timer.Stop();
            timer.Tick -= OnTick;
            if (menu != null) menu.Closed -= OnMenuClosed;
            foreach (Window window in windows)
            {
                if (window == null) continue;
                window.SourceInitialized -= OnSourceInitialized;
                window.IsVisibleChanged -= OnVisibilityChanged;
                window.StateChanged -= OnStateChanged;
                window.Closed -= OnClosed;
            }
        }
    }
}
