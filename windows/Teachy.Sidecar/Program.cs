using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Forms;
using Teachy.Platform;

namespace Teachy.Sidecar;

/// <summary>
/// The OS bridge for the Electron shell.
///
/// Electron cannot do UI Automation, low-level keyboard hooks, or SAPI, so the
/// verified C# platform layer keeps doing that work and speaks to the renderer
/// over newline-delimited JSON on stdin/stdout. One JSON object per line:
///
///   in : {"id":"7","command":"capture-screen","args":{...}}
///   out: {"id":"7","ok":true,"result":{...}}          — reply to a command
///   out: {"event":"ptt-pressed","payload":{...}}      — unsolicited event
///
/// A hidden WinForms message loop runs on the main thread because the global
/// push-to-talk hook requires one; stdin is pumped on a background thread.
/// </summary>
internal static class Program
{
    private static readonly object stdoutWriteLock = new();

    private static GlobalPushToTalkHook? pushToTalkHook;
    private static MicrophoneRecorder? microphoneRecorder;
    private static MouseOutlineTracker? mouseOutlineTracker;
    private static LocalSpeechSynthesizer? speechSynthesizer;
    private static TeachyConfiguration configuration = TeachyConfiguration.Load();

    /// <summary>Durable per-course progress, so a course survives across days.</summary>
    private static readonly LearnerProgressStore learnerProgress = LearnerProgressStore.Load();

    /// <summary>Element list from the most recent inspect, so ids the model cites resolve.</summary>
    private static IReadOnlyList<InspectedUiElement> lastInspectedElements = Array.Empty<InspectedUiElement>();

    [STAThread]
    private static void Main()
    {
        TeachyLog.Write("Sidecar: starting.");

        microphoneRecorder = new MicrophoneRecorder();
        mouseOutlineTracker = new MouseOutlineTracker();
        speechSynthesizer = new LocalSpeechSynthesizer();

        InstallPushToTalkHook();

        // Pump stdin off the UI thread so the hook's message loop stays responsive.
        var stdinReaderThread = new Thread(ReadCommandsFromStandardInput)
        {
            IsBackground = true,
            Name = "TeachySidecarStdin",
        };
        stdinReaderThread.Start();

        EmitEvent("ready", new JsonObject
        {
            ["hasApiKey"] = configuration.HasOpenRouterApiKey,
        });

        // Required for the low-level keyboard hook to receive callbacks.
        Application.Run();
    }

    private static void InstallPushToTalkHook()
    {
        pushToTalkHook = new GlobalPushToTalkHook();

        pushToTalkHook.PushToTalkPressed += () =>
        {
            string? microphoneProblem = MicrophoneRecorder.DescribeMicrophoneProblem();
            if (microphoneProblem is not null)
            {
                EmitEvent("ptt-error", new JsonObject { ["message"] = microphoneProblem });
                return;
            }

            speechSynthesizer?.StopSpeaking();
            microphoneRecorder?.StartRecording();
            mouseOutlineTracker?.StartTracking();
            EmitEvent("ptt-pressed", new JsonObject());
        };

        pushToTalkHook.PushToTalkReleased += () =>
        {
            byte[]? recordedWavBytes = microphoneRecorder?.StopRecordingAndGetWavBytes();
            IReadOnlyList<System.Drawing.Point>? tracedOutline = mouseOutlineTracker?.StopTrackingAndGetOutline();

            EmitEvent("ptt-released", new JsonObject());

            if (recordedWavBytes is null)
            {
                EmitEvent("transcript", new JsonObject
                {
                    ["ok"] = false,
                    ["message"] = "That was too short to hear — hold Ctrl+Alt while you talk, then let go.",
                });
                return;
            }

            // Transcribe off the hook thread; recognition takes real time.
            ThreadPool.QueueUserWorkItem(_ =>
            {
                TranscriptionResult transcriptionResult = SystemSpeechTranscriber.TranscribeWavAudio(recordedWavBytes);
                var transcriptPayload = new JsonObject
                {
                    ["ok"] = transcriptionResult.Succeeded,
                    ["text"] = transcriptionResult.Transcript,
                    ["message"] = transcriptionResult.FailureMessage,
                };
                if (tracedOutline is { Count: > 1 })
                {
                    transcriptPayload["outlinePointCount"] = tracedOutline.Count;
                    pendingMouseOutline = tracedOutline;
                }
                EmitEvent("transcript", transcriptPayload);
            });
        };

        pushToTalkHook.Install();
        TeachyLog.Write("Sidecar: push-to-talk hook installed.");
    }

    /// <summary>Outline traced during the last push-to-talk, consumed by the next capture.</summary>
    private static IReadOnlyList<System.Drawing.Point>? pendingMouseOutline;

