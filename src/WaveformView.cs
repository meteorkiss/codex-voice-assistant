using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;

namespace ShengBan.Desktop
{
    // These are level-driven motion designs, not individual frequency measurements.
    public sealed class WaveformView : FrameworkElement
    {
        private string style = "rays", mode = "idle";
        private double level, elapsed, visualTime, envelope, motionPhase;
        private double busyMix;
        private long inputTimestamp;
        private bool hasFrame, renderingSubscribed;
        private readonly SolidColorBrush[] colors = new SolidColorBrush[72];
        private readonly SolidColorBrush[,] dustBrushes = new SolidColorBrush[36, 12];
        private readonly Pen[] threadPens = new Pen[20], flowPens = new Pen[5], haloPens = new Pen[5];
        private readonly Pen[,] sheenPens = new Pen[3, 5];
        private readonly Pen minimalPen, minimalEchoPen, flowHitPen;
        private readonly Geometry wideHit, haloHit, minimalHit;
        private readonly SolidColorBrush hitBrush;
        private readonly double[] particleSeeds = new double[180];
        private StreamGeometry[] cachedFlow;
        public string StyleName { get { return style; } }
        public string Mode { get { return mode; } }
        public double Level { get { return level; } }
        public bool IsBar { get { return style == "bars" || style == "flow"; } }

        public WaveformView()
        {
            Focusable = false; Cursor = Cursors.SizeAll; SnapsToDevicePixels = false;
            for (int i = 0; i < colors.Length; i++) colors[i] = Brush(Palette(i / 71.0), 1);
            for (int i = 0; i < 36; i++) for (int j = 0; j < 12; j++)
            { Color color = Palette(i / 35.0); color.A = (byte)(255 * (.3 + .5 * j / 11.0)); dustBrushes[i, j] = Brush(color, 1); }
            // One-alpha hit areas preserve dragging between marks while leaving the
            // circular center and the surrounding desktop completely transparent.
            hitBrush = Brush(Color.FromArgb(1, 128, 180, 175), 1);
            wideHit = Annulus(66, 128); haloHit = Annulus(76, 112); minimalHit = Annulus(81, 108);
            for (int i = 0; i < 20; i++) threadPens[i] = Line(Spectrum(27 + i * 4.8, .39 + .36 * Math.Sin(i / 19.0 * Math.PI)), i % 6 == 0 ? .95 : .62);
            Color[] sheen = { Color.FromRgb(166, 231, 235), Color.FromRgb(223, 182, 217), Color.FromRgb(179, 207, 248) };
            double[] fade = { .07, .22, .48, .22, .07 };
            for (int i = 0; i < 3; i++) for (int j = 0; j < 5; j++) sheenPens[i, j] = Line(Brush(sheen[i], fade[j]), 1.1);
            double[] widths = { 20, 14, 9, 4.5, 1.2 };
            for (int i = 0; i < 5; i++) haloPens[i] = Line(Spectrum(36, i == 4 ? .85 : .035 + i * .022), widths[i]);
            for (int i = 0; i < 5; i++) flowPens[i] = Line(Spectrum(8 + i * 9, i == 2 ? .92 : .22 + .08 * i), i == 2 ? 1.7 : .85);
            minimalPen = Line(Spectrum(32, .9), 1.15); minimalEchoPen = Line(Spectrum(70, .34), .65);
            flowHitPen = Line(hitBrush, 12);
            for (int i = 0; i < 180; i++) particleSeeds[i] = Noise(i + 91);
            Loaded += OnLoaded; Unloaded += OnUnloaded; IsVisibleChanged += OnVisibilityChanged;
            System.Windows.Automation.AutomationProperties.SetName(this, "悬浮声波；拖动移动，右键打开菜单");
        }

