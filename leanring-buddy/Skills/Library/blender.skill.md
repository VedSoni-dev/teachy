---
name: Blender
bundleIds: [org.blenderfoundation.blender]
sites: []
summary: 3D modelling, animation and rendering. Written for Blender 3.x and 4.x with the default keymap.
---
## Layout
- Topbar: the menus (File, Edit, Render, Window, Help), then workspace tabs (Layout, Modeling, Sculpting, UV Editing, Shading, Animation, Rendering and more).
- In the default Layout workspace: the 3D Viewport fills the middle, the Outliner is at the top right, the Properties editor is under it, and the Timeline runs along the bottom.
- The 3D Viewport's header has the mode menu (Object Mode, Edit Mode) at the left and, at the right, the shading buttons: wireframe, solid, material preview, rendered.
- Inside the viewport: the Toolbar on the left (T) and the Sidebar on the right (N) with Item, Tool and View tabs.
- The Properties editor has a column of icon tabs: Render, Output, Scene, World, Object, Modifiers (wrench), Physics, Data, Material.

## Where things are
- Add an object: Add menu in the viewport header (Shift+A).
- Edit a mesh's points, edges and faces: press Tab for Edit Mode, then 1, 2 or 3.
- Add a modifier (Subdivision, Mirror, Bevel): Properties > Modifiers > Add Modifier.
- Give an object a material: Properties > Material > New. Edit its nodes in the Shading workspace.
- Smooth the look of a surface: right-click the object > Shade Smooth.
- Choose the render engine (EEVEE or Cycles): Properties > Render.
- Resolution, frame range, file format and output folder: Properties > Output.
- Import or export OBJ, FBX, glTF, STL: File > Import, File > Export.
- Use the graphics card for Cycles: Edit > Preferences > System.
- No number pad or no middle mouse button: Edit > Preferences > Input > Emulate Numpad, Emulate 3 Button Mouse.

## Gotchas
- Keys act on the editor under the mouse pointer. If a shortcut does nothing, move the pointer over the 3D Viewport.
- A render shows only what the camera sees. No camera means an empty picture.
- After scaling in Object Mode, modifiers and bevels can look wrong until the scale is applied: Ctrl+A > Scale.
- H hides the selection and is easy to press by accident. Option+H brings everything back.
- Where a guide says Alt, use Option on a Mac. Ctrl stays Ctrl; save and undo use Cmd.

## Shortcuts
- Move, rotate, scale: G, R, S. Then X, Y or Z to lock to an axis.
- Select all: A. Delete: X. Duplicate: Shift+D. Join objects: Ctrl+J.
- In Edit Mode: extrude E, inset I, loop cut Ctrl+R, bevel Ctrl+B.
- Views: Numpad 1 front, 3 side, 7 top, 0 camera, Period frames the selection.
- Shading pie menu: Z. Render: F12. Insert keyframe: I. Search commands: F3.
