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

            try
            {
                activeWaveInDevice = new WaveInEvent
                {
                    WaveFormat = RecordingWaveFormat,
                    BufferMilliseconds = 50,
                };
                activeWaveInDevice.DataAvailable += HandleAudioDataAvailable;
                activeWaveInDevice.StartRecording();
            }
            catch (Exception recordingStartError)
            {
                TeachyLog.Write($"Mic start failed: {recordingStartError.GetType().Name}: {recordingStartError.Message}");
                activeWaveInDevice?.Dispose();
                activeWaveInDevice = null;
            }
        }
    }

    /// <summary>Stops recording and returns the captured audio as WAV bytes (null if nothing captured).</summary>
    public byte[]? StopRecordingAndGetWavBytes()
    {
        lock (recordingStateLock)
        {
            if (activeWaveInDevice is null)
            {
                return null;
            }

            activeWaveInDevice.DataAvailable -= HandleAudioDataAvailable;
            activeWaveInDevice.StopRecording();
            activeWaveInDevice.Dispose();
            activeWaveInDevice = null;

            recordedWavWriter?.Dispose(); // flushes WAV headers into recordedAudioBuffer
            recordedWavWriter = null;

            byte[]? recordedWavBytes = recordedAudioBuffer?.ToArray();
            recordedAudioBuffer?.Dispose();
            recordedAudioBuffer = null;

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
