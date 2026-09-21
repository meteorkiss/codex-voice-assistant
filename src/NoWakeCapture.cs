using System;
using System.Collections.Generic;
using System.IO;

// Continuous AEC capture and bounded utterance segmentation. This component
// deliberately does not decide who is being addressed and cannot dispatch work.
public sealed class NoWakeSegment
{
    public byte[] Pcm { get; internal set; }
    public DateTime StartedUtc { get; internal set; }
    public DateTime EndedUtc { get; internal set; }
    public double DurationSeconds { get; internal set; }
    public double Rms { get; internal set; }
    public double Peak { get; internal set; }
    public int VoiceFrames { get; internal set; }
    public string EndReason { get; internal set; }
    public long Generation { get; internal set; }
}

public sealed class NoWakeSegmenter
{
    private const int SampleRate = 16000;
    private const int BytesPerSample = 2;
    private const int FrameSamples = 320; // 20 ms
    private const int FrameBytes = FrameSamples * BytesPerSample;
    private const int PreRollFrames = 25; // 500 ms
    private const int StartVoiceFrames = 3;
    private const int EndSilenceFrames = 45; // 900 ms
    private const int MinimumVoiceFrames = 8;
    private const int MaximumFrames = 900; // 18 s
    private const double VoiceRms = 0.010;
    private const double VoicePeak = 0.055;
    private const int QueueLimit = 2;

    private readonly object gate = new object();
    private readonly Queue<byte[]> preRoll = new Queue<byte[]>();
    private readonly Queue<bool> preRollVoiced = new Queue<bool>();
    private readonly Queue<NoWakeSegment> completed = new Queue<NoWakeSegment>();
    private readonly List<byte> remainder = new List<byte>();
    private MemoryStream active;
    private DateTime activeStartedUtc;
    private int consecutiveVoice, trailingSilence, activeFrames, voiceFrames;
    private double sumSquares, peak;
    private long sampleCount, generation;
    private int dropped;

    public NoWakeSegmenter(long captureGeneration) { generation = captureGeneration; }
    public int PendingCount { get { lock (gate) return completed.Count; } }
    public int DroppedCount { get { lock (gate) return dropped; } }
    public bool HasActiveSegment { get { lock (gate) return active != null; } }

    public void AcceptPcm(byte[] pcm)
    {
        if (pcm == null || pcm.Length == 0) return;
        lock (gate)
        {
            remainder.AddRange(pcm);
            while (remainder.Count >= FrameBytes)
            {
                byte[] frame = remainder.GetRange(0, FrameBytes).ToArray();
                remainder.RemoveRange(0, FrameBytes);
                AcceptFrame(frame);
            }
        }
    }

    private void AcceptFrame(byte[] frame)
    {
        double frameSquares = 0, framePeak = 0;
        for (int i = 0; i + 1 < frame.Length; i += 2)
        {
            short raw = (short)(frame[i] | (frame[i + 1] << 8));
            double value = raw / 32768.0;
            frameSquares += value * value;
            framePeak = Math.Max(framePeak, Math.Abs(value));
        }
        double frameRms = Math.Sqrt(frameSquares / FrameSamples);
        bool voiced = frameRms >= VoiceRms || framePeak >= VoicePeak;

        if (active == null)
        {
            preRoll.Enqueue(frame);
            preRollVoiced.Enqueue(voiced);
            while (preRoll.Count > PreRollFrames) { preRoll.Dequeue(); preRollVoiced.Dequeue(); }
            consecutiveVoice = voiced ? consecutiveVoice + 1 : 0;
            if (consecutiveVoice < StartVoiceFrames) return;
            active = new MemoryStream();
            activeStartedUtc = DateTime.UtcNow.AddMilliseconds(-preRoll.Count * 20);
            activeFrames = voiceFrames = trailingSilence = 0;
            sumSquares = peak = 0;
            while (preRoll.Count > 0) Append(preRoll.Dequeue(), preRollVoiced.Dequeue());
            consecutiveVoice = 0;
            return;
        }

        Append(frame, voiced);
        trailingSilence = voiced ? 0 : trailingSilence + 1;
        if (activeFrames >= MaximumFrames) Finish("maximum-duration");
        else if (trailingSilence >= EndSilenceFrames) Finish("silence");
    }

    private void Append(byte[] frame, bool voiced)
    {
        active.Write(frame, 0, frame.Length);
        activeFrames++;
        if (voiced) voiceFrames++;
        for (int i = 0; i + 1 < frame.Length; i += 2)
        {
            short raw = (short)(frame[i] | (frame[i + 1] << 8));
            double value = raw / 32768.0;
            sumSquares += value * value;
            peak = Math.Max(peak, Math.Abs(value));
            sampleCount++;
        }
    }

