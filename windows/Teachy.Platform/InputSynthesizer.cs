using System.Runtime.InteropServices;
using System.Windows.Automation;

namespace Teachy.Platform;

/// <summary>
/// Performs real mouse/keyboard actions on the user's behalf — the Windows
/// equivalent of the macOS AgentMacNativeTools ui_action. Prefers the UI
/// Automation Invoke/Value patterns (exact, no pointer hijacking) and falls
/// back to synthesized input only when a control exposes no pattern.
/// </summary>
public static class InputSynthesizer
{
    /// <summary>
    /// Clicks an inspected element. Uses the Invoke pattern when available so
    /// the click lands on the control itself rather than whatever happens to be
    /// under those coordinates.
    /// </summary>
    public static bool ClickElement(InspectedUiElement targetElement)
    {
        try
        {
            if (targetElement.AutomationElement is { } automationElement)
            {
                if (automationElement.TryGetCurrentPattern(InvokePattern.Pattern, out object invokePatternObject))
                {
                    ((InvokePattern)invokePatternObject).Invoke();
                    TeachyLog.Write($"Action: invoked \"{targetElement.Name}\".");
                    return true;
                }

                if (automationElement.TryGetCurrentPattern(SelectionItemPattern.Pattern, out object selectionPatternObject))
                {
                    ((SelectionItemPattern)selectionPatternObject).Select();
                    TeachyLog.Write($"Action: selected \"{targetElement.Name}\".");
                    return true;
                }

                if (automationElement.TryGetCurrentPattern(TogglePattern.Pattern, out object togglePatternObject))
                {
                    ((TogglePattern)togglePatternObject).Toggle();
                    TeachyLog.Write($"Action: toggled \"{targetElement.Name}\".");
                    return true;
                }
            }

            return ClickAtScreenPixel(targetElement.CenterInScreenPixels);
        }
        catch (Exception clickError)
        {
            TeachyLog.Write($"Action click failed on \"{targetElement.Name}\": {clickError.Message}");
            return false;
        }
    }

    /// <summary>Moves the pointer and left-clicks at an absolute screen pixel.</summary>
    public static bool ClickAtScreenPixel(System.Drawing.Point screenPixelPoint)
    {
        try
        {
            NativeMethods.SetCursorPos(screenPixelPoint.X, screenPixelPoint.Y);
            Thread.Sleep(40); // let hover states settle, like a human pause

            var mouseInputs = new[]
            {
                BuildMouseInput(NativeMethods.MOUSEEVENTF_LEFTDOWN),
                BuildMouseInput(NativeMethods.MOUSEEVENTF_LEFTUP),
            };
            uint sentEventCount = NativeMethods.SendInput(
                (uint)mouseInputs.Length, mouseInputs, Marshal.SizeOf<NativeMethods.INPUT>());

            TeachyLog.Write($"Action: clicked ({screenPixelPoint.X},{screenPixelPoint.Y}).");
            return sentEventCount == mouseInputs.Length;
        }
        catch (Exception clickError)
        {
            TeachyLog.Write($"Action click-at-point failed: {clickError.Message}");
            return false;
        }
    }

    /// <summary>
    /// Types text into an element. Uses the Value pattern when available
    /// (instant and reliable), otherwise focuses and synthesizes keystrokes.
    /// </summary>
    public static bool TypeIntoElement(InspectedUiElement targetElement, string textToType)
    {
        try
        {
            if (targetElement.AutomationElement is { } automationElement
                && automationElement.TryGetCurrentPattern(ValuePattern.Pattern, out object valuePatternObject))
            {
                var valuePattern = (ValuePattern)valuePatternObject;
                if (!valuePattern.Current.IsReadOnly)
                {
                    automationElement.SetFocus();
                    valuePattern.SetValue(textToType);
                    TeachyLog.Write($"Action: set value of \"{targetElement.Name}\".");
                    return true;
                }
            }

            targetElement.AutomationElement?.SetFocus();
            Thread.Sleep(60);
            return TypeText(textToType);
        }
        catch (Exception typeError)
        {
            TeachyLog.Write($"Action type failed on \"{targetElement.Name}\": {typeError.Message}");
            return false;
        }
    }

    /// <summary>Synthesizes keystrokes for arbitrary text into whatever has focus.</summary>
    public static bool TypeText(string textToType)
    {
        try
        {
            var keyboardInputs = new List<NativeMethods.INPUT>(textToType.Length * 2);
            foreach (char characterToType in textToType)
            {
                keyboardInputs.Add(BuildUnicodeKeyInput(characterToType, isKeyUp: false));
                keyboardInputs.Add(BuildUnicodeKeyInput(characterToType, isKeyUp: true));
            }

            NativeMethods.INPUT[] inputArray = keyboardInputs.ToArray();
            uint sentEventCount = NativeMethods.SendInput(
                (uint)inputArray.Length, inputArray, Marshal.SizeOf<NativeMethods.INPUT>());

            TeachyLog.Write($"Action: typed {textToType.Length} characters.");
            return sentEventCount == inputArray.Length;
        }
        catch (Exception typeError)
        {
            TeachyLog.Write($"Action typing failed: {typeError.Message}");
            return false;
        }
    }

