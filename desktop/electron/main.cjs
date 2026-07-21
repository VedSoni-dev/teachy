const { app, BrowserWindow, screen, ipcMain, Tray, Menu, nativeImage } = require('electron');
const path = require('node:path');
const { SidecarBridge } = require('./sidecar.cjs');

/** The C# OS bridge — push-to-talk, capture, UI Automation, speech. */
const sidecar = new SidecarBridge();

/**
 * The notch window. Frameless, transparent, always-on-top, and click-through
 * wherever it is transparent — the Electron equivalent of the macOS
 * non-activating NSPanel that hosts the notch.
 *
 * The window stays at the OPEN notch size at all times and the renderer
 * animates the silhouette inside it. That mirrors the Mac, where the NSPanel
 * is fixed at ClickyNotchSizing.windowSize and SwiftUI animates the shape.
 */
let notchWindow = null;
let overlayWindow = null;
let cursorPollTimer = null;
let trayIcon = null;

/**
 * Rasterizes the Teachy mark into a tray bitmap.
 *
 * Electron's nativeImage does NOT decode SVG on Windows — createFromDataURL
 * with an SVG silently yields an empty image and the tray shows nothing. So the
 * triangle is filled directly into a BGRA buffer instead.
 */
function buildTeachyTrayImage() {
  const iconSize = 16;
  const centerX = iconSize / 2;
  const centerY = iconSize / 2;
  const triangleHeight = (iconSize * Math.sqrt(3)) / 2;

  // Same equilateral-rotated-(-35°) geometry as the Mac's Triangle shape.
  const rotationRadians = (-35 * Math.PI) / 180;
  const vertices = [
    [centerX, centerY - triangleHeight / 1.5],
    [centerX - iconSize / 2, centerY + triangleHeight / 3],
    [centerX + iconSize / 2, centerY + triangleHeight / 3],
  ].map(([x, y]) => {
    const deltaX = x - centerX;
    const deltaY = y - centerY;
    return [
      centerX + deltaX * Math.cos(rotationRadians) - deltaY * Math.sin(rotationRadians),
      centerY + deltaX * Math.sin(rotationRadians) + deltaY * Math.cos(rotationRadians),
    ];
  });

  function signedArea(a, b, c) {
    return (b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1]);
  }

  const pixelBuffer = Buffer.alloc(iconSize * iconSize * 4);
  for (let pixelY = 0; pixelY < iconSize; pixelY++) {
    for (let pixelX = 0; pixelX < iconSize; pixelX++) {
      const samplePoint = [pixelX + 0.5, pixelY + 0.5];
      const d1 = signedArea(vertices[0], vertices[1], samplePoint);
      const d2 = signedArea(vertices[1], vertices[2], samplePoint);
      const d3 = signedArea(vertices[2], vertices[0], samplePoint);
      const hasNegative = d1 < 0 || d2 < 0 || d3 < 0;
      const hasPositive = d1 > 0 || d2 > 0 || d3 > 0;
      const isInsideTriangle = !(hasNegative && hasPositive);

      if (isInsideTriangle) {
        const offset = (pixelY * iconSize + pixelX) * 4;
        pixelBuffer[offset + 0] = 0xff; // B — Teachy blue #3380FF
        pixelBuffer[offset + 1] = 0x80; // G
        pixelBuffer[offset + 2] = 0x33; // R
        pixelBuffer[offset + 3] = 0xff; // A
      }
    }
  }

  return nativeImage.createFromBitmap(pixelBuffer, { width: iconSize, height: iconSize });
}

/**
 * Tray presence — the Windows stand-in for the macOS menu-bar status item.
 * The icon is drawn at runtime as the Teachy triangle so there is no asset
 * pipeline to keep in sync.
 */
function createTrayIcon() {
  trayIcon = new Tray(buildTeachyTrayImage());
  trayIcon.setToolTip('Teachy — hold Ctrl+Alt to talk');

  trayIcon.setContextMenu(
    Menu.buildFromTemplate([
      { label: 'Open Teachy', click: () => notchWindow?.webContents.send('notch:open') },
      { type: 'separator' },
      { label: 'Quit Teachy', click: () => app.quit() },
    ]),
  );

  trayIcon.on('click', () => notchWindow?.webContents.send('notch:open'));
}

const NOTCH_WINDOW_WIDTH = 640;
const NOTCH_WINDOW_HEIGHT = 400; // open height plus room for the shadow

/**
 * Full-screen, transparent, permanently click-through overlay that hosts the
 * companion cursor, its response bubble, and the pointing animation — the
 * Electron equivalent of the macOS OverlayWindow NSPanel.
 */
