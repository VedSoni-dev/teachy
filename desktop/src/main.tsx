import React from 'react';
import { createRoot } from 'react-dom/client';
import '@fontsource/inter/400.css';
import '@fontsource/inter/500.css';
import '@fontsource/inter/600.css';
import '@fontsource/inter/700.css';
import './styles/tokens.css';
import './styles/global.css';
import { Notch } from './notch/Notch';
import { Overlay } from './overlay/Overlay';

const rootElement = document.getElementById('root');
if (!rootElement) {
  throw new Error('Root element missing from index.html');
}

// One bundle serves both windows; the main process picks which via ?window=.
const isOverlayWindow = new URLSearchParams(window.location.search).get('window') === 'overlay';

createRoot(rootElement).render(
  <React.StrictMode>{isOverlayWindow ? <Overlay /> : <Notch />}</React.StrictMode>,
);
