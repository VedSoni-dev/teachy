import { app, BrowserWindow, Tray, nativeImage, screen, globalShortcut, ipcMain } from 'electron'
import { join } from 'path'
import { existsSync } from 'fs'
import { panelMaterialOptions, configurePanelBehavior } from './platform'

// The notch panel size when open. The physical-notch-width collapsed state is a
// later renderer concern; the window itself stays this fixed size (same approach
// as the SwiftUI ClickyNotchSizing — animate the shape, not the frame).
const PANEL_WIDTH = 460
const PANEL_HEIGHT = 640

let panelWindow: BrowserWindow | null = null
let tray: Tray | null = null

function createPanelWindow(): BrowserWindow {
  const primaryDisplay = screen.getPrimaryDisplay()
  const { x: workAreaX, width: workAreaWidth } = primaryDisplay.workArea

  const window = new BrowserWindow({
    width: PANEL_WIDTH,
    height: PANEL_HEIGHT,
    // Top-center, where the notch lives.
    x: Math.round(workAreaX + (workAreaWidth - PANEL_WIDTH) / 2),
    y: 0,
    frame: false,
    transparent: true,
    resizable: false,
    skipTaskbar: true,
    show: false,
    fullscreenable: false,
    hasShadow: false,
    ...panelMaterialOptions(),
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      sandbox: false
    }
  })

  configurePanelBehavior(window)

  // electron-vite provides ELECTRON_RENDERER_URL in dev (Vite server); in a packaged
  // build we load the built HTML from disk.
  const rendererDevURL = process.env['ELECTRON_RENDERER_URL']
  if (rendererDevURL) {
    window.loadURL(rendererDevURL)
  } else {
    window.loadFile(join(__dirname, '../renderer/index.html'))
  }

  window.on('closed', () => {
    panelWindow = null
  })

  return window
}

function togglePanel(): void {
  if (!panelWindow) {
    panelWindow = createPanelWindow()
    panelWindow.once('ready-to-show', () => panelWindow?.show())
    return
  }
  if (panelWindow.isVisible()) {
    panelWindow.hide()
  } else {
    panelWindow.show()
  }
}

function createTray(): void {
  // Load a template tray icon if present; otherwise fall back to a titled empty
  // tray so the app is still runnable before the real icon asset is added.
  const trayIconPath = join(__dirname, '../../resources/trayTemplate.png')
  const trayIcon = existsSync(trayIconPath)
    ? nativeImage.createFromPath(trayIconPath)
    : nativeImage.createEmpty()
  if (process.platform === 'darwin') {
    trayIcon.setTemplateImage(true)
  }

  tray = new Tray(trayIcon)
  if (trayIcon.isEmpty()) {
    tray.setTitle('Teachy')
  }
  tray.setToolTip('Teachy — click to open')
  tray.on('click', () => togglePanel())
  tray.on('right-click', () => togglePanel())
}

// Push-to-talk: the same ctrl+alt chord the Mac app used. Electron's globalShortcut
// only reports key-DOWN, so v1 registers a toggle; a listen-only key-up path
// (matching the CGEvent tap) is a Week-2 refinement.
function registerPushToTalk(): void {
  const registered = globalShortcut.register('Control+Alt+Space', () => {
    panelWindow?.webContents.send('push-to-talk:toggle')
  })
  if (!registered) {
    console.warn('[teachy] push-to-talk shortcut could not be registered')
  }
}

app.whenReady().then(() => {
  // Menu-bar / tray app — no dock icon, matching the LSUIElement Mac behavior.
  if (process.platform === 'darwin') {
    app.dock?.hide()
  }

  createTray()
  registerPushToTalk()

  // Open the panel once at launch so there's something to see during bring-up.
  panelWindow = createPanelWindow()
  panelWindow.once('ready-to-show', () => panelWindow?.show())

  ipcMain.on('panel:toggle', () => togglePanel())
  ipcMain.on('panel:collapse', () => panelWindow?.hide())

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      panelWindow = createPanelWindow()
      panelWindow.once('ready-to-show', () => panelWindow?.show())
    }
  })
})

// Tray app: stay alive when all windows are closed (the tray is the home base).
app.on('window-all-closed', () => {
  // Intentionally do not quit — Teachy lives in the tray/menu bar.
})

app.on('will-quit', () => {
  globalShortcut.unregisterAll()
})