        public void SetFrame(string newStyle, double newLevel, string newMode, double elapsedSeconds)
        {
            VerifyAccess();
            switch (newStyle) { case "rays": case "halo": case "particles": case "minimal": case "bars": case "flow": style = newStyle; break; default: style = "rays"; break; }
            mode = newMode == "listen" || newMode == "speak" || newMode == "busy" ? newMode : "idle";
            level = double.IsNaN(newLevel) || double.IsInfinity(newLevel) ? 0 : Math.Max(0, Math.Min(1, newLevel));
            elapsed = double.IsNaN(elapsedSeconds) || double.IsInfinity(elapsedSeconds) ? 0 : elapsedSeconds;
            inputTimestamp = Stopwatch.GetTimestamp();
            if (!hasFrame)
            {
                hasFrame = true; visualTime = elapsed; motionPhase = elapsed * .16; envelope = level;
                busyMix = mode == "busy" ? 1 : 0;
            }
            else Advance(elapsed);
            cachedFlow = null; InvalidateVisual();
        }
        private void OnLoaded(object sender, RoutedEventArgs e) { UpdateRenderingSubscription(); }
        private void OnUnloaded(object sender, RoutedEventArgs e) { UnsubscribeRendering(); }
        private void OnVisibilityChanged(object sender, DependencyPropertyChangedEventArgs e) { UpdateRenderingSubscription(); }
        private void UpdateRenderingSubscription()
        {
            if (!IsLoaded || !IsVisible) { UnsubscribeRendering(); return; }
            if (renderingSubscribed) return;
            inputTimestamp = Stopwatch.GetTimestamp(); elapsed = visualTime;
            CompositionTarget.Rendering += OnRendering; renderingSubscribed = true;
        }
        private void UnsubscribeRendering()
        { if (renderingSubscribed) { CompositionTarget.Rendering -= OnRendering; renderingSubscribed = false; } }
        private void OnRendering(object sender, EventArgs e)
        {
            if (!hasFrame) return;
            Advance(elapsed + (Stopwatch.GetTimestamp() - inputTimestamp) / (double)Stopwatch.Frequency);
            cachedFlow = null; InvalidateVisual();
        }
        private void Advance(double seconds)
        {
            // Live composition interpolates the supplied clock. Unloaded rendering
            // uses it exactly, so exported frames remain reproducible.
            double delta = seconds - visualTime;
            if (delta < 0) { if (delta < -.5) visualTime = seconds; return; }
            if (delta <= .00001) return;
            double dt = Math.Min(.25, delta); visualTime = seconds;
            envelope += (level - envelope) * (1 - Math.Exp(-dt / (level > envelope ? .042 : .22)));
            double blend = 1 - Math.Exp(-dt / .24);
            busyMix += ((mode == "busy" ? 1 : 0) - busyMix) * blend;
            // Integrate speed instead of multiplying elapsed by a new mode speed.
            // A listening/speaking label is not an audio sample. At zero level,
            // both settle to the same quiet drift as idle; sound drives motion.
            motionPhase += dt * (.16 + busyMix * .04 + Energy * 2.1);
        }
        private double Phase { get { return motionPhase; } }
        private double Breath { get { return .5 + .5 * Math.Sin(Phase * .91 - .7); } }
        // Expand quiet speech visually without changing microphone gain, wake
        // detection, or the raw Level reported to the rest of the application.
        // Keep silence at zero and preserve headroom through the entire range.
        private double Energy { get { return Math.Pow(Math.Max(0, Math.Min(1, envelope)), .55); } }
        private double Activity { get { return Energy; } }
        private static SolidColorBrush Brush(Color color, double opacity)
        { SolidColorBrush b = new SolidColorBrush(color); b.Opacity = opacity; b.Freeze(); return b; }
        private static Color Palette(double position)
        {
            Color[] stops = { Color.FromRgb(78, 202, 213), Color.FromRgb(99, 184, 239), Color.FromRgb(133, 151, 230), Color.FromRgb(166, 142, 225), Color.FromRgb(197, 152, 212) };
            double at = Math.Max(0, Math.Min(.999999, position)) * 4; int i = (int)at; double t = at - i;
            return Color.FromRgb((byte)(stops[i].R + (stops[i + 1].R - stops[i].R) * t), (byte)(stops[i].G + (stops[i + 1].G - stops[i].G) * t), (byte)(stops[i].B + (stops[i + 1].B - stops[i].B) * t));
        }
        private static LinearGradientBrush Spectrum(double angle, double opacity)
        {
            LinearGradientBrush b = new LinearGradientBrush(); b.StartPoint = new Point(0, 0); b.EndPoint = new Point(1, 1);
            b.GradientStops.Add(new GradientStop(Palette(0), 0)); b.GradientStops.Add(new GradientStop(Palette(.28), .38));
            b.GradientStops.Add(new GradientStop(Palette(.66), .74)); b.GradientStops.Add(new GradientStop(Palette(1), 1));
            b.RelativeTransform = new RotateTransform(angle, .5, .5); b.Opacity = opacity; b.Freeze(); return b;
        }
        private static Pen Line(Brush b, double width)
        { Pen p = new Pen(b, width); p.StartLineCap = PenLineCap.Round; p.EndLineCap = PenLineCap.Round; p.LineJoin = PenLineJoin.Round; p.Freeze(); return p; }
        private static double Noise(int seed) { double v = Math.Sin(seed * 127.1 + 3.7) * 43758.5453; return v - Math.Floor(v); }
        private Point Polar(double a, double r) { return new Point(140 + Math.Cos(a) * r, 140 + Math.Sin(a) * r); }
        private static Geometry Annulus(double inside, double outside)
        {
            GeometryGroup g = new GeometryGroup(); g.FillRule = FillRule.EvenOdd;
            g.Children.Add(new EllipseGeometry(new Point(140, 140), outside, outside)); g.Children.Add(new EllipseGeometry(new Point(140, 140), inside, inside)); g.Freeze(); return g;
        }
        private Geometry RingHitGeometry() { return style == "halo" ? haloHit : style == "minimal" ? minimalHit : wideHit; }
        private Point FilamentPoint(double a, double radius, double amplitude, double strand)
        {
            double field = .48 * Math.Sin(a * 2 + Phase * .91 + strand * .11) + .31 * Math.Sin(a * 3 - Phase * .63 + strand * .27) + .21 * Math.Sin(a * 7 + Phase * .37 + strand * .18);
            double fine = Math.Sin(a * 4 - Phase * .43 + strand * .34) * Math.Sin(Phase * .51 + strand * .18);
            return Polar(a + (.003 + Activity * .01) * Math.Sin(a * 3 + Phase + strand * .15), radius + amplitude * field + fine * (.18 + Activity * 1.8));
        }
        private StreamGeometry Filament(double radius, double amplitude, double strand, int samples)
        {
            StreamGeometry g = new StreamGeometry();
            using (StreamGeometryContext c = g.Open())
            {
                for (int i = 0; i < samples; i++)
                {
                    double a = i / (double)samples * Math.PI * 2 - Math.PI / 2;
                    // Independent travelling fields avoid fixed star vertices.
                    Point p = FilamentPoint(a, radius, amplitude, strand);
                    if (i == 0) c.BeginFigure(p, false, true); else c.LineTo(p, true, false);
                }
            }
            g.Freeze(); return g;
        }
        private void DrawSheen(DrawingContext d)
        {
            // Short, feathered highlights follow the strands themselves. Their
            // independent local drift avoids a rigid orbiting progress indicator.
            for (int k = 0; k < 3; k++)
            {
                double strand = 3 + k * 6, center = -2.4 + k * 2.1 + .6 * Math.Sin(Phase * (.46 + k * .07) + k * .9);
                double radius = 93 + (strand - 9.5) * (.65 + Activity * .15) + Breath * .25 + Energy * 3;
                for (int section = 0; section < 5; section++)
                {
                    StreamGeometry g = new StreamGeometry();
                    using (StreamGeometryContext c = g.Open()) for (int j = 0; j <= 8; j++)
                    {
                        double angle = center - .5 + (section + j / 8.0) * .2;
                        Point p = FilamentPoint(angle, radius, 1.2 + Activity * 20 + Breath * .2, strand);
                        if (j == 0) c.BeginFigure(p, false, false); else c.LineTo(p, true, false);
                    }
                    g.Freeze(); d.DrawGeometry(null, sheenPens[k, section], g);
                }
            }
        }
        private StreamGeometry FlowPath(int index)
        {
            StreamGeometry g = new StreamGeometry();
            using (StreamGeometryContext c = g.Open())
            {
                for (int i = 0; i <= 112; i++)
                {
                    double t = i / 112.0, edge = Math.Pow(Math.Sin(t * Math.PI), 1.45);
                    double stream = .72 * Math.Sin(t * Math.PI * 3.4 - Phase * 1.5 + index * .43) + .28 * Math.Sin(t * Math.PI * 6.2 + Phase * .72 - index * .6);
                    Point p = new Point(14 + t * 252, 56 + edge * (stream * (.45 + Breath * .15 + Activity * 36) * (1 - Math.Abs(index - 2) * .14) + (index - 2) * (.45 + Activity * 2.5)));
                    if (i == 0) c.BeginFigure(p, false, false); else c.LineTo(p, true, false);
                }
            }
            g.Freeze(); return g;
        }
        private Rect BarRect(int i)
        {
            double edge = Math.Pow(Math.Sin(i / 40.0 * Math.PI), .85);
            double wave = .56 + .22 * Math.Sin(i * .48 - Phase * 1.8) + .14 * Math.Sin(i * .21 + Phase * .79) + .08 * Math.Sin(i * 1.17 + Phase * .4);
            double height = 3.5 + edge * (.4 + Breath * .1 + Activity * 80) * wave;
            return new Rect(21 + i * 5.8, 56 - height / 2, 4.5, height);
        }
        private Rect BarHitRect(int i)
        {
            // Keep the previous minimum drag target even when the new bars rest.
            Rect r = BarRect(i);
            double minimum = 7 + Math.Pow(Math.Sin(i / 40.0 * Math.PI), .8) * 17 * (.35 + .65 * Noise(i + 61));
            if (r.Height < minimum) r = new Rect(r.X, 56 - minimum / 2, r.Width, minimum);
            r.Inflate(1.3, 5); return r;
        }
        private void EnsureFlow() { if (cachedFlow == null) { cachedFlow = new StreamGeometry[5]; for (int i = 0; i < 5; i++) cachedFlow[i] = FlowPath(i); } }
        protected override void OnRender(DrawingContext d)
        {
            base.OnRender(d); if (ActualWidth <= 0 || ActualHeight <= 0) return;
            d.PushTransform(new ScaleTransform(ActualWidth / 280, ActualHeight / (IsBar ? 112 : 280)));
            if (!IsBar) { d.PushClip(RingHitGeometry()); d.DrawGeometry(hitBrush, null, RingHitGeometry()); }
            if (style == "rays")
            {
                d.PushOpacity(.65 + Breath * .025 + Energy * .3);
                for (int i = 0; i < 20; i++) d.DrawGeometry(null, threadPens[i], Filament(93 + (i - 9.5) * (.65 + Activity * .15) + Breath * .25 + Energy * 3, 1.2 + Activity * 20 + Breath * .2, i, 144));
                DrawSheen(d);
                d.Pop();
            }
            else if (style == "halo")
            {
                StreamGeometry path = Filament(93 + Breath * .2 + Energy * 3, .25 + Activity * 6, 2, 160);
                d.PushOpacity(.65 + Breath * .025 + Energy * .3);
                for (int i = 0; i < 5; i++) d.DrawGeometry(null, haloPens[i], path);
                d.DrawGeometry(null, minimalEchoPen, Filament(97 + Breath * .2 + Energy * 2, .2 + Activity * 5, 7, 160)); d.Pop();
            }
            else if (style == "particles")
            {
                for (int i = 0; i < 180; i++)
                {
                    double n = particleSeeds[i], a = i / 180.0 * Math.PI * 2 - Math.PI / 2;
                    double drift = Math.Sin(Phase * (.4 + n * .4) + i * 1.37);
                    double size = .45 + n * .6 + Activity * .75;
                    int glow = Math.Min(11, (int)(2 + Energy * (6 + 3 * (.5 + .5 * Math.Sin(i * .7 + Phase)))));
                    d.DrawEllipse(dustBrushes[(int)((.5 + .5 * Math.Sin(a + .7)) * 35), glow], null, Polar(a + (.003 + Activity * .02) * drift, 81 + n * 22 + drift * (.3 + Activity * 10) + Energy * 3), size, size);
                }
            }
            else if (style == "minimal")
            {
                d.PushOpacity(.62 + Breath * .025 + Energy * .35); d.DrawGeometry(null, minimalPen, Filament(90 + Breath * .15 + Energy * 3, .2 + Activity * 6, 0, 160));
                d.DrawGeometry(null, minimalEchoPen, Filament(99 + Breath * .1 + Energy * 2, .1 + Activity * 4, 6, 160)); d.Pop();
            }
            else if (style == "bars")
            {
                for (int i = 0; i < 41; i++)
                {
                    Rect rect = BarRect(i), hit = BarHitRect(i);
                    d.DrawRoundedRectangle(hitBrush, null, hit, 3, 3); d.DrawRoundedRectangle(colors[(int)(i / 40.0 * 71)], null, rect, 2.2, 2.2);
                }
            }
            else
            {
                EnsureFlow(); for (int i = 0; i < 5; i++) { d.DrawGeometry(null, flowHitPen, cachedFlow[i]); d.DrawGeometry(null, flowPens[i], cachedFlow[i]); }
            }
            if (!IsBar) d.Pop();
            d.Pop();
        }
        public bool IsInteractivePoint(Point point)
        {
            if (ActualWidth <= 0 || ActualHeight <= 0) return false;
            Point p = new Point(point.X * 280 / ActualWidth, point.Y * (IsBar ? 112 : 280) / ActualHeight);
            if (!IsBar) return RingHitGeometry().FillContains(p);
            if (style == "bars") { for (int i = 0; i < 41; i++) if (BarHitRect(i).Contains(p)) return true; return false; }
            EnsureFlow(); for (int i = 0; i < 5; i++) if (cachedFlow[i].StrokeContains(flowHitPen, p)) return true; return false;
        }
        protected override HitTestResult HitTestCore(PointHitTestParameters parameters)
        { return IsInteractivePoint(parameters.HitPoint) ? new PointHitTestResult(this, parameters.HitPoint) : null; }
    }

    public static class DesktopPlacement
    {
        [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] private struct MONITORINFO { public int Size; public RECT Monitor, Work; public uint Flags; }
        [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
        [DllImport("user32.dll")] private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
        public static Rect GetWorkArea(Window window)
        {
            IntPtr handle = new WindowInteropHelper(window).Handle;
            MONITORINFO info = new MONITORINFO(); info.Size = Marshal.SizeOf(typeof(MONITORINFO));
            if (!GetMonitorInfo(MonitorFromWindow(handle, 2), ref info)) return SystemParameters.WorkArea;
            Matrix transform = Matrix.Identity;
            HwndSource source = HwndSource.FromHwnd(handle);
            if (source != null && source.CompositionTarget != null) transform = source.CompositionTarget.TransformFromDevice;
            Point a = transform.Transform(new Point(info.Work.Left, info.Work.Top));
            Point b = transform.Transform(new Point(info.Work.Right, info.Work.Bottom));
            return new Rect(a, b);
        }
    }
}
