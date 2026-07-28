import { useEffect, useState } from 'react'
import { ProgressTab } from './tabs/ProgressTab'
import { PlaceholderTab } from './tabs/PlaceholderTab'

type TabId = 'learn' | 'progress' | 'portfolio' | 'skills' | 'settings'

interface TabDef {
  id: TabId
  label: string
  accentVar: string
  icon: JSX.Element
}

// Mirrors the SwiftUI header: Learn · Progress · Portfolio · Skills · Settings,
// each with the same accent it had natively (see ClickyNotchRootView.tabAccent).
const TABS: TabDef[] = [
  { id: 'learn', label: 'Learn', accentVar: 'var(--color-learn-accent)', icon: iconBook() },
  { id: 'progress', label: 'Progress', accentVar: 'var(--color-success)', icon: iconTrend() },
  { id: 'portfolio', label: 'Portfolio', accentVar: 'var(--color-portfolio-accent)', icon: iconFolder() },
  { id: 'skills', label: 'Skills', accentVar: 'var(--color-skills-accent)', icon: iconChart() },
  { id: 'settings', label: 'Settings', accentVar: 'var(--color-text-secondary)', icon: iconGear() }
]

export function App(): JSX.Element {
  const [activeTab, setActiveTab] = useState<TabId>('progress')

  // Prove the push-to-talk bridge is wired end-to-end (main → preload → renderer).
  useEffect(() => {
    const unsubscribe = window.teachy?.onPushToTalkToggle(() => {
      console.log('[teachy] push-to-talk toggled')
    })
    return unsubscribe
  }, [])

  return (
    <div className="app-shell">
      <div className="tabbar">
        {TABS.map((tab) => (
          <button
            key={tab.id}
            className="tab"
            data-active={activeTab === tab.id}
            style={{ ['--tab-accent' as string]: tab.accentVar }}
            title={tab.label}
            onClick={() => setActiveTab(tab.id)}
          >
            {tab.icon}
          </button>
        ))}
        <span className="tab-spacer" />
        <button className="icon-btn" title="Collapse" onClick={() => window.teachy?.collapse()}>
          {iconChevronUp()}
        </button>
      </div>

      <div className="content">
        {activeTab === 'progress' && <ProgressTab />}
        {activeTab === 'learn' && <PlaceholderTab title="Learn" note="Courses + in-lesson tutor — porting next (Week 2)." />}
        {activeTab === 'portfolio' && <PlaceholderTab title="Portfolio" note="Shipped artifacts with provenance — Week 3." />}
        {activeTab === 'skills' && <PlaceholderTab title="Skills" note="Proficiency + evidence — Week 3." />}
        {activeTab === 'settings' && <PlaceholderTab title="Settings" note="Keys, updates, permissions — Week 4." />}
      </div>
    </div>
  )
}

// ── Inline icons (no icon-font dependency; CSP-safe) ───────────

function iconBook(): JSX.Element {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20" />
      <path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z" />
    </svg>
  )
}
function iconTrend(): JSX.Element {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M3 17l6-6 4 4 8-8" />
      <path d="M17 7h4v4" />
    </svg>
  )
}
function iconFolder(): JSX.Element {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor">
      <path d="M10 4H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-8l-2-2z" />
    </svg>
  )
}
function iconChart(): JSX.Element {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M3 3v18h18" />
      <path d="M7 15v-4M12 15V9M17 15v-7" />
    </svg>
  )
}
function iconGear(): JSX.Element {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
    </svg>
  )
}
function iconChevronUp(): JSX.Element {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M18 15l-6-6-6 6" />
    </svg>
  )
}
