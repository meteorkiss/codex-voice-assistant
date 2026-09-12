param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run Windows PowerShell 5.1 with -STA.'}
. (Join-Path $Root 'src\DesktopShell.ps1')
$outDir=Join-Path $Root 'work\center-playback-render'
[void][IO.Directory]::CreateDirectory($outDir)
$shell=New-DesktopShell
$script:checks=0;$script:buttonClicks=0;$script:stopClicks=0;$script:waveClicks=0
function Assert-That([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function Get-HitOwner($RootVisual,[double]$X,[double]$Y){
    $hit=[Windows.Media.VisualTreeHelper]::HitTest($RootVisual,(New-Object Windows.Point($X,$Y)))
    if(-not $hit){return $null}
    $node=$hit.VisualHit
    while($node){
        if($node -is [Windows.Controls.Button] -or $node -is [ShengBan.Desktop.WaveformView]){return $node}
        $node=[Windows.Media.VisualTreeHelper]::GetParent($node)
    }
    return $hit.VisualHit
}
function Render-Root([int]$Width,[int]$Height){
    $root=$shell.Window.Content
    $root.Measure((New-Object Windows.Size($Width,$Height)))
    $root.Arrange((New-Object Windows.Rect(0,0,$Width,$Height)))
    $root.UpdateLayout()
    $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap($Width,$Height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($root)
    return $bitmap
}
function Save-Png($Bitmap,[string]$Name){
    $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($Bitmap))
    $stream=[IO.File]::Create((Join-Path $outDir ($Name+'.png')))
    try{$encoder.Save($stream)}finally{$stream.Dispose()}
}
function On-Desktop($Bitmap,[string]$Color){
    $visual=New-Object Windows.Media.DrawingVisual;$dc=$visual.RenderOpen()
    $bounds=New-Object Windows.Rect(0,0,$Bitmap.PixelWidth,$Bitmap.PixelHeight)
    $dc.DrawRectangle([Windows.Media.BrushConverter]::new().ConvertFromString($Color),$null,$bounds)
    $dc.DrawImage($Bitmap,$bounds);$dc.Close()
    $result=New-Object Windows.Media.Imaging.RenderTargetBitmap($Bitmap.PixelWidth,$Bitmap.PixelHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $result.Render($visual);return $result
}
function Save-Gallery($Images,[string]$Name,[string]$Color){
    $visual=New-Object Windows.Media.DrawingVisual;$dc=$visual.RenderOpen()
    $dc.DrawRectangle([Windows.Media.BrushConverter]::new().ConvertFromString($Color),$null,(New-Object Windows.Rect(0,0,780,720)))
    $index=0
    foreach($state in @('play','pause')){
        foreach($style in @('rays','halo','particles','minimal','bars','flow')){
            $column=$index%3;$row=[Math]::Floor($index/3)
            $bitmap=$Images[$style+'-'+$state]
            $width=$bitmap.PixelWidth*.62;$height=$bitmap.PixelHeight*.62
            $dc.DrawImage($bitmap,(New-Object Windows.Rect(($column*260+(260-$width)/2),($row*180+(180-$height)/2),$width,$height)))
            $index++
        }
    }
    $dc.Close();$result=New-Object Windows.Media.Imaging.RenderTargetBitmap(780,720,96,96,[Windows.Media.PixelFormats]::Pbgra32);$result.Render($visual);Save-Png $result $Name
}
try{
    $button=$shell.Controls.CenterPlaybackButton;$stop=$shell.Controls.CenterStopButton;$group=$shell.Controls.CenterPlaybackGroup;$rootVisual=$shell.Window.Content
    Assert-That ($button -is [Windows.Controls.Button] -and $rootVisual -is [Windows.Controls.Grid] -and $null -eq $rootVisual.Background) 'Overlay must be a background-free Grid and native Button.'
    Assert-That ($button.Tag -eq 'play' -and $stop.Tag -eq 'stop' -and $button.Width -eq 34 -and $stop.Width -eq 34 -and $button.Clip -is [Windows.Media.EllipseGeometry] -and $stop.Clip -is [Windows.Media.EllipseGeometry]) 'Default button pair size, state or circular clips are incorrect.'
    Assert-That ([object]::ReferenceEquals($button.ContextMenu,$shell.Menu) -and [object]::ReferenceEquals($shell.Waveform.ContextMenu,$shell.Menu)) 'Button and waveform do not share the settings context menu.'
    Assert-That ([Windows.Controls.ContextMenuService]::GetShowOnDisabled($button) -and [Windows.Controls.ToolTipService]::GetShowOnDisabled($button)) 'Disabled button loses its context menu or tooltip.'
    Assert-That ([object]::ReferenceEquals($stop.ContextMenu,$shell.Menu) -and [Windows.Controls.ContextMenuService]::GetShowOnDisabled($stop) -and [Windows.Controls.ToolTipService]::GetShowOnDisabled($stop)) 'Stop button must retain the same disabled context menu and tooltip behavior.'
    Assert-That ([object]::ReferenceEquals([Windows.Media.VisualTreeHelper]::GetParent($button),$group) -and [object]::ReferenceEquals([Windows.Media.VisualTreeHelper]::GetParent($stop),$group) -and [object]::ReferenceEquals([Windows.Media.VisualTreeHelper]::GetParent($group),$rootVisual) -and [object]::ReferenceEquals([Windows.Media.VisualTreeHelper]::GetParent($shell.Waveform),$rootVisual) -and $null -eq $group.Background) 'Button group must be transparent and a sibling of the draggable waveform.'
    $button.Add_Click({$script:buttonClicks++})
    $stop.Add_Click({$script:stopClicks++})
    $shell.Waveform.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent,[Windows.RoutedEventHandler]{$script:waveClicks++})
    $button.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    $stop.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    Assert-That ($script:buttonClicks -eq 1 -and $script:stopClicks -eq 1 -and $script:waveClicks -eq 0) 'Center clicks are not independent or reached the waveform route.'
    $hover=@($button.Style.Triggers | Where-Object {$_.Property -eq [Windows.UIElement]::IsMouseOverProperty})
    Assert-That ($hover.Count -eq 1 -and $hover[0].Setters[0].Value -eq .60) 'Hover must use the restrained opacity trigger.'
    $gallery=@{}
    foreach($size in @(180,260,360)){
        foreach($style in @('rays','halo','particles','minimal','bars','flow')){
            Set-DesktopShellSize $shell $size $style
            $height=if($style -in @('bars','flow')){[int]($size*.4)}else{$size}
            $shell.Waveform.SetFrame($style,.45,'speak',1.25)
            foreach($state in @('play','pause')){
                $button.Tag=$state;$button.IsEnabled=$true;$stop.IsEnabled=$true
                $bitmap=Render-Root $size $height
                $playGlyph=$button.Template.FindName('PlayGlyph',$button);$pauseGlyph=$button.Template.FindName('PauseGlyph',$button)
                Assert-That (($playGlyph.Visibility -eq 'Visible') -eq ($state -eq 'play') -and ($pauseGlyph.Visibility -eq 'Visible') -eq ($state -eq 'pause')) ($style+'/'+$size+' glyph did not follow Tag.')
                Assert-That ($button.Opacity -eq .30 -and $stop.Opacity -eq .30 -and $button.ActualHeight -le $height -and $stop.Template.FindName('StopGlyph',$stop).Visibility -eq 'Visible') ($style+'/'+$size+' pair is too large, too opaque or missing its stop glyph.')
                $groupCenter=$group.TranslatePoint((New-Object Windows.Point(($group.ActualWidth/2),($group.ActualHeight/2))),$rootVisual)
                Assert-That ([Math]::Abs($groupCenter.X-$size/2) -lt .1 -and [Math]::Abs($groupCenter.Y-$height/2) -lt .1) ($style+'/'+$size+' button pair is not centered.')
                if($style -notin @('bars','flow')){Assert-That (([Math]::Sqrt([Math]::Pow($group.ActualWidth/2,2)+[Math]::Pow($group.ActualHeight/2,2))) -lt ($size*65/280)) ($style+'/'+$size+' pair no longer fits inside the smallest transparent inner disk.')}
                Assert-That ($null -eq (Get-HitOwner $rootVisual 0 0)) ($style+'/'+$size+' transparent outer corner captures input.')
                foreach($target in @($button,$stop)){
                    $position=$target.TranslatePoint((New-Object Windows.Point(($target.ActualWidth/2),($target.ActualHeight/2))),$rootVisual)
                    Assert-That ([object]::ReferenceEquals((Get-HitOwner $rootVisual $position.X $position.Y),$target)) ($style+'/'+$size+' button center does not hit its own control.')
                    $offset=$target.ActualWidth/2-1
                    foreach($dx in @(-$offset,$offset)){foreach($dy in @(-$offset,$offset)){
                        $point=New-Object Windows.Point(($position.X+$dx),($position.Y+$dy))
                        $owner=Get-HitOwner $rootVisual $point.X $point.Y
                        Assert-That (-not [object]::ReferenceEquals($owner,$target)) ($style+'/'+$size+' circular button corner captures input.')
                        Assert-That (($null -ne $owner) -eq $shell.Waveform.IsInteractivePoint($point)) ($style+'/'+$size+' transparent button corner changed underlying waveform hits.')
                    }}
                }
                $gapPoint=New-Object Windows.Point(($size/2),($height/2))
                Assert-That (($null -ne (Get-HitOwner $rootVisual $gapPoint.X $gapPoint.Y)) -eq $shell.Waveform.IsInteractivePoint($gapPoint)) ($style+'/'+$size+' transparent gap between buttons captures input.')
                $mark=if($style -eq 'bars'){New-Object Windows.Point((23*$size/280),($height/2))}elseif($style -eq 'flow'){New-Object Windows.Point((14*$size/280),($height/2))}else{New-Object Windows.Point(($size*215/260),($height/2))}
                Assert-That ([object]::ReferenceEquals((Get-HitOwner $rootVisual $mark.X $mark.Y),$shell.Waveform)) ($style+'/'+$size+' original waveform no longer receives its own marks.')
                $pixels=New-Object byte[] ($size*$height*4);$bitmap.CopyPixels($pixels,$size*4,0)
                Assert-That ($pixels[3] -eq 0) ($style+'/'+$size+' outer alpha is no longer zero.')
                if($style -notin @('bars','flow')){
                    $gapX=[int]($size/2);$gapY=[int]($height/2+25)
                    Assert-That ($pixels[($gapY*$size+$gapX)*4+3] -eq 0 -and $null -eq (Get-HitOwner $rootVisual $gapX $gapY)) ($style+'/'+$size+' gap around center button lost transparency or click-through.')
                }
                foreach($background in @(@{name='light';color='#F5F5F7'},@{name='dark';color='#20242D'})){
                    Save-Png (On-Desktop $bitmap $background.color) ($style+'-'+$state+'-'+$size+'-'+$background.name)
                }
                if($size -eq 260){$gallery[$style+'-'+$state]=$bitmap}
            }
        }
    }
    Save-Gallery $gallery 'all-styles-light' '#F5F5F7';Save-Gallery $gallery 'all-styles-dark' '#20242D'
    Set-DesktopShellSize $shell 260 'rays';$shell.Waveform.SetFrame('rays',0,'idle',0);$button.Tag='play';$button.IsEnabled=$false;$stop.IsEnabled=$false
    $disabled=Render-Root 260 260
    Assert-That ($button.Opacity -eq .15 -and $stop.Opacity -eq .15) 'Disabled center buttons must remain visible but quieter.'
    Save-Png (On-Desktop $disabled '#F5F5F7') 'disabled-light';Save-Png (On-Desktop $disabled '#20242D') 'disabled-dark'
    @{ok=$true;checks=$script:checks;sizes=@(180,260,360);styles=@('rays','halo','particles','minimal','bars','flow');states=@('play','pause');renderDirectory=$outDir;desktopClickThrough='WPF hit geometry and rendered alpha tested; no external desktop click automation.';realAudio=0;realMicrophones=0;realCodexRequests=0} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $outDir 'result.json') -Encoding UTF8
    Write-Output ('Passed '+$script:checks+' center-playback checks. Renders: '+$outDir)
}finally{Close-DesktopShell $shell}
