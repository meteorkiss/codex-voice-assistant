using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace CodexReader.Audio {
    // Metadata only. The injectable owner view keeps liveness policy testable
    // without opening capture endpoints or changing another process's session.
    internal interface ICaptureProcessOwner : IDisposable {
        bool HasExited { get; }
        string ProcessName { get; }
    }

    // Reads capture-session metadata only; never creates an audio client or reads samples.
    public sealed class CaptureSession {
        public string DeviceId { get; set; }
        public string SessionId { get; set; }
        public int ProcessId { get; set; }
        public string ProcessName { get; set; }
        public int State { get; set; }
        public bool Active { get { return State == 1; } }
    }

    public sealed class MicGuard : IDisposable {
        private readonly object gate = new object();
        private readonly List<Endpoint> endpoints = new List<Endpoint>();
        private readonly ManualResetEvent wake = new ManualResetEvent(false);
        private Thread thread;
        private volatile bool stopping;
        private volatile bool active;
        private volatile bool codexActive;
        private volatile bool ready;
        private string lastError = "";
        private string defaultCaptureEndpointId = "";
        private string defaultRenderEndpointId = "";
        private long defaultEndpointTimestamp;
        private CaptureSession[] snapshot = new CaptureSession[0];
        private long activationVersion;
        private long stateVersion;
        private long scanCount;
        private int intervalMs;
        private IntPtr notifyWindow;
        public const int NotificationMessage = 0x8000 + 433;
        [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hwnd, int msg, IntPtr wp, IntPtr lp);
        public bool AnyCaptureActive { get { return active; } }
        public bool CodexCaptureActive { get { return codexActive; } }
        public bool Ready { get { return ready; } }
        // Consumers compare this monotonic value, so even short sessions are not missed.
        public long ActivationVersion { get { return Interlocked.Read(ref activationVersion); } }
        public long StateVersion { get { return Interlocked.Read(ref stateVersion); } }
        public long ScanCount { get { return Interlocked.Read(ref scanCount); } }
        public string LastError { get { lock (gate) return lastError; } }
        // Cached metadata only: UI health checks never enumerate COM devices.
        public string DefaultCaptureEndpointId { get { lock (gate) return defaultCaptureEndpointId; } }
        public string DefaultRenderEndpointId { get { lock (gate) return defaultRenderEndpointId; } }
        public long DefaultEndpointAgeMs {
            get {
                long stamp = Interlocked.Read(ref defaultEndpointTimestamp);
                return stamp == 0 ? -1 : (long)((Stopwatch.GetTimestamp() - stamp) * 1000.0 / Stopwatch.Frequency);
            }
        }
        public CaptureSession[] Sessions { get { lock (gate) return (CaptureSession[])snapshot.Clone(); } }
        public MicGuard() { }
        private sealed class NativeCaptureProcessOwner : ICaptureProcessOwner {
            private readonly Process process;
            internal NativeCaptureProcessOwner(Process value) { process = value; }
            public bool HasExited { get { return process.HasExited; } }
            public string ProcessName { get { return process.ProcessName; } }
            public void Dispose() { process.Dispose(); }
        }
        internal static bool TryGetCaptureOwnerName(int processId, out string name) {
            return TryGetCaptureOwnerName(processId, delegate(int id) {
                return new NativeCaptureProcessOwner(Process.GetProcessById(id));
            }, out name);
        }
        // False means positively known to have exited, never merely inaccessible.
        // Recheck on every scan: endpoint sessions can outlive a process, and a
        // PID may later be reused by a different live owner.
        internal static bool TryGetCaptureOwnerName(int processId, Func<int, ICaptureProcessOwner> open, out string name) {
            name = processId == 0 ? "System" : "Unknown";
            if (processId <= 0) return true;
            ICaptureProcessOwner owner;
            try { owner = open(processId); }
            catch (ArgumentException) { return false; } // GetProcessById: no such positive PID.
            catch { return true; }
            if (owner == null) return true;
            try {
                if (owner.HasExited) return false;
                string current = owner.ProcessName;
                if (!String.IsNullOrEmpty(current)) name = current;
                return true;
            } catch { return true; }
            finally { try { owner.Dispose(); } catch { } }
        }
        public void Start() { Start(25, IntPtr.Zero); }
        public void Start(int pollIntervalMs, IntPtr windowHandle) {
            if (thread != null) throw new InvalidOperationException("Already started.");
            intervalMs = Math.Max(15, Math.Min(1000, pollIntervalMs));
            notifyWindow = windowHandle;
            thread = new Thread(Run);
            thread.IsBackground = true;
            thread.Name = "Codex capture-session guard";
            thread.SetApartmentState(ApartmentState.MTA);
            thread.Start();
        }
        private void Run() {
            IMMDeviceEnumerator devices = null;
            try {
                // Avoid binding the shared COM identity to our imported coclass: NAudio
                // also activates this CLSID and its concrete RCW cast would otherwise fail.
                devices = (IMMDeviceEnumerator)CreatePrivateComObject(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"));
                long nextRefresh = 0;
                Stopwatch clock = Stopwatch.StartNew();
                while (!stopping) {
                    try {
                        if (clock.ElapsedMilliseconds >= nextRefresh) {
                            RefreshDefaultEndpoints(devices);
                            RefreshEndpoints(devices);
                            nextRefresh = clock.ElapsedMilliseconds + 1000;
                        }
                        Poll();
                        ready = true;
                        Interlocked.Increment(ref scanCount);
                        lock (gate) lastError = "";
                    } catch (Exception e) { lock (gate) lastError = e.GetType().Name + ": " + e.Message; }
                    wake.WaitOne(intervalMs);
                    wake.Reset();
                }
            } catch (Exception e) { lock (gate) lastError = e.GetType().Name + ": " + e.Message; }
            finally {
                foreach (Endpoint ep in endpoints) ep.Dispose();
                endpoints.Clear();
                Release(devices);
                ready = false;
            }
        }
        private static string ReadDefaultEndpointId(IMMDeviceEnumerator devices, int flow, int role) {
            IMMDevice device = null;
            try {
                if (devices.GetDefaultAudioEndpoint(flow, role, out device) < 0 || device == null) return "";
                string id;
                return device.GetId(out id) >= 0 ? id ?? "" : "";
            } catch { return ""; }
            finally { Release(device); }
        }
        private void RefreshDefaultEndpoints(IMMDeviceEnumerator devices) {
            string capture = ReadDefaultEndpointId(devices, 1, 2); // capture / communications
            string render = ReadDefaultEndpointId(devices, 0, 1); // render / multimedia
            lock (gate) {
                defaultCaptureEndpointId = capture;
                defaultRenderEndpointId = render;
                Interlocked.Exchange(ref defaultEndpointTimestamp, Stopwatch.GetTimestamp());
            }
        }
        private void RefreshEndpoints(IMMDeviceEnumerator devices) {
            IMMDeviceCollection collection = null;
            var present = new HashSet<string>(StringComparer.Ordinal);
            try {
                Check(devices.EnumAudioEndpoints(1, 1, out collection)); // capture, DEVICE_STATE_ACTIVE
                uint count; Check(collection.GetCount(out count));
                for (uint i = 0; i < count; i++) {
                    IMMDevice device = null;
                    try {
                        Check(collection.Item(i, out device));
                        string id; Check(device.GetId(out id)); present.Add(id);
                        Endpoint ep = endpoints.Find(delegate(Endpoint e) { return e.Id == id; });
                        if (ep == null) {
                            object manager = null;
                            Guid iid = typeof(IAudioSessionManager2).GUID;
                            Check(device.Activate(ref iid, 23, IntPtr.Zero, out manager));
                            ep = new Endpoint(id, (IAudioSessionManager2)manager, wake);
                            endpoints.Add(ep);
                        }
                        ep.RefreshSessions();
                    } finally { Release(device); }
                }
                for (int i = endpoints.Count - 1; i >= 0; i--) {
                    if (!present.Contains(endpoints[i].Id)) { endpoints[i].Dispose(); endpoints.RemoveAt(i); }
                }
            } finally { Release(collection); }
        }
        private void Poll() {
            var items = new List<CaptureSession>();
            foreach (Endpoint ep in endpoints) ep.Read(items);
            bool nextActive = false, nextCodex = false;
            foreach (CaptureSession item in items) {
                if (!item.Active) continue;
                nextActive = true;
                if (String.Equals(item.ProcessName, "ChatGPT", StringComparison.OrdinalIgnoreCase) ||
                    String.Equals(item.ProcessName, "Codex", StringComparison.OrdinalIgnoreCase)) nextCodex = true;
            }
            bool changed = nextActive != active || nextCodex != codexActive;
            if (nextActive && !active) Interlocked.Increment(ref activationVersion);
            active = nextActive;
            codexActive = nextCodex;
            lock (gate) snapshot = items.ToArray();
            if (changed) {
                Interlocked.Increment(ref stateVersion);
            }
            // Never call MCI from this worker: MCI aliases may belong to their opening thread.
            // A window can stop its own player upon this message; normal UI polling also works.
            if ((changed || active) && notifyWindow != IntPtr.Zero)
                PostMessage(notifyWindow, NotificationMessage, new IntPtr(active ? 1 : 0), IntPtr.Zero);
        }
        public void Dispose() {
            stopping = true; wake.Set();
            if (thread != null && Thread.CurrentThread != thread) thread.Join(2000);
            // If a driver stalls inside COM, retain the event until process exit.
            if (thread == null || !thread.IsAlive) wake.Dispose();
        }
        internal static void Check(int hr) { if (hr < 0) Marshal.ThrowExceptionForHR(hr); }
        internal static void Release(object value) { if (value != null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value); }
        private static object CreatePrivateComObject(Guid clsid) {
            object shared=Activator.CreateInstance(Type.GetTypeFromCLSID(clsid));
            IntPtr unknown=IntPtr.Zero;
            try { unknown=Marshal.GetIUnknownForObject(shared); return Marshal.GetUniqueObjectForIUnknown(unknown); }
            finally { if(unknown!=IntPtr.Zero) Marshal.Release(unknown); Release(shared); }
        }

        private sealed class Endpoint : IAudioSessionNotification, IDisposable {
            public string Id;
            private readonly IAudioSessionManager2 manager;
            private readonly ManualResetEvent wake;
            private readonly object gate = new object();
            private readonly Dictionary<string, IAudioSessionControl2> sessions = new Dictionary<string, IAudioSessionControl2>();
            private bool disposed;
            public Endpoint(string id, IAudioSessionManager2 mgr, ManualResetEvent signal) {
                Id = id; manager = mgr; wake = signal;
                Check(manager.RegisterSessionNotification(this));
            }
            public int OnSessionCreated(IAudioSessionControl session) {
                try { Add(session); wake.Set(); } catch { }
                return 0;
            }
            private void Add(IAudioSessionControl raw) {
                IAudioSessionControl2 session = raw as IAudioSessionControl2;
                if (session == null) { Release(raw); return; }
                string key;
                if (session.GetSessionInstanceIdentifier(out key) < 0 || key == null) { Release(raw); return; }
                lock (gate) {
                    if (disposed || sessions.ContainsKey(key)) { Release(raw); return; }
                    sessions.Add(key, session);
                }
            }
            public void RefreshSessions() {
                IAudioSessionEnumerator enumerator = null;
                try {
                    Check(manager.GetSessionEnumerator(out enumerator));
                    int count; Check(enumerator.GetCount(out count));
                    for (int i = 0; i < count; i++) {
                        IAudioSessionControl control;
                        if (enumerator.GetSession(i, out control) >= 0) Add(control);
                    }
                } finally { Release(enumerator); }
            }
            public void Read(List<CaptureSession> output) {
                lock (gate) {
                    var expired = new List<string>();
                    foreach (KeyValuePair<string, IAudioSessionControl2> pair in sessions) {
                        int state; uint process;
                        if (pair.Value.GetState(out state) < 0 || state == 2) { expired.Add(pair.Key); continue; }
                        if (pair.Value.GetProcessId(out process) < 0) process = 0;
                        int processId = unchecked((int)process);
                        string name;
                        if (!TryGetCaptureOwnerName(processId, out name)) continue;
                        output.Add(new CaptureSession { DeviceId = Id, SessionId = pair.Key, ProcessId = processId, ProcessName = name, State = state });
                    }
                    foreach (string key in expired) { Release(sessions[key]); sessions.Remove(key); }
                }
            }
            public void Dispose() {
                lock (gate) {
                    disposed = true;
                    foreach (IAudioSessionControl2 value in sessions.Values) Release(value);
                    sessions.Clear();
                }
                manager.UnregisterSessionNotification(this);
                Release(manager);
            }
        }
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] internal class MMDeviceEnumerator { }
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int flow, uint mask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }
    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceCollection {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index, out IMMDevice device);
    }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, uint context, IntPtr activation, [MarshalAs(UnmanagedType.IUnknown)] out object obj);
        [PreserveSig] int OpenPropertyStore(uint access, out IntPtr store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out uint state);
    }
    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionManager2 {
        [PreserveSig] int GetAudioSessionControl(IntPtr sessionGuid, uint flags, out IntPtr control);
        [PreserveSig] int GetSimpleAudioVolume(IntPtr sessionGuid, uint flags, out IntPtr volume);
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator enumerator);
        [PreserveSig] int RegisterSessionNotification(IAudioSessionNotification client);
        [PreserveSig] int UnregisterSessionNotification(IAudioSessionNotification client);
        [PreserveSig] int RegisterDuckNotification([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr client);
        [PreserveSig] int UnregisterDuckNotification(IntPtr client);
    }
    [Guid("641DD20B-4D41-49CC-ABA3-174B9477BB08"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionNotification {
        [PreserveSig] int OnSessionCreated(IAudioSessionControl control);
    }
    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionEnumerator {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index, out IAudioSessionControl session);
    }
    [ComImport, Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionControl {
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        [PreserveSig] int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr context);
        [PreserveSig] int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string path);
        [PreserveSig] int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string path, IntPtr context);
        [PreserveSig] int GetGroupingParam(out Guid grouping);
        [PreserveSig] int SetGroupingParam(ref Guid grouping, IntPtr context);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr client);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr client);
    }
    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionControl2 {
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        [PreserveSig] int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr context);
        [PreserveSig] int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string path);
        [PreserveSig] int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string path, IntPtr context);
        [PreserveSig] int GetGroupingParam(out Guid grouping);
        [PreserveSig] int SetGroupingParam(ref Guid grouping, IntPtr context);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr client);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr client);
        [PreserveSig] int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetProcessId(out uint pid);
        [PreserveSig] int IsSystemSoundsSession();
        [PreserveSig] int SetDuckingPreference([MarshalAs(UnmanagedType.Bool)] bool optOut);
    }
}
