using System.Windows;
using Teachy.Engine;
using Teachy.Platform;

namespace Teachy.App;

/// <summary>
/// Central state machine — the Windows port of the macOS CompanionManager core
/// loop for quick on-screen Q&amp;A:
///
///   PTT press → record mic → PTT release → transcribe → capture screen with
///   grid → OpenRouter vision chat (streaming) → parse [POINT:...] → speak +
///   point with the overlay cursor → fade out.
///
/// Typed questions from the panel run the same pipeline minus the audio steps.
/// Courses / LessonPlayer / tools arrive in later phases.
/// </summary>
public sealed class CompanionManager : IDisposable
{
    private readonly GlobalPushToTalkHook pushToTalkHook = new();
    private readonly MicrophoneRecorder microphoneRecorder = new();
    private readonly MouseOutlineTracker mouseOutlineTracker = new();

    /// <summary>Path the learner traced while holding push-to-talk, consumed by the next capture.</summary>
    private IReadOnlyList<System.Drawing.Point>? pendingMouseOutline;

    /// <summary>Elements shown to the model this turn, so [POINT:ax:ID] can resolve.</summary>
    private IReadOnlyList<InspectedUiElement> lastInspectedElements = Array.Empty<InspectedUiElement>();

    /// <summary>
    /// Resolves a POINT tag to screen pixels — an ax element id wins (exact
    /// bounds from UI Automation), otherwise fall back to the grid/pixel math.
    /// </summary>
    private System.Drawing.Point? ResolvePointingTarget(ParsedPointTag pointTag, CapturedScreenshot capturedScreenshot)
    {
        if (pointTag.AutomationElementId is int automationElementId)
        {
            InspectedUiElement? referencedElement = lastInspectedElements
                .FirstOrDefault(element => element.ElementId == automationElementId);
            if (referencedElement is not null)
            {
                return referencedElement.CenterInScreenPixels;
            }
        }

        return ScreenGridAnnotationUtility.ResolvePointTagToScreenPixel(pointTag, capturedScreenshot);
    }
    private readonly LocalSpeechSynthesizer speechSynthesizer = new();

    private TeachyConfiguration configuration = TeachyConfiguration.Load();

    private OverlayWindow? overlayWindow;
    private NotchWindow? notchWindow;
    private CourseLessonHUDWindow? courseLessonHudWindow;

    // ---- Active course session state (LessonPlayer v1) ----
    private CourseCatalogEntry? activeCourse;
    private IReadOnlyList<CourseLearningGoal>? activeCourseGoals;
    private int currentGoalIndex;

    /// <summary>Set after a goal passes when the goal has a teach-back question —
    /// the learner's next voice/typed answer completes it and advances (protégé effect).</summary>
    private bool isAwaitingTeachBackAnswer;

    /// <summary>True when the in-flight model turn came from the learner (voice/typed)
    /// rather than an auto coach prompt — used to detect teach-back answers.</summary>
    private bool pendingTurnIsUserInitiated;

    public readonly LearnerProgressStore learnerProgress = LearnerProgressStore.Load();

    public bool IsCourseActive => activeCourse is not null;

    /// <summary>Text-only conversation memory for follow-up questions (last few turns).</summary>
    private readonly List<CompanionConversationTurn> conversationHistory = new();
    private const int MaximumRememberedConversationTurns = 6;

    private CancellationTokenSource? activeReplyCancellation;
    private bool isHandlingInteraction;

    public bool HasOpenRouterApiKey => configuration.HasOpenRouterApiKey;

    /// <summary>Key-aware effective model, mirroring the macOS default logic:
    /// BYOK users get the smartest tutor unless they explicitly picked a model.</summary>
    public string ChatModelIdentifier =>
        OpenRouterModelOptions.SanitizedModelIdentifier(
            configuration.ChosenChatModelIdentifier, configuration.HasOpenRouterApiKey);

