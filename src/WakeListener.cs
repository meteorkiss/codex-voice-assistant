using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

// Local one-shot keyword spotting: waveIn -> in-memory pipe -> local Python.
// Legacy mode is half-duplex. Echo mode uses an explicitly bound speaker reference
// and keeps microphone capture alive across wake -> acknowledgement -> question.
public sealed class WakeListener : IDisposable
{
    [StructLayout(LayoutKind.Sequential, Pack=2)]
    private struct WaveFormat { public ushort FormatTag,Channels; public uint SamplesPerSec,AvgBytesPerSec; public ushort BlockAlign,BitsPerSample,ExtraSize; }
    [StructLayout(LayoutKind.Sequential)]
    private struct WaveHeader { public IntPtr Data; public uint BufferLength,BytesRecorded; public UIntPtr User; public uint Flags,Loops; public IntPtr Next; public UIntPtr Reserved; }
    [DllImport("winmm.dll")] private static extern uint waveInOpen(out IntPtr h,uint id,ref WaveFormat f,IntPtr callback,IntPtr instance,uint flags);
    [DllImport("winmm.dll")] private static extern uint waveInPrepareHeader(IntPtr h,IntPtr p,uint size);
    [DllImport("winmm.dll")] private static extern uint waveInUnprepareHeader(IntPtr h,IntPtr p,uint size);
    [DllImport("winmm.dll")] private static extern uint waveInAddBuffer(IntPtr h,IntPtr p,uint size);
    [DllImport("winmm.dll")] private static extern uint waveInStart(IntPtr h);
    [DllImport("winmm.dll")] private static extern uint waveInStop(IntPtr h);
    [DllImport("winmm.dll")] private static extern uint waveInReset(IntPtr h);
    [DllImport("winmm.dll")] private static extern uint waveInClose(IntPtr h);
    [DllImport("winmm.dll",CharSet=CharSet.Unicode)] private static extern uint waveInGetErrorText(uint code,StringBuilder text,uint size);
    private const int BufferSize=1280;
    public sealed class Snapshot
    {
        public bool IsListening { get; set; }
        public bool IsStopping { get; set; }
        public bool IsReady { get; set; }
        public long ActivationVersion { get; set; }
        public string LastKeyword { get; set; }
        public float Confidence { get; set; }
        public bool ConfidenceAvailable { get; set; }
        public float KeywordThreshold { get; set; }
        public string Error { get; set; }
        public int AudioLevel { get; set; }
        public DateTime ActivatedUtc { get; set; }
        public bool FullDuplexReady { get; set; }
        public bool HasQuestion { get; set; }
    }
    public sealed class HealthSnapshot
    {
        public string State { get; set; }
        public bool NeedsRecovery { get; set; }
        public string Reason { get; set; }
        public long CapturedSamples { get; set; }
        public long ProcessedSamples { get; set; }
        public long CaptureAgeMs { get; set; }
        public long ProgressAgeMs { get; set; }
        public bool HasActivated { get; set; }
    }
    private readonly object gate=new object();
    private readonly ManualResetEvent completed=new ManualResetEvent(true),workerReady=new ManualResetEvent(false);
    private bool listening,stopping,stopRequested,ready,disposed;
    private string python="",workerPath="",modelDir="",phrase="",normalizedPhrase="",lastKeyword="",error="";
    private float threshold=0.35f;
    private long activationVersion,runVersion;
    private int audioLevel;
    private DateTime activatedUtc=DateTime.MinValue;
    private Thread thread;
    private bool echoMode,echoDetected,questionTaken;
    private string echoCaptureId="",echoRenderId="";
    private EchoCapture echoCapture;
    private long capturedSamples,ringStartSample,keywordEndSample;
    private readonly Queue<byte[]> echoPending=new Queue<byte[]>();
    private readonly List<byte> ring=new List<byte>();
    private QuestionRecorder question;
    private bool fixtureInputComplete;
    private bool fixtureMode,hasActivated,recoveryStopQueued;
    private long runStartedTicks,lastCaptureTicks,lastProgressTicks,submittedSamples,processedSamples;
    private string healthError="";
    private Process ownedWorker;
    private long ownedWorkerRun;

