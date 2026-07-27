import { resolve } from 'path'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Preview-only config: serves the renderer UI in a plain browser (no Electron
// window), for fast visual verification during development. The real app is
// built by electron.vite.config.ts. window.teachy is absent here — the UI guards
// every call with optional chaining, so it renders fine standalone.
export default defineConfig({
  root: resolve(__dirname, 'src/renderer'),
  plugins: [react()],
  server: { port: 5273 }
})