    public void SetChosenChatModel(string chosenModelIdentifier)
    {
        configuration.ChosenChatModelIdentifier = chosenModelIdentifier;
        configuration.Save();
    }

    // ---- Notch placement ----

    public NotchPlacementPreset GetNotchPlacementPreset() => configuration.NotchPlacementPreset;

    /// <summary>Exact position for the Custom preset, or null when no custom position was ever saved.</summary>
    public (double Left, double Top, string HorizontalAlignment)? GetCustomNotchPlacement()
    {
        if (configuration.CustomNotchLeft is null || configuration.CustomNotchTop is null)
        {
            return null;
        }
        return (configuration.CustomNotchLeft.Value, configuration.CustomNotchTop.Value,
            configuration.CustomNotchHorizontalAlignment ?? "Left");
    }

    public void SetNotchPlacementPreset(NotchPlacementPreset placementPreset)
    {
        configuration.NotchPlacementPreset = placementPreset;
        configuration.Save();
        RunOnUiThread(() => notchWindow?.ApplyPlacementFromConfig());
    }

    /// <summary>Called after the user drags the notch — persists exactly where they put it.</summary>
    public void SetCustomNotchPosition(double leftInDeviceIndependentUnits, double topInDeviceIndependentUnits, string horizontalAlignmentName)
    {
        configuration.NotchPlacementPreset = NotchPlacementPreset.Custom;
        configuration.CustomNotchLeft = leftInDeviceIndependentUnits;
        configuration.CustomNotchTop = topInDeviceIndependentUnits;
        configuration.CustomNotchHorizontalAlignment = horizontalAlignmentName;
        configuration.Save();
    }

    public bool ShowTeachyCursor => configuration.ShowTeachyCursor;

    /// <summary>Toggles the always-visible companion cursor ("Show Teachy" on macOS).</summary>
    public void SetShowTeachyCursor(bool shouldShowTeachyCursor)
    {
        configuration.ShowTeachyCursor = shouldShowTeachyCursor;
        configuration.Save();

        RunOnUiThread(() =>
        {
            if (shouldShowTeachyCursor)
            {
                overlayWindow?.StartFollowingPointer();
            }
            else
            {
                overlayWindow?.StopFollowingPointer();
            }
        });
    }

    public void Start()
    {
        overlayWindow = new OverlayWindow();
        overlayWindow.Show();
        if (configuration.ShowTeachyCursor)
        {
            overlayWindow.StartFollowingPointer();
        }

        notchWindow = new NotchWindow(this);
        notchWindow.Show(); // the notch lives on screen permanently, like the mac

        pushToTalkHook.PushToTalkPressed += HandlePushToTalkPressed;
        pushToTalkHook.PushToTalkReleased += HandlePushToTalkReleased;
        pushToTalkHook.Install();

        // First run: spring the notch open on Settings so the user can paste their key.
        if (!configuration.HasOpenRouterApiKey)
        {
            RunOnUiThread(() => notchWindow?.ExpandToSettings());
        }
    }

    public void TogglePanel()
    {
        RunOnUiThread(() =>
        {
            notchWindow?.RefreshStatusDisplay();
            notchWindow?.ToggleExpanded();
        });
    }