    public WakeListener() { }
    public WakeListener(string pythonExe,string workerScript,string models) { Configure(pythonExe,workerScript,models); }
    public void Configure(string pythonExe,string workerScript,string models)
    {
        lock(gate)
        {
            if(disposed) throw new ObjectDisposedException("WakeListener");
            if(listening || stopping) throw new InvalidOperationException("Stop wake listening before reconfiguring.");
            python=Path.GetFullPath(pythonExe); workerPath=Path.GetFullPath(workerScript); modelDir=Path.GetFullPath(models);
            if(!File.Exists(python) || !File.Exists(workerPath) || !Directory.Exists(modelDir)) throw new FileNotFoundException("The local wake runtime or model directory is missing.");
        }
    }
    public float KeywordThreshold
    {
        get { lock(gate) return threshold; }
        set { if(value<=0 || value>=1 || Single.IsNaN(value)) throw new ArgumentOutOfRangeException("value"); lock(gate) threshold=value; }
    }
    // The model exposes a threshold, but no per-detection probability.
    public float MinimumConfidence { get { return KeywordThreshold; } set { KeywordThreshold=value; } }
    public bool IsListening { get { lock(gate) return listening; } }
    public bool IsStopping { get { lock(gate) return stopping; } }
    public bool IsReady { get { lock(gate) return ReadyLocked(Stopwatch.GetTimestamp()); } }
    public long ActivationVersion { get { lock(gate) return activationVersion; } }
    public string LastKeyword { get { lock(gate) return lastKeyword; } }
    public float Confidence { get { return Single.NaN; } }
    public bool ConfidenceAvailable { get { return false; } }
    public string Error { get { lock(gate) return error; } }
    public int AudioLevel { get { lock(gate) return audioLevel; } }
    public bool FullDuplexReady { get { lock(gate) return echoMode && !fixtureMode && echoCapture!=null && ReadyLocked(Stopwatch.GetTimestamp()); } }
    public string CaptureEndpointId { get { lock(gate) return echoMode ? echoCaptureId : ""; } }
    public string RenderEndpointId { get { lock(gate) return echoMode ? echoRenderId : ""; } }
    public bool HasQuestion { get { lock(gate) return listening && question!=null && !questionTaken && echoDetected && !stopping; } }
    public bool FixtureInputComplete { get { lock(gate) return fixtureInputComplete; } }
    public QuestionRecorder TakeQuestionRecorder()
    {
        lock(gate) { if(!HasQuestion) return null; questionTaken=true; return question; }
    }
    public void Start() { Start("你好，声伴"); }
    public void Start(string wakePhrase) { Begin(wakePhrase,null); }
    public void StartEcho(string wakePhrase,string captureId,string renderId) { Begin(wakePhrase,null,true,captureId,renderId); }
    // Feeds already-processed fixture audio at real-time speed, without opening any device.
    // This test entry point deliberately never advertises FullDuplexReady.
    public void StartProcessedWaveForTest(string wakePhrase,byte[] wav) { Begin(wakePhrase,ReadPcmWave(wav),true); }
    public void StartWaveFile(string wakePhrase,string path) { StartWaveBytes(wakePhrase,File.ReadAllBytes(path)); }
    public void StartWaveBytes(string wakePhrase,byte[] wav)
    {
        if(wav==null) throw new ArgumentNullException("wav");
        Begin(wakePhrase,ReadPcmWave(wav));
    }
    private void Begin(string wakePhrase,byte[] pcm,bool useEcho=false,string captureId=null,string renderId=null)
    {
        string normalized=NormalizePhrase(wakePhrase);
        if(normalized.Length<2 || normalized.Length>16) throw new ArgumentException("Use 2 to 16 Chinese characters.","wakePhrase");
        lock(gate)
        {
            if(disposed) throw new ObjectDisposedException("WakeListener");
            if(listening || stopping) throw new InvalidOperationException("Wake listener is already active.");
            if(python.Length==0) throw new InvalidOperationException("Call Configure before Start.");
            phrase=wakePhrase; normalizedPhrase=normalized; lastKeyword=""; error="";
            listening=true; stopping=false; stopRequested=false; ready=false; audioLevel=0;
            echoMode=useEcho; echoCaptureId=captureId ?? ""; echoRenderId=renderId ?? ""; echoDetected=false; questionTaken=false;
            echoCapture=null; capturedSamples=0; ringStartSample=0; keywordEndSample=0; ring.Clear(); echoPending.Clear(); question=null; fixtureInputComplete=false;
            fixtureMode=pcm!=null; hasActivated=false; recoveryStopQueued=false; healthError="";
            runStartedTicks=Stopwatch.GetTimestamp(); lastCaptureTicks=0; lastProgressTicks=0; submittedSamples=0; processedSamples=0;
            completed.Reset(); workerReady.Reset(); long run=++runVersion;
            thread=new Thread(delegate() { Run(pcm,run); }); thread.IsBackground=true; thread.Name="Local wake listener"; thread.Start();
        }
    }
    public void Stop() { lock(gate) { if(!listening || stopping) return; stopping=true; stopRequested=true; ready=false; } }
    public void Cancel() { Stop(); }
    public bool StopAndWait(int ms) { Stop(); return completed.WaitOne(Math.Max(0,ms)); }
    // Recovery is a stop request, never a second capture. Kill only the saved
    // worker object for this generation, outside gate and off the UI thread.
    // This releases a blocked stdin write without claiming the device is closed.
    public void RequestRecoveryStop()
    {
        Process target; long run;
        lock(gate)
        {
            if(!listening) return;
            HealthSnapshot health=HealthLocked(Stopwatch.GetTimestamp());
            if(health.NeedsRecovery)
            {
                healthError=health.Reason;
                if(error.Length==0) error="Local wake listening requires recovery: "+health.Reason+".";
            }
            ready=false; stopping=true; stopRequested=true;
            if(recoveryStopQueued) return;
            recoveryStopQueued=true; target=ownedWorker; run=runVersion;
        }
        if(target==null) return;
        ThreadPool.QueueUserWorkItem(delegate(object ignored)
        {
            lock(gate) { if(run!=runVersion || ownedWorkerRun!=run || !Object.ReferenceEquals(ownedWorker,target)) return; }
            try { target.Kill(); } catch(InvalidOperationException) { } catch(System.ComponentModel.Win32Exception) { }
        });
    }
    private static long AgeMs(long now,long then)
    {
        return then==0 ? -1 : Math.Max(0,(long)((now-then)*1000.0/Stopwatch.Frequency));
    }
    private HealthSnapshot HealthLocked(long now)
    {
        HealthSnapshot value=new HealthSnapshot { State="idle",Reason="",CapturedSamples=capturedSamples,ProcessedSamples=processedSamples,
            CaptureAgeMs=AgeMs(now,lastCaptureTicks),ProgressAgeMs=AgeMs(now,lastProgressTicks),HasActivated=hasActivated };
        if(stopping) { value.State="stopping"; value.Reason=healthError; return value; }
        if(error.Length>0 || healthError.Length>0)
        { value.State="error"; value.Reason=healthError.Length>0 ? healthError : "worker-error"; value.NeedsRecovery=true; return value; }
        if(!listening) return value;
        bool initialized=lastCaptureTicks!=0 && (hasActivated || lastProgressTicks!=0);
        if(!initialized)
        {
            value.State="starting";
            if(AgeMs(now,runStartedTicks)>10000) { value.State="stalled"; value.Reason="startup-timeout"; value.NeedsRecovery=true; }
            return value;
        }
        if(value.CaptureAgeMs>3000) value.Reason="capture-stalled";
        else if(!hasActivated && value.ProgressAgeMs>3000) value.Reason="progress-stalled";
        // Include captured PCM still queued before stdin; a responsive worker
        // must not hide a blocked/slow producer. Accelerated files are exempt.
        else if(!fixtureMode && !hasActivated && capturedSamples-processedSamples>48000) value.Reason="progress-lag";
        if(value.Reason.Length>0) { value.State="stalled"; value.NeedsRecovery=true; }
        else value.State="healthy";
        return value;
    }
    private bool ReadyLocked(long now) { return ready && HealthLocked(now).State=="healthy"; }
    public HealthSnapshot GetHealthSnapshot() { lock(gate) return HealthLocked(Stopwatch.GetTimestamp()); }
    private bool ShouldStop { get { lock(gate) return stopRequested; } }
    private void OnWorkerOutput(long run,DataReceivedEventArgs args)
    {
        HandleWorkerLine(run,args.Data);
    }
    private void HandleWorkerLine(long run,string line)
    {
        if(String.IsNullOrEmpty(line)) return;
        if(line=="READY") { lock(gate) { if(run==runVersion && listening && !stopping && !disposed) workerReady.Set(); } return; }
        string[] values=line.Split(new char[]{'\t'},2);
        if(values[0]=="PROGRESS")
        {
            lock(gate)
            {
                if(run!=runVersion || !listening || stopping || disposed || hasActivated) return;
                long sample;
                if(values.Length!=2 || !Int64.TryParse(values[1],NumberStyles.None,CultureInfo.InvariantCulture,out sample) || sample<=processedSamples || sample>submittedSamples)
                { healthError="invalid-progress"; error="Local wake worker sent invalid audio progress."; ready=false; return; }
                processedSamples=sample; lastProgressTicks=Stopwatch.GetTimestamp();
            }
            return;
        }
        if(values.Length!=2) return;
        if(values[0]=="END_SAMPLE")
        {
            long sample;
            if(Int64.TryParse(values[1],out sample)) lock(gate) { if(run==runVersion && !stopping) keywordEndSample=Math.Max(0,sample); }
            return;
        }
        string value; try { value=Encoding.UTF8.GetString(Convert.FromBase64String(values[1])); } catch { return; }
        lock(gate)
        {
            if(run!=runVersion || !listening || stopping || disposed) return;
            if(values[0]=="WAKE" && NormalizePhrase(value)==normalizedPhrase)
            {
                if(hasActivated || healthError.Length>0) return;
                hasActivated=true;
                lastKeyword=phrase; activatedUtc=DateTime.UtcNow; activationVersion++;
                if(echoMode)
                {
                    echoDetected=true;
                    // Preserve a 120ms overlap around final token time, including all decoder latency.
                    long start=keywordEndSample>0 ? Math.Max(ringStartSample,keywordEndSample-1920) : Math.Max(ringStartSample,capturedSamples-8000);
                    int offset=(int)Math.Min(ring.Count,Math.Max(0,start-ringStartSample)*2);
                    question=new QuestionRecorder(this,ring.GetRange(offset,ring.Count-offset).ToArray());
                    ring.Clear(); echoPending.Clear();
                }
                else { stopping=true; stopRequested=true; ready=false; }
            }
            else if(values[0]=="ERROR") { error=value; stopping=true; stopRequested=true; ready=false; }
        }
    }
    private void Run(byte[] testPcm,long run)
    {
        Process process=null; IntPtr device=IntPtr.Zero;
        List<IntPtr> headers=new List<IntPtr>(),buffers=new List<IntPtr>();
        uint headerSize=(uint)Marshal.SizeOf(typeof(WaveHeader));
        using(AutoResetEvent audioEvent=new AutoResetEvent(false))
        {
            try
            {
                ProcessStartInfo info=new ProcessStartInfo(python);
                info.Arguments=Quote(workerPath)+" --model-dir "+Quote(modelDir)+" --phrase "+Quote(normalizedPhrase)+" --threshold "+threshold.ToString(CultureInfo.InvariantCulture);
                info.WorkingDirectory=Path.GetDirectoryName(workerPath); info.UseShellExecute=false; info.CreateNoWindow=true;
                info.RedirectStandardInput=true; info.RedirectStandardOutput=true; info.RedirectStandardError=true;
                info.StandardOutputEncoding=Encoding.UTF8; info.StandardErrorEncoding=Encoding.UTF8;
                info.EnvironmentVariables["PYTHONIOENCODING"]="utf-8"; info.EnvironmentVariables["PYTHONDONTWRITEBYTECODE"]="1";
                process=new Process(); process.StartInfo=info;
                process.OutputDataReceived+=delegate(object sender,DataReceivedEventArgs args) { OnWorkerOutput(run,args); };
                process.ErrorDataReceived+=delegate(object sender,DataReceivedEventArgs args) { if(!String.IsNullOrWhiteSpace(args.Data)) lock(gate) { if(run==runVersion && !stopRequested && error.Length==0) error=args.Data; } };
                if(!process.Start()) throw new InvalidOperationException("Could not start the local wake worker.");
                lock(gate) { ownedWorker=process; ownedWorkerRun=run; }
                process.StandardInput.AutoFlush=true; process.BeginOutputReadLine(); process.BeginErrorReadLine();
                Stopwatch startup=Stopwatch.StartNew();
                while(!workerReady.WaitOne(40))
                {
                    if(ShouldStop) return;
                    if(process.HasExited) throw new InvalidOperationException("Wake worker exited before it was ready. "+Error);
                    if(startup.ElapsedMilliseconds>10000) throw new TimeoutException("Wake model took too long to load.");
                }
                if(ShouldStop) return;
                if(testPcm!=null)
                {
                    if(echoMode) { RunProcessedFixture(process,testPcm,run); return; }
                    lock(gate) ready=true;
                    for(int offset=0;offset<testPcm.Length && !ShouldStop;offset+=BufferSize)
                    {
                        int count=Math.Min(BufferSize,testPcm.Length-offset);
                        lock(gate) { capturedSamples+=count/2; lastCaptureTicks=Stopwatch.GetTimestamp(); }
                        WritePcm(process,testPcm,offset,count,run);
                    }
                    if(!ShouldStop)
                    {
                        process.StandardInput.WriteLine("END"); process.StandardInput.Close();
                        if(!process.WaitForExit(5000)) throw new TimeoutException("Wake fixture decoding did not finish.");
                        process.WaitForExit();
                    }
                    return;
                }
                if(echoMode)
                {
                    RunEcho(process,run);
                    return;
                }
                WaveFormat format=new WaveFormat { FormatTag=1,Channels=1,SamplesPerSec=16000,AvgBytesPerSec=32000,BlockAlign=2,BitsPerSample=16,ExtraSize=0 };
                Check(waveInOpen(out device,UInt32.MaxValue,ref format,audioEvent.SafeWaitHandle.DangerousGetHandle(),IntPtr.Zero,0x00050000));
                for(int i=0;i<8;i++)
                {
                    IntPtr buffer=Marshal.AllocHGlobal(BufferSize); buffers.Add(buffer);
                    IntPtr header=Marshal.AllocHGlobal((int)headerSize); headers.Add(header);
                    Marshal.StructureToPtr(new WaveHeader { Data=buffer,BufferLength=BufferSize },header,false);
                    Check(waveInPrepareHeader(device,header,headerSize)); Check(waveInAddBuffer(device,header,headerSize));
                }
                Check(waveInStart(device)); lock(gate) { if(!stopping) ready=true; }
                int next=0;
                while(!ShouldStop)
                {
                    audioEvent.WaitOne(60); if(ShouldStop) break;
                    if(process.HasExited) throw new InvalidOperationException("Wake worker stopped unexpectedly. "+Error);
                    for(int drained=0;drained<headers.Count && !ShouldStop;drained++)
                    {
                        IntPtr pointer=headers[next]; WaveHeader header=(WaveHeader)Marshal.PtrToStructure(pointer,typeof(WaveHeader));
                        if((header.Flags&1)==0) break;
                        int length=(int)header.BytesRecorded;
                        if(length>0)
                        {
                            byte[] bytes=new byte[length]; Marshal.Copy(header.Data,bytes,0,length);
                            lock(gate) { capturedSamples+=bytes.Length/2; lastCaptureTicks=Stopwatch.GetTimestamp(); }
                            UpdateLevel(bytes); WritePcm(process,bytes,0,bytes.Length,run);
                        }
                        header.BytesRecorded=0; Marshal.StructureToPtr(header,pointer,false); next=(next+1)%headers.Count;
                        if(!ShouldStop) Check(waveInAddBuffer(device,pointer,headerSize));
                    }
                }
            }
            catch(Exception ex) { lock(gate) { if(!stopRequested) error=ex.Message; } }
            finally
            {
                if(device!=IntPtr.Zero)
                {
                    waveInStop(device); waveInReset(device);
                    foreach(IntPtr h in headers) waveInUnprepareHeader(device,h,headerSize);
                    waveInClose(device);
                }
                foreach(IntPtr h in headers) Marshal.FreeHGlobal(h);
                foreach(IntPtr b in buffers) Marshal.FreeHGlobal(b);
                lock(gate) { if(ownedWorkerRun==run && Object.ReferenceEquals(ownedWorker,process)) ownedWorker=null; }
                if(process!=null) { try { if(!process.HasExited) { process.Kill(); process.WaitForExit(1000); } } catch { } process.Dispose(); }
                QuestionRecorder finished; lock(gate) finished=question;
                if(finished!=null) finished.Complete(Error);
                // The device is really closed before publishing completion.
                lock(gate) { ready=false; listening=false; stopping=false; audioLevel=0; completed.Set(); }
            }
        }
    }
    private void WritePcm(Process process,byte[] bytes,int offset,int count,long run)
    {
        if(count<=0) return;
        lock(gate)
        {
            if(run!=runVersion || stopRequested) return;
            // Publish before writing: stdout may acknowledge on another thread
            // immediately after a completed write. Never hold gate during I/O.
            submittedSamples+=count/2;
        }
        process.StandardInput.WriteLine(Convert.ToBase64String(bytes,offset,count));
    }
    private void RunEcho(Process process,long run)
    {
        EchoCapture capture=new EchoCapture();
        lock(gate) echoCapture=capture;
        capture.PcmAvailable=delegate(byte[] bytes) { AcceptEchoPcm(bytes,run,true); };
        try
        {
            capture.Start(echoCaptureId,echoRenderId);
            while(!ShouldStop)
            {
                if(capture.Error.Length>0) throw new InvalidOperationException(capture.Error);
                if(!capture.IsRunning) throw new InvalidOperationException("Echo capture stopped unexpectedly.");
                bool captureReady=capture.IsReady;
                lock(gate) ready=captureReady && !stopping;
                byte[] bytes=null; bool detected;
                lock(gate) { detected=echoDetected; if(!detected && echoPending.Count>0) bytes=echoPending.Dequeue(); }
                if(!detected && process.HasExited)
                {
                    process.WaitForExit(); lock(gate) detected=echoDetected;
                    if(!detected) throw new InvalidOperationException("Wake worker stopped unexpectedly. "+Error);
                }
                if(bytes!=null && !detected)
                {
                    try { WritePcm(process,bytes,0,bytes.Length,run); }
                    catch(IOException)
                    {
                        if(!process.WaitForExit(1000)) throw;
                        process.WaitForExit(); lock(gate) detected=echoDetected;
                        if(!detected) throw;
                    }
                }
                else Thread.Sleep(5);
            }
        }
        finally
        {
            // Keep the listening/stopping state until native capture has actually released.
            while(!capture.StopAndWait(250)) { lock(gate) { ready=false; stopping=true; } }
            capture.Dispose(); lock(gate) { echoCapture=null; ring.Clear(); echoPending.Clear(); }
        }
    }
    private void AcceptEchoPcm(byte[] bytes,long run,bool queue)
    {
        if(bytes==null || bytes.Length==0) return;
        lock(gate)
        {
            if(run!=runVersion || stopRequested) return;
            capturedSamples+=bytes.Length/2; lastCaptureTicks=Stopwatch.GetTimestamp(); UpdateLevel(bytes);
            if(question!=null) question.Append(bytes);
            else
            {
                ring.AddRange(bytes);
                if(ring.Count>96000) { int remove=ring.Count-96000; ring.RemoveRange(0,remove); ringStartSample+=remove/2; }
                if(queue) { echoPending.Enqueue(bytes); if(echoPending.Count>200) { error="Local keyword processing fell behind the microphone."; stopRequested=true; stopping=true; } }
            }
        }
    }
    private void RunProcessedFixture(Process process,byte[] pcm,long run)
    {
        lock(gate) ready=true;
        for(int offset=0;offset<pcm.Length && !ShouldStop;offset+=BufferSize)
        {
            int count=Math.Min(BufferSize,pcm.Length-offset); byte[] bytes=new byte[count]; Array.Copy(pcm,offset,bytes,0,count);
            AcceptEchoPcm(bytes,run,false);
            bool detected; lock(gate) detected=echoDetected;
            if(!detected) WritePcm(process,bytes,0,bytes.Length,run);
            Thread.Sleep(40);
        }
        lock(gate) fixtureInputComplete=true;
        while(!ShouldStop) Thread.Sleep(10);
    }
    private void UpdateLevel(byte[] bytes)
    {
        double sum=0; for(int i=0;i+1<bytes.Length;i+=2) { double sample=(short)(bytes[i]|(bytes[i+1]<<8))/32768.0; sum+=sample*sample; }
        double rms=Math.Sqrt(sum/Math.Max(1,bytes.Length/2));
        int value=(int)Math.Round(Math.Max(0,Math.Min(100,(20*Math.Log10(rms+1e-8)+60)*100/60)));
        lock(gate) audioLevel=value;
    }
    private static void Check(uint code)
    {
        if(code==0) return; StringBuilder message=new StringBuilder(256); waveInGetErrorText(code,message,256);
        throw new InvalidOperationException("Microphone: "+message.ToString()+" ("+code+")");
    }
    private static byte[] ReadPcmWave(byte[] wav)
    {
        using(BinaryReader reader=new BinaryReader(new MemoryStream(wav,false)))
        {
            if(Encoding.ASCII.GetString(reader.ReadBytes(4))!="RIFF") throw new ArgumentException("Invalid RIFF WAV.");
            reader.ReadUInt32(); if(Encoding.ASCII.GetString(reader.ReadBytes(4))!="WAVE") throw new ArgumentException("Invalid WAVE header.");
            bool formatOk=false;
            while(reader.BaseStream.Position+8<=reader.BaseStream.Length)
            {
                string id=Encoding.ASCII.GetString(reader.ReadBytes(4)); uint length=reader.ReadUInt32(); long start=reader.BaseStream.Position;
                if(length>reader.BaseStream.Length-start) throw new ArgumentException("Truncated WAV chunk.");
                if(id=="fmt " && length>=16)
                {
                    ushort encoding=reader.ReadUInt16(),channels=reader.ReadUInt16(); uint rate=reader.ReadUInt32();
                    reader.ReadUInt32(); reader.ReadUInt16(); ushort bits=reader.ReadUInt16();
                    formatOk=encoding==1 && channels==1 && rate==16000 && bits==16;
                }
                if(id=="data") { if(!formatOk || length%2!=0) throw new ArgumentException("Expected 16kHz mono 16-bit PCM WAV."); return reader.ReadBytes((int)length); }
                reader.BaseStream.Position=start+length+(length%2);
            }
            throw new ArgumentException("No PCM data found.");
        }
    }
    private static string Quote(string value)
    {
        StringBuilder text=new StringBuilder("\""); int slashes=0;
        foreach(char c in value)
        {
            if(c=='\\') { slashes++; continue; }
            if(c=='\"') { text.Append('\\',slashes*2+1); text.Append(c); slashes=0; continue; }
            text.Append('\\',slashes); slashes=0; text.Append(c);
        }
        text.Append('\\',slashes*2); text.Append('"'); return text.ToString();
    }
    public static string NormalizePhrase(string value)
    {
        if(value==null) return ""; StringBuilder text=new StringBuilder();
        foreach(char c in value.Normalize(NormalizationForm.FormKC)) if(Char.IsLetterOrDigit(c)) text.Append(Char.ToLowerInvariant(c)); return text.ToString();
    }
    public Snapshot GetSnapshot()
    {
        lock(gate) return new Snapshot { IsListening=listening,IsStopping=stopping,IsReady=ReadyLocked(Stopwatch.GetTimestamp()),ActivationVersion=activationVersion,
            LastKeyword=lastKeyword,Confidence=Single.NaN,ConfidenceAvailable=false,KeywordThreshold=threshold,Error=error,AudioLevel=audioLevel,ActivatedUtc=activatedUtc,
            FullDuplexReady=FullDuplexReady,HasQuestion=HasQuestion };
    }
    // Recorder-shaped handoff keeps the same physical AEC stream and the immediate question pre-roll.
    public sealed class QuestionRecorder : IDisposable
    {
        private readonly object sync=new object(); private readonly WakeListener owner; private readonly MemoryStream pcm=new MemoryStream();
        private bool recording=true,stopping,cancelled,completed; private string path="",lastFile="",error="";
        private DateTime started=DateTime.UtcNow,lastVoice=DateTime.MinValue; private int level;
        internal QuestionRecorder(WakeListener listener,byte[] prefix) { owner=listener; Append(prefix); }
        public bool IsRecording { get { lock(sync) return recording; } }
        public bool IsStopping { get { lock(sync) return stopping; } }
        public int AudioLevel { get { lock(sync) return level; } }
        public int Level { get { return AudioLevel; } }
        public DateTime StartedUtc { get { lock(sync) return started; } }
        public DateTime LastVoiceUtc { get { lock(sync) return lastVoice; } }
        public string LastFile { get { lock(sync) return lastFile; } }
        public string Error { get { lock(sync) return error; } }
        public void Start() { lock(sync) { if(completed) throw new InvalidOperationException("The echo question has ended."); } }
        internal void Append(byte[] bytes)
        {
            lock(sync)
            {
                if(!recording || stopping) return;
                if(pcm.Length+bytes.Length>32000*303) { error="Voice question exceeded five minutes."; return; }
                pcm.Write(bytes,0,bytes.Length); double sum=0;
                for(int i=0;i+1<bytes.Length;i+=2) { double sample=(short)(bytes[i]|(bytes[i+1]<<8))/32768.0; sum+=sample*sample; }
                double rms=Math.Sqrt(sum/Math.Max(1,bytes.Length/2)); level=(int)Math.Round(Math.Max(0,Math.Min(100,(20*Math.Log10(rms+1e-8)+60)*100/60)));
                if(rms>0.006) lastVoice=DateTime.UtcNow;
            }
        }
        public void StopToFileAsync(string file)
        {
            if(String.IsNullOrWhiteSpace(file)) throw new ArgumentException("A WAV path is required.");
            lock(sync) { if(!recording || stopping) return; path=Path.GetFullPath(file); stopping=true; }
            owner.Stop();
        }
        public void Cancel() { lock(sync) { if(completed) return; cancelled=true; stopping=true; } owner.Stop(); }
        internal void Complete(string captureError)
        {
            lock(sync)
            {
                if(completed) return;
                try
                {
                    if(captureError.Length>0) error=captureError;
                    if(!cancelled && error.Length==0 && path.Length>0)
                    {
                        Directory.CreateDirectory(Path.GetDirectoryName(path));
                        using(BinaryWriter writer=new BinaryWriter(File.Create(path)))
                        {
                            writer.Write(Encoding.ASCII.GetBytes("RIFF")); writer.Write((uint)(36+pcm.Length)); writer.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
                            writer.Write((uint)16); writer.Write((ushort)1); writer.Write((ushort)1); writer.Write((uint)16000); writer.Write((uint)32000);
                            writer.Write((ushort)2); writer.Write((ushort)16); writer.Write(Encoding.ASCII.GetBytes("data")); writer.Write((uint)pcm.Length);
                            pcm.Position=0; pcm.CopyTo(writer.BaseStream);
                        }
                        lastFile=path;
                    }
                }
                catch(Exception ex) { error=ex.Message; }
                finally { pcm.Dispose(); recording=false; stopping=false; completed=true; level=0; }
            }
        }
        public void Dispose() { Cancel(); }
    }
    public void Dispose() { lock(gate) { if(disposed) return; } Stop(); completed.WaitOne(2500); lock(gate) disposed=true; }
}