    /// <summary>Presses a named key (enter, tab, escape, backspace, delete, arrows).</summary>
    public static bool PressKey(string keyName)
    {
        ushort? virtualKeyCode = keyName.Trim().ToLowerInvariant() switch
        {
            "enter" or "return" => 0x0D,
            "tab" => 0x09,
            "escape" or "esc" => 0x1B,
            "backspace" => 0x08,
            "delete" or "del" => 0x2E,
            "up" => 0x26,
            "down" => 0x28,
            "left" => 0x25,
            "right" => 0x27,
            "home" => 0x24,
            "end" => 0x23,
            "space" => 0x20,
            _ => null,
        };

        if (virtualKeyCode is null)
        {
            TeachyLog.Write($"Action: unknown key \"{keyName}\".");
            return false;
        }

        try
        {
            var keyInputs = new[]
            {
                BuildVirtualKeyInput(virtualKeyCode.Value, isKeyUp: false),
                BuildVirtualKeyInput(virtualKeyCode.Value, isKeyUp: true),
            };
            NativeMethods.SendInput((uint)keyInputs.Length, keyInputs, Marshal.SizeOf<NativeMethods.INPUT>());
            TeachyLog.Write($"Action: pressed {keyName}.");
            return true;
        }
        catch (Exception keyError)
        {
            TeachyLog.Write($"Action key press failed: {keyError.Message}");
            return false;
        }
    }

    /// <summary>Scrolls the wheel at the current pointer position. Positive scrolls up.</summary>
    public static bool Scroll(int wheelNotches)
    {
        try
        {
            NativeMethods.INPUT scrollInput = BuildMouseInput(NativeMethods.MOUSEEVENTF_WHEEL);
            scrollInput.union.mouseInput.mouseData = wheelNotches * 120; // WHEEL_DELTA
            NativeMethods.SendInput(1, new[] { scrollInput }, Marshal.SizeOf<NativeMethods.INPUT>());
            return true;
        }
        catch (Exception scrollError)
        {
            TeachyLog.Write($"Action scroll failed: {scrollError.Message}");
            return false;
        }
    }

    private static NativeMethods.INPUT BuildMouseInput(uint mouseEventFlags) => new()
    {
        type = NativeMethods.INPUT_MOUSE,
        union = new NativeMethods.InputUnion
        {
            mouseInput = new NativeMethods.MOUSEINPUT { dwFlags = mouseEventFlags },
        },
    };

    private static NativeMethods.INPUT BuildUnicodeKeyInput(char characterToType, bool isKeyUp) => new()
    {
        type = NativeMethods.INPUT_KEYBOARD,
        union = new NativeMethods.InputUnion
        {
            keyboardInput = new NativeMethods.KEYBDINPUT
            {
                wScan = characterToType,
                dwFlags = NativeMethods.KEYEVENTF_UNICODE | (isKeyUp ? NativeMethods.KEYEVENTF_KEYUP : 0),
            },
        },
    };

    private static NativeMethods.INPUT BuildVirtualKeyInput(ushort virtualKeyCode, bool isKeyUp) => new()
    {
        type = NativeMethods.INPUT_KEYBOARD,
        union = new NativeMethods.InputUnion
        {
            keyboardInput = new NativeMethods.KEYBDINPUT
            {
                wVk = virtualKeyCode,
                dwFlags = isKeyUp ? NativeMethods.KEYEVENTF_KEYUP : 0,
            },
        },
    };

    private static class NativeMethods
    {
        internal const int INPUT_MOUSE = 0;
        internal const int INPUT_KEYBOARD = 1;
        internal const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
        internal const uint MOUSEEVENTF_LEFTUP = 0x0004;
        internal const uint MOUSEEVENTF_WHEEL = 0x0800;
        internal const uint KEYEVENTF_KEYUP = 0x0002;
        internal const uint KEYEVENTF_UNICODE = 0x0004;

        [DllImport("user32.dll", SetLastError = true)]
        internal static extern uint SendInput(uint inputCount, INPUT[] inputs, int structureSize);

        [DllImport("user32.dll")]
        internal static extern bool SetCursorPos(int x, int y);

        [StructLayout(LayoutKind.Sequential)]
        internal struct INPUT
        {
            public int type;
            public InputUnion union;
        }

        [StructLayout(LayoutKind.Explicit)]
        internal struct InputUnion
        {
            [FieldOffset(0)] public MOUSEINPUT mouseInput;
            [FieldOffset(0)] public KEYBDINPUT keyboardInput;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct MOUSEINPUT
        {
            public int dx;
            public int dy;
            public int mouseData;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct KEYBDINPUT
        {
            public ushort wVk;
            public ushort wScan;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }
    }
}
