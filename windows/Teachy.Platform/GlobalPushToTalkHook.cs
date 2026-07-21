using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Teachy.Platform;

/// <summary>
/// System-wide push-to-talk monitor — the Windows equivalent of the macOS
/// listen-only CGEvent tap. Uses a low-level keyboard hook (WH_KEYBOARD_LL) to
/// detect Ctrl+Alt held together (mirroring ctrl+option on the Mac). The hook
/// observes and never swallows events, so typing elsewhere is unaffected.
///
/// Note: on some international layouts AltGr reports as Ctrl+Alt; acceptable
/// for v0 because press-and-HOLD (not a tap) is what triggers recording.
/// </summary>
public sealed class GlobalPushToTalkHook : IDisposable
{
    /// <summary>Fired on the hook thread when both Ctrl and Alt become held.</summary>
    public event Action? PushToTalkPressed;

    /// <summary>Fired on the hook thread when either modifier is released after a press.</summary>
    public event Action? PushToTalkReleased;

    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;

    private const int VK_LCONTROL = 0xA2;
    private const int VK_RCONTROL = 0xA3;
    private const int VK_LMENU = 0xA4; // left Alt
    private const int VK_RMENU = 0xA5; // right Alt

    private IntPtr installedHookHandle = IntPtr.Zero;
    private LowLevelKeyboardProc? keyboardHookCallbackKeptAlive; // prevents GC of the native callback delegate

    private bool isControlKeyHeld;
    private bool isAltKeyHeld;
    private bool isPushToTalkCurrentlyActive;

    public void Install()
    {
        if (installedHookHandle != IntPtr.Zero)
        {
            return;
        }

        keyboardHookCallbackKeptAlive = KeyboardHookCallback;
        using Process currentProcess = Process.GetCurrentProcess();
        using ProcessModule currentModule = currentProcess.MainModule!;
        installedHookHandle = SetWindowsHookEx(
            WH_KEYBOARD_LL,
            keyboardHookCallbackKeptAlive,
            GetModuleHandle(currentModule.ModuleName),
            0);

        if (installedHookHandle == IntPtr.Zero)
        {
            throw new InvalidOperationException("Failed to install the global push-to-talk keyboard hook.");
        }
    }

    private IntPtr KeyboardHookCallback(int hookCode, IntPtr windowsMessageIdentifier, IntPtr keyboardEventDataPointer)
    {
        if (hookCode >= 0)
        {
            int virtualKeyCode = Marshal.ReadInt32(keyboardEventDataPointer); // first field of KBDLLHOOKSTRUCT
            int messageIdentifier = (int)windowsMessageIdentifier;
            bool isKeyDownMessage = messageIdentifier is WM_KEYDOWN or WM_SYSKEYDOWN;
            bool isKeyUpMessage = messageIdentifier is WM_KEYUP or WM_SYSKEYUP;

            if (virtualKeyCode is VK_LCONTROL or VK_RCONTROL)
            {
                if (isKeyDownMessage) { isControlKeyHeld = true; }
                if (isKeyUpMessage) { isControlKeyHeld = false; }
            }
            else if (virtualKeyCode is VK_LMENU or VK_RMENU)
            {
                if (isKeyDownMessage) { isAltKeyHeld = true; }
                if (isKeyUpMessage) { isAltKeyHeld = false; }
            }

            bool shouldPushToTalkBeActive = isControlKeyHeld && isAltKeyHeld;
            if (shouldPushToTalkBeActive && !isPushToTalkCurrentlyActive)
            {
                isPushToTalkCurrentlyActive = true;
                PushToTalkPressed?.Invoke();
            }
            else if (!shouldPushToTalkBeActive && isPushToTalkCurrentlyActive)
            {
                isPushToTalkCurrentlyActive = false;
                PushToTalkReleased?.Invoke();
            }
        }

        // Always pass the event through — this hook is listen-only.
        return CallNextHookEx(installedHookHandle, hookCode, windowsMessageIdentifier, keyboardEventDataPointer);
    }

    public void Dispose()
    {
        if (installedHookHandle != IntPtr.Zero)
        {
            UnhookWindowsHookEx(installedHookHandle);
            installedHookHandle = IntPtr.Zero;
        }
    }

    private delegate IntPtr LowLevelKeyboardProc(int hookCode, IntPtr windowsMessageIdentifier, IntPtr keyboardEventDataPointer);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int hookType, LowLevelKeyboardProc hookCallback, IntPtr moduleHandle, uint threadIdentifier);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hookHandle);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hookHandle, int hookCode, IntPtr windowsMessageIdentifier, IntPtr keyboardEventDataPointer);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetModuleHandle(string moduleName);
}
