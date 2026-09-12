using System;
using System.IO;
using System.Threading;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

public static class EchoAcousticHarness
{
    public sealed class Result { public byte[] Wave { get; set; } public double Rms { get; set; } public double Seconds { get; set; } public string Error { get; set; } }
    // Controlled self-authored loudspeaker fixture; no audio is written to disk.
    public static Result RecordPlayback(string microphone,string speaker,string fixture,bool useEcho,int repeats)
    {
        EchoCapture echo=null; WasapiCapture raw=null; MMDevice device=null;
        object gate=new object(); MemoryStream samples=new MemoryStream(); WaveFormat format=new WaveFormat(16000,16,1);
        using(ManualResetEvent rawStopped=new ManualResetEvent(false))
        {
            try
            {
                CodexReader.AudioPlayer.SelectEndpoint(speaker);
                if(useEcho)
                {
                    echo=new EchoCapture(); echo.PcmAvailable=delegate(byte[] bytes) { lock(gate) samples.Write(bytes,0,bytes.Length); };
                    echo.Start(microphone,speaker);
                    for(int i=0;i<300 && !echo.IsReady && echo.IsRunning;i++) Thread.Sleep(20);
                    if(!echo.IsReady) throw new InvalidOperationException(echo.Error);
                }
                else
                {
                    using(var devices=new MMDeviceEnumerator()) device=devices.GetDevice(microphone);
                    raw=new WasapiCapture(device); format=raw.WaveFormat;
                    raw.DataAvailable+=delegate(object sender,WaveInEventArgs args) { lock(gate) samples.Write(args.Buffer,0,args.BytesRecorded); };
                    raw.RecordingStopped+=delegate { rawStopped.Set(); }; raw.StartRecording();
                }
                Thread.Sleep(500);
                for(int i=0;i<repeats;i++)
                {
                    CodexReader.AudioPlayer.Play(fixture);
                    while(CodexReader.AudioPlayer.State=="playing") Thread.Sleep(20);
                    CodexReader.AudioPlayer.Stop(); Thread.Sleep(250);
                }
                Thread.Sleep(700);
                if(echo!=null && !String.IsNullOrEmpty(echo.Error)) throw new InvalidOperationException(echo.Error);
            }
            finally
            {
                CodexReader.AudioPlayer.Stop();
                if(echo!=null) echo.Dispose();
                if(raw!=null) { raw.StopRecording(); rawStopped.WaitOne(2000); raw.Dispose(); }
                if(device!=null) device.Dispose();
            }
        }
        byte[] captured; lock(gate) captured=samples.ToArray(); samples.Dispose();
        using(var input=new RawSourceWaveStream(new MemoryStream(captured,false),format))
        {
            ISampleProvider provider=input.ToSampleProvider();
            if(provider.WaveFormat.Channels==2) provider=new StereoToMonoSampleProvider(provider);
            if(provider.WaveFormat.SampleRate!=16000) provider=new WdlResamplingSampleProvider(provider,16000);
            var pcm=new SampleToWaveProvider16(provider);
            using(var output=new MemoryStream())
            {
                using(var writer=new WaveFileWriter(new IgnoreDisposeStream(output),pcm.WaveFormat))
                { byte[] bytes=new byte[3200]; int n; while((n=pcm.Read(bytes,0,bytes.Length))>0) writer.Write(bytes,0,n); }
                byte[] wave=output.ToArray(); double sum=0; int count=0;
                using(var waveReader=new WaveFileReader(new MemoryStream(wave,false)))
                { byte[] bytes=new byte[3200]; int n; while((n=waveReader.Read(bytes,0,bytes.Length))>0) for(int i=0;i+1<n;i+=2) { double s=(short)(bytes[i]|(bytes[i+1]<<8))/32768.0;sum+=s*s;count++; } }
                return new Result { Wave=wave,Rms=Math.Sqrt(sum/Math.Max(1,count)),Seconds=count/16000.0,Error="" };
            }
        }
    }
    private sealed class IgnoreDisposeStream : Stream
    {
        readonly Stream stream; public IgnoreDisposeStream(Stream value) { stream=value; }
        public override bool CanRead { get { return stream.CanRead; } } public override bool CanSeek { get { return stream.CanSeek; } } public override bool CanWrite { get { return stream.CanWrite; } }
        public override long Length { get { return stream.Length; } } public override long Position { get { return stream.Position; } set { stream.Position=value; } }
        public override void Flush() { stream.Flush(); } public override int Read(byte[] b,int o,int n) { return stream.Read(b,o,n); }
        public override long Seek(long o,SeekOrigin origin) { return stream.Seek(o,origin); } public override void SetLength(long n) { stream.SetLength(n); } public override void Write(byte[] b,int o,int n) { stream.Write(b,o,n); }
    }
}