function createOverlayWindow() {
  const primaryDisplay = screen.getPrimaryDisplay();
  const { x, y, width, height } = primaryDisplay.bounds;

  overlayWindow = new BrowserWindow({
    x,
    y,
    width,
    height,
    frame: false,
    transparent: true,
    resizable: false,
    movable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    focusable: false,
    hasShadow: false,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  // The overlay must never intercept a click — it is pure decoration.
  overlayWindow.setIgnoreMouseEvents(true, { forward: true });
  overlayWindow.setAlwaysOnTop(true, 'screen-saver');

  const developmentServerUrl = process.env.VITE_DEV_SERVER_URL;
  if (developmentServerUrl) {
    overlayWindow.loadURL(`${developmentServerUrl}?window=overlay`);
  } else {
    overlayWindow.loadFile(path.join(__dirname, '..', 'dist', 'index.html'), {
      query: { window: 'overlay' },
    });
  }

  overlayWindow.once('ready-to-show', () => {
    overlayWindow.showInactive();
    startCursorPolling();
  });
}

/**
 * Pushes the global cursor position to the overlay so the companion can trail
 * it. Only the main process can read the cursor outside its own windows.
 */
function startCursorPolling() {
  if (cursorPollTimer) {
    return;
  }
  cursorPollTimer = setInterval(() => {
    if (!overlayWindow || overlayWindow.isDestroyed()) {
      return;
    }
    const cursorPoint = screen.getCursorScreenPoint();
    overlayWindow.webContents.send('overlay:cursor', cursorPoint);
  }, 16); // ~60fps
}

function createNotchWindow() {
  const primaryDisplay = screen.getPrimaryDisplay();
  const { x: workAreaX, y: workAreaY, width: workAreaWidth } = primaryDisplay.workArea;

  notchWindow = new BrowserWindow({
    width: NOTCH_WINDOW_WIDTH,
    height: NOTCH_WINDOW_HEIGHT,
    x: Math.round(workAreaX + (workAreaWidth - NOTCH_WINDOW_WIDTH) / 2),
    y: workAreaY,
    frame: false,
    transparent: true,
    resizable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    hasShadow: false,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  notchWindow.setAlwaysOnTop(true, 'screen-saver');

  const developmentServerUrl = process.env.VITE_DEV_SERVER_URL;
  if (developmentServerUrl) {
    notchWindow.loadURL(developmentServerUrl);
  } else {
    notchWindow.loadFile(path.join(__dirname, '..', 'dist', 'index.html'));
  }

  notchWindow.once('ready-to-show', () => {
    notchWindow.showInactive(); // appear without stealing focus
  });
}

/**
 * The renderer reports whether the pointer is over real notch chrome. When it
 * is not, the window goes click-through so the desktop underneath stays usable.
 */
ipcMain.on('notch:set-interactive', (_event, isInteractive) => {
  if (notchWindow) {
    notchWindow.setIgnoreMouseEvents(!isInteractive, { forward: true });
  }
});

/**
 * Renderer -> sidecar passthrough. The renderer names a command; the main
 * process forwards it. Errors come back as rejected promises the UI can show.
 */
ipcMain.handle('sidecar:send', async (_event, command, args) => {
  return sidecar.send(command, args ?? {});
});

/**
 * Manual notch dragging. `-webkit-app-region: drag` would be simpler but it
 * swallows mouse events on the dragged element, which breaks hover-to-open —
 * so the renderer tracks the pointer and reports deltas instead.
 */
ipcMain.on('notch:move-by', (_event, delta) => {
  if (!notchWindow || notchWindow.isDestroyed()) {
    return;
  }
  const [currentX, currentY] = notchWindow.getPosition();
  notchWindow.setPosition(Math.round(currentX + delta.dx), Math.round(currentY + delta.dy));
});

ipcMain.handle('notch:get-position', () => {
  if (!notchWindow || notchWindow.isDestroyed()) {
    return { x: 0, y: 0 };
  }
  const [x, y] = notchWindow.getPosition();
  return { x, y };
});

/** Applies a placement preset by moving the window to that screen edge. */
ipcMain.on('notch:apply-placement', (_event, placement) => {
  if (!notchWindow || notchWindow.isDestroyed()) {
    return;
  }
  const { workArea } = screen.getPrimaryDisplay();
  const [windowWidth] = notchWindow.getSize();

  let targetX = workArea.x + Math.round((workArea.width - windowWidth) / 2);
  if (placement === 'TopLeft') {
    targetX = workArea.x;
  } else if (placement === 'TopRight') {
    targetX = workArea.x + workArea.width - windowWidth;
  }
  notchWindow.setPosition(targetX, workArea.y);
});

/** Forwards a sidecar event to the renderer so the UI can react to it. */
function forwardSidecarEventToRenderer(eventName) {
  sidecar.on(eventName, (payload) => {
    notchWindow?.webContents.send(`sidecar:${eventName}`, payload);
  });
}

/**
 * Overlay control, driven by the notch window's companion loop. Screen points
 * arrive in PHYSICAL pixels (that is what the C# capture and UI Automation
 * report), so convert to the DIP space Electron windows live in.
 */
ipcMain.on('overlay:command', (_event, command) => {
  if (!overlayWindow || overlayWindow.isDestroyed()) {
    return;
  }

  if (command.type === 'point-at' && command.point) {
    const { scaleFactor } = screen.getPrimaryDisplay();
    overlayWindow.webContents.send('overlay:point-at', {
      x: command.point.x / scaleFactor,
      y: command.point.y / scaleFactor,
      label: command.label ?? null,
    });
    return;
  }

  overlayWindow.webContents.send('overlay:state', command);
});

app.whenReady().then(() => {
  sidecar.start();
  for (const eventName of ['ready', 'ptt-pressed', 'ptt-released', 'ptt-error', 'transcript']) {
    forwardSidecarEventToRenderer(eventName);
  }
  createNotchWindow();
  createOverlayWindow();
  createTrayIcon();
});

app.on('before-quit', () => {
  if (cursorPollTimer) {
    clearInterval(cursorPollTimer);
    cursorPollTimer = null;
  }
  sidecar.stop();
});

app.on('window-all-closed', () => {
  app.quit();
});
