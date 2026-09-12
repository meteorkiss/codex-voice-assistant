param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationCore,PresentationFramework,WindowsBase,System.Xaml
Add-Type -Path (Join-Path $Root 'src\WaveformView.cs') -ReferencedAssemblies @('PresentationCore','PresentationFramework','WindowsBase','System.Xaml')
Add-Type -ReferencedAssemblies @('PresentationCore','PresentationFramework','WindowsBase','System.Xaml') -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Reflection;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
public static class WaveformTestPixels {
 public static byte[] Render(FrameworkElement view,int width,int height) {
  view.Measure(new Size(width,height));view.Arrange(new Rect(0,0,width,height));view.UpdateLayout();
  var b=new RenderTargetBitmap(width,height,96,96,PixelFormats.Pbgra32);b.Render(view);
  var bytes=new byte[width*height*4];b.CopyPixels(bytes,width*4,0);return bytes;
 }
 public static double Delta(byte[] a,byte[] b){long sum=0;for(int i=0;i<a.Length;i++)sum+=Math.Abs((int)a[i]-(int)b[i]);return sum/(double)a.Length;}
 public static int PaintedDisk(byte[] data,int width,int height,double radius){int count=0;for(int y=0;y<height;y++)for(int x=0;x<width;x++)if(Math.Pow(x+.5-width/2.0,2)+Math.Pow(y+.5-height/2.0,2)<radius*radius&&data[(y*width+x)*4+3]>0)count++;return count;}
 public static double[] DrawTimes(FrameworkElement view,int count){
  var method=view.GetType().GetMethod("OnRender",BindingFlags.Instance|BindingFlags.NonPublic);var results=new double[count];
  for(int i=0;i<count;i++){var visual=new DrawingVisual();var drawing=visual.RenderOpen();var watch=Stopwatch.StartNew();method.Invoke(view,new object[]{drawing});drawing.Close();watch.Stop();results[i]=watch.Elapsed.TotalMilliseconds;}
  return results;
 }
}
'@
$checks=[Collections.Generic.List[string]]::new()
function Assert-Wave([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$checks.Add($Message)}
function Private-Field($View,[string]$Name){$View.GetType().GetField($Name,[Reflection.BindingFlags]'NonPublic,Instance').GetValue($View)}
function Pump-Ui([int]$Milliseconds){
 $frame=[Windows.Threading.DispatcherFrame]::new();$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds($Milliseconds)
 $handler={ $timer.Stop();$frame.Continue=$false }.GetNewClosure();$timer.Add_Tick($handler);$timer.Start()
 try{[Windows.Threading.Dispatcher]::PushFrame($frame)}finally{$timer.Stop();$timer.Remove_Tick($handler)}
}
$bench=@()
$audioMetrics=@()
$audioImages=@{}
foreach($style in @('rays','halo','particles','minimal','bars','flow')){
 $view=[ShengBan.Desktop.WaveformView]::new();$height=if($style -in @('bars','flow')){112}else{280}
 $view.SetFrame($style,0,'idle',0);$first=[WaveformTestPixels]::Render($view,280,$height)
 for($i=1;$i -le 25;$i++){$view.SetFrame($style,0,'idle',$i/25.0)}
 $rest=[WaveformTestPixels]::Render($view,280,$height)
 Assert-Wave ($view.StyleName -eq $style) ($style+' preserves style ID')
 $quietDrift=[WaveformTestPixels]::Delta($first,$rest)
 Assert-Wave ($quietDrift -gt .005) ($style+' retains restrained idle drift at zero input')
 Assert-Wave ($rest[3] -eq 0) ($style+' outside remains transparent')
 Assert-Wave (-not $view.IsInteractivePoint([Windows.Point]::new(0,0))) ($style+' outside rejects dragging')
 if(-not $view.IsBar){
  $radius=if($style -eq 'halo'){75}elseif($style -eq 'minimal'){80}else{65}
  Assert-Wave ([WaveformTestPixels]::PaintedDisk($rest,280,280,$radius) -eq 0) ($style+' whole center is transparent at rest')
  Assert-Wave (-not $view.IsInteractivePoint([Windows.Point]::new(140,140))) ($style+' center rejects dragging')
  Assert-Wave ($view.IsInteractivePoint([Windows.Point]::new(235,140))) ($style+' original ring drag range works')
  for($i=26;$i -le 80;$i++){$view.SetFrame($style,1,'speak',$i/25.0)}
  $active=[WaveformTestPixels]::Render($view,280,280)
  Assert-Wave ([WaveformTestPixels]::PaintedDisk($active,280,280,$radius) -eq 0) ($style+' whole center is transparent at maximum activity')
  $scaled=[WaveformTestPixels]::Render($view,196,196)
  Assert-Wave ($view.IsInteractivePoint([Windows.Point]::new(164.5,98))) ($style+' scaled ring drag range works')
 }else{
  $x=if($style -eq 'bars'){23}else{14}
  Assert-Wave ($view.IsInteractivePoint([Windows.Point]::new($x,56))) ($style+' original drag point works')
 }
 $times=@([WaveformTestPixels]::DrawTimes($view,100)|Sort-Object)
 $bench += [ordered]@{style=$style;drawMedianMs=$times[50];drawP95Ms=$times[95]}
 $zero=[ShengBan.Desktop.WaveformView]::new();$low=[ShengBan.Desktop.WaveformView]::new();$loud=[ShengBan.Desktop.WaveformView]::new();$silentSpeak=[ShengBan.Desktop.WaveformView]::new();$silentListen=[ShengBan.Desktop.WaveformView]::new()
 # First frames share exactly the same motion phase. Differences therefore come
 # from supplied amplitude, not from clock speed or an invented speaking pulse.
 $zero.SetFrame($style,0,'idle',1);$low.SetFrame($style,.15,'speak',1);$loud.SetFrame($style,.8,'speak',1);$silentSpeak.SetFrame($style,0,'speak',1);$silentListen.SetFrame($style,0,'listen',1)
 $zeroPixels=[WaveformTestPixels]::Render($zero,280,$height);$lowPixels=[WaveformTestPixels]::Render($low,280,$height);$loudPixels=[WaveformTestPixels]::Render($loud,280,$height)
 $amplitudeDelta=[WaveformTestPixels]::Delta($zeroPixels,$loudPixels)
 Assert-Wave ([WaveformTestPixels]::Delta($zeroPixels,[WaveformTestPixels]::Render($silentSpeak,280,$height)) -eq 0 -and [WaveformTestPixels]::Delta($zeroPixels,[WaveformTestPixels]::Render($silentListen,280,$height)) -eq 0) ($style+' silent speaking and listening do not invent audio energy')
 Assert-Wave ($amplitudeDelta -gt [Math]::Max(.15,$quietDrift*4)) ($style+' actual amplitude visibly dominates idle drift at the same clock phase')
 Assert-Wave ([WaveformTestPixels]::Delta($lowPixels,$loudPixels) -gt .10 -and [WaveformTestPixels]::Delta($zeroPixels,$lowPixels) -gt .05) ($style+' low and high real input have distinguishable geometry or brightness')
 $audioMetrics += @{style=$style;quietOneSecondDelta=$quietDrift;fixedPhaseAmplitudeDelta=$amplitudeDelta}
 foreach($entry in @(@{name='zero';pixels=$zeroPixels},@{name='low';pixels=$lowPixels},@{name='loud';pixels=$loudPixels})){
  $audioImages[$style+'-'+$entry.name]=[Windows.Media.Imaging.BitmapSource]::Create(280,$height,96,96,[Windows.Media.PixelFormats]::Pbgra32,$null,$entry.pixels,1120)
 }
}
$view=[ShengBan.Desktop.WaveformView]::new();$view.SetFrame('rays',0,'idle',0)
$view.SetFrame('rays',.8,'idle',.04);$attack=Private-Field $view 'envelope'
Assert-Wave ($attack -gt .45 -and $attack -lt .8) 'input attacks quickly even while waiting for wake'
$view.SetFrame('rays',0,'idle',.08);$release=Private-Field $view 'envelope'
Assert-Wave ($release -lt $attack -and $release -gt .4) 'input decays instead of snapping to zero'
for($i=3;$i -le 35;$i++){$view.SetFrame('rays',0,'idle',$i*.04)}
Assert-Wave ((Private-Field $view 'envelope') -lt .02) 'input settles after the release tail'
$before=Private-Field $view 'motionPhase';$view.SetFrame('rays',0,'busy',1.44);$after=Private-Field $view 'motionPhase'
Assert-Wave ($after -gt $before -and $after-$before -lt .1) 'mode change keeps phase continuous'
$view.SetFrame('invalid',[double]::NaN,'invalid',[double]::PositiveInfinity)
Assert-Wave ($view.StyleName -eq 'rays' -and $view.Mode -eq 'idle' -and $view.Level -eq 0) 'invalid public input remains safely normalized'
$view.SetFrame('bars',2,'listen',0);Assert-Wave ($view.Level -eq 1 -and $view.IsBar) 'level maximum and IsBar remain compatible'
$view.SetFrame('halo',-2,'idle',0);Assert-Wave ($view.Level -eq 0 -and -not $view.IsBar) 'level minimum and ring mode remain compatible'
$a=[ShengBan.Desktop.WaveformView]::new();$b=[ShengBan.Desktop.WaveformView]::new()
for($i=0;$i -le 75;$i++){$mode=if($i -lt 25){'idle'}elseif($i -lt 50){'listen'}else{'speak'};$input=[Math]::Max(0,[Math]::Sin($i*.3))*.7;$a.SetFrame('rays',$input,$mode,$i*.04);$b.SetFrame('rays',$input,$mode,$i*.04)}
Assert-Wave ([WaveformTestPixels]::Delta([WaveformTestPixels]::Render($a,280,280),[WaveformTestPixels]::Render($b,280,280)) -eq 0) 'unloaded fixed-clock frame exports are deterministic'
$window=[Windows.Window]::new();$window.Width=2;$window.Height=2;$window.Left=-32000;$window.Top=-32000;$window.ShowInTaskbar=$false;$window.ShowActivated=$false;$window.WindowStyle='None';$window.Content=$a
try{
 $window.Show();Pump-Ui 100
 Assert-Wave ([bool](Private-Field $a 'renderingSubscribed')) 'visible loaded visual subscribes to composition rendering'
 $phase=Private-Field $a 'motionPhase';Pump-Ui 90
 Assert-Wave ((Private-Field $a 'motionPhase') -gt $phase) 'composition advances without new business timer samples'
 $window.Hide();Pump-Ui 35
 Assert-Wave (-not [bool](Private-Field $a 'renderingSubscribed')) 'hidden visual removes static rendering subscription'
 $window.Show();Pump-Ui 50
 Assert-Wave ([bool](Private-Field $a 'renderingSubscribed')) 'reshown visual resumes its rendering subscription'
}finally{$window.Close();Pump-Ui 35}
Assert-Wave (-not [bool](Private-Field $a 'renderingSubscribed')) 'closed visual removes static rendering subscription'
$out=Join-Path $Root 'work\waveform-redesign\after';[void](New-Item -ItemType Directory -Path $out -Force)
foreach($background in @(@{name='light';color='#F5F5F7'},@{name='dark';color='#20242D'})){
 $gallery=New-Object Windows.Controls.Grid;$gallery.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($background.color)
 for($i=0;$i -lt 3;$i++){[void]$gallery.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))}
 for($i=0;$i -lt 6;$i++){[void]$gallery.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))}
 $row=0
 foreach($style in @('rays','halo','particles','minimal','bars','flow')){
  $column=0
  foreach($entry in @(@{name='zero';label='0.00'},@{name='low';label='0.15'},@{name='loud';label='0.80'})){
   $tile=New-Object Windows.Controls.Grid
   $image=New-Object Windows.Controls.Image;$image.Source=$audioImages[$style+'-'+$entry.name];$image.Width=170;$image.Height=if($style -in @('bars','flow')){68}else{170};$image.HorizontalAlignment='Center';$image.VerticalAlignment='Center';$image.Margin='0,0,0,18';[void]$tile.Children.Add($image)
   $label=New-Object Windows.Controls.TextBlock;$label.Text=$style+' · input '+$entry.label;$label.FontSize=11;$label.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString($(if($background.name -eq 'dark'){'#A7AFBE'}else{'#6F7784'}));$label.HorizontalAlignment='Center';$label.VerticalAlignment='Bottom';$label.Margin='0,0,0,6';[void]$tile.Children.Add($label)
   [Windows.Controls.Grid]::SetRow($tile,$row);[Windows.Controls.Grid]::SetColumn($tile,$column);[void]$gallery.Children.Add($tile);$column++
  }
  $row++
 }
 $gallery.Measure((New-Object Windows.Size(660,1140)));$gallery.Arrange((New-Object Windows.Rect(0,0,660,1140)));$gallery.UpdateLayout()
 $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap(660,1140,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($gallery)
 $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$file=[IO.File]::Create((Join-Path $out ('audio-levels-'+$background.name+'.png')))
 try{$encoder.Save($file)}finally{$file.Dispose()}
}
[ordered]@{passed=$checks.Count;checks=@($checks);drawTiming=$bench;audioLevelContrasts=$audioMetrics;amplitudeSource='Controlled 0/.15/.8 values exercise the real rendering input; live AudioPlayer sampling is tested separately.'}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $out 'regression.json') -Encoding UTF8
Write-Output ('PASS '+$checks.Count+' waveform checks');$bench|ForEach-Object{[pscustomobject]$_}|Format-Table
