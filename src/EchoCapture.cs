using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

// WASAPI capability inspection. A successful OS/version check is NOT proof of AEC.
// Probe initializes a shared communications stream but never calls Start or reads audio.
public sealed partial class EchoCapture : IDisposable
{
    public sealed class Capability
    {
        public string CaptureEndpointId { get; set; }
        public string RenderEndpointId { get; set; }
        public string CaptureName { get; set; }
        public string RenderName { get; set; }
        public bool Initialized { get; set; }
        public bool AecPresent { get; set; }
        public bool AecActive { get; set; }
        public bool ReferenceControllable { get; set; }
        public bool ReferenceBound { get; set; }
        public bool FullDuplexReady { get { return false; } } // Probe does not validate playback routing or acoustics.
        public string EffectsHResult { get; set; }
        public string ReferenceHResult { get; set; }
        public string[] Effects { get; set; }
        public string Error { get; set; }
        public int SampleRate { get; set; }
        public int Channels { get; set; }
    }
    internal static readonly Guid AecEffect = new Guid("6f64adbe-8211-11e2-8c70-2c27d7f001fa");
    private readonly object gate=new object();
    private readonly ManualResetEvent stopped=new ManualResetEvent(true),cancel=new ManualResetEvent(false);
    private bool running,stopping,ready,disposed;
    private string error="",captureEndpoint="",renderEndpoint="";
    private Thread captureThread;
    private long frames;
    private int level;
    private readonly Queue<byte[]> pending=new Queue<byte[]>();
    public bool IsRunning { get { lock(gate) return running; } }
    public bool IsStopping { get { lock(gate) return stopping; } }
    public bool IsReady { get { lock(gate) return ready; } }
    public bool AecActive { get { return IsReady; } }
    public bool ReferenceBound { get { return IsReady; } }
    public string Provider { get { return "Windows Voice Capture DSP / source AEC"; } }
    public string Error { get { lock(gate) return error; } }
    public string CaptureEndpointId { get { lock(gate) return captureEndpoint; } }
    public string RenderEndpointId { get { lock(gate) return renderEndpoint; } }
    public long FramesCaptured { get { lock(gate) return frames; } }
    public int AudioLevel { get { lock(gate) return level; } }
    // A C# consumer may install a callback before Start; callbacks run on the capture thread.
    // PowerShell callers should poll ReadAvailablePcm instead of installing scriptblock callbacks.
    public Action<byte[]> PcmAvailable { get; set; }
    public void Start(string captureId,string renderId)
    {
        if(String.IsNullOrEmpty(captureId) || String.IsNullOrEmpty(renderId)) throw new ArgumentException("Explicit capture and render endpoint IDs are required.");
        lock(gate)
        {
            if(disposed) throw new ObjectDisposedException("EchoCapture");
            if(running || stopping) throw new InvalidOperationException("Echo capture is already active.");
            captureEndpoint=captureId; renderEndpoint=renderId; error=""; frames=0; level=0;
            pending.Clear(); ready=false; running=true; stopping=false; cancel.Reset(); stopped.Reset();
            captureThread=new Thread(RunDmo); captureThread.IsBackground=true; captureThread.Name="Local echo-cancelled microphone";
            captureThread.SetApartmentState(ApartmentState.MTA); captureThread.Start();
        }
    }
    public void Stop() { lock(gate) { if(!running) return; stopping=true; ready=false; cancel.Set(); } }
    public bool StopAndWait(int milliseconds) { Stop(); return stopped.WaitOne(Math.Max(0,milliseconds)); }
    public byte[] ReadAvailablePcm()
    {
        lock(gate)
        {
            using(MemoryStream data=new MemoryStream()) { while(pending.Count>0) { byte[] chunk=pending.Dequeue(); data.Write(chunk,0,chunk.Length); } return data.ToArray(); }
        }
    }
    private void Publish(byte[] bytes)
    {
        double sum=0; for(int i=0;i+1<bytes.Length;i+=2) { double s=(short)(bytes[i]|(bytes[i+1]<<8))/32768.0; sum+=s*s; }
        double rms=Math.Sqrt(sum/Math.Max(1,bytes.Length/2));
        lock(gate)
        {
            frames+=bytes.Length/2;
            level=(int)Math.Round(Math.Max(0,Math.Min(100,(20*Math.Log10(rms+1e-8)+60)*100/60)));
            if(PcmAvailable==null) { pending.Enqueue(bytes); while(pending.Count>250) pending.Dequeue(); }
        }
        Action<byte[]> callback=PcmAvailable; if(callback!=null) callback(bytes);
    }
    private static int FindIndex(EDeviceEnumerator enumerator,int flow,string id)
    {
        EDeviceCollection collection=null;
        try
        {
            Check(enumerator.EnumAudioEndpoints(flow,1,out collection)); uint count; Check(collection.GetCount(out count));
            for(uint i=0;i<count;i++) { EDevice item=null; try { Check(collection.Item(i,out item)); string current; Check(item.GetId(out current)); if(current==id) return (int)i; } finally { Release(item); } }
            throw new InvalidOperationException("The selected audio endpoint is no longer active.");
        }
        finally { Release(collection); }
    }
    private static void SetDmoProperty(EPropertyStore store,uint id,int value,bool boolean)
    {
        EPropertyKey key=new EPropertyKey { FormatId=new Guid("6f52c567-0360-4bd2-9617-ccbf1421c939"),Id=id };
        EPropVariant variant=new EPropVariant();
        if(boolean) { variant.Type=11; variant.BoolValue=value!=0 ? (short)-1 : (short)0; }
        else { variant.Type=3; variant.IntValue=value; }
        Check(store.SetValue(ref key,ref variant));
    }
    private void RunDmo()
    {
        EDeviceEnumerator enumerator=null; EMediaObject dmo=null; EPropertyStore properties=null;
        ESilentRender reference=null; EMediaBuffer buffer=null; IntPtr format=IntPtr.Zero;
        try
        {
            enumerator=CreateEnumerator();
            int microphone=FindIndex(enumerator,1,captureEndpoint),speaker=FindIndex(enumerator,0,renderEndpoint);
            // This explicit shared render stream supplies a stable reference clock even when TTS is idle.
            // It contains digital silence only; TTS is rendered separately to exactly this endpoint.
            reference=new ESilentRender(enumerator,renderEndpoint);
            dmo=(EMediaObject)new EVoiceDmo(); properties=(EPropertyStore)dmo;
            SetDmoProperty(properties,2,0,false); // SINGLE_CHANNEL_AEC, not NS-only mode.
            SetDmoProperty(properties,3,1,true); // source mode: DMO obtains real mic + selected speaker streams.
            SetDmoProperty(properties,4,(speaker<<16)|(microphone&65535),false);
            // Read back the device pair and AEC mode; fail if the implementation rejected the configuration.
            EPropertyKey deviceKey=new EPropertyKey { FormatId=new Guid("6f52c567-0360-4bd2-9617-ccbf1421c939"),Id=4 };
            EPropVariant value; Check(properties.GetValue(ref deviceKey,out value));
            try { if(value.Type!=3 || value.IntValue!=((speaker<<16)|(microphone&65535))) throw new InvalidOperationException("AEC device pair was not accepted."); }
            finally { PropVariantClear(ref value); }
            format=Marshal.AllocCoTaskMem(Marshal.SizeOf(typeof(EWaveFormat)));
            Marshal.StructureToPtr(new EWaveFormat { Tag=1,Channels=1,SamplesPerSec=16000,AvgBytesPerSec=32000,BlockAlign=2,BitsPerSample=16 },format,false);
            EMediaType type=new EMediaType { MajorType=new Guid("73647561-0000-0010-8000-00aa00389b71"), SubType=new Guid("00000001-0000-0010-8000-00aa00389b71"), FixedSize=1,
                FormatType=new Guid("05589f81-c356-11ce-bf01-00aa0055595a"), FormatSize=(uint)Marshal.SizeOf(typeof(EWaveFormat)), Format=format };
            Check(dmo.SetOutputType(0,ref type,0));
            Check(dmo.AllocateStreamingResources());
            buffer=new EMediaBuffer(32000); EOutputBuffer[] output=new EOutputBuffer[1];
            Stopwatch clock=Stopwatch.StartNew(); long lastAudio=0;
            while(!cancel.WaitOne(5))
            {
                reference.Pump(); buffer.SetLength(0); output[0]=new EOutputBuffer { Buffer=buffer.InterfacePointer };
                uint status; int hr=dmo.ProcessOutput(0,1,output,out status); Check(hr);
                byte[] bytes=buffer.Copy();
                if(bytes.Length>0)
                {
                    lastAudio=clock.ElapsedMilliseconds;
                    lock(gate) { if(!stopping) ready=true; }
                    Publish(bytes);
                }
                if(clock.ElapsedMilliseconds-lastAudio>3000) throw new InvalidOperationException("AEC stopped producing audio; its speaker reference is unavailable.");
            }
        }
        catch(Exception ex) { lock(gate) { if(!stopping) error=ex.Message+" ("+Hex(Marshal.GetHRForException(ex))+")"; } }
        finally
        {
            if(dmo!=null) { try { dmo.FreeStreamingResources(); } catch { } }
            if(buffer!=null) buffer.Dispose(); if(format!=IntPtr.Zero) Marshal.FreeCoTaskMem(format);
            // properties and dmo are two interfaces on one RCW: release exactly once.
            Release(dmo); if(reference!=null) reference.Dispose(); Release(enumerator);
            lock(gate) { ready=false; running=false; stopping=false; level=0; stopped.Set(); }
        }
    }
    public void Dispose() { StopAndWait(3000); lock(gate) disposed=true; }
    public static Capability ProbeDefault() { return Probe(null, null); }
    public static string GetDefaultCaptureEndpointId()
    {
        EDeviceEnumerator enumerator=null; EDevice device=null;
        try { enumerator=CreateEnumerator(); Check(enumerator.GetDefaultAudioEndpoint(1,2,out device)); string id; Check(device.GetId(out id)); return id; }
        finally { Release(device); Release(enumerator); }
    }
    public static Capability Probe(string captureEndpointId, string renderEndpointId)
    {
        Capability result = null;
        Thread t = new Thread(delegate() { result = ProbeOnThread(captureEndpointId, renderEndpointId); });
        t.IsBackground = true; t.SetApartmentState(ApartmentState.MTA); t.Start();
        if (!t.Join(8000)) return new Capability { Error="WASAPI initialization timed out; no audio was started.", Effects=new string[0] };
        return result;
    }
    private static Capability ProbeOnThread(string captureId, string renderId)
    {
        var result = new Capability { Effects=new string[0], Error="" };
        EDeviceEnumerator enumerator=null; EDevice capture=null, render=null;
        EAudioClient2 client=null; object effects=null, control=null;
        IntPtr format=IntPtr.Zero, effectsPointer=IntPtr.Zero;
        try
        {
            enumerator=CreateEnumerator();
            Check(String.IsNullOrEmpty(captureId) ? enumerator.GetDefaultAudioEndpoint(1,2,out capture) : enumerator.GetDevice(captureId,out capture));
            Check(String.IsNullOrEmpty(renderId) ? enumerator.GetDefaultAudioEndpoint(0,1,out render) : enumerator.GetDevice(renderId,out render));
            string id; Check(capture.GetId(out id)); result.CaptureEndpointId=id; result.CaptureName=Name(capture);
            Check(render.GetId(out id)); result.RenderEndpointId=id; result.RenderName=Name(render);
            Guid iid=typeof(EAudioClient2).GUID; object raw;
            Check(capture.Activate(ref iid,23,IntPtr.Zero,out raw)); client=(EAudioClient2)raw;
            EClientProperties properties=new EClientProperties { Size=16, Category=3 };
            Check(client.SetClientProperties(ref properties)); Check(client.GetMixFormat(out format));
            EWaveFormat wf=(EWaveFormat)Marshal.PtrToStructure(format,typeof(EWaveFormat));
            result.SampleRate=(int)wf.SamplesPerSec; result.Channels=wf.Channels;
            Check(client.Initialize(0,0,1000000,0,format,IntPtr.Zero)); result.Initialized=true;
            iid=typeof(EAudioEffectsManager).GUID; int hr=client.GetService(ref iid,out effects); result.EffectsHResult=Hex(hr);
            if(hr>=0)
            {
                uint count; Check(((EAudioEffectsManager)effects).GetAudioEffects(out effectsPointer,out count));
                var items=new List<string>(); int size=Marshal.SizeOf(typeof(EAudioEffect));
                for(uint i=0;i<count;i++)
                {
                    EAudioEffect effect=(EAudioEffect)Marshal.PtrToStructure(IntPtr.Add(effectsPointer,(int)i*size),typeof(EAudioEffect));
                    items.Add(effect.Id.ToString()+" state="+effect.State+" configurable="+(effect.CanSetState!=0));
                    if(effect.Id==AecEffect) { result.AecPresent=true; result.AecActive=effect.State==1; }
                }
                result.Effects=items.ToArray();
            }
            iid=typeof(EAecControl).GUID; hr=client.GetService(ref iid,out control);
            result.ReferenceControllable=hr>=0;
            if(hr>=0) { hr=((EAecControl)control).SetEchoCancellationRenderEndpoint(result.RenderEndpointId); result.ReferenceBound=hr>=0; }
            result.ReferenceHResult=Hex(hr);
        }
        catch(Exception ex) { result.Error=ex.Message+" ("+Hex(Marshal.GetHRForException(ex))+")"; }
        finally
        {
            if(effectsPointer!=IntPtr.Zero) Marshal.FreeCoTaskMem(effectsPointer);
            if(format!=IntPtr.Zero) Marshal.FreeCoTaskMem(format);
            Release(control); Release(effects); Release(client); Release(render); Release(capture); Release(enumerator);
        }
        return result;
    }
    internal static string Name(EDevice device)
    {
        EPropertyStore store=null; EPropVariant value=new EPropVariant();
        try
        {
            Check(device.OpenPropertyStore(0,out store));
            EPropertyKey key=new EPropertyKey { FormatId=new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), Id=14 };
            Check(store.GetValue(ref key,out value));
            return value.Type==31 ? Marshal.PtrToStringUni(value.Pointer) : "";
        }
        finally { PropVariantClear(ref value); Release(store); }
    }
    internal static void Check(int hr) { if(hr<0) Marshal.ThrowExceptionForHR(hr); }
    internal static string Hex(int hr) { return "0x"+unchecked((uint)hr).ToString("X8"); }
    internal static void Release(object obj) { if(obj!=null && Marshal.IsComObject(obj)) Marshal.ReleaseComObject(obj); }
    private static EDeviceEnumerator CreateEnumerator()
    {
        object shared=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")));
        IntPtr unknown=IntPtr.Zero;
        try { unknown=Marshal.GetIUnknownForObject(shared); return (EDeviceEnumerator)Marshal.GetUniqueObjectForIUnknown(unknown); }
        finally { if(unknown!=IntPtr.Zero) Marshal.Release(unknown); Release(shared); }
    }
    [DllImport("ole32.dll")] internal static extern int PropVariantClear(ref EPropVariant value);
    [StructLayout(LayoutKind.Sequential,Pack=2)] internal struct EWaveFormat { public ushort Tag,Channels; public uint SamplesPerSec,AvgBytesPerSec; public ushort BlockAlign,BitsPerSample,ExtraSize; }
    [StructLayout(LayoutKind.Sequential)] internal struct EClientProperties { public uint Size; public int Offload,Category; public uint Options; }
    [StructLayout(LayoutKind.Sequential)] internal struct EAudioEffect { public Guid Id; public int CanSetState,State; }
    [StructLayout(LayoutKind.Sequential)] internal struct EPropertyKey { public Guid FormatId; public uint Id; }
    [StructLayout(LayoutKind.Explicit,Size=24)] internal struct EPropVariant { [FieldOffset(0)] public ushort Type; [FieldOffset(8)] public IntPtr Pointer; [FieldOffset(8)] public int IntValue; [FieldOffset(8)] public short BoolValue; }
    [ComImport,Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] internal class EEnumerator { }
    [ComImport,Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] internal interface EDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int flow,uint state,out EDeviceCollection collection);
        [PreserveSig] int GetDefaultAudioEndpoint(int flow,int role,out EDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id,out EDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }
    [ComImport,Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] internal interface EDeviceCollection {
        [PreserveSig] int GetCount(out uint count); [PreserveSig] int Item(uint index,out EDevice device);
    }
    [ComImport,Guid("D666063F-1587-4E43-81F1-B948E807363F"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] internal interface EDevice {
        [PreserveSig] int Activate(ref Guid iid,uint context,IntPtr activation,[MarshalAs(UnmanagedType.IUnknown)] out object obj);
        [PreserveSig] int OpenPropertyStore(uint access,out EPropertyStore store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out uint state);
    }
    [ComImport,Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] internal interface EPropertyStore {
        [PreserveSig] int GetCount(out uint count); [PreserveSig] int GetAt(uint index,out EPropertyKey key);
        [PreserveSig] int GetValue(ref EPropertyKey key,out EPropVariant value);
        [PreserveSig] int SetValue(ref EPropertyKey key,ref EPropVariant value); [PreserveSig] int Commit();
    }
    [ComImport,Guid("726778CD-F60A-4eda-82DE-E47610CD78AA"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] internal interface EAudioClient2 {
        [PreserveSig] int Initialize(int share,uint flags,long duration,long period,IntPtr format,IntPtr session);
        [PreserveSig] int GetBufferSize(out uint frames); [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out uint frames); [PreserveSig] int IsFormatSupported(int share,IntPtr format,out IntPtr closest);
        [PreserveSig] int GetMixFormat(out IntPtr format); [PreserveSig] int GetDevicePeriod(out long normal,out long minimum);
        [PreserveSig] int Start(); [PreserveSig] int Stop(); [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr handle);
        [PreserveSig] int GetService(ref Guid iid,[MarshalAs(UnmanagedType.IUnknown)] out object service);
        [PreserveSig] int IsOffloadCapable(int category,out int capable);
        [PreserveSig] int SetClientProperties(ref EClientProperties properties);
        [PreserveSig] int GetBufferSizeLimits(IntPtr format,int eventDriven,out long minimum,out long maximum);
    }
    [ComImport,Guid("4460B3AE-4B44-4527-8676-7548A8ACD260"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] internal interface EAudioEffectsManager {
        [PreserveSig] int RegisterAudioEffectsChangedNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterAudioEffectsChangedNotificationCallback(IntPtr client);
        [PreserveSig] int GetAudioEffects(out IntPtr effects,out uint count);
        [PreserveSig] int SetAudioEffectState(Guid effect,int state);
    }
    [ComImport,Guid("f4ae25b5-aaa3-437d-b6b3-dbbe2d0e9549"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] internal interface EAecControl {
        [PreserveSig] int SetEchoCancellationRenderEndpoint([MarshalAs(UnmanagedType.LPWStr)] string endpointId);
    }
    private sealed class ESilentRender : IDisposable
    {
        EAudioClient2 client; ERenderClient renderer; uint size;
        public ESilentRender(EDeviceEnumerator enumerator,string endpoint)
        {
            EDevice device=null; IntPtr format=IntPtr.Zero;
            try
            {
                Check(enumerator.GetDevice(endpoint,out device)); Guid iid=typeof(EAudioClient2).GUID; object raw;
                Check(device.Activate(ref iid,23,IntPtr.Zero,out raw)); client=(EAudioClient2)raw;
                Check(client.GetMixFormat(out format)); Check(client.Initialize(0,0,1000000,0,format,IntPtr.Zero));
                Check(client.GetBufferSize(out size)); iid=typeof(ERenderClient).GUID;
                Check(client.GetService(ref iid,out raw)); renderer=(ERenderClient)raw;
                Pump(); Check(client.Start());
            }
            catch { Dispose(); throw; }
            finally { if(format!=IntPtr.Zero) Marshal.FreeCoTaskMem(format); Release(device); }
        }
        public void Pump()
        {
            uint padding; Check(client.GetCurrentPadding(out padding)); uint count=size-padding;
            if(count>0) { IntPtr data; Check(renderer.GetBuffer(count,out data)); Check(renderer.ReleaseBuffer(count,2)); }
        }
        public void Dispose() { if(client!=null) { try { client.Stop(); } catch { } } Release(renderer); Release(client); renderer=null; client=null; }
    }
    [ComImport,Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] internal interface ERenderClient {
        [PreserveSig] int GetBuffer(uint count,out IntPtr data); [PreserveSig] int ReleaseBuffer(uint count,uint flags);
    }
    [ComImport,Guid("745057c7-f353-4f2d-a7ee-58434477730e")] internal class EVoiceDmo { }
    [StructLayout(LayoutKind.Sequential)] internal struct EMediaType {
        public Guid MajorType,SubType; public int FixedSize,TemporalCompression; public uint SampleSize;
        public Guid FormatType; public IntPtr Unknown; public uint FormatSize; public IntPtr Format;
    }
    [StructLayout(LayoutKind.Sequential)] internal struct EOutputBuffer { public IntPtr Buffer; public uint Status; public long Timestamp,Duration; }
    [ComImport,Guid("d8ad0f58-5494-4102-97c5-ec798e59bcf4"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] internal interface EMediaObject {
        [PreserveSig] int GetStreamCount(out uint inputs,out uint outputs);
        [PreserveSig] int GetInputStreamInfo(uint index,out uint flags); [PreserveSig] int GetOutputStreamInfo(uint index,out uint flags);
        [PreserveSig] int GetInputType(uint stream,uint typeIndex,out EMediaType type); [PreserveSig] int GetOutputType(uint stream,uint typeIndex,out EMediaType type);
        [PreserveSig] int SetInputType(uint stream,ref EMediaType type,uint flags); [PreserveSig] int SetOutputType(uint stream,ref EMediaType type,uint flags);
        [PreserveSig] int GetInputCurrentType(uint stream,out EMediaType type); [PreserveSig] int GetOutputCurrentType(uint stream,out EMediaType type);
        [PreserveSig] int GetInputSizeInfo(uint stream,out uint size,out uint lookahead,out uint alignment); [PreserveSig] int GetOutputSizeInfo(uint stream,out uint size,out uint alignment);
        [PreserveSig] int GetInputMaxLatency(uint stream,out long latency); [PreserveSig] int SetInputMaxLatency(uint stream,long latency);
        [PreserveSig] int Flush(); [PreserveSig] int Discontinuity(uint stream);
        [PreserveSig] int AllocateStreamingResources(); [PreserveSig] int FreeStreamingResources();
        [PreserveSig] int GetInputStatus(uint stream,out uint flags);
        [PreserveSig] int ProcessInput(uint stream,IntPtr buffer,uint flags,long timestamp,long duration);
        [PreserveSig] int ProcessOutput(uint flags,uint count,[In,Out,MarshalAs(UnmanagedType.LPArray,SizeParamIndex=1)] EOutputBuffer[] buffers,out uint status);
        [PreserveSig] int Lock(int locked);
    }
    [Guid("59eff8b9-938c-4a26-82f2-95cb84cdc837"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown),ComVisible(true)]
    public interface IMemoryMediaBuffer {
        [PreserveSig] int SetLength(uint length); [PreserveSig] int GetMaxLength(out uint length);
        [PreserveSig] int GetBufferAndLength(IntPtr bufferPointer,IntPtr lengthPointer);
    }
    [ClassInterface(ClassInterfaceType.None),ComVisible(true)]
    public sealed class EMediaBuffer : IMemoryMediaBuffer,IDisposable
    {
        private IntPtr data; private uint length,capacity; public IntPtr InterfacePointer { get; private set; }
        public EMediaBuffer(int size) { capacity=(uint)size; data=Marshal.AllocHGlobal(size); InterfacePointer=Marshal.GetComInterfaceForObject(this,typeof(IMemoryMediaBuffer)); }
        public int SetLength(uint value) { if(value>capacity) return unchecked((int)0x80070057); length=value; return 0; }
        public int GetMaxLength(out uint value) { value=capacity; return 0; }
        public int GetBufferAndLength(IntPtr bufferPointer,IntPtr lengthPointer) { if(bufferPointer!=IntPtr.Zero) Marshal.WriteIntPtr(bufferPointer,data); if(lengthPointer!=IntPtr.Zero) Marshal.WriteInt32(lengthPointer,(int)length); return 0; }
        public byte[] Copy() { byte[] bytes=new byte[length]; if(length>0) Marshal.Copy(data,bytes,0,(int)length); return bytes; }
        public void Dispose() { if(InterfacePointer!=IntPtr.Zero) { Marshal.Release(InterfacePointer); InterfacePointer=IntPtr.Zero; } if(data!=IntPtr.Zero) { Marshal.FreeHGlobal(data); data=IntPtr.Zero; } }
    }
}
