import type { TeachyApi } from './index'

declare global {
  interface Window {
    teachy: TeachyApi
  }
}