    private static void ReadCommandsFromStandardInput()
    {
        using var standardInputReader = new StreamReader(Console.OpenStandardInput());

        while (standardInputReader.ReadLine() is { } commandLine)
        {
            if (string.IsNullOrWhiteSpace(commandLine))
            {
                continue;
            }

            string requestId = "";
            try
            {
                if (JsonNode.Parse(commandLine) is not JsonObject requestObject)
                {
                    continue;
                }

                requestId = requestObject["id"]?.GetValue<string>() ?? "";
                string commandName = requestObject["command"]?.GetValue<string>() ?? "";
                JsonObject commandArguments = requestObject["args"] as JsonObject ?? new JsonObject();

                JsonNode? commandResult = ExecuteCommand(commandName, commandArguments);
                WriteJsonLine(new JsonObject
                {
                    ["id"] = requestId,
                    ["ok"] = true,
                    ["result"] = commandResult,
                });
            }
            catch (Exception commandError)
            {
                TeachyLog.Write($"Sidecar command failed: {commandError.GetType().Name}: {commandError.Message}");
                WriteJsonLine(new JsonObject
                {
                    ["id"] = requestId,
                    ["ok"] = false,
                    ["error"] = commandError.Message,
                });
            }
        }

        // stdin closed — the shell exited, so the sidecar should not linger.
        TeachyLog.Write("Sidecar: stdin closed, exiting.");
        Application.Exit();
    }

    private static JsonNode? ExecuteCommand(string commandName, JsonObject commandArguments)
    {
        switch (commandName)
        {
            case "capture-screen":
                return CaptureScreen(includeElements: commandArguments["includeElements"]?.GetValue<bool>() ?? true);

            case "inspect-elements":
            {
                lastInspectedElements = UiElementInspector.InspectForegroundWindow();
                return BuildElementListJson(lastInspectedElements);
            }

            case "click-element":
            {
                int elementId = commandArguments["elementId"]!.GetValue<int>();
                InspectedUiElement? targetElement = FindElementById(elementId);
                if (targetElement is null)
                {
                    throw new InvalidOperationException($"No element with id {elementId}.");
                }
                return JsonValue.Create(InputSynthesizer.ClickElement(targetElement));
            }

            case "click-point":
            {
                int pointX = commandArguments["x"]!.GetValue<int>();
                int pointY = commandArguments["y"]!.GetValue<int>();
                return JsonValue.Create(InputSynthesizer.ClickAtScreenPixel(new System.Drawing.Point(pointX, pointY)));
            }

            case "type-text":
            {
                int elementId = commandArguments["elementId"]!.GetValue<int>();
                string textToType = commandArguments["text"]?.GetValue<string>() ?? "";
                InspectedUiElement? targetElement = FindElementById(elementId);
                if (targetElement is null)
                {
                    throw new InvalidOperationException($"No element with id {elementId}.");
                }
                return JsonValue.Create(InputSynthesizer.TypeIntoElement(targetElement, textToType));
            }

            case "press-key":
                return JsonValue.Create(InputSynthesizer.PressKey(commandArguments["key"]?.GetValue<string>() ?? ""));

            case "scroll":
                return JsonValue.Create(InputSynthesizer.Scroll(commandArguments["notches"]?.GetValue<int>() ?? -3));

            case "speak":
            {
                speechSynthesizer?.SpeakInterruptingCurrentSpeech(commandArguments["text"]?.GetValue<string>() ?? "");
                return JsonValue.Create(true);
            }

            case "stop-speaking":
            {
                speechSynthesizer?.StopSpeaking();
                return JsonValue.Create(true);
            }

            case "get-config":
                return new JsonObject
                {
                    ["hasApiKey"] = configuration.HasOpenRouterApiKey,
                    ["chatModel"] = configuration.ChosenChatModelIdentifier,
                    ["showTeachyCursor"] = configuration.ShowTeachyCursor,
                    ["notchPlacement"] = configuration.NotchPlacementPreset.ToString(),
                };

            case "get-api-key":
                // Stays inside the local process boundary; used to call OpenRouter.
                return JsonValue.Create(configuration.GetOpenRouterApiKey());

            case "set-api-key":
            {
                configuration.SetOpenRouterApiKey(commandArguments["key"]?.GetValue<string>() ?? "");
                configuration.Save();
                return JsonValue.Create(true);
            }

            case "set-config":
            {
                if (commandArguments["chatModel"] is { } chatModelNode)
                {
                    configuration.ChosenChatModelIdentifier = chatModelNode.GetValue<string>();
                }
                if (commandArguments["showTeachyCursor"] is { } showCursorNode)
                {
                    configuration.ShowTeachyCursor = showCursorNode.GetValue<bool>();
                }
                if (commandArguments["notchPlacement"] is { } placementNode
                    && Enum.TryParse(placementNode.GetValue<string>(), out NotchPlacementPreset parsedPlacement))
                {
                    configuration.NotchPlacementPreset = parsedPlacement;
                }
                configuration.Save();
                return JsonValue.Create(true);
            }

            case "open-url":
            {
                string requestedUrl = commandArguments["url"]?.GetValue<string>() ?? "";
                // http/https only — this must never become a way to launch programs.
                if (!Uri.TryCreate(requestedUrl, UriKind.Absolute, out Uri? parsedUrl)
                    || (parsedUrl.Scheme != Uri.UriSchemeHttp && parsedUrl.Scheme != Uri.UriSchemeHttps))
                {
                    throw new InvalidOperationException($"Refused to open \"{requestedUrl}\" — only http/https URLs are allowed.");
                }
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = parsedUrl.ToString(),
                    UseShellExecute = true,
                });
                return JsonValue.Create(true);
            }

