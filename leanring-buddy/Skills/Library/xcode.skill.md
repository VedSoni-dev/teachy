---
name: Xcode
bundleIds: [com.apple.dt.Xcode]
sites: []
summary: Apple's IDE for Mac and iPhone apps. Written for Xcode 15 and 16.
---
## Layout
- Navigator area on the left, with tabs along its top: Project (files), Source Control, Bookmarks, Find, Issues, Tests, Debug, Breakpoints, Reports.
- Editor in the middle. Inspectors on the right. Debug area (variables and console) at the bottom.
- Toolbar: Run and Stop at the left, then the scheme and run destination (which simulator or device), the activity bar that shows build status, and + for the Library at the right.
- Click the blue project icon at the top of the Project navigator to open the project editor: targets on the left, tabs General, Signing & Capabilities, Resource Tags, Info, Build Settings, Build Phases, Build Rules.

## Where things are
- Pick a simulator or device: the run destination in the toolbar.
- Signing team and bundle identifier: project editor > target > Signing & Capabilities.
- Minimum OS version, app icon, display name: target > General.
- Add a permission string or other Info.plist key: target > Info.
- Add a Swift package: File > Add Package Dependencies.
- Capabilities such as iCloud or Push: Signing & Capabilities > + Capability.
- SwiftUI preview: Editor > Canvas.
- Devices and simulators list: Window > Devices and Simulators.
- Archive for TestFlight or the App Store: Product > Archive, then Window > Organizer.
- Environment variables and launch arguments: Product > Scheme > Edit Scheme > Run > Arguments.
- Apple ID accounts: Xcode > Settings > Accounts.
- Download simulator runtimes: Xcode > Settings > Components (Platforms in Xcode 15).
- Derived data location: Xcode > Settings > Locations.

## Gotchas
- Archive is greyed out while a simulator is the run destination. Choose Any iOS Device or a real device.
- "Signing requires a development team" means no team is picked in Signing & Capabilities.
- A stale build that makes no sense: Product > Clean Build Folder, then build again.
- Red file names in the navigator are references to files that moved or were deleted on disk.
- A new file must have its target ticked in the File inspector or it will not be compiled.

## Shortcuts
- Run: Cmd+R. Build: Cmd+B. Test: Cmd+U. Stop: Cmd+Period. Clean: Shift+Cmd+K.
- Open Quickly: Shift+Cmd+O. Find in project: Shift+Cmd+F.
- Show or hide navigator: Cmd+0. Inspectors: Option+Cmd+0. Debug area: Shift+Cmd+Y.
- Jump to definition: Ctrl+Cmd+click. Comment a line: Cmd+Slash. Re-indent: Ctrl+I.
