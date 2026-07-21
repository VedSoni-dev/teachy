using System.Globalization;
using System.Speech.Recognition;

namespace Teachy.Platform;

/// <summary>Transcription outcome — carries the failure reason so the UI can say something useful.</summary>
public sealed class TranscriptionResult
{
    public string? Transcript { get; init; }

    /// <summary>Learner-facing explanation when Transcript is null.</summary>
    public string? FailureMessage { get; init; }

    public bool Succeeded => !string.IsNullOrWhiteSpace(Transcript);
}

/// <summary>
/// Local offline transcription over a recorded WAV buffer — the Windows
/// equivalent of the macOS AppleSpeechTranscriptionProvider fallback tier.
/// Picks an installed recognizer explicitly (the parameterless constructor
/// throws when the UI culture has no matching recognizer) and reports why a
/// transcription failed instead of silently returning nothing.
/// </summary>
public static class SystemSpeechTranscriber
{
    public static TranscriptionResult TranscribeWavAudio(byte[] recordedWavBytes)
    {
        RecognizerInfo? recognizerToUse = SelectInstalledRecognizer();
        if (recognizerToUse is null)
        {
            TeachyLog.Write("STT: no speech recognizer installed on this machine.");
            return new TranscriptionResult
            {
                FailureMessage = "No Windows speech recognizer is installed. Add one in Settings → Time & language → Speech, or type your question in the Teachy panel.",
            };
        }

        // Collected outside the try so a late-stream exception can't throw away
        // text we already recognized.
        var transcriptParts = new List<string>();

        try
        {
            using var speechRecognitionEngine = new SpeechRecognitionEngine(recognizerToUse);
            speechRecognitionEngine.LoadGrammar(new DictationGrammar());

            // Dictation over a finished buffer: give the engine room before it
            // gives up on a quiet lead-in, and don't cut off mid-sentence.
            speechRecognitionEngine.InitialSilenceTimeout = TimeSpan.FromSeconds(4);
            speechRecognitionEngine.BabbleTimeout = TimeSpan.FromSeconds(4);
            speechRecognitionEngine.EndSilenceTimeout = TimeSpan.FromMilliseconds(700);

            using var recognitionFinished = new ManualResetEventSlim(false);

            speechRecognitionEngine.SpeechRecognized += (_, speechRecognizedArgs) =>
            {
                if (!string.IsNullOrWhiteSpace(speechRecognizedArgs.Result?.Text))
                {
                    transcriptParts.Add(speechRecognizedArgs.Result.Text);
                }
            };
            speechRecognitionEngine.RecognizeCompleted += (_, _) => recognitionFinished.Set();

            using var recordedAudioStream = new MemoryStream(recordedWavBytes);
            speechRecognitionEngine.SetInputToWaveStream(recordedAudioStream);

            // RecognizeAsync(Multiple) is the correct API for a finished buffer:
            // it walks the whole stream and raises RecognizeCompleted at the end.
            // (Looping the synchronous Recognize() throws "no audio input is
            // supplied" once the stream is consumed instead of returning null.)
            speechRecognitionEngine.RecognizeAsync(RecognizeMode.Multiple);

            // Generous ceiling — push-to-talk clips are seconds long, so this only
            // trips if the engine wedges.
            if (!recognitionFinished.Wait(TimeSpan.FromSeconds(30)))
            {
                TeachyLog.Write("STT: recognition timed out; using whatever was recognized.");
            }
            speechRecognitionEngine.RecognizeAsyncStop();
        }
        catch (Exception transcriptionError)
        {
            TeachyLog.Write($"STT error (partial text kept): {transcriptionError.GetType().Name}: {transcriptionError.Message}");

            if (transcriptParts.Count == 0)
            {
                return new TranscriptionResult
                {
                    FailureMessage = $"Voice input hit an error ({transcriptionError.Message}). You can type your question in the Teachy panel instead.",
                };
            }
        }

        string fullTranscript = string.Join(" ", transcriptParts).Trim();
        if (fullTranscript.Length > 0)
        {
            TeachyLog.Write($"STT ok ({recognizerToUse.Culture}): \"{fullTranscript}\"");
            return new TranscriptionResult { Transcript = fullTranscript };
        }

        TeachyLog.Write($"STT: recognizer returned no text for {recordedWavBytes.Length} bytes of audio.");
        return new TranscriptionResult
        {
            FailureMessage = "I heard audio but couldn't make out words — try speaking a bit closer to the mic, or type your question in the Teachy panel.",
        };
    }

    /// <summary>
    /// Prefers a recognizer matching the current culture, then any English one,
    /// then whatever is installed — mirrors how the mac falls back across
    /// transcription providers rather than hard-failing.
    /// </summary>
    private static RecognizerInfo? SelectInstalledRecognizer()
    {
        try
        {
            IReadOnlyList<RecognizerInfo> installedRecognizers = SpeechRecognitionEngine.InstalledRecognizers();
            if (installedRecognizers.Count == 0)
            {
                return null;
            }

            CultureInfo currentCulture = CultureInfo.CurrentCulture;
            return installedRecognizers.FirstOrDefault(recognizer => recognizer.Culture.Equals(currentCulture))
                ?? installedRecognizers.FirstOrDefault(recognizer => recognizer.Culture.TwoLetterISOLanguageName == "en")
                ?? installedRecognizers[0];
        }
        catch (Exception recognizerLookupError)
        {
            TeachyLog.Write($"STT: recognizer lookup failed: {recognizerLookupError.Message}");
            return null;
        }
    }
}
