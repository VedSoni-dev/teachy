using System.IO;
using NAudio.Wave;

namespace Teachy.Platform;

/// <summary>
/// Push-to-talk microphone capture — the Windows equivalent of the macOS
/// AVAudioEngine pipeline in BuddyDictationManager. Records 16 kHz mono PCM16
/// while the hotkey is held and returns a finished WAV byte buffer on release,
/// ready for an upload- or file-based transcription provider.
/// </summary>
public sealed class MicrophoneRecorder : IDisposable
{
    /// <summary>Live input level (0..1) for waveform feedback in the overlay.</summary>
    public event Action<double>? AudioLevelChanged;

    private WaveInEvent? activeWaveInDevice;
    private MemoryStream? recordedAudioBuffer;
    private WaveFileWriter? recordedWavWriter;
    private readonly object recordingStateLock = new();

    /// <summary>
    /// Signalled when NAudio's record thread for the current session has actually
    /// exited. We must not dispose the device before that — see StopRecordingAndGetWavBytes.
    /// Never disposed: a stale RecordingStopped callback may still Set() it, and
    /// ManualResetEventSlim only needs disposal once its WaitHandle has been touched.
    /// </summary>
    private ManualResetEventSlim? recordThreadExited;

    /// <summary>
    /// How long to wait for NAudio's record thread to exit before disposing anyway.
    /// Generous: a 50ms buffer loop exits almost immediately, so hitting this means
    /// the driver is wedged and we would rather leak the device than hang the sidecar.
    /// </summary>
    private static readonly TimeSpan RecordThreadExitTimeout = TimeSpan.FromSeconds(2);

    private static readonly WaveFormat RecordingWaveFormat = new(rate: 16000, bits: 16, channels: 1);

    /// <summary>Null when a capture device is available, otherwise why recording can't start.</summary>
    public static string? DescribeMicrophoneProblem()
    {
        try
        {
            if (WaveInEvent.DeviceCount == 0)
            {
                return "No microphone found. Plug one in (or enable it in Windows sound settings) and try again.";
            }
            return null;
        }
        catch (Exception microphoneCheckError)
        {
            TeachyLog.Write($"Mic check failed: {microphoneCheckError.Message}");
            return $"Couldn't reach the microphone ({microphoneCheckError.Message}).";
        }
    }

    public void StartRecording()
    {
        lock (recordingStateLock)
        {
            if (activeWaveInDevice is not null)
            {
                return;
            }

            recordedAudioBuffer = new MemoryStream();
            recordedWavWriter = new WaveFileWriter(new IgnoreDisposeStream(recordedAudioBuffer), RecordingWaveFormat);

            // Owned by this session only, and captured by the handler below rather than
            // read back off the field — so a late callback from a previous session can
            // never signal the current one.
            ManualResetEventSlim thisSessionRecordThreadExited = new(initialState: false);
            recordThreadExited = thisSessionRecordThreadExited;

            try
            {
                activeWaveInDevice = new WaveInEvent
                {
                    WaveFormat = RecordingWaveFormat,
                    BufferMilliseconds = 50,
                };
                activeWaveInDevice.DataAvailable += HandleAudioDataAvailable;
                activeWaveInDevice.RecordingStopped += (_, stoppedEventArgs) =>
                {
                    if (stoppedEventArgs.Exception is not null)
                    {
                        TeachyLog.Write($"Mic: recording stopped with {stoppedEventArgs.Exception.GetType().Name}: {stoppedEventArgs.Exception.Message}");
                    }
                    thisSessionRecordThreadExited.Set();
                };
                activeWaveInDevice.StartRecording();
            }
            catch (Exception recordingStartError)
            {
                TeachyLog.Write($"Mic start failed: {recordingStartError.GetType().Name}: {recordingStartError.Message}");
                activeWaveInDevice?.Dispose();
                activeWaveInDevice = null;
                recordedWavWriter?.Dispose();
                recordedWavWriter = null;
                recordedAudioBuffer?.Dispose();
                recordedAudioBuffer = null;
                recordThreadExited = null;
            }
        }
    }