    private void Finish(string reason)
    {
        byte[] pcm = active.ToArray();
        active.Dispose(); active = null;
        if (voiceFrames >= MinimumVoiceFrames)
        {
            NoWakeSegment segment = new NoWakeSegment
            {
                Pcm = pcm,
                StartedUtc = activeStartedUtc,
                EndedUtc = DateTime.UtcNow,
                DurationSeconds = pcm.Length / (double)(SampleRate * BytesPerSample),
                Rms = Math.Sqrt(sumSquares / Math.Max(1, sampleCount)),
                Peak = peak,
                VoiceFrames = voiceFrames,
                EndReason = reason,
                Generation = generation
            };
            completed.Enqueue(segment);
            while (completed.Count > QueueLimit) { completed.Dequeue(); dropped++; }
        }
        activeFrames = voiceFrames = trailingSilence = consecutiveVoice = 0;
        sumSquares = peak = 0; sampleCount = 0;
        preRoll.Clear(); preRollVoiced.Clear();
    }

    public NoWakeSegment TryDequeue()
    {
        lock (gate) return completed.Count == 0 ? null : completed.Dequeue();
    }

    public void Reset(long captureGeneration)
    {
        lock (gate)
        {
            if (active != null) { active.Dispose(); active = null; }
            preRoll.Clear(); preRollVoiced.Clear(); completed.Clear(); remainder.Clear();
            consecutiveVoice = trailingSilence = activeFrames = voiceFrames = dropped = 0;
            sumSquares = peak = 0; sampleCount = 0; generation = captureGeneration;
        }
    }
}

public sealed class NoWakeCapture : IDisposable
{
    private readonly object gate = new object();
    private EchoCapture capture;
    private NoWakeSegmenter segmenter;
    private bool disposed;
    private long generation;

    public bool IsRunning { get { lock (gate) return capture != null && capture.IsRunning; } }
    public bool IsStopping { get { lock (gate) return capture != null && capture.IsStopping; } }
    public bool IsReady { get { lock (gate) return capture != null && capture.IsReady; } }
    public string Error { get { lock (gate) return capture == null ? "" : capture.Error; } }
    public int AudioLevel { get { lock (gate) return capture == null ? 0 : capture.AudioLevel; } }
    public string CaptureEndpointId { get { lock (gate) return capture == null ? "" : capture.CaptureEndpointId; } }
    public string RenderEndpointId { get { lock (gate) return capture == null ? "" : capture.RenderEndpointId; } }
    public int PendingCount { get { lock (gate) return segmenter == null ? 0 : segmenter.PendingCount; } }
    public int DroppedCount { get { lock (gate) return segmenter == null ? 0 : segmenter.DroppedCount; } }
    public long Generation { get { lock (gate) return generation; } }

    public void Start(string captureEndpointId, string renderEndpointId, long captureGeneration)
    {
        if (String.IsNullOrEmpty(captureEndpointId) || String.IsNullOrEmpty(renderEndpointId))
            throw new ArgumentException("Explicit capture and render endpoint IDs are required.");
        lock (gate)
        {
            if (disposed) throw new ObjectDisposedException("NoWakeCapture");
            if (capture != null) throw new InvalidOperationException("No-wake capture is already active.");
            generation = captureGeneration;
            NoWakeSegmenter nextSegmenter = new NoWakeSegmenter(captureGeneration);
            segmenter = nextSegmenter;
            EchoCapture next = new EchoCapture();
            next.PcmAvailable = delegate(byte[] bytes) { nextSegmenter.AcceptPcm(bytes); };
            capture = next;
            try { next.Start(captureEndpointId, renderEndpointId); }
            catch { next.PcmAvailable = null; next.Dispose(); capture = null; segmenter = null; throw; }
        }
    }

    public NoWakeSegment TryDequeueSegment()
    {
        lock (gate) return segmenter == null ? null : segmenter.TryDequeue();
    }

    public void Stop()
    {
        lock (gate) { if (capture != null) capture.Stop(); }
    }

    public bool StopAndWait(int milliseconds)
    {
        EchoCapture current;
        lock (gate) current = capture;
        if (current == null) return true;
        bool stopped = current.StopAndWait(milliseconds);
        if (stopped)
        {
            lock (gate)
            {
                if (Object.ReferenceEquals(capture, current))
                {
                    current.PcmAvailable = null; current.Dispose(); capture = null;
                    if (segmenter != null) segmenter.Reset(generation + 1);
                    segmenter = null;
                }
            }
        }
        return stopped;
    }

    public static void WriteWave(string path, byte[] pcm)
    {
        if (pcm == null) throw new ArgumentNullException("pcm");
        using (FileStream stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        using (BinaryWriter writer = new BinaryWriter(stream))
        {
            writer.Write(new char[] { 'R', 'I', 'F', 'F' }); writer.Write(36 + pcm.Length);
            writer.Write(new char[] { 'W', 'A', 'V', 'E', 'f', 'm', 't', ' ' }); writer.Write(16);
            writer.Write((short)1); writer.Write((short)1); writer.Write(16000); writer.Write(32000);
            writer.Write((short)2); writer.Write((short)16);
            writer.Write(new char[] { 'd', 'a', 't', 'a' }); writer.Write(pcm.Length); writer.Write(pcm);
        }
    }

    public void Dispose()
    {
        lock (gate) { if (disposed) return; }
        StopAndWait(3000);
        lock (gate) disposed = true;
    }
}
