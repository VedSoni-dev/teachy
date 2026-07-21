using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Teachy.Platform;

/// <summary>
/// Persisted app configuration at %USERPROFILE%\.teachy\config-windows.json.
/// The OpenRouter API key is encrypted at rest with DPAPI (current-user scope) —
/// the Windows analogue of the macOS Keychain storage.
/// </summary>
public sealed class TeachyConfiguration
{
    [JsonPropertyName("protectedOpenRouterApiKey")]
    public string? ProtectedOpenRouterApiKeyBase64 { get; set; }

    /// <summary>
    /// User-chosen chat model, or null to follow the key-aware default
    /// (OpenRouterModelOptions.DefaultModelIdentifier) — same behavior as macOS.
    /// </summary>
    [JsonPropertyName("chatModel")]
    public string? ChosenChatModelIdentifier { get; set; }

    /// <summary>
    /// "Show Teachy" — when true the companion cursor trails the pointer at all
    /// times; when false it only appears during an interaction (macOS transient
    /// cursor mode). Defaults on, like the mac app.
    /// </summary>
    [JsonPropertyName("showTeachyCursor")]
    public bool ShowTeachyCursor { get; set; } = true;

    /// <summary>Where the notch sits on screen. Defaults to top-center, matching the Mac.</summary>
    [JsonPropertyName("notchPlacementPreset")]
    [JsonConverter(typeof(JsonStringEnumConverter))]
    public NotchPlacementPreset NotchPlacementPreset { get; set; } = NotchPlacementPreset.TopCenter;

    /// <summary>Exact notch position when NotchPlacementPreset is Custom (device-independent units).</summary>
    [JsonPropertyName("customNotchLeft")]
    public double? CustomNotchLeft { get; set; }

    [JsonPropertyName("customNotchTop")]
    public double? CustomNotchTop { get; set; }

    /// <summary>"Left" / "Center" / "Right" — how the visible bar sits within the drag frame. Null = Left.</summary>
    [JsonPropertyName("customNotchHorizontalAlignment")]
    public string? CustomNotchHorizontalAlignment { get; set; }

    [JsonIgnore]
    public bool HasOpenRouterApiKey => !string.IsNullOrEmpty(ProtectedOpenRouterApiKeyBase64);

    public static TeachyConfiguration Load()
    {
        try
        {
            if (File.Exists(TeachyDataPaths.ConfigurationFilePath))
            {
                string configurationJson = File.ReadAllText(TeachyDataPaths.ConfigurationFilePath);
                TeachyConfiguration? loadedConfiguration = JsonSerializer.Deserialize<TeachyConfiguration>(configurationJson);
                if (loadedConfiguration is not null)
                {
                    return loadedConfiguration;
                }
            }
        }
        catch (Exception)
        {
            // A corrupt config file should never brick startup — fall through to defaults.
        }

        return new TeachyConfiguration();
    }

    public void Save()
    {
        TeachyDataPaths.EnsureDirectoriesExist();
        string configurationJson = JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(TeachyDataPaths.ConfigurationFilePath, configurationJson);
    }

    public void SetOpenRouterApiKey(string openRouterApiKeyPlaintext)
    {
        byte[] protectedKeyBytes = ProtectedData.Protect(
            Encoding.UTF8.GetBytes(openRouterApiKeyPlaintext),
            optionalEntropy: null,
            scope: DataProtectionScope.CurrentUser);
        ProtectedOpenRouterApiKeyBase64 = Convert.ToBase64String(protectedKeyBytes);
    }

    /// <summary>Decrypts and returns the stored OpenRouter key, or null when absent/undecryptable.</summary>
    public string? GetOpenRouterApiKey()
    {
        if (string.IsNullOrEmpty(ProtectedOpenRouterApiKeyBase64))
        {
            return null;
        }

        try
        {
            byte[] unprotectedKeyBytes = ProtectedData.Unprotect(
                Convert.FromBase64String(ProtectedOpenRouterApiKeyBase64),
                optionalEntropy: null,
                scope: DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(unprotectedKeyBytes);
        }
        catch (Exception)
        {
            return null;
        }
    }
}
