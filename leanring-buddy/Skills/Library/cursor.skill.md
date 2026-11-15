---
name: Cursor
bundleIds: [com.todesktop.230313mzl4w4u92]
sites: []
summary: An AI code editor built on VS Code. It changes often; the AI pane's names and shortcuts are version-specific.
---
## Layout
- The same shell as VS Code: file Explorer and other views in a side bar, the editor with tabs in the middle, a Panel at the bottom for Terminal and Problems, and a Status Bar along the bottom edge.
- The view icons (Explorer, Search, Source Control, Extensions) sit in a horizontal row at the top of the side bar by default, not in a vertical strip as in VS Code.
- The AI pane is on the right. It has a text box at the bottom, a mode picker (Agent, Ask and others) and a model picker next to it.
- There are two settings screens: VS Code settings (Cmd+Comma) and Cursor Settings.

## Where things are
- Open the AI pane: Cmd+L, or Cmd+I.
- Edit the selected code in place with a prompt: Cmd+K.
- Accept a grey inline suggestion: Tab.
- Point the AI at something: type @ in the text box and pick a file, folder, docs or the web.
- Review what the agent changed: the diff shown in the editor, with Accept and Reject buttons per change and for the whole file.
- Undo an agent run: the Restore Checkpoint link on an earlier message in the chat.
- Cursor Settings: Cursor > Settings > Cursor Settings (Shift+Cmd+J). Models, Rules, MCP servers, indexing and privacy mode live there.
- Project rules for the AI: files in the .cursor/rules folder (older projects use a .cursorrules file).
- The Command Palette (Shift+Cmd+P) and Cmd+P work as in VS Code.
- Install the `cursor` terminal command: Command Palette > Shell Command: Install 'cursor' command.
- Extensions: Shift+Cmd+X.

## Gotchas
- Cmd+K in the terminal writes a shell command from a prompt; it does not clear the screen as in other terminals.
- VS Code shortcuts that start with Cmd+K (such as Cmd+K then Cmd+S) are remapped to start with Cmd+R.
- Agent mode can edit many files and run commands. Check the diff before accepting, and use checkpoints to go back.
- If the AI seems unaware of the project, look at indexing status in Cursor Settings.
- Extensions come from a different marketplace than VS Code's, so a few Microsoft extensions are missing or differ.

## Shortcuts
- AI pane: Cmd+L or Cmd+I. Inline edit: Cmd+K. Accept suggestion: Tab.
- Cursor Settings: Shift+Cmd+J. Command Palette: Shift+Cmd+P.
- Open file by name: Cmd+P. Terminal: Ctrl+Backtick. Toggle side bar: Cmd+B.
