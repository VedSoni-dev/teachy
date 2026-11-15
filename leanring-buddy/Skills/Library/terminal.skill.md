---
name: Terminal
bundleIds: [com.apple.Terminal]
sites: []
summary: Apple's Terminal app. The default shell is zsh.
---
## Layout
- A window of text with a prompt. Tabs appear in a bar under the title when more than one is open.
- The title shows the folder, the running command and the window size.
- Everything else is in the menu bar: Terminal, Shell, Edit, View, Window, Help.
- Terminal > Settings has General, Profiles, Window Groups and Encodings. A profile is a look (colours, font) plus behaviour, with its own tabs: Text, Window, Tab, Shell, Keyboard, Advanced.

## Where things are
- New window: Shell > New Window. New tab: Shell > New Tab.
- Split the view to see earlier output: View > Split Pane.
- Change colours and font: Terminal > Settings > Profiles > Text. Pick a profile and click Default at the bottom of the list to use it for new windows.
- Which shell opens: Terminal > Settings > General > Shells open with.
- Keep or close the window when a shell exits: Profiles > Shell > When the shell exits.
- Make Option work as Meta (for word jumps in some tools): Profiles > Keyboard > Use Option as Meta key.
- Paste a file's full path: drag the file from Finder into the window.
- Open Terminal at a folder: Control-click the folder in Finder > Services > New Terminal at Folder. Enable it in System Settings > Keyboard > Keyboard Shortcuts > Services.
- Save everything on screen to a file: Shell > Export Text As.
- Let commands reach protected folders: System Settings > Privacy & Security > Full Disk Access, then switch Terminal on.

## Gotchas
- Cmd+C copies. Ctrl+C stops the running command. They are different keys.
- Nothing appears while typing a password after sudo. That is normal; type it and press Return.
- Pasting several lines runs each one as it is pasted.
- "Operation not permitted" on Desktop, Documents or Mail folders means Terminal lacks Full Disk Access.
- "command not found" for a tool that is installed usually means its folder is not in PATH, set in ~/.zshrc.
- Closing a window kills whatever is running in it.

## Shortcuts
- New window: Cmd+N. New tab: Cmd+T. Close: Cmd+W.
- Clear the screen and scrollback: Cmd+K. Find: Cmd+F.
- Bigger and smaller text: Cmd+Plus and Cmd+Minus.
- Jump to the previous or next prompt: Cmd+Up Arrow and Cmd+Down Arrow.
- Stop a command: Ctrl+C. End input: Ctrl+D. Start of line: Ctrl+A. End: Ctrl+E.
- Previous command: Up Arrow. Search history: Ctrl+R. Complete a name: Tab.