    /// <summary>
    /// Starts a course session — the LessonPlayer loop: coach the current goal,
    /// verify with vision on "I did it", advance. Courses without ported goal
    /// data fall back to live voice coaching.
    /// </summary>
    public void StartCourse(CourseCatalogEntry courseEntry)
    {
        RunOnUiThread(() =>
        {
            notchWindow?.Collapse();

            IReadOnlyList<CourseLearningGoal>? courseGoals = CourseDefinitions.GoalsForCourse(courseEntry.CourseIdentifier);

            if (courseEntry.StartUrl is not null)
            {
                try
                {
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = courseEntry.StartUrl,
                        UseShellExecute = true,
                    });
                }
                catch (Exception)
                {
                    // Browser launch failure shouldn't block the coaching hand-off.
                }
            }

            if (courseGoals is null)
            {
                string courseKickoffMessage =
                    $"Let's start {courseEntry.Title}. Hold Ctrl+Alt any time and I'll coach you through each step on your screen.";
                overlayWindow?.ShowResponseText(courseKickoffMessage);
                speechSynthesizer.SpeakInterruptingCurrentSpeech(courseKickoffMessage);
                overlayWindow?.FadeOutAfterDelay(TimeSpan.FromSeconds(8));
                return;
            }

            activeCourse = courseEntry;
            activeCourseGoals = courseGoals;

            // Resume where the learner left off — projects survive across days.
            CourseProgress? savedProgress = learnerProgress.ProgressForCourse(courseEntry.CourseIdentifier);
            currentGoalIndex = savedProgress is { IsCourseCompleted: false }
                ? Math.Clamp(savedProgress.CompletedGoalCount, 0, courseGoals.Count - 1)
                : 0;

            courseLessonHudWindow ??= new CourseLessonHUDWindow(this);
            courseLessonHudWindow.Show();
            RefreshCourseHudHeader();

            RunCourseCoachTurn(courseGoals[currentGoalIndex].CoachAsk);
        });
    }

    public void ExitCourse()
    {
        RunOnUiThread(() =>
        {
            activeCourse = null;
            activeCourseGoals = null;
            currentGoalIndex = 0;
            courseLessonHudWindow?.Hide();
            speechSynthesizer.StopSpeaking();
            overlayWindow?.FadeOutAfterDelay(TimeSpan.Zero);
        });
    }

    /// <summary>
    /// "Do it for me" — hands the current goal to the agent loop, which acts on
    /// the real UI while narrating each step aloud. Mirrors the macOS
    /// executeActStep path (announce before act).
    /// </summary>
    public void RequestDoItForMe()
    {
        if (isHandlingInteraction)
        {
            return;
        }

        string? openRouterApiKey = configuration.GetOpenRouterApiKey();
        if (openRouterApiKey is null)
        {
            notchWindow?.ExpandToSettings();
            return;
        }

        string actionGoal = activeCourseGoals is not null && activeCourse is not null
            ? $"Do this step for the learner in the course \"{activeCourse.Title}\": {activeCourseGoals[currentGoalIndex].Goal} " +
              $"It is complete when: {activeCourseGoals[currentGoalIndex].DoneWhen ?? "the learner can see it is done"}."
            : "Do the thing the learner just asked for, on their screen.";

        RunDoItForMe(actionGoal, openRouterApiKey);
    }

    private void RunDoItForMe(string actionGoal, string openRouterApiKey)
    {
        isHandlingInteraction = true;
        courseLessonHudWindow?.ShowCoachLine("Okay — I'll do this part. Watch what I click.");
        speechSynthesizer.SpeakInterruptingCurrentSpeech("Okay, I'll do this part. Watch what I click.");

        _ = Task.Run(async () =>
        {
            try
            {
                IReadOnlyList<InspectedUiElement> initialElements = UiElementInspector.InspectForegroundWindow();
                CapturedScreenshot initialScreenshot = ScreenCaptureUtility.CapturePrimaryScreenWithGrid();

                var toolExecutor = new AgentToolExecutor(initialElements);
                var agentLoop = new AgentToolLoop(openRouterApiKey, ChatModelIdentifier);

                string finalSummary = await agentLoop.RunAsync(
                    AgentToolDefinitions.BuildAgentSystemPrompt(),
                    actionGoal,
                    initialScreenshot.JpegBytes,
                    AgentToolExecutor.FormatElementList(initialElements),
                    toolExecutor.ExecuteAsync,
                    onNarration: narrationText => RunOnUiThread(() =>
                    {
                        // Announce before the action lands, like the mac agent.
                        courseLessonHudWindow?.ShowCoachLine(narrationText);
                        overlayWindow?.ShowResponseText(narrationText);
                        speechSynthesizer.SpeakInterruptingCurrentSpeech(narrationText);
                    }),
                    CancellationToken.None);

                RunOnUiThread(() =>
                {
                    courseLessonHudWindow?.ShowCoachLine(finalSummary);
                    overlayWindow?.ShowResponseText(finalSummary);
                    overlayWindow?.FadeOutAfterDelay(TimeSpan.FromSeconds(8));
                });
            }
            catch (Exception agentError)
            {
                TeachyLog.Write($"Do-it-for-me failed: {agentError.Message}");
                RunOnUiThread(() =>
                {
                    string failureMessage = $"I couldn't finish that automatically: {agentError.Message}";
                    courseLessonHudWindow?.ShowCoachLine(failureMessage);
                    overlayWindow?.ShowResponseText(failureMessage);
                    overlayWindow?.FadeOutAfterDelay(TimeSpan.FromSeconds(7));
                });
            }
            finally
            {
                isHandlingInteraction = false;
            }
        });
    }

    public void RequestCourseHint()
    {
        if (activeCourseGoals is null)
        {
            return;
        }
        CourseLearningGoal currentGoal = activeCourseGoals[currentGoalIndex];
        string hintAsk = currentGoal.Tips.Count > 0
            ? $"I'm stuck on: {currentGoal.Goal} Give me one concrete hint for my exact screen right now. (Author tips you can draw from: {string.Join("; ", currentGoal.Tips)})"
            : $"I'm stuck on: {currentGoal.Goal} Give me one concrete hint for my exact screen right now.";
        RunCourseCoachTurn(hintAsk);
    }

    public void RequestCourseVerification()
    {
        if (activeCourse is null || activeCourseGoals is null || isHandlingInteraction)
        {
            return;
        }

        CourseLearningGoal currentGoal = activeCourseGoals[currentGoalIndex];

        // While a teach-back is pending, "I did it" acts as skip — mac teach-backs are soft.
        if (isAwaitingTeachBackAnswer)
        {
            isAwaitingTeachBackAnswer = false;
            AdvanceToNextCourseGoal("teach-back skipped, that's okay");
            return;
        }

        // Concept goals with no doneWhen advance on learner confirmation (mac requireUserAdvance).
        if (currentGoal.DoneWhen is null)
        {
            BeginTeachBackOrAdvance(currentGoal, "you confirmed it");
            return;
        }

        courseLessonHudWindow?.ShowCoachLine("Checking your screen…");

        string doneWhenCriteria = currentGoal.DoneWhen;

        _ = Task.Run(async () =>
        {
            try
            {
                string? openRouterApiKey = configuration.GetOpenRouterApiKey();
                if (openRouterApiKey is null)
                {
                    return;
                }

                CapturedScreenshot capturedScreenshot = ScreenCaptureUtility.CapturePrimaryScreenWithGrid();
                var openRouterClient = new OpenRouterClient(openRouterApiKey, ChatModelIdentifier);

                CourseVerificationResult verificationResult = await CourseVerifier.VerifyAsync(
                    openRouterClient, doneWhenCriteria, capturedScreenshot.JpegBytes, CancellationToken.None);

                RunOnUiThread(() =>
                {
                    // Mac parity: pass AND partial both advance; offTrack coaches the gap.
                    if (verificationResult.Status is CourseVerificationStatus.Pass or CourseVerificationStatus.Partial)
                    {
                        BeginTeachBackOrAdvance(currentGoal, verificationResult.WhatsGood);
                    }
                    else
                    {
                        string coachback = verificationResult.SuggestedNextAction
                            ?? verificationResult.WhatsMissing
                            ?? "Not quite there yet — keep going and press I did it when it's on screen.";
                        courseLessonHudWindow?.ShowCoachLine(coachback);
                        speechSynthesizer.SpeakInterruptingCurrentSpeech(coachback);
                    }
                });
            }
            catch (Exception verificationError)
            {
                RunOnUiThread(() => courseLessonHudWindow?.ShowCoachLine($"Verification hiccup: {verificationError.Message}"));
            }
        });
    }

    /// <summary>
    /// After a goal passes: run the soft teach-back first when the goal has one
    /// (protégé effect, like the mac LessonPlayer), otherwise advance directly.
    /// </summary>
    private void BeginTeachBackOrAdvance(CourseLearningGoal passedGoal, string whatWentWell)
    {
        if (passedGoal.TeachBackPrompt is not null)
        {
            isAwaitingTeachBackAnswer = true;
            string teachBackAsk =
                $"Nice — {whatWentWell}. Quick teach-back before we move on: {passedGoal.TeachBackPrompt} Hold Ctrl+Alt and tell me — or press I did it to skip.";
            courseLessonHudWindow?.ShowCoachLine(teachBackAsk);
            speechSynthesizer.SpeakInterruptingCurrentSpeech(teachBackAsk);
        }
        else
        {
            AdvanceToNextCourseGoal(whatWentWell);
        }
    }

    private void AdvanceToNextCourseGoal(string whatWentWell, bool speakTransition = true)
    {
        if (activeCourse is null || activeCourseGoals is null)
        {
            return;
        }

        // Persist progress so the course survives across days (mac learner memory).
        learnerProgress.RecordGoalCompleted(
            activeCourse.CourseIdentifier, currentGoalIndex + 1, activeCourseGoals.Count);

        bool wasFinalGoal = currentGoalIndex >= activeCourseGoals.Count - 1;
        if (wasFinalGoal)
        {
            string completionMessage =
                $"That's the whole course — {activeCourse.Title} done. {whatWentWell}. Seriously nice work.";
            courseLessonHudWindow?.ShowCoachLine(completionMessage);
            if (speakTransition)
            {
                speechSynthesizer.SpeakInterruptingCurrentSpeech(completionMessage);
            }
            activeCourse = null;
            activeCourseGoals = null;
            return;
        }

        currentGoalIndex++;
        RefreshCourseHudHeader();
        CourseLearningGoal nextGoal = activeCourseGoals[currentGoalIndex];

        if (speakTransition)
        {
            string advanceMessage = $"Nailed it — {whatWentWell}. Next up: {nextGoal.Title}.";
            speechSynthesizer.SpeakInterruptingCurrentSpeech(advanceMessage);
            courseLessonHudWindow?.ShowCoachLine(advanceMessage);
            RunCourseCoachTurn(nextGoal.CoachAsk);
        }
        else
        {
            // Silent advance after a teach-back: the model reply already handled the
            // transition — auto-prompt the next goal once that speech has room to land.
            var nextCoachTurnDelay = new System.Windows.Threading.DispatcherTimer
            {
                Interval = TimeSpan.FromSeconds(8),
            };
            nextCoachTurnDelay.Tick += (_, _) =>
            {
                nextCoachTurnDelay.Stop();
                if (activeCourse is not null && activeCourseGoals is not null
                    && currentGoalIndex < activeCourseGoals.Count
                    && activeCourseGoals[currentGoalIndex] == nextGoal)
                {
                    RunCourseCoachTurn(nextGoal.CoachAsk);
                }
            };
            nextCoachTurnDelay.Start();
        }
    }

    private void RefreshCourseHudHeader()
    {
        if (activeCourse is null || activeCourseGoals is null)
        {
            return;
        }
        courseLessonHudWindow?.ShowCourseState(
            activeCourse.Title,
            activeCourseGoals[currentGoalIndex].Title,
            currentGoalIndex + 1,
            activeCourseGoals.Count);
    }

    private void RunCourseCoachTurn(string coachAsk)
    {
        if (isHandlingInteraction)
        {
            return;
        }
        speechSynthesizer.StopSpeaking();
        pendingTurnIsUserInitiated = false;
        _ = RunCompanionInteractionAsync(() => Task.FromResult<string?>(coachAsk));
    }

    public void SaveOpenRouterApiKey(string openRouterApiKeyPlaintext)
    {
        configuration.SetOpenRouterApiKey(openRouterApiKeyPlaintext);
        configuration.Save();
    }

    // ---- Push-to-talk voice path ----

    private void HandlePushToTalkPressed()
    {
        RunOnUiThread(() =>
        {
            if (isHandlingInteraction)
            {
                return;
            }

            string? microphoneProblem = MicrophoneRecorder.DescribeMicrophoneProblem();
            if (microphoneProblem is not null)
            {
                overlayWindow?.ShowResponseText(microphoneProblem);
                overlayWindow?.FadeOutAfterDelay(TimeSpan.FromSeconds(6));
                return;
            }

            speechSynthesizer.StopSpeaking();
            microphoneRecorder.StartRecording();
            mouseOutlineTracker.StartTracking();
            overlayWindow?.ShowListeningState();
            notchWindow?.SetLiveActivity(true);
        });
    }

    private void HandlePushToTalkReleased()
    {
        RunOnUiThread(() =>
        {
            notchWindow?.SetLiveActivity(false);
            byte[]? recordedWavBytes = microphoneRecorder.StopRecordingAndGetWavBytes();
            pendingMouseOutline = mouseOutlineTracker.StopTrackingAndGetOutline();

            if (isHandlingInteraction)
            {
                return;
            }
            if (recordedWavBytes is null)
            {
                overlayWindow?.ShowResponseText("That was too short to hear — hold Ctrl+Alt while you talk, then let go.");
                overlayWindow?.FadeOutAfterDelay(TimeSpan.FromSeconds(4));
                return;
            }

            overlayWindow?.ShowStatus("transcribing…");

            pendingTurnIsUserInitiated = true;
            _ = RunCompanionInteractionAsync(async () =>
            {
                TranscriptionResult transcriptionResult =
                    await Task.Run(() => SystemSpeechTranscriber.TranscribeWavAudio(recordedWavBytes));
                if (!transcriptionResult.Succeeded)
                {
                    RunOnUiThread(() =>
                    {
                        overlayWindow?.ShowResponseText(
                            transcriptionResult.FailureMessage ?? "I couldn't catch that — try again, or type your question in the Teachy panel.");
                        overlayWindow?.FadeOutAfterDelay(TimeSpan.FromSeconds(7));
                    });
                    return null;
                }
                return transcriptionResult.Transcript;
            });
        });
    }

    // ---- Typed question path (panel fallback) ----

    public void HandleTypedQuestion(string typedQuestion)
    {
        RunOnUiThread(() =>
        {
            if (isHandlingInteraction)
            {
                return;
            }
            speechSynthesizer.StopSpeaking();
            overlayWindow?.ShowStatus("looking at your screen…");
            pendingTurnIsUserInitiated = true;
            _ = RunCompanionInteractionAsync(() => Task.FromResult<string?>(typedQuestion));
        });
    }

    // ---- Shared pipeline ----

    /// <summary>
    /// Runs one full companion interaction. questionProvider resolves the user's
    /// question (from transcription or typed input); a null result aborts quietly.
    /// </summary>
    private async Task RunCompanionInteractionAsync(Func<Task<string?>> questionProvider)
    {
        isHandlingInteraction = true;
        activeReplyCancellation?.Cancel();
        activeReplyCancellation = new CancellationTokenSource();
        CancellationToken cancellationToken = activeReplyCancellation.Token;

        try
        {
            string? userQuestion = await questionProvider();
            if (userQuestion is null)
            {
                return;
            }

            string? openRouterApiKey = configuration.GetOpenRouterApiKey();
            if (openRouterApiKey is null)
            {
                RunOnUiThread(() =>
                {
                    overlayWindow?.ShowResponseText("Add your free OpenRouter API key in the Teachy panel first (click the tray icon).");
                    overlayWindow?.FadeOutAfterDelay(TimeSpan.FromSeconds(5));
                    TogglePanel();
                });
                return;
            }

            // Capture the screen with the model-facing grid burned in, plus any
            // chalk circle the learner traced while asking.
            IReadOnlyList<System.Drawing.Point>? mouseOutlineForThisTurn = pendingMouseOutline;
            pendingMouseOutline = null;

            // Read the real control tree alongside the pixels — pointing at a known
            // element beats guessing a grid cell from the image.
            IReadOnlyList<InspectedUiElement> inspectedElements =
                await Task.Run(UiElementInspector.InspectForegroundWindow);
            lastInspectedElements = inspectedElements;

            CapturedScreenshot capturedScreenshot =
                await Task.Run(() => ScreenCaptureUtility.CapturePrimaryScreenWithGrid(mouseOutlineForThisTurn));
            RunOnUiThread(() => overlayWindow?.ShowStatus("thinking…"));

            string systemPrompt = CompanionPromptBuilder.BuildSystemPrompt(
                capturedScreenshot.WidthInPixels,
                capturedScreenshot.HeightInPixels,
                inspectedElements.Count > 0 ? AgentToolExecutor.FormatElementList(inspectedElements) : null);

            if (capturedScreenshot.CircledGridCells is not null)
            {
                systemPrompt += $"""


                    THE LEARNER CIRCLED SOMETHING — the yellow chalk stroke on the screenshot is
                    their own drawing, made while asking this question. It covers grid cells:
                    {capturedScreenshot.CircledGridCells}.
                    Whatever they mean by "this" / "that" / "here" is inside that stroke. Answer
                    about what is circled, and ignore the chalk itself as page content.
                    """;
            }

            // Inside a course, every turn carries the current goal so replies coach
            // toward doneWhen instead of answering generically (LessonPlayer behavior).
            if (activeCourse is not null && activeCourseGoals is not null)
            {
                CourseLearningGoal currentGoal = activeCourseGoals[currentGoalIndex];
                bool isTeachBackAnswerTurn = isAwaitingTeachBackAnswer && pendingTurnIsUserInitiated;

                if (isTeachBackAnswerTurn)
                {
                    string nextGoalTitle = currentGoalIndex < activeCourseGoals.Count - 1
                        ? activeCourseGoals[currentGoalIndex + 1].Title
                        : "wrapping up the course";
                    systemPrompt += $"""


                        TEACH-BACK MOMENT — the learner just finished the goal "{currentGoal.Title}"
                        in the course "{activeCourse.Title}" and is answering this teach-back question:
                        "{currentGoal.TeachBackPrompt}"
                        React to their explanation warmly in 1-2 sentences — affirm what they got
                        right, gently correct anything wrong. Then transition in one sentence to
                        what's next: {nextGoalTitle}. Do not re-explain the whole topic.
                        """;
                }
                else
                {
                    systemPrompt += $"""


                        ACTIVE COURSE CONTEXT — you are running the course "{activeCourse.Title}".
                        Current goal ({currentGoalIndex + 1} of {activeCourseGoals.Count}): {currentGoal.Title}.
                        The learner is trying to: {currentGoal.Goal}
                        The goal is done when: {currentGoal.DoneWhen ?? "the learner says they understand it"}
                        Coach them toward this goal from what you SEE on their screen right now —
                        one small concrete next step at a time, pointing at the real UI. Never dump
                        the whole plan. Celebrate real progress briefly, then move.
                        """;
                }
            }

            var openRouterClient = new OpenRouterClient(openRouterApiKey, ChatModelIdentifier);

            string fullReplyText = await openRouterClient.StreamCompanionReplyAsync(
                systemPrompt,
                conversationHistory,
                userQuestion,
                capturedScreenshot.JpegBytes,
                onPartialText: partialText => RunOnUiThread(() =>
                {
                    // Stream text into the bubble with tags stripped as they appear.
                    overlayWindow?.ShowResponseText(PointTagParser.Parse(partialText).SpokenText);
                }),
                cancellationToken);

            ParsedModelReply parsedReply = PointTagParser.Parse(fullReplyText);

            RememberConversationTurn("user", userQuestion);
            RememberConversationTurn("assistant", parsedReply.SpokenText);

            RunOnUiThread(() =>
            {
                overlayWindow?.ShowResponseText(parsedReply.SpokenText);
                speechSynthesizer.SpeakInterruptingCurrentSpeech(parsedReply.SpokenText);

                // Mirror the coach line into the course HUD, like the mac lesson HUD.
                if (activeCourse is not null)
                {
                    courseLessonHudWindow?.ShowCoachLine(parsedReply.SpokenText);
                }

                // The learner just answered a teach-back — the model reply above already
                // reacted and transitioned, so advance quietly after it finishes speaking.
                if (isAwaitingTeachBackAnswer && pendingTurnIsUserInitiated && activeCourse is not null)
                {
                    isAwaitingTeachBackAnswer = false;
                    AdvanceToNextCourseGoal("teach-back done", speakTransition: false);
                }

                if (parsedReply.PointTag is null)
                {
                    TeachyLog.Write("Point: model reply had no [POINT:...] tag.");
                }
                else
                {
                    System.Drawing.Point? pointingTarget = ResolvePointingTarget(parsedReply.PointTag, capturedScreenshot);
                    if (pointingTarget is null)
                    {
                        TeachyLog.Write(
                            $"Point: tag present (ax={parsedReply.PointTag.AutomationElementId}, " +
                            $"cell={parsedReply.PointTag.GridCellIdentifier}, px={parsedReply.PointTag.PixelCoordinate}) " +
                            "but could not resolve to a screen pixel.");
                    }
                    else
                    {
                        TeachyLog.Write($"Point: animating to screen pixel ({pointingTarget.Value.X},{pointingTarget.Value.Y}).");
                        overlayWindow?.AnimatePointingToScreenPixel(pointingTarget.Value);
                    }
                }

                // Rough read-aloud time before the transient fade-out, like the Mac's
                // transient cursor mode: base + per-word allowance.
                int wordCount = parsedReply.SpokenText.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length;
                double estimatedSpeechSeconds = Math.Clamp(1.5 + wordCount * 0.38, 3, 30);
                overlayWindow?.FadeOutAfterDelay(TimeSpan.FromSeconds(estimatedSpeechSeconds));
            });
        }
        catch (OperationCanceledException)
        {
            // A newer interaction superseded this one — nothing to clean up.
        }
        catch (Exception unexpectedError)
        {
            RunOnUiThread(() =>
            {
                overlayWindow?.ShowResponseText($"Something went wrong: {unexpectedError.Message}");
                overlayWindow?.FadeOutAfterDelay(TimeSpan.FromSeconds(6));
            });
        }
        finally
        {
            isHandlingInteraction = false;
        }
    }

    private void RememberConversationTurn(string role, string text)
    {
        conversationHistory.Add(new CompanionConversationTurn { Role = role, Text = text });
        while (conversationHistory.Count > MaximumRememberedConversationTurns)
        {
            conversationHistory.RemoveAt(0);
        }
    }

    private static void RunOnUiThread(Action uiAction)
    {
        System.Windows.Application currentApplication = System.Windows.Application.Current;
        if (currentApplication.Dispatcher.CheckAccess())
        {
            uiAction();
        }
        else
        {
            currentApplication.Dispatcher.BeginInvoke(uiAction);
        }
    }

    public void Dispose()
    {
        activeReplyCancellation?.Cancel();
        pushToTalkHook.Dispose();
        microphoneRecorder.Dispose();
        speechSynthesizer.Dispose();
    }
}
