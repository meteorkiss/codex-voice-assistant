param([string]$Root=(Split-Path -Parent $PSScriptRoot),[switch]$SilentPlayback)
$ErrorActionPreference='Stop'
. (Join-Path $Root 'src\AudioBootstrap.ps1')
$outDir=Join-Path $Root 'work\tests\audio-level'
[void][IO.Directory]::CreateDirectory($outDir)
Add-Type -ReferencedAssemblies $audioReferences -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;
using NAudio.Wave;
public sealed class AudioLevelResult {
 public int Passed; public string[] Checks; public string[] DecoderFormats;
 public double SoftLevel, LoudLevel, DecayAt200ms;
 public string Mp3DecoderFormat; public int Mp3Blocks, Mp3DistinctLevels; public double Mp3MinLevel, Mp3MaxLevel;
}
public static class AudioLevelTests {
 private sealed class Bytes : IWaveProvider {
  public WaveFormat WaveFormat {get;private set;} public byte[] Data;public int Position;
  public Bytes(WaveFormat format,byte[] data){WaveFormat=format;Data=data;}
  public int Read(byte[] buffer,int offset,int count){int size=Math.Min(count,Data.Length-Position);Array.Copy(Data,Position,buffer,offset,size);Position+=size;return size;}
 }
 private sealed class Meter {
  private readonly object meter;private readonly Type type;private long ticks;
  public IWaveProvider Provider;
  public Meter(Type type,IWaveProvider source){this.type=type;meter=Activator.CreateInstance(type,BindingFlags.Instance|BindingFlags.NonPublic,null,new object[]{source,new Func<long>(()=>ticks)},null);Provider=(IWaveProvider)meter;}
  public double Level {get{return (double)type.GetProperty("Level").GetValue(meter,null);}}
  public void At(double ms){ticks=(long)(ms*Stopwatch.Frequency/1000);}
  public void Reset(){type.GetMethod("Reset").Invoke(meter,null);}
  public void ReadAll(){byte[] data=new byte[Provider.WaveFormat.AverageBytesPerSecond];Provider.Read(data,0,data.Length);}
 }
 private static readonly List<string> checks=new List<string>();
 private static void Check(bool value,string message){if(!value)throw new Exception(message);checks.Add(message);}
 private static double Expected(double rms){return rms<=.001?0:Math.Max(0,Math.Min(1,(20*Math.Log10(rms)+60)/60));}
 private static byte[] Pcm16(int amplitude,int channels=1,bool muteRight=false){var bytes=new byte[1600*channels*2];for(int frame=0;frame<1600;frame++)for(int channel=0;channel<channels;channel++){short sample=(short)((muteRight&&channel==1)?0:(frame%2==0?amplitude:-amplitude));var value=BitConverter.GetBytes(sample);Array.Copy(value,0,bytes,(frame*channels+channel)*2,2);}return bytes;}
 private static Meter Make(Type type,WaveFormat format,byte[] data){var meter=new Meter(type,new Bytes(format,data));meter.ReadAll();return meter;}
 public static AudioLevelResult Run(Type playerType,string directory,string mp3Path){
  checks.Clear();Type type=playerType.Assembly.GetType("CodexReader.AudioLevelProvider",true);
  var silent=Make(type,new WaveFormat(16000,16,1),new byte[3200]);Check(silent.Level==0,"all-zero PCM16 reports zero");
  var soft=Make(type,new WaveFormat(16000,16,1),Pcm16(512));var loud=Make(type,new WaveFormat(16000,16,1),Pcm16(16384));
  Check(soft.Level>0 && soft.Level<loud.Level && loud.Level<=1,"soft and loud decoded samples preserve actual loudness ordering");
  Check(Math.Abs(soft.Level-Expected(512/32768.0))<1e-10,"PCM16 soft level matches measured RMS dBFS mapping");
  Check(Math.Abs(loud.Level-Expected(.5))<1e-10,"PCM16 loud level matches measured RMS dBFS mapping");
  var floor=Make(type,new WaveFormat(16000,16,1),Pcm16(1));Check(floor.Level==0,"sub -60 dBFS values stay at the meter floor");
  var stereo=Make(type,new WaveFormat(16000,16,2),Pcm16(16384,2,true));Check(Math.Abs(stereo.Level-Expected(.5/Math.Sqrt(2)))<1e-10,"stereo RMS includes both channels without doubling the level");
  byte[] raw=Pcm16(4096);var source=new Bytes(new WaveFormat(16000,16,1),raw);var pass=new Meter(type,source);var buffer=new byte[raw.Length+11];for(int i=0;i<buffer.Length;i++)buffer[i]=0xA5;
  int read=pass.Provider.Read(buffer,5,raw.Length);bool same=read==raw.Length;for(int i=0;i<raw.Length;i++)same &= buffer[i+5]==raw[i];
  Check(same && buffer[0]==0xA5 && buffer[buffer.Length-1]==0xA5,"meter forwards original PCM bytes and respects buffer offset/count");
  Check(object.ReferenceEquals(pass.Provider.WaveFormat,source.WaveFormat),"meter retains the original audio format object");
  pass.Provider.Read(buffer,0,buffer.Length);Check(pass.Level==0,"end of stream clears the last decoded level");
  var floatBytes=new byte[6400];for(int i=0;i<1600;i++)Array.Copy(BitConverter.GetBytes(i%2==0?.2f:-.2f),0,floatBytes,i*4,4);
  var floating=Make(type,WaveFormat.CreateIeeeFloatWaveFormat(16000,1),floatBytes);Check(Math.Abs(floating.Level-Expected(.2))<1e-7,"float32 decoded PCM uses actual float amplitudes");
  var invalidFloats=new byte[8];Array.Copy(BitConverter.GetBytes(float.NaN),0,invalidFloats,0,4);Array.Copy(BitConverter.GetBytes(float.PositiveInfinity),0,invalidFloats,4,4);
  Check(Make(type,WaveFormat.CreateIeeeFloatWaveFormat(16000,1),invalidFloats).Level==0,"non-finite float PCM cannot corrupt the UI level");
  var clipped=Make(type,WaveFormat.CreateIeeeFloatWaveFormat(16000,1),BitConverter.GetBytes(2f));Check(clipped.Level==1,"over-range float PCM is bounded at one");
  var pcm8=new byte[1600];for(int i=0;i<pcm8.Length;i++)pcm8[i]=128;Check(Make(type,new WaveFormat(16000,8,1),pcm8).Level==0,"unsigned PCM8 midpoint is silence");
  var pcm24=new byte[4800];for(int i=0;i<1600;i++){int value=i%2==0?4194304:-4194304;pcm24[i*3]=(byte)value;pcm24[i*3+1]=(byte)(value>>8);pcm24[i*3+2]=(byte)(value>>16);}
  Check(Math.Abs(Make(type,new WaveFormat(16000,24,1),pcm24).Level-Expected(.5))<1e-10,"signed PCM24 is sign-extended correctly");
  var pcm32=new byte[6400];for(int i=0;i<1600;i++)Array.Copy(BitConverter.GetBytes(i%2==0?1073741824:-1073741824),0,pcm32,i*4,4);
  Check(Math.Abs(Make(type,new WaveFormat(16000,32,1),pcm32).Level-Expected(.5))<1e-10,"signed PCM32 uses full scale without integer overflow");
  Check(Math.Abs(Make(type,new WaveFormatExtensible(16000,16,1),Pcm16(16384)).Level-Expected(.5))<1e-10,"extensible PCM format is recognized by its subformat");
  loud.At(99);Check(Math.Abs(loud.Level-Expected(.5))<1e-10,"fresh WASAPI-sized buffer holds the measured level");
  loud.At(200);double decay=loud.Level;Check(decay>0 && decay<Expected(.5),"missing future PCM decays without inventing new amplitude");
  loud.At(349);Check(loud.Level<decay && loud.Level>0,"stale level continues down monotonically");
  loud.At(350);Check(loud.Level==0,"350 ms stale data returns exact zero");
  loud.At(10000);Check(loud.Level==0,"very old data never revives");
  var reset=Make(type,new WaveFormat(16000,16,1),Pcm16(16384));reset.Reset();Check(reset.Level==0,"pause/resume reset removes an old level immediately");
  var streamSource=new Bytes(new WaveFormat(16000,16,1),Pcm16(16384));var streamMeter=new Meter(type,streamSource);streamMeter.ReadAll();streamSource.Data=new byte[3200];streamSource.Position=0;streamMeter.At(60);streamMeter.ReadAll();Check(streamMeter.Level==0,"new silent PCM clears a previous loud block");
  var unlocked= new Meter(type,new Bytes(new WaveFormat(16000,16,1),Pcm16(8192)));object gate=playerType.GetField("Gate",BindingFlags.Static|BindingFlags.NonPublic).GetValue(null);
  using(var completed=new ManualResetEvent(false)){Exception fault=null;var thread=new Thread(()=>{try{unlocked.ReadAll();}catch(Exception ex){fault=ex;}finally{completed.Set();}});thread.IsBackground=true;Monitor.Enter(gate);try{thread.Start();Check(completed.WaitOne(700),"audio Read completes while AudioPlayer Gate is held");Check(fault==null,"independent audio-thread metering succeeds");}finally{Monitor.Exit(gate);}thread.Join();}
  var formats=new List<string>();
  foreach(bool useFloat in new[]{false,true}){
   string path=Path.Combine(directory,useFloat?"decode-float.wav":"decode-pcm16.wav");
   try{WaveFormat input=useFloat?WaveFormat.CreateIeeeFloatWaveFormat(16000,1):new WaveFormat(16000,16,1);byte[] data=useFloat?floatBytes:Pcm16(16384);
    using(var writer=new WaveFileWriter(path,input))writer.Write(data,0,data.Length);
    using(var decoder=new MediaFoundationReader(path)){var measured=new Meter(type,decoder);measured.ReadAll();Check(measured.Level>0 && measured.Level<=1,"actual MediaFoundationReader output is metered for "+(useFloat?"float WAV":"PCM16 WAV"));formats.Add((useFloat?"float WAV -> ":"PCM16 WAV -> ")+decoder.WaveFormat.ToString());}
   }finally{if(File.Exists(path))File.Delete(path);}
  }
  Check((double)playerType.GetProperty("Level").GetValue(null,null)==0,"public player Level is zero without a playing clip");
  int blocks=0;double minimum=1,maximum=0;var distinct=new HashSet<int>();string mp3Format;
  using(var decoder=new MediaFoundationReader(mp3Path)){
   mp3Format=decoder.WaveFormat.ToString();var measured=new Meter(type,decoder);
   int count=Math.Max(decoder.WaveFormat.BlockAlign,decoder.WaveFormat.AverageBytesPerSecond/50);
   count-=count%decoder.WaveFormat.BlockAlign;byte[] block=new byte[count];
   while(true){measured.At(blocks*20);int size=measured.Provider.Read(block,0,block.Length);if(size==0)break;double level=measured.Level;
    Check(level>=0 && level<=1 && !Double.IsNaN(level),"cached TTS MP3 block "+blocks+" yields a bounded measured level");
    minimum=Math.Min(minimum,level);maximum=Math.Max(maximum,level);distinct.Add((int)Math.Round(level*1000));blocks++;
   }
   Check(measured.Level==0,"cached TTS MP3 EOF clears the meter");
  }
  Check(blocks>=5 && distinct.Count>=4,"actual cached TTS MP3 has multiple distinct decoded block levels");
  Check(maximum-minimum>.15,"actual cached TTS MP3 level follows substantial within-clip amplitude changes");
  return new AudioLevelResult{Passed=checks.Count,Checks=checks.ToArray(),DecoderFormats=formats.ToArray(),SoftLevel=soft.Level,LoudLevel=Expected(.5),DecayAt200ms=decay,Mp3DecoderFormat=mp3Format,Mp3Blocks=blocks,Mp3DistinctLevels=distinct.Count,Mp3MinLevel=minimum,Mp3MaxLevel=maximum};
 }
}
'@
$result=[AudioLevelTests]::Run([CodexReader.AudioPlayer],$outDir,(Join-Path $Root 'assets\ack-zh-TW-HsiaoChenNeural.mp3'))
$result|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $outDir 'result.json') -Encoding UTF8
Write-Output ('PASS '+$result.Passed+' deterministic decoded-audio meter checks')
$result|Select-Object SoftLevel,LoudLevel,DecayAt200ms,DecoderFormats,Mp3DecoderFormat,Mp3Blocks,Mp3DistinctLevels,Mp3MinLevel,Mp3MaxLevel|ConvertTo-Json -Depth 3
Write-Output 'No microphone or speaker playback. Nonzero fixtures were decoded from local files only and deleted.'
if($SilentPlayback){
    $silentPath=Join-Path $outDir ('silent-player-'+[Guid]::NewGuid().ToString('N')+'.wav')
    $writer=[NAudio.Wave.WaveFileWriter]::new($silentPath,[NAudio.Wave.WaveFormat]::new(16000,16,1))
    try{$samples=New-Object byte[] (16000*2*3);$writer.Write($samples,0,$samples.Length)}finally{$writer.Dispose()}
    try{
        [CodexReader.AudioPlayer]::Play($silentPath);Start-Sleep -Milliseconds 160
        if([CodexReader.AudioPlayer]::State -ne 'playing' -or [CodexReader.AudioPlayer]::Level -ne 0){throw 'Silent playback must play while reporting zero actual level.'}
        $reader=[CodexReader.AudioPlayer].GetField('reader',[Reflection.BindingFlags]'Static,NonPublic').GetValue($null)
        $meter=[CodexReader.AudioPlayer].GetField('meter',[Reflection.BindingFlags]'Static,NonPublic').GetValue($null)
        $input=$meter.GetType().GetField('source',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($meter)
        if(-not [object]::ReferenceEquals($reader,$input)){throw 'Production meter must wrap the actual retained decoder.'}
        [CodexReader.AudioPlayer]::Pause();Start-Sleep -Milliseconds 80
        if([CodexReader.AudioPlayer]::State -ne 'paused' -or [CodexReader.AudioPlayer]::Level -ne 0){throw 'Paused player must report exact zero.'}
        [CodexReader.AudioPlayer]::Resume();Start-Sleep -Milliseconds 160
        if([CodexReader.AudioPlayer]::State -ne 'playing' -or [CodexReader.AudioPlayer]::Level -ne 0){throw 'Resumed silent player must keep exact zero.'}
        [CodexReader.AudioPlayer]::Stop()
        if([CodexReader.AudioPlayer]::State -ne 'closed' -or [CodexReader.AudioPlayer]::Level -ne 0){throw 'Stopped player must report exact zero and release playback.'}
        Write-Output 'PASS 5 real shared-WASAPI silence/level/lifecycle checks; no nonzero audio was played.'
    }finally{[CodexReader.AudioPlayer]::Stop();if(Test-Path -LiteralPath $silentPath){Remove-Item -LiteralPath $silentPath -Force}}
}
