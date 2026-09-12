using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace CodexReader {
    public static class AudioPlayer {
        // Explicit endpoint selection keeps the TTS route equal to the AEC reference.
        private static readonly object Gate=new object();
        private static WasapiOut player;
        private static MediaFoundationReader reader;
        private static AudioLevelProvider meter;
        private static MMDevice endpoint;
        private static string selectedEndpoint="",lastError="";
        private static double startSeconds;
        public static string RenderEndpointId { get { lock(Gate) { EnsureEndpoint(); return endpoint.ID; } } }
        public static string LastError { get { lock(Gate) return lastError; } }
        public static double PositionSeconds { get { lock(Gate) {
            if(reader==null || player==null) return 0;
            // The decoder reads ahead. Use bytes presented by WASAPI in its
            // output format, then add the seek origin for a resumed clip.
            double position=startSeconds;
            try { position+=player.GetPosition()/(double)player.OutputWaveFormat.AverageBytesPerSecond; }
            catch { return startSeconds; } // Repeating audio is safer than skipping it.
            return Math.Max(0,Math.Min(reader.TotalTime.TotalSeconds,position));
        } } }
        // This player's decoded PCM loudness, not a microphone/system meter or FFT.
        public static double Level { get { lock(Gate) {
            return player!=null && player.PlaybackState==PlaybackState.Playing && meter!=null ? meter.Level : 0;
        } } }
        public static void SelectEndpoint(string endpointId) {
            lock(Gate) { Stop(); if(endpoint!=null) endpoint.Dispose(); endpoint=null; selectedEndpoint=endpointId ?? ""; EnsureEndpoint(); }
        }
        private static void EnsureEndpoint() {
            if(endpoint!=null) {
                if(endpoint.State!=DeviceState.Active) throw new InvalidOperationException("The selected speaker was disconnected.");
                return;
            }
            using(var devices=new MMDeviceEnumerator()) {
                endpoint=String.IsNullOrEmpty(selectedEndpoint) ? devices.GetDefaultAudioEndpoint(DataFlow.Render,Role.Multimedia) : devices.GetDevice(selectedEndpoint);
                selectedEndpoint=endpoint.ID;
            }
        }
        public static void Play(string path) {
            PlayFrom(path,0);
        }
        public static void PlayFrom(string path,double positionSeconds) {
            if(Double.IsNaN(positionSeconds) || Double.IsInfinity(positionSeconds) || positionSeconds<0)
                throw new ArgumentOutOfRangeException("positionSeconds");
            lock(Gate) {
                Stop(); EnsureEndpoint(); lastError="";
                try {
                    if(!File.Exists(path)) throw new FileNotFoundException("The voice clip is missing.",path);
                    reader=new MediaFoundationReader(path);
                    reader.CurrentTime=TimeSpan.FromSeconds(Math.Min(positionSeconds,reader.TotalTime.TotalSeconds));
                    startSeconds=reader.CurrentTime.TotalSeconds;
                    meter=new AudioLevelProvider(reader);
                    player=new WasapiOut(endpoint,AudioClientShareMode.Shared,true,60);
                    player.Init(meter); player.Play();
                } catch(Exception ex) { lastError=ex.Message; Stop(); throw; }
            }
        }
        public static string State {
            get { lock(Gate) {
                if(player==null) return "closed";
                if(player.PlaybackState==PlaybackState.Playing) return "playing";
                if(player.PlaybackState==PlaybackState.Paused) return "paused";
                return "stopped";
            } }
        }
        public static void Pause() { lock(Gate) { if(player!=null) player.Pause(); if(meter!=null) meter.Reset(); } }
        public static void Resume() { lock(Gate) { if(player!=null) { if(meter!=null) meter.Reset(); player.Play(); } } }
        public static void Stop() {
            lock(Gate) {
                if(player!=null) { try { player.Stop(); } finally { player.Dispose(); player=null; } }
                if(meter!=null) { meter.Reset(); meter=null; }
                if(reader!=null) { reader.Dispose(); reader=null; }
                startSeconds=0;
            }
        }
    }

    // Read runs on WasapiOut's worker. It never takes AudioPlayer.Gate: Stop and
    // Pause can wait for that worker while holding Gate. Immutable snapshots keep
    // the UI meter coherent without a cross-thread callback or a shared lock.
    internal sealed class AudioLevelProvider : IWaveProvider {
        private sealed class Sample { internal readonly double Level; internal readonly long Timestamp; internal Sample(double level,long timestamp) { Level=level; Timestamp=timestamp; } }
        private readonly IWaveProvider source;
        private readonly Func<long> clock;
        private readonly int sampleBytes;
        private readonly bool floatingPoint;
        private Sample latest;
        internal AudioLevelProvider(IWaveProvider source):this(source,Stopwatch.GetTimestamp) {}
        internal AudioLevelProvider(IWaveProvider source,Func<long> clock) {
            if(source==null) throw new ArgumentNullException("source");
            if(clock==null) throw new ArgumentNullException("clock");
            this.source=source; this.clock=clock;
            WaveFormat format=source.WaveFormat;
            WaveFormatEncoding encoding=format.Encoding;
            WaveFormatExtensible extensible=format as WaveFormatExtensible;
            if(extensible!=null) {
                if(extensible.SubFormat==new Guid("00000001-0000-0010-8000-00aa00389b71")) encoding=WaveFormatEncoding.Pcm;
                else if(extensible.SubFormat==new Guid("00000003-0000-0010-8000-00aa00389b71")) encoding=WaveFormatEncoding.IeeeFloat;
            }
            floatingPoint=encoding==WaveFormatEncoding.IeeeFloat;
            int bits=format.BitsPerSample;
            if(!((encoding==WaveFormatEncoding.Pcm && (bits==8 || bits==16 || bits==24 || bits==32)) || (floatingPoint && (bits==32 || bits==64))))
                throw new NotSupportedException("The decoded audio format cannot be metered: "+format.ToString());
            sampleBytes=bits/8;
            latest=new Sample(0,clock());
        }
        public WaveFormat WaveFormat { get { return source.WaveFormat; } }
        public double Level { get {
            Sample sample=Volatile.Read(ref latest);
            double age=Math.Max(0,(clock()-sample.Timestamp)/(double)Stopwatch.Frequency);
            if(age>=.35) return 0;
            // A normal 60 ms WASAPI buffer stays current. Missing future PCM fades
            // out promptly; it never leaves a latched visual level behind.
            return sample.Level*(age<=.10 ? 1 : (.35-age)/.25);
        } }
        public void Reset() { Volatile.Write(ref latest,new Sample(0,clock())); }
        public int Read(byte[] buffer,int offset,int count) {
            int read=source.Read(buffer,offset,count);
            int samples=read/sampleBytes;
            if(samples==0) { Reset(); return read; }
            double sum=0;
            for(int i=offset,end=offset+samples*sampleBytes;i<end;i+=sampleBytes) {
                double value;
                if(floatingPoint) value=sampleBytes==4 ? BitConverter.ToSingle(buffer,i) : BitConverter.ToDouble(buffer,i);
                else if(sampleBytes==1) value=(buffer[i]-128)/128.0;
                else if(sampleBytes==2) value=(short)(buffer[i] | (buffer[i+1]<<8))/32768.0;
                else if(sampleBytes==3) { int raw=buffer[i] | (buffer[i+1]<<8) | (buffer[i+2]<<16); if((raw & 0x800000)!=0) raw|=unchecked((int)0xff000000); value=raw/8388608.0; }
                else value=BitConverter.ToInt32(buffer,i)/2147483648.0;
                if(Double.IsNaN(value) || Double.IsInfinity(value)) value=0;
                value=Math.Max(-1,Math.Min(1,value)); sum+=value*value;
            }
            double rms=Math.Sqrt(sum/samples);
            double level=rms<=.001 ? 0 : Math.Max(0,Math.Min(1,(20*Math.Log10(rms)+60)/60));
            Volatile.Write(ref latest,new Sample(level,clock()));
            return read;
        }
    }
}