    /// <summary>Stops recording and returns the captured audio as WAV bytes (null if nothing captured).</summary>
    /// <remarks>
    /// Teardown deliberately happens OUTSIDE <see cref="recordingStateLock"/>. NAudio raises
    /// DataAvailable on its own record thread, and that handler takes the same lock — so
    /// stopping and disposing the device while holding it deadlocked the record thread inside
    /// the callback, let Dispose free the wave headers underneath it, and the thread then
    /// resumed into WaveInBuffer.Reuse() → waveInAddBuffer on freed memory. That is an
    /// AccessViolationException, which .NET cannot catch: it killed the whole sidecar process
    /// (exit 0xC0000005) and left the app with no background service.
    ///
    /// So: detach state under the lock (any in-flight callback immediately becomes a no-op),
    /// release it, then stop, wait for the record thread to actually exit, and only then dispose.
    /// </remarks>
    public byte[]? StopRecordingAndGetWavBytes()
    {
        WaveInEvent? deviceBeingStopped;
        WaveFileWriter? writerBeingClosed;
        MemoryStream? bufferBeingClosed;
        ManualResetEventSlim? exitSignal;

        lock (recordingStateLock)
        {
            if (activeWaveInDevice is null)
            {
                return null;
            }

            deviceBeingStopped = activeWaveInDevice;
            writerBeingClosed = recordedWavWriter;
            bufferBeingClosed = recordedAudioBuffer;
            exitSignal = recordThreadExited;

            // Clearing these first means a DataAvailable callback already waiting on the
            // lock writes nothing and returns, instead of touching a disposed writer.
            activeWaveInDevice = null;
            recordedWavWriter = null;
            recordedAudioBuffer = null;
            recordThreadExited = null;
        }

        deviceBeingStopped.DataAvailable -= HandleAudioDataAvailable;
        deviceBeingStopped.StopRecording();

        // StopRecording only signals the record thread; it returns before that thread has
        // finished its current buffer pass. Disposing now is what corrupted memory before.
        if (exitSignal is null || exitSignal.Wait(RecordThreadExitTimeout))
        {
            deviceBeingStopped.Dispose();
        }
        else
        {
            TeachyLog.Write("Mic: record thread did not exit in time; leaking the device rather than disposing under it.");
        }

        writerBeingClosed?.Dispose(); // flushes WAV headers into the captured buffer

        byte[]? recordedWavBytes = bufferBeingClosed?.ToArray();
        bufferBeingClosed?.Dispose();

        // 16kHz mono PCM16 = 32000 bytes/sec, so 8000 bytes ≈ 0.25s — below that
        // it's a stray hotkey tap, not speech.
        const int minimumUsableWavByteCount = 8000;
        if (recordedWavBytes is null || recordedWavBytes.Length < minimumUsableWavByteCount)
        {
            TeachyLog.Write($"Mic: discarded short capture ({recordedWavBytes?.Length ?? 0} bytes).");
            return null;
        }

        TeachyLog.Write($"Mic: captured {recordedWavBytes.Length} bytes.");
        return recordedWavBytes;
    }

    private void HandleAudioDataAvailable(object? sender, WaveInEventArgs waveInEventArgs)
    {
        lock (recordingStateLock)
        {
            recordedWavWriter?.Write(waveInEventArgs.Buffer, 0, waveInEventArgs.BytesRecorded);
        }

        // Peak level over this buffer for the listening waveform.
        double peakSampleMagnitude = 0;
        for (int byteIndex = 0; byteIndex + 1 < waveInEventArgs.BytesRecorded; byteIndex += 2)
        {
            short pcmSample = BitConverter.ToInt16(waveInEventArgs.Buffer, byteIndex);
            double sampleMagnitude = Math.Abs(pcmSample) / 32768.0;
            if (sampleMagnitude > peakSampleMagnitude)
            {
                peakSampleMagnitude = sampleMagnitude;
            }
        }
        AudioLevelChanged?.Invoke(peakSampleMagnitude);
    }

    public void Dispose()
    {
        StopRecordingAndGetWavBytes();
    }

    /// <summary>
    /// WaveFileWriter disposes its target stream by default; this wrapper keeps
    /// the underlying MemoryStream alive so we can read the finished WAV bytes.
    /// </summary>
    private sealed class IgnoreDisposeStream : Stream
    {
        private readonly Stream innerStream;
        public IgnoreDisposeStream(Stream innerStream) => this.innerStream = innerStream;

        public override bool CanRead => innerStream.CanRead;
        public override bool CanSeek => innerStream.CanSeek;
        public override bool CanWrite => innerStream.CanWrite;
        public override long Length => innerStream.Length;
        public override long Position { get => innerStream.Position; set => innerStream.Position = value; }
        public override void Flush() => innerStream.Flush();
        public override int Read(byte[] buffer, int offset, int count) => innerStream.Read(buffer, offset, count);
        public override long Seek(long offset, SeekOrigin origin) => innerStream.Seek(offset, origin);
        public override void SetLength(long value) => innerStream.SetLength(value);
        public override void Write(byte[] buffer, int offset, int count) => innerStream.Write(buffer, offset, count);
        protected override void Dispose(bool disposing) { /* intentionally do not dispose innerStream */ }
    }
}
