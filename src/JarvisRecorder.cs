using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

// Local microphone capture with waveIn. Poll properties from the UI; no PS callbacks.
public sealed class JarvisRecorder : IDisposable
{
    [StructLayout(LayoutKind.Sequential, Pack=2)]
    private struct WaveFormat
    {
        public ushort FormatTag, Channels;
        public uint SamplesPerSec, AvgBytesPerSec;
        public ushort BlockAlign, BitsPerSample, ExtraSize;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct WaveHeader
    {
        public IntPtr Data;
        public uint BufferLength, BytesRecorded;
        public UIntPtr User;
        public uint Flags, Loops;
        public IntPtr Next;
        public UIntPtr Reserved;
    }
    [DllImport("winmm.dll")] private static extern uint waveInOpen(out IntPtr h, uint id, ref WaveFormat format, IntPtr callback, IntPtr instance, uint flags);
    [DllImport("winmm.dll")] private static extern uint waveInPrepareHeader(IntPtr h, IntPtr header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveInUnprepareHeader(IntPtr h, IntPtr header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveInAddBuffer(IntPtr h, IntPtr header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveInStart(IntPtr h);
    [DllImport("winmm.dll")] private static extern uint waveInStop(IntPtr h);
    [DllImport("winmm.dll")] private static extern uint waveInReset(IntPtr h);
    [DllImport("winmm.dll")] private static extern uint waveInClose(IntPtr h);
    [DllImport("winmm.dll", CharSet=CharSet.Unicode)] private static extern uint waveInGetErrorText(uint code, System.Text.StringBuilder text, uint size);
    private const uint HeaderDone = 1;
    private const uint HeaderPrepared = 2;
    private const int BufferSize = 1280; // 40 ms, 16kHz mono s16le
    private readonly object gate = new object();
    private readonly ManualResetEvent completed = new ManualResetEvent(true);
    private readonly List<IntPtr> headers = new List<IntPtr>();
    private readonly List<IntPtr> buffers = new List<IntPtr>();
    private Thread thread;
    private bool recording, stopping, stopRequested, cancelled, disposed;
    private int level;
    private int nextHeaderIndex;
    private DateTime lastVoiceUtc = DateTime.MinValue, startedUtc = DateTime.MinValue;
    private string lastFile = "", requestedFile = "", error = "";

    public bool IsRecording { get { lock (gate) return recording; } }
    public bool IsStopping { get { lock (gate) return stopping; } }
    public int Level { get { lock (gate) return level; } }
    public int AudioLevel { get { lock (gate) return level; } }
    public DateTime LastVoiceUtc { get { lock (gate) return lastVoiceUtc; } }
    public DateTime StartedUtc { get { lock (gate) return startedUtc; } }
    public string LastFile { get { lock (gate) return lastFile; } }
    public string Error { get { lock (gate) return error; } }

    public void Start()
    {
        lock (gate)
        {
            if (disposed) throw new ObjectDisposedException("JarvisRecorder");
            if (recording || stopping) throw new InvalidOperationException("Recording is already active.");
            recording = true; stopping = false; stopRequested = false; cancelled = false;
            level = 0; nextHeaderIndex = 0; lastVoiceUtc = DateTime.MinValue; startedUtc = DateTime.UtcNow;
            lastFile = ""; requestedFile = ""; error = ""; completed.Reset();
            thread = new Thread(CaptureLoop); thread.IsBackground = true;
            thread.Name = "Jarvis microphone"; thread.Start();
        }
    }

    public void StopToFileAsync(string path)
    {
        if (String.IsNullOrWhiteSpace(path)) throw new ArgumentException("A WAV path is required.", "path");
        string absolutePath = Path.GetFullPath(path);
        lock (gate)
        {
            if (!recording || stopping) return;
            requestedFile = absolutePath; stopping = true; stopRequested = true;
        }
    }
    public void StopToFile(string path)
    {
        StopToFileAsync(path);
        if (!completed.WaitOne(5000)) throw new TimeoutException("Microphone did not stop within 5 seconds.");
        if (Error.Length != 0) throw new InvalidOperationException(Error);
    }
    public void Cancel()
    {
        lock (gate)
        {
            if (!recording) return;
            cancelled = true; requestedFile = ""; stopping = true; stopRequested = true;
        }
    }
    private bool ShouldStop { get { lock (gate) return stopRequested; } }
    private void Check(uint code)
    {
        if (code == 0) return;
        System.Text.StringBuilder msg = new System.Text.StringBuilder(256);
        waveInGetErrorText(code,msg,256);
        throw new InvalidOperationException("Microphone: " + msg.ToString() + " (" + code + ")");
    }

    private void CaptureLoop()
    {
        IntPtr device = IntPtr.Zero;
        uint headerSize = (uint)Marshal.SizeOf(typeof(WaveHeader));
        using (AutoResetEvent ready = new AutoResetEvent(false))
        using (MemoryStream pcm = new MemoryStream())
        {
            try
            {
                WaveFormat format = new WaveFormat { FormatTag=1, Channels=1, SamplesPerSec=16000,
                    AvgBytesPerSec=32000, BlockAlign=2, BitsPerSample=16, ExtraSize=0 };
                Check(waveInOpen(out device, UInt32.MaxValue, ref format, ready.SafeWaitHandle.DangerousGetHandle(), IntPtr.Zero, 0x00050000));
                for (int i=0; i<8; i++)
                {
                    IntPtr buffer=Marshal.AllocHGlobal(BufferSize); buffers.Add(buffer);
                    IntPtr header=Marshal.AllocHGlobal((int)headerSize); headers.Add(header);
                    Marshal.StructureToPtr(new WaveHeader { Data=buffer, BufferLength=BufferSize },header,false);
                    Check(waveInPrepareHeader(device,header,headerSize));
                    Check(waveInAddBuffer(device,header,headerSize));
                }
                Check(waveInStart(device));
                while (!ShouldStop)
                {
                    ready.WaitOne(80);
                    Drain(device,pcm,headerSize,true);
                }
                Check(waveInStop(device));
                Check(waveInReset(device));
                Drain(device,pcm,headerSize,false);
            }
            catch (Exception ex) { lock(gate) error = ex.Message; }
            finally
            {
                if (device != IntPtr.Zero)
                {
                    waveInReset(device);
                    foreach (IntPtr h in headers) waveInUnprepareHeader(device,h,headerSize);
                    waveInClose(device);
                }
                foreach (IntPtr h in headers) Marshal.FreeHGlobal(h);
                foreach (IntPtr b in buffers) Marshal.FreeHGlobal(b);
                headers.Clear(); buffers.Clear();
            }
            try
            {
                string path;
                lock(gate) path = cancelled || error.Length != 0 ? "" : requestedFile;
                if (path.Length != 0)
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(path));
                    using (BinaryWriter writer = new BinaryWriter(File.Create(path)))
                    {
                        writer.Write(System.Text.Encoding.ASCII.GetBytes("RIFF")); writer.Write((uint)(36+pcm.Length));
                        writer.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt ")); writer.Write((uint)16);
                        writer.Write((ushort)1); writer.Write((ushort)1); writer.Write((uint)16000); writer.Write((uint)32000);
                        writer.Write((ushort)2); writer.Write((ushort)16); writer.Write(System.Text.Encoding.ASCII.GetBytes("data"));
                        writer.Write((uint)pcm.Length); pcm.Position=0; pcm.CopyTo(writer.BaseStream);
                    }
                    lock(gate) lastFile=path;
                }
            }
            catch (Exception ex) { lock(gate) error = ex.Message; }
            lock(gate) { recording=false; stopping=false; level=0; completed.Set(); }
        }
    }

    private void Drain(IntPtr device, MemoryStream pcm, uint headerSize, bool requeue)
    {
        for (int drained=0; drained<headers.Count; drained++)
        {
            IntPtr pointer=headers[nextHeaderIndex];
            WaveHeader header = (WaveHeader)Marshal.PtrToStructure(pointer, typeof(WaveHeader));
            if ((header.Flags & HeaderDone) == 0) break;
            int length = (int)header.BytesRecorded;
            if (length > 0)
            {
                byte[] bytes = new byte[length]; Marshal.Copy(header.Data,bytes,0,length); pcm.Write(bytes,0,length);
                double squared=0;
                for (int i=0; i+1<length; i+=2) { double sample=(short)(bytes[i] | (bytes[i+1]<<8))/32768.0; squared+=sample*sample; }
                double rms=Math.Sqrt(squared/Math.Max(1,length/2));
                int nextLevel = (int)Math.Round(Math.Max(0,Math.Min(100,(20*Math.Log10(rms+1e-8)+60)*100/60)));
                lock(gate)
                {
                    level=nextLevel;
                    // Activity only: UI may opt into silence-to-send; this is not semantic VAD.
                    if (rms > 0.012) lastVoiceUtc=DateTime.UtcNow;
                }
            }
            header.BytesRecorded=0; Marshal.StructureToPtr(header,pointer,false);
            nextHeaderIndex=(nextHeaderIndex+1)%headers.Count;
            if (requeue && !ShouldStop)
            {
                Check(waveInAddBuffer(device,pointer,headerSize));
            }
        }
    }
    public void Dispose()
    {
        lock(gate) { if(disposed) return; disposed=true; }
        Cancel(); completed.WaitOne(2500);
    }
}
