---
name: Visual Studio Code
bundleIds: [com.microsoft.VSCode, com.microsoft.VSCodeInsiders, com.vscodium]
sites: [vscode.dev]
summary: Microsoft's code editor. Almost everything is reachable from the Command Palette.
---
## Layout
- Activity Bar at the far left: Explorer (files), Search, Source Control, Run and Debug, Extensions. Clicking one opens it in the Side Bar beside it.
- Editor in the middle, with tabs. It can be split into groups.
- Panel at the bottom: Problems, Output, Debug Console, Terminal, Ports.
- Status Bar along the bottom edge: Git branch at the left; errors and warnings; at the right the cursor position, indentation, encoding and language mode. Most of these are clickable.
- A second side bar on the right usually holds Chat.

## Where things are
- Command Palette (run any command by name): Shift+Cmd+P.
- Open a file by name: Cmd+P.
- Settings: Code > Settings > Settings (Cmd+Comma). The raw file: Command Palette > Preferences: Open User Settings (JSON).
- Keyboard shortcuts: Cmd+K then Cmd+S.
- Install extensions: Extensions in the Activity Bar (Shift+Cmd+X).
- Terminal: Ctrl+Backtick, or Terminal > New Terminal.
- Search across files: Shift+Cmd+F.
- Commit, stage and push: Source Control in the Activity Bar.
- Change a file's language: click the language name in the Status Bar.
- Format a file: Shift+Option+F.
- Colour theme: Cmd+K then Cmd+T.
- Auto save: File > Auto Save.
- Install the `code` command for the terminal: Command Palette > Shell Command: Install 'code' command in PATH.
- Pick a Python interpreter: Command Palette > Python: Select Interpreter.

## Gotchas
- Settings exist at User level and Workspace level. A Workspace value (in .vscode/settings.json) wins, which is why a setting can seem to be ignored.
- A folder opened in Restricted Mode (Workspace Trust) disables tasks, debugging and some extensions until you trust it.
- Features like Python or Prettier come from extensions. If a command is missing, the extension is not installed or is disabled for this workspace.
- A single click opens a file in preview (italic tab) and the next click replaces it. Double-click to keep it open.

## Shortcuts
- Toggle Side Bar: Cmd+B. Split editor: Cmd+Backslash.
- Go to definition: F12. Rename symbol: F2. Quick fix: Cmd+Period.
- Add next match to selection: Cmd+D. Add a cursor: Option+click.
- Comment a line: Cmd+Slash. Move a line: Option+Up or Option+Down.
- Word wrap: Option+Z. Go to line: Ctrl+G.
