using System.Speech.Synthesis;

namespace Teachy.Platform;

/// <summary>
/// Local text-to-speech via Windows SAPI — the direct analogue of the macOS
/// NSSpeechSynthesizer-based LocalSpeechSynthesizer. Speaks companion replies
/// aloud; any new utterance cancels the previous one.
/// </summary>
public sealed class LocalSpeechSynthesizer : IDisposable
{
    private readonly SpeechSynthesizer speechSynthesizer = new();

    public LocalSpeechSynthesizer()
    {
        speechSynthesizer.SetOutputToDefaultAudioDevice();
        speechSynthesizer.Rate = 1; // slightly brisk, tutor-like pacing
    }

    public void SpeakInterruptingCurrentSpeech(string textToSpeak)
    {
        if (string.IsNullOrWhiteSpace(textToSpeak))
        {
            return;
        }

        speechSynthesizer.SpeakAsyncCancelAll();
        speechSynthesizer.SpeakAsync(textToSpeak);
    }

    public void StopSpeaking()
    {
        speechSynthesizer.SpeakAsyncCancelAll();
    }

    public void Dispose()
    {
        speechSynthesizer.Dispose();
    }
}