            case "get-progress":
            {
                var progressObject = new JsonObject();
                foreach ((string courseIdentifier, CourseProgress courseProgress) in learnerProgress.CourseProgressByCourseId)
                {
                    progressObject[courseIdentifier] = new JsonObject
                    {
                        ["completedGoals"] = courseProgress.CompletedGoalCount,
                        ["totalGoals"] = courseProgress.TotalGoalCount,
                        ["completed"] = courseProgress.IsCourseCompleted,
                        ["lastActivityUtc"] = courseProgress.LastActivityUtc.ToString("o"),
                    };
                }
                return progressObject;
            }

            case "record-goal-completed":
            {
                learnerProgress.RecordGoalCompleted(
                    commandArguments["courseId"]!.GetValue<string>(),
                    commandArguments["completedGoals"]!.GetValue<int>(),
                    commandArguments["totalGoals"]!.GetValue<int>());
                return JsonValue.Create(true);
            }

            case "get-screen-info":
            {
                System.Windows.Forms.Screen primaryScreen = System.Windows.Forms.Screen.PrimaryScreen
                    ?? System.Windows.Forms.Screen.AllScreens[0];
                return new JsonObject
                {
                    ["width"] = primaryScreen.Bounds.Width,
                    ["height"] = primaryScreen.Bounds.Height,
                };
            }

            case "quit":
            {
                Application.Exit();
                return JsonValue.Create(true);
            }

            default:
                throw new InvalidOperationException($"Unknown command \"{commandName}\".");
        }
    }

    private static JsonNode CaptureScreen(bool includeElements)
    {
        IReadOnlyList<System.Drawing.Point>? outlineForThisCapture = pendingMouseOutline;
        pendingMouseOutline = null;

        CapturedScreenshot capturedScreenshot = ScreenCaptureUtility.CapturePrimaryScreenWithGrid(outlineForThisCapture);

        if (includeElements)
        {
            lastInspectedElements = UiElementInspector.InspectForegroundWindow();
        }

        return new JsonObject
        {
            ["jpegBase64"] = Convert.ToBase64String(capturedScreenshot.JpegBytes),
            ["width"] = capturedScreenshot.WidthInPixels,
            ["height"] = capturedScreenshot.HeightInPixels,
            ["circledGridCells"] = capturedScreenshot.CircledGridCells,
            ["elements"] = includeElements ? BuildElementListJson(lastInspectedElements) : null,
        };
    }

    private static JsonArray BuildElementListJson(IReadOnlyList<InspectedUiElement> elements)
    {
        var elementArray = new JsonArray();
        foreach (InspectedUiElement element in elements)
        {
            elementArray.Add(new JsonObject
            {
                ["id"] = element.ElementId,
                ["name"] = element.Name,
                ["controlType"] = element.ControlTypeName,
                ["centerX"] = element.CenterInScreenPixels.X,
                ["centerY"] = element.CenterInScreenPixels.Y,
                ["enabled"] = element.IsEnabled,
                ["line"] = element.ToModelLine(),
            });
        }
        return elementArray;
    }

    private static InspectedUiElement? FindElementById(int elementId) =>
        lastInspectedElements.FirstOrDefault(element => element.ElementId == elementId);

    private static void EmitEvent(string eventName, JsonObject payload)
    {
        WriteJsonLine(new JsonObject
        {
            ["event"] = eventName,
            ["payload"] = payload,
        });
    }

    private static void WriteJsonLine(JsonObject message)
    {
        // Serialized: the hook thread, the stdin thread and the thread pool all write here.
        lock (stdoutWriteLock)
        {
            Console.Out.WriteLine(message.ToJsonString(new JsonSerializerOptions { WriteIndented = false }));
            Console.Out.Flush();
        }
    }
}
