# HeyClicky: full changelog inventory + feature deep dives (for parity planning)

Compiled Sat Nov 14, 2026. Read-only: nothing was signed up for, downloaded or bought.

## 0. Sources and scope

**What exists on heyclicky.com** (sitemap, checked Nov 14, 2026): `/`, `/for-mac`, `/for-windows`, `/changelog`, `/trust`, `/about`, `/careers`, `/privacy-policy`, `/terms`, `/referral-terms`. All of them were read in full.
- **No docs, help center, blog or standalone feature pages exist.** `/docs`, `/help`, `/blog`, `/features`, `/faq`, `/support`, `/updates` and `/releases` all redirect (307) to the homepage. `/pricing` goes to `/#pr`. Feature content lives in homepage sections, the FAQ and the changelog. Support is `mailto:hi@heyclicky.com`.
- **Changelog:** a single page with 44 entries, from "1.0, Apr 6, 2026" to "Mac 1.1.3 / Windows 1.1.5, Nov 6, 2026". It has All/Mac/Windows filters. "Mac only" and "Windows only" tags attach to the item *before* them (checked in the DOM).

**Other sources:**
- **Official YouTube:** real-time graphics (YlW_-hdw7hs), draw on screen (nT16HPxYX-s), screen-aware dictation (km54y7Xd_7g), spatial context (bLnkvjw7j84) and "powerpuff clickies" (Bo5v6QxsLnw, no transcript). Also the **85-minute v1.1.1 launch livestream** "we shipped something new" (xOkfw1_ePhg, Oct 23). I read their transcripts and sampled their frames.
- **X:** all 22 tweets the changelog links to, plus searches of @heyclicky and @FarzaTV posts and replies about drawing, 3D, dictation and the renderer.
- **GitHub:** `farzaa/clicky-releases` (release list and the Sparkle `appcast.xml`). This is metadata only; no DMG was downloaded.
- **Chrome Web Store:** the HeyClicky extension listing.
- **Earlier work:** facts from my Nov 11 video digests and Nov 14 research are labeled **[prior research]**.

**Labels used:** **[inference]** marks my engineering reading of the evidence, not something the company said. **[not found]** means I looked and found nothing.

---

## 1. Version and platform timeline (quick view)

| Date (2026) | Mac | Windows | Headline |
|---|---|---|---|
| Nov 6 | 1.1.3 | 1.1.5 | Long jobs that finish, answers your way |
| Oct 30 | 1.1.2 | 1.1.4 | HeyClicky window, 130+ languages, Google speech |
| Oct 24 | – | 1.1.3 | Self-update check build |
| Oct 24 | – | 1.1.2 | Windows self-updates, new installer |
| Oct 23 | 1.1.1 | 1.1.1 | 2D/3D drawing, One brain, Drive, Chrome extension, Windows launch |
| Oct 2 | 1.0.53 | – | Several accounts per app |
| Sep 24 | 1.0.52 | – | Smaller notch, Invite & earn, GPT-6 |
| Sep 18 | 1.0.51 | – | Resizable Home |
| Sep 14 | 1.0.50 | – | Keeping Clickys going |
| Sep 12 | 1.0.49 | – | Introducing Clickys |
| Aug 25 | 1.0.48 | – | Walkthroughs go the distance (15 steps) |
| Aug 13 | 1.0.47 | – | Whole-document understanding |
| Aug 1 | 1.0.46 | – | More reliable voice, proactive agents removed |
| Jul 31 | 1.0.45 | – | Faster realtime voice (router) |
| Jul 23 | 1.0.44 | – | Teams |
| Jul 22 | 1.0.43 | – | Agent retries, routing |
| Jul 20 | 1.0.42 | – | Reliability |
| Jul 20 | 1.0.41 | – | New logo, UPI |
| Jul 17 | 1.0.40 | – | Hands-on tutorial, Excalidraw-style drawings |
| Jul 15 | 1.0.39 | – | Dictation polish, privacy |
| Jul 14 | 1.0.38 | – | Dictation tuning (2 models) |
| Jul 14 | 1.0.37 | – | Dictation and screen-aware dictation |
| Jul 13 | 1.0.34-36 | – | Road to dictation |
| Jul 6 | 1.0.33 | – | Spatial context, skills, proactive agents, memory |
| Jul 4 | 1.0.32 | – | Account deletion |
| Jul 1 | 1.0.31 | – | Claude Fable 5 default |
| Jun 29 | 1.0.30 | – | Quick fix |
| Jun 28 | 1.0.29 | – | Yearly billing |
| Jun 23 | 1.0.28 | – | 89 app skills |
| Jun 20 | 1.0.27 | – | Notch only |
| Jun 19 | 1.0.26 | – | Draw on screen, realtime computer use |
| Jun 18 | 1.0.25 | – | Screen highlight (draw for HeyClicky) |
| Jun 14 | 1.0.24 | – | No more frozen keyboards |
| Jun 8 | 1.0.23 | – | Drag files into notch |
| Jun 1 | 1.0.22 | – | Interrupt anytime |
| May 30 | 1.0.21 | – | Clicky renamed HeyClicky, realtime voice |
| May 19 | 1.0.20 | – | Sleep fix |
| May 16 | 1.0.19 | – | Small tunings |
| May 14 | 1.0.16-18 | – | Notch follow-ups |
| May 13 | 1.0.15 | – | A home in the notch, connectors |
| May 4 | 1.0.12 | – | HeyClicky can click |
| Apr 30 | 1.0.11 | – | Google Workspace, custom shortcuts |
| Apr 27 | 1.0.10 | – | HeyClicky agents |
| Apr 6 | 1.0 | – | Introducing HeyClicky |

**Builds missing from the changelog** (from GitHub `clicky-releases`):
- v1.00 (Apr 17), 1.0.1 (Apr 20), 1.0.3 and 1.0.4 (Apr 21), 1.0.5 and 1.0.6 (Apr 23), 1.0.7 (Apr 25), 1.0.8 (Apr 26), 1.0.9 (Apr 28), 1.0.13 and 1.0.14 (May 5).
- 1.0.54 (Oct 23) was "Superseded by v1.1.1 (same build, renamed)".
- 1.0.47-internal (Aug 24) was an internal build that was not published to the Sparkle appcast.
- The DMG was renamed from `Clicky.dmg` to `HeyClicky.dmg` at 1.0.23.

**Sparkle details:** `minimumSystemVersion` is 14.2. The Sparkle build number was 71 at 1.1.3. DMG size went from about 425 MB (1.1.1) to about 200 MB (1.1.2).

**Release-note extra (1.0.18):** "Notch no longer expands the instant the cursor brushes it. Added a short hover dwell…"

---

## 2. Changelog: entry-by-entry inventory (newest first, as on the site)

Reporter and requester names are left out. Quotes are verbatim.

### Nov 6, 2026: Mac 1.1.3 / Windows 1.1.5. "Long jobs that finish, answers your way, and fixes for what bugged you most"
Intro: long jobs keep going until done, HeyClicky remembers how you like to be talked to, saying no to a job sticks, and agents can upload files on websites. Windows gets an install/update window and fixes to the notch, typing and chimes. Has a video (`heyclicky-1.1.3-preview.mp4`).

**What's new**
- **Answers the way you like them** (no update needed): "Ask for shorter answers, a yes or no first, or simpler words, and HeyClicky remembers it and keeps doing it, today and next week." It "checks your screen before giving the next step, so it stops repeating steps you've already done."
- **Jobs can upload files:** agents can attach files on websites in Chrome (e.g. a photo on a form). "Before, Chrome refused every upload from the store extension." It asks once before a file goes to a site, or you can turn on *Settings > Agents > Always approve file uploads*. The Chrome extension now self-updates "as soon as no agent is using it."
- **Make a job repeat from its chat** (Mac only): "do this every Monday at 9" in the job's own chat makes that job repeat. "Asking for a schedule only sets the schedule; it runs right away only if you ask."
- **Close the chat, keep the answer:** clicking outside the notch while it's answering a typed question folds the chat away, and "the rest of the answer keeps coming as captions at the bottom of your screen."
- **Stop an agent from its chat:** a Stop button in the HeyClicky window while it's working. You can still type to steer it.

**Windows only**
- **Install/update window:** the installer shows progress in a small HeyClicky window. Install & Relaunch shows "updating heyclicky" with a percentage, then "opening heyclicky".
- **Onboarding like the Mac:** "The video card glides beside your cursor, also when it switches sides." Glows on the welcome, color and "give me a home" screens follow their shapes. The "I live in your notch now" card sits closer to the top.
- **Smaller notch:** with *Settings > Cursor > Hide floating cursor* on, the cursor says "okay see you <3" and fades out instead of parking in the notch as a black strip. The Listening and Thinking strips are narrower.
- **Typing works everywhere:** in the box under a full agent reply and in the document view.
- Settings switches no longer look switched on when hovered. Alt+Tab only shows HeyClicky while one of its windows is open. The logo shows correctly in Alt+Tab and on the taskbar. Chimes are clean on Bluetooth and built-in speakers.

**Agents**
- **Long jobs finish:** big jobs (e.g. "tagging two weeks of email") "now pick up where they left off and keep going until it's done, with notes on your goal and your rules that they read again as they go."
- **Jobs remember overnight:** "A job that sat quiet for 6 hours used to forget its whole conversation." Jobs now keep their history however long they wait.
- **Passing work to a job:** the job gets "the details you two agreed on, not only your last few words."
- **Chrome holds on through slow pages** (e.g. Google Tag Manager): jobs keep access and re-check the page.
- **No means no, until you say go:** tapping Not now on a computer-use request means it "won't ask again for 30 minutes."
- **Fewer surprise follow-ups:** when a job reports back, HeyClicky asks what's next instead of auto-sending more work (which would use another agent message). Jobs stop asking permission for tests and fixes you already asked for.
- **Follow-ups bring the screen:** a message to a working job attaches a fresh screenshot.
- **How many messages do I have left?:** it now gives a real answer, talk messages included.

**Voice**
- **Fewer "I didn't catch that":** "no longer guesses which language you'll speak, and it ignores stray bits of noise that came out in a language you never use."
- **Honest about safety filters:** if the AI provider's safety filter blocks a request (e.g. hands-on security practice), it says so plainly and offers to explain the ideas.
- **Recording apps aren't calls:** GarageBand, Audacity and OBS no longer count as a call, so job-done notices still play.

**Fixed**
- Chrome extension setup on older versions could stall at "please turn on Developer mode yourself" (no update needed).
- **"A 3D figure in a drawing's window stopped turning after you clicked the window."** (Mac)
- Duplicate long typed messages. Duplicate message right after a reply (Mac).
- "Keep going" on a paused job works again, and failed or paused jobs say why.
- Files and screenshots dropped on the HeyClicky window land in the open chat (Mac).
- A routine's task lost its first words ("Each day at 9 a.m." became "A.m.").
- Checklist font (Mac).
- It says "the escape key" instead of "esc" when it starts driving. *Settings > Dictation* shows the Dictionary above Language.

### Oct 30, 2026: Mac 1.1.2 / Windows 1.1.4. "Go deeper with your agents, support for 130+ languages, and lots of bug fixes"
Has a video (on X) and a screenshot of the new HeyClicky window.

**What's new**
- **The HeyClicky window:** chat, full replies, documents and Settings can open into "a resizable window that grows out of the notch." It has a sidebar with your chat and every agent's chat, documents open beside the chat, and it follows the system light/dark look.
- **Voices in 130+ languages:** "just talk to it in yours." *Settings > Voice > Voices* has "30 new voices… They sound like someone from there, not an English speaker reading a script. Tap a voice to hear it first."
- **Agents get names:** short names like "Inbox Hunter" on cards and in the sidebar. **Press ← and → to flip through the cards under the notch.**
- **Smarter ears in every language:** "Voice and dictation now hear you through Google's newest speech model. It picks up your language on its own and follows you when you switch mid-sentence, like English with Hindi or Urdu."
- **Dictation in 83 languages:** the picker in *Settings > Dictation* has 83 languages, and "picking Urdu finally writes Urdu."
- **Chrome in one click:** the extension now comes from the Chrome Web Store ("just Add to Chrome, no Developer mode") and works in Edge, Brave, Arc and Vivaldi. It can swap out the old preview copy for you.
- **Updates install themselves:** once an update has downloaded and the app has been idle for 5 minutes, it restarts into the new version.

**Agents**
- **Long jobs keep going:** a job running past 20 minutes keeps working instead of pausing, and "still costs one agent message as long as it stays within its budget." If it needs your OK it shows Keep going.
- **Agents that remember:** jobs remember earlier work, read public web pages without asking for Chrome, and pick up your answer to a Chrome question mid-task.
- **Your chat updates as you talk:** live transcript in the chat, which no longer jumps when new messages arrive.

**Fixed**
- Mission Control showed blank or black desktops (Mac).
- A drive could end "as soon as your pointer left the Let Clicky drive button."
- A message to an already-working agent was charged as a new agent message. It now counts as the same job, and a job that never started is refunded.
- Jobs ride out brief database errors.
- Jobs failed on networks blocking some addresses or after an app was disconnected. They now carry on without that app.
- A flag emoji on a page could break a job for good.
- A follow-up right after a job finished said it was still working. Large images could fail a job.
- Voice stuck on "Speaking" with some audio devices. A chime crack on the talk keys.

### Oct 24, 2026: Windows 1.1.3. "A quick check of the new updates"
A behind-the-scenes check that self-updating works. Updating from 1.1.2 to 1.1.3 happens on its own.

### Oct 24, 2026: Windows 1.1.2. "HeyClicky for Windows now updates itself"
- **Updates install themselves:** it checks in the background and installs on quit, or right away from *Settings > General > Install & Relaunch*. Users on 1.1.1 must download once more by hand.
- **New installer for every PC:** small, signed and the same file every release, "so Windows should stop warning about it." When it can't run on a PC, it says why and shows an Email us button.
- **Fixes:**
  - It didn't start on Windows set to a decimal-comma locale (French, German, Spanish).
  - **"3D drawings work on PCs whose graphics card can't draw them the usual way."**
  - Clicking the chat box after a drive gave the keyboard back to the app behind it.
  - A drive could end the moment it began. Typing during a drive now stops as soon as you take the screen back.
  - **"Dragging a drawing's cards, turning a 3D figure after moving its window,"** plus early crashes.

### Oct 23, 2026: Mac 1.1.1 / Windows 1.1.1. "HeyClicky can draw in 3D, 2D and much more"
"Our biggest update yet… explains things by drawing right on your screen, in 2D and 3D, with one brain that sees, talks, remembers and gets things done. It can drive your Mac for you, work in your Chrome, and everything lives in one simple notch." Has a video (YouTube full livestream) and an animated image (`draw-3d.webp`).

**What's new**
- **HeyClicky for Windows** (Windows only): first version, for Windows 10 and 11. It can't update itself, so you need 1.1.2+ once by hand.
- **HeyClicky draws, in 2D and 3D:** "Ask about anything and HeyClicky circles, points and sketches right on your screen while it talks. Explanations land on little cards with real photos, and when the answer is a real thing, like an engine, a molecule or a building, HeyClicky builds a 3D model you can drag around and click on to ask about any part."
- **One brain:** "one brain that hears you, sees your screen, answers, and hands bigger work to agents. It starts answering a couple of seconds after you let go, remembers what was on your screen earlier in the conversation, and remembers your conversations from day to day."
- **HeyClicky drive:** "When something needs doing in an app on your computer, HeyClicky asks, and with your yes it moves the mouse and types while you watch. Move your mouse, talk or press Escape and you're back in control."
- **The HeyClicky Chrome extension:** agents work in your own Chrome, on signed-in sites, "in their own tab group beside your tabs." It asks once the first time a task needs it, and can install the extension for you.
- **A new notch:** Home, the whole chat and Settings live in the notch. "Agents you've handed work to hang from the notch as little windows that show their plan while they work and their result when they're done."
- **Captions:** *Settings > Voice > "Captions while HeyClicky talks"* shows words at the bottom of the screen. "Typed questions that get a drawing show their answer as captions too."

**Also new**
- **Just hand it off:** bigger asks run as a job with its own window on the notch. Follow-ups continue the job. Old Clickys are kept.
- **Routines, just by asking:** "every Tuesday and Thursday at 5, check my inbox for invoices." Change, pause or delete them by voice or in *Settings > Routines*.
- **A shorter tour:** "Onboarding skips the style step, shows HeyClicky driving and dictation, and ends by drawing where you're headed."
- **Suggestions are taking a break** (paused while they rethink them).

**Fixed (Mac only)**
- Pro shows right after you pay (it polls until the plan updates). Failed renewals open the billing page.
- Routines stop crying wolf (no false offline or "connect apps" prompts, and the upgrade card no longer keeps reopening).
- Window screenshots on two displays no longer come out blank.
- Settings tidy-ups: long shortcuts in *Settings > Shortcuts*, and a per-account Reconnect button in *Settings > Integrations*.

### Oct 2, 2026: 1.0.53. "Several accounts per app, and a pile of fixes"
**Connectors**
- **Several accounts of one app:** *Settings > Integrations* lists each account with its sign-in address and an "Add another account" link. You can label accounts (Work or Personal) and disconnect each separately. "add this to my work calendar" picks the right one. Unspecified reads hit every account and attribute each result. Actions happen in the account where the item lives. It asks once which account should send something new.
- **Apps ready before a Clicky starts:** after wake, it waits for connected apps to load.
- **Calendar invites stay on the right calendar:** events on a secondary calendar no longer invite your main account.
- **Reddit and Monday paused** ("almost never worked").

**Clickys & routines**
- **Follow up by holding your voice keys:** point at a finished agent's card (top right) and hold the voice shortcut. The card shows a Listening waveform. A short tap or Escape drops it.
- Cards show only the latest reply's files.
- **Stopped within 10 seconds = refunded** agent message.
- **Leaner agents:** "Every step an agent takes now carries less than half the setup it used to, and long conversations reuse what was already read instead of starting over."
- **Clickys ask instead of guessing:** they do what they can, then ask "one short set of questions." Voice only starts an agent when you clearly ask for work, otherwise it offers one. It holds off when you say "wait".
- Always approve is now the main button on the extra-agent-messages card, with Approve once beside it.
- Routines at your limit wait quietly until the allowance resets.
- No more twin Clickys (e.g. one named "Tell Scout").
- **One browser window per task.**

**Computer use**
- **Your Allow sticks** across pauses for more agent messages and handoffs to helper agents.
- **Fixes itself:** "It now notices when its helper has stopped working, restarts it, and tries again on its own."
- **Answering is free:** Allow and Not now no longer cost an agent message. Ask cards are "a calm blue".

**Home & voice**
- Smoother notch peek and Home opens. Each Clicky's file piles are preloaded.
- Updates no longer close Home. An Update app button appears in the Home header and the notch peek.
- **Remembers the page you just left:** "what did billing say?" after navigating away looks back at the prior page.
- **Walkthroughs keep their place:** no more loops or "say continue" right after a correct click. "Clicky now keeps a running log of what you've done, and waits for slow pages to finish loading before it looks again."
- **Setups that start where you are:** it asks what you already have and never repeats a step that just failed.
- Making a Clicky works from text mode or voice even if the New Clicky page was left halfway. With no Clickys, the notch offers Create Clicky.
- Report a bug no longer opens email behind Home.

**Suggestions:** no repeats across days or within a batch. It remembers cards that were seen, approved or declined.

**Onboarding & settings**
- First routine asks first ("Yes, keep it going").
- The interview no longer freezes on Back.
- "Dock cursor" was renamed "Hide floating cursor" (*Settings > Cursor*).
- The login item stays off if you turned it off.

**Fixed**
- Upgrade page crash on macOS 26.
- A second copy of the app refuses to start (answers were heard 2-3 times).
- No beachball after sleep, display or Bluetooth changes (audio waits moved to the background).
- Voice reconnects after a dropped connection or VPN, and stops blaming the mic.
- Voice with the lid closed switches mic.
- Control+C, Control+arrow and Control+scroll no longer count as a double-Control tap.
- Window screenshots work (it steps aside while you pick a window).
- Mission Control thumbnails work.
- Markdown notes open.
- The walkthrough cursor is freed when the mouse moves.
- **"Clicky's memory of you could get cut off partway through… It now keeps every section whole."**
- Account deletion clears local Clickys and moves their files to the Trash.
- No "UNKNOWN" badge on Files & Folders.

### Sep 24, 2026: 1.0.52. "A smaller notch, and invite your friends"
**The notch:** hovering opens a small **peek** with Suggestions, pins, every Clicky and apps, plus each Clicky's 3 newest files as a pile. You can hover, click or drag files out of the notch. Expand Home gives the full view. Toggle: *Settings > General > Quick peek on notch hover*.

**Invite & earn:** a HeyClicky username with an invite link at `heyclicky.com/@yourname`. The friend gets 25% off their first month on a monthly plan. You get 25% of their plan's price monthly for up to 12 months, in cash. Open it from Home's sidebar or Settings. The friend discount is shown up front on the plans card.

**Home**
- Replies are one selectable block (⌘A, ⌘C).
- Home opens smoothly and closes when the pointer leaves (drafts kept).
- Archived Clickys show in search, with Unarchive.
- Glassy thumbs-up that persists.

**Clickys**
- **Every Clicky announces done** out loud and beside the cursor, however it was started. Calls and screen sharing keep it quiet. Do Not Disturb now only silences scheduled routines.
- Follow-ups on the agent card (mic or text box). The card shows a thumbnail pile of the files it made.
- **Clicky knows its own settings:** "stop announcing yourself" or "talk slower" walks you to the setting. "you talk too much" is remembered. It can report plan usage.
- **"Clickys run on GPT-6:** Your Clickys now run on GPT-6 Luna, and deep answers use GPT-6 Sol."
- **Tables:** one sheet, answer first, a few short columns, a single link column. Caveats go in the chat.

**Computer use**
- **Your yes covers one conversation** only.
- **Stays in the background:** "Clickys now work inside apps without moving your real pointer or jumping into another app's address bar. The agent's floating cursor is gone for now." That cursor layer had caused black or covered window screenshots and Loom shares.

**Suggestions**
- Built from the last two days of app activity. A message-based card offers to handle the whole stream.
- Card order is stable.
- If 3 mornings go unopened, it backs off (1 day up to 1 week). *Settings > Agents* can turn them off.
- The first 3 tasks end differently: one makes an artifact, one gives an answer in chat, one acts in an app.

**Onboarding & plans**
- The tour introduces Farza's two default Clickys before the three personalized ones, and ends in the notch.
- Sign-in, checkout and shared-skill browser pages are restyled. After checkout it tells you beside the cursor whether your plan started.

**Fixed**
- Boxed "cite turn2search4" codes in replies.
- Another app's floating bar over the notch blocked Escape and typing.
- The first hover after launch.
- Unread count matches the dots.
- Meta Ads connector row "spells out how to connect with your own Meta app ID."

### Sep 18, 2026: 1.0.51. "A resizable Home and a whole bunch of fixes"
**Home**
- **Resize Home from the notch:** drag the left, right or bottom edges or bottom corners. It grows evenly from the notch and the size is remembered. Double-click an edge to reset. It now opens smaller by default.
- **The notch always opens Home:** the old tabbed notch panel was removed. Cmd+, or Settings… opens Home's Settings page. The setup card ⋯ menu keeps Check for Updates, Log Out and Quit.
- Home remembers being a popped-out window (position and size). The pop-out uses picture-in-picture icons.
- Sending keeps your scroll place. The jump-to-newest arrow "sweeps a ring once."
- **Unread count on the notch** (gel badge).
- A busy Clicky's profile shows the 10 newest results plus See more. Gel buttons.

**Suggestions:** a carousel, one card at a time, with arrows and faded previews. "do it" starts the visible card. Approving gets a quick "On it." The morning card is shorter, its chime is 30% quieter, and it has a Dismiss button. Dismissing 3 days in a row rests it for 5 days.

**Clickys & routines**
- **Make several Clickys in one ask** (up to 5). Making one on the New Clicky page no longer starts a task or uses a credit.
- **Names with more personality:** "two friendly words that say the job" (e.g. PDF Desk, Scout, Lab, Keeper) instead of "Something Buddy".
- **Long chats are quick again:** "One history pass on a 297-turn chat went from 2.14s to 0.15s." It loads the newest turns first and fetches older ones on scroll.
- **Only the screenshot that matters:** typing inside Home doesn't attach a screenshot of Home. "Older screenshots in a conversation also stop riding along with every new request." "Voice asks still see your screen."
- **Routines wait for your Mac and your internet:** "I'll run it when the internet is back". Offline failures don't count toward the 3-failure pause. Routines no longer announce starts.
- Failures stay in place in the conversation. Inline formatting in work steps.

**Quiet when you're busy:** on a call or screen share, unprompted voice updates, cursor text, the done chime, the morning hello and tip cards are silent. *Settings > Agents > Announcements* has separate switches for spoken updates and "Show updates beside the cursor".

**Connectors:** custom connector tokens are validated with a real request on save, edit, launch and refresh. The row shows Checking, then Connected or "Token rejected" with Edit token.

**Onboarding & settings**
- *Settings > General > Replay the welcome tour* (video, full tour, interview).
- Skip the interview by voice.
- **It opts out of macOS Automatic Termination** (macOS was quitting it 15-30 s into onboarding because no window was open).
- The muted-Mac card stays out of the interview.

**Fixed**
- Suggestion queue capacity is 20x higher (server-side). 4,000+ users were affected.
- Plan shows "Checking your plan…" instead of Free when sign-in is slow, and sessions refresh earlier.
- Steadier double-Control composer.
- Check for Updates no longer freezes the notch.
- It steps aside on ⇧⌘4 or ⇧⌘5.
- **"Dictation no longer pastes a stray `<transcript>` wrapper, or makes up text from a near-silent tap."**
- Clearer errors when OpenAI is unavailable in your region.
- Wake-from-sleep crash. Audio-output-change freeze.
- WhatsApp community link.
- Links close the Home sheet.
- Account deletion removes you from the marketing list.

### Sep 14, 2026: 1.0.50. "Keeping your Clickys going"
**Clickys & routines**
- Long stuck conversations fixed.
- A missing conversation starts fresh.
- Quick follow-ups wait for the agent to be ready or go as a new turn.
- **Routines pause after 3 failed runs in a row** (they used to retry every 5 min and burn credits) and say why in the profile.

**Home & suggestions**
- Drafts and attached files persist per chat while the app is open.
- Mark as Unread / Mark as Read.
- Escape closes the expanded notch panel until the cursor leaves. Opening a link tucks Home away.
- Right-click menus match. **The AGENTS.md and Folder shortcuts were removed from the Clicky profile.**
- Suggestions carry their source details (message, document or link) into the task.

**Billing:** the notch moves aside for the upgrade card. Responsive plan buttons, with an error if the link fails.

### Sep 12, 2026: 1.0.49. "Introducing Clickys"
"HeyClicky is 20 weeks old, and after 1.2 million messages we noticed we barely used agents ourselves… a little team of Clickys, each with its own name, face, memory, and job." Has a YouTube video and screenshots: New Clicky conversation, Home, character customization GIF, result preview, custom connector form, suggestions, morning hello, routine.

**Getting started**
- Pick a character style, answer **four quick questions**, and meet **three Clickys made for you**. The tour introduces them.
- Make a new Clicky through conversation (it asks follow-ups).
- **Setup has its own usage limits** (it doesn't spend your normal allowance).

**Clickys & Home**
- Persistent Clickys: "own name, memory, conversation, and folder for its files."
- **A new home:** a full chat interface opened from the notch, the Dock or **Control + Command + A**. It expands into its own window. "No model pickers, no settings maze. Just a chat and a hold-to-talk pill."
- **Make them yours:** **Dreamy Cloud** and **Puff Pals** styles. "Their faces react as they listen, think, and talk, and doze off when you stop them." The face and color follow into the notch and the top-right card.
- Pin, search, archive. Status indicators.
- A legacy toggle in Settings brings back older work.

**Voice & conversations**
- Hold the voice shortcut in a Clicky's chat to talk to that Clicky.
- **Ask from anywhere:** "what's running right now?", "tell Launch Scout I like this shirt too", "make me a Clicky that cleans my desktop every morning". It routes to the right Clicky or founds a new one.
- Follow-ups know who you mean. Spoken updates name the Clicky.
- Live progress. Work steps tuck away when done. Stop and retry. Approved suggestions queue per Clicky.
- Long-chat loading.
- **"HeyClicky remembers more of your recent conversations (40 messages, up from 20), plus everything you said in the onboarding interview."**

**Files, apps & settings**
- Drag, attach or ⌘V files into chat. Attachment-only sends.
- Preview documents, PDFs and images in Home. Each chat remembers its open document. **Markdown previews live-update.** Animated images play.
- **Connect your own tools:** "Add custom MCP connections alongside the built-in app catalog, using a server URL or a local command. Supported connections can sign in through your browser or use an API key. HeyClicky reads what the connector can do so your Clickys know when to use it."
- Connection status (connecting, ready, sign in again). Changes update the voice assistant's knowledge mid-conversation.
- Settings moved into Home (apps, account, voices, shortcuts).
- **Skills are on pause:** "We've removed Skills for now… we plan to bring them back in a new form."

**Suggestions**
- Clickys research connected apps and the web, then propose tasks (read-only, and the task waits for your go-ahead).
- "do it", "show me the next one", Adjust.
- **Morning hello:** Clickys pop out of the notch with a Show me button. It waits during calls, screen sharing or Focus mode.
- **Pipeline:** "one researcher per connected app plus the public web, reading full documents from the last 72 hours, then an editor picks the ideas worth your time." Feedback on rejections shapes tomorrow's batch.

**Routines**
- "give me a daily briefing", "check this every few hours". Runs on this Mac while the app is open. Pause, resume, run now, delete.
- Results arrive in chat with an unread dot (no voice or chime). One catch-up run after sleep.
- Waits while offline or busy, retries after a delay. Archiving a Clicky pauses its routines.

**Computer use**
- Before clicking or typing, a Clicky asks in chat and in the top-right panel: **"Allow once", "Always allow", "Not now"**, or answer by voice.
- **A separate browser window** in Chrome or Chromium using your signed-in profile. For the page you're viewing, it asks whether to use that tab or a new window. Non-Chromium browsers may fall back to a tab.

**Improved & fixed**
- Permission setup (the Screen Recording guide points to the screen-and-audio list).
- Refreshed sounds.
- Team checkout promo codes.
- **"Home idles at 3 to 5% CPU… Our first build sat at 36 to 43%."**
- Bluetooth cue pre-roll.
- **Dictation only lands in Home's composer when Home actually has focus.**
- External monitor menu-bar bug: "voice holds fell back to the spoken router".
- 'Pick a display' stuck. Top-right card button targets. Launch stalls.

### Aug 25, 2026: 1.0.48. "Walkthroughs go the distance"
**New**
- **Always approve for agents** (toggle in *Settings → Agent*).
- **Shortcuts your way:** "The dictation and hands-free shortcuts now take any held combo or a double-tap, so bindings like Control Control finally work. One double-tap starts hands-free dictation, the next one stops it."
- Log Out shows your email.
- The changelog is linked from *Settings → Support & Updates*. A "See what's new" notch card appears after updates.

**Walkthroughs**
- **"Up to 15 steps:** Step-by-step walkthroughs used to stop at 5 steps… The budget is now 15."
- **No more lost context:** across a manual-work pause and "continue", "it now remembers the goal and every completed step."

**Audio**
- AirPods clipping: the profile switch waits for post-reply silence and playback pre-rolls (117 users were affected last month).
- A wedged mic fails over to the built-in mic and says so in the notch (300 users had mic failures, 104 stuck until restart).
- Pro audio interfaces work (Behringer UMC404HD sample-format mismatch).
- **Muted speaker:** the reply is copied to the clipboard, with a one-click volume fix in the notch.

**Dictation**
- **"Sturdier insertion: Paste now respects your keyboard layout (Dvorak and Colemak…), the clipboard restore no longer races slow apps into pasting your old clipboard, clipboard managers stop archiving your dictated text, and no more stray trailing space after Chinese, Japanese, or Thai."**
- **"Dictating into a terminal can never run your words as commands. Newlines are collapsed before insertion."**

**Agents**
- **Works on managed Macs** "with IT-managed Codex policies" (31 failed spawns across 6 users).
- **"A new computer-use engine:** Computer use moved to a faster native driver. Background clicks stay scoped to the target window and never move your real cursor."

**Fixed**
- Files dropped on the notch vanished (154 users, 473 files).
- HeyClicky could see its own windows (e.g. the Skills Library).
- Notch animation. Agents search icon under the hardware notch.
- Cold-start race.
- "now knows the actual current time on every turn", and says "let me check that for you" less.

### Aug 13, 2026: 1.0.47. "Whole-document understanding"
- **Whole-document understanding:** for a PDF, file or web page it reads the entire thing as context, not just what's visible.
- **Works outside the US:** requests from Asia and the Middle East hit a Hong Kong data center that the AI providers block. It now detects this and re-routes through the US (28 users in 9 countries).
- **Smarter answers:** "Detailed and screen-related questions now route to a deeper model."
- Lighter CPU: an always-running animation was removed and sound playback moved off the main thread (idle CPU had reached 45%, and 1,600+ users hit a freeze after double-tapping Control).
- **No more cut-off answers:** deep answers had a hard 60-second timeout and now run to completion (58 users).

**Dictation**
- **Long recordings are safe:** ">10 minutes, including hands-free" sessions no longer drop. "every finished transcript gets a local backup."
- **Interruptions don't wipe your work** (WhatsApp call, mic change).
- **Works in more apps:** inserts in WeChat, WeCom, Chromium browsers (Chrome, Brave, Arc) and Electron apps (Slack, VS Code, ChatGPT) "instead of falling back to the clipboard" (1,836 users affected).
- **Faithful cleanup:** "No more rewriting or adding words you didn't say."

**Fixed:** lag after background agent tasks. Silent account-deletion failures. Blank System Settings window and the Help menu. Leftover drawings when closing text mode, and stale text in guided tours. **Security:** sign-in credentials moved to the macOS Keychain.

### Aug 1, 2026: 1.0.46. "More reliable voice"
- **Calmer voice:** web lookups happen silently instead of being narrated.
- **Faster first response:** "We warm up the session and network paths before you start speaking."
- **Removed proactive agents** and all local activity tracking ("No app names, no tab titles, no accessibility data, and the old local database deletes itself on update").

### Jul 31, 2026: 1.0.45. "Faster realtime voice"
"We rewrote the voice harness."
- **Noticeably faster:** "Quick questions get a fast model, deep or complex ones go to a frontier model. A little router decides on every question."
- Talks more like a person (fewer greetings and fillers).
- **Voice speed control:** *Settings → Voice*, 0.5x to 1.5x.
- **Privacy:** account deletion erases analytics data. A data-exposure hole found in a security audit was fixed.

### Jul 23, 2026: 1.0.44. "HeyClicky for teams"
- One subscription with a mix of Pro and Max seats, plus a small dashboard for members and billing.
- **Team-shared skills** (private to the team).
- Teams are set up by hand (email hi@heyclicky.com). The first pilot customer is onboarded.

### Jul 22, 2026: 1.0.43. "Agent retries and routing fixes"
Retry button on failed agent cards. API routing fixed for location-blocked regions (e.g. South Korea). Always-on realtime reliability fixes. Mic crashes, including the top native crash.

### Jul 20, 2026: 1.0.42. "Reliability fixes across the board"
- Freezes and stuck cursor in DaVinci Resolve and other heavy apps.
- **Push-to-talk (Control + Option)** requests being dropped.
- Strict corporate networks.
- Agents not starting.
- The notch stays put on display changes. Text mode got a close button. Tidier integrations popup.

### Jul 20, 2026: 1.0.41. "A new face, agents unstuck"
New logo. **UPI support** with rupee pricing (Stripe checkout). Agent-stuck fix.

### Jul 17, 2026: 1.0.40. "A hands-on tutorial in onboarding"
- **Guided tutorial (about 2 minutes):** "say a first hello out loud, watch HeyClicky draw on the screen, circle something and ask about it, draft an email reply by voice, and try dictation in a real text box."
- **"Hand-drawn annotations:** When HeyClicky draws on your screen, the shapes now look hand-drawn, Excalidraw-style, instead of machine-perfect."

### Jul 15, 2026: 1.0.39. "Dictation polish, and a privacy step"
- **"No more em dashes:** Dictation cleanup no longer inserts em dashes into your text."
- The update window comes to the front.
- The skill-panel orbit animation pauses offscreen.
- **Privacy:** removed proactive activity tracking and all accessibility-data collection, and the afternoon proactive slot. Morning suggestions wait until at least 6am local time.

### Jul 14, 2026: 1.0.38. "Dictation tuning"
**"Dictation now runs on two models, one for speech-to-text and one for cleanup, with timing measured per utterance. Faster and more accurate."**

### Jul 14, 2026: 1.0.37. "Dictation, and screen-aware dictation"
"As fast as Wispr Flow, if not faster, and it formats your text nicely." Has a YouTube demo and a `dictation.webp` screenshot.
- **Super fast speech-to-text:** "Dictate into any app on your Mac. Gmail, Claude, Slack… **Press and hold Fn + Control, speak, and the text streams in at around 450ms. Double tap Fn + Control for hands-free mode**, and change either anytime in *Settings → Shortcuts*."
- **It learns your words:** "Grammar and spelling get cleaned up for you. And if a word comes out wrong, just edit it within about 20 seconds and it's added to your dictionary automatically (also editable in *Settings → Dictionary*)."
- **Multi-language:** "It auto-detects your language, with 50+ supported. If detection is a bit off, set a default in *Settings → Dictation*."
- Unlimited dictation on Pro and Max. Free has "a generous limit".
- **Screen-aware: "Ramble, and let HeyClicky write it":** "Open the email, press Control + Option, and say 'HeyClicky, type a reply to this person in the text box here'. It takes a screenshot, understands what you're replying to, and inserts a draft written in your voice, based on HeyClicky's memories of you. You can even activate a skill (our Y-Combinator skill, or Write Like Farza lol) and it writes like the skill."
- **Fixed:** dictation fell back to the clipboard in Electron apps like Discord. Clicks at the start and end of notch chimes.

### Jul 13, 2026: 1.0.34-36. "The road to dictation"
- **Hold-to-dictate:** "Promoted out of developer preview and on by default, with shortcuts, hands-free mode, and cancel. Streaming plus a faster engine made it about 3.4x faster."
- **Cursor customization** page in Settings.
- **Skills 2.0:** "Capability-aware skill creation and better routing, a My Skills filter in the library, and creators get emailed when their skill is approved."
- **"Text insertion now prefers typing directly into the field over the clipboard."**
- Redesigned DMG install window.
- **Fixed:** account deletion server error. The top macOS 26 crash.

### Jul 6, 2026: 1.0.33. "Spatial context, skills, proactive agents, memory"
- **Spatial context: "Point, circle, scribble":** "When you talk to HeyClicky, you'll notice a little trail of paint it leaves behind. Draw on your screen to point at or circle the specific thing you want the AI to focus on."
- **Skills library:** "hover your notch, click add skill, and activate any of about 100 community-built skills in one click. When you talk to HeyClicky or run an agent, the skill is active… Hit 'Create a skill' and type what it should do."
- **Proactive agents:** every morning and afternoon, two personalized agent suggestions appear at the top right, approved with a click. Later turned off (see 1.0.46).
- **Memory:** "Your name, your language, how you like your CSVs named, everything. Under the hood it maintains two files: **PROFILE.md** for your habits and general preferences, and **VOLATILE.md** for the project you're working on right now. Both get injected into the voice model and the agent."
- **Also:**
  - **Library mode:** typed replies stream as text and get read aloud.
  - **Realtime voice model upgraded to gpt-realtime-2.1.**
  - Billing blips (paywalled and double-charged users).
  - Guided walkthroughs hanging on typed sessions. A duplicate spoken acknowledgement when handing off to the deeper model.

### Jul 4, 2026: 1.0.32. "Delete your account, if you must"
- Permanent account deletion in Settings.
- **"Walkthrough drawings are no longer capped at 3 shapes on screen."**
- Skills library and proactive agents were behind flags.

### Jul 1, 2026: 1.0.31. "Claude Fable 5 by default"
- **Claude Fable 5 is the default** ("really good at understanding your screen… a tiny bit slower, but way more accurate").
- **Always On is headphones-only** ("Without headphones it was pretty broken… still experimental").
- The cursor color picker moved to its own Settings page.
- **Fixed:** "The Codex we bundle inside HeyClicky broke, so agents were failing."
- **Highlights and drawings:** "A highlighted area now disappears after 2 seconds. If HeyClicky drew something like a polygon to explain a concept, it stays while it's speaking, and once it stops, everything clears. Nothing stays on your screen."
- **Clearer agent approval prompt:** approving more messages from your plan is not a card charge.

### Jun 29, 2026: 1.0.30. "A quick fix"
Crash when purchasing Pro, plus top reliability fixes.

### Jun 28, 2026: 1.0.29. "Yearly billing"
- Yearly plans at 20% off, with a monthly/yearly toggle on the paywall. A haptic on hovering the agent HUD.
- **Fixed:**
  - Notch jank on submitting text. A macOS 26 panel auto-resize crash. The cursor landing on the wrong monitor.
  - **"Text drafts that were claimed but never inserted (with a clipboard fallback just in case)."**
  - Mic recovers when the device disappears.
- Has a video: "$10k MRR, celebrated at a gas station."

### Jun 23, 2026: 1.0.28. "HeyClicky learned 89 apps"
- **"App skills:** HeyClicky now carries teaching skills for 89 apps, with browser-site matching, so guidance inside your tools is much sharper."
- **Quieter learning:** "one cursor bubble per app instead of a notch card every time."
- Morning greetings appear between 7am and noon. Has a Demo Day video.

### Jun 20, 2026: 1.0.27. "Notch only"
Feature Request and Community links in Settings. The menu-bar icon was removed and the notch is the only home. Fixed cursor lag in DaVinci Resolve "caused by blocking accessibility queries."

### Jun 19, 2026: 1.0.26. "Draw on your screen, realtime computer use"
- **"HeyClicky draws on your screen:** …FL Studio, Cursor, Claude Code, anything. Now it can draw directly on your screen and walk you through step by step, made much smarter by skill files injected based on the program you're in. It even detects when you click where it told you to, and moves you to the next step."
- **Realtime: "Control your computer with your voice:** We shipped the world's first realtime computer-use system… 'Play Lucid Dreams by Juice WRLD on Spotify', 'Open up my Stripe dashboard for me', 'Check my Google Calendar'… **Try always-on mode by pressing Control three times (requires headphones).**"
- **A way more powerful agent** with integrations (Supabase, building Mac apps, Notion CRM). "Honest note: it's not good at controlling your computer yet."
- **"6x faster, and 70+ languages:** Replies are now near instant. If you ask something complex about your screen, it hands off to a more powerful model and thinks longer." Languages include Spanish, Portuguese, French, Japanese, Russian, Chinese, German, Korean and Hindi.

### Jun 18, 2026: 1.0.25. "Draw for HeyClicky"
- **"Screen highlight:** Press Ctrl + Option and draw on your screen. Annotations are now always-on, so you can circle the thing you're asking about." This became spatial context in 1.0.33.
- **An eager agent:** "acts on write actions immediately and only asks for confirmation on deletes, emails, and money."
- **Fixed:** the double-Control input box didn't open with Caps Lock on. High CPU from agent HUD chips re-rendering every frame.

### Jun 14, 2026: 1.0.24. "No more frozen keyboards"
- **Fixed:**
  - A system-wide keyboard freeze. A missing screen permission now routes to the notch.
  - **"The always-on echo loop. Proper echo cancellation means you can barge in over your speakers now."**
  - Quitting when another app triggered "Hide Others". Keyboard focus not being released after text mode.
- **Tidier agents:** the floating agent HUD folds into the screen corner as an accordion. Text responses get an inline follow-up composer.
- **An honest answer:** "what model are you?" now returns the truth about the models in its voice loop.

### Jun 8, 2026: 1.0.23. "Drag files into the notch"
- Drag files into the notch to chat about them.
- **"The double-tap text box now opens instantly, and text responses get a copy button and selectable text."**
- Realtime voice follows Bluetooth device switches.
- Links (YouTube, Maps, searches) open directly instead of being read aloud.
- Bug reports include logs. A fix for compat mode getting stuck hidden.

### Jun 1, 2026: 1.0.22. "Interrupt me anytime"
- **Barge in** during always-on mode.
- Spotify playback searches any track, album or artist (it was "deliberately restricted to AC/DC").
- Fixed the notch stuck on "Thinking…" after a cancelled voice turn.

### May 30, 2026: 1.0.21. "Clicky is now HeyClicky"
- Renamed everywhere (app and process).
- **Realtime voice:** "A new realtime voice surface, now the default for voice and typed input. Plus a voice picker with spoken previews."
- **"Draw-on-screen guidance:** The first version of guided walkthroughs: target rings, annotations, and narration, on by default."
- **Google Calendar** via realtime voice (read and create events).
- Spotify tool (AC/DC only, as a joke).
- **Improved:** the notch is the only home, the menu-bar panel is gone, and agent history is searchable. The default mic is the built-in mic, with no crackle on the first word.
- **Removed:** HeyClicky Notes.

### May 19, 2026: 1.0.20. "A sleep fix"
Chime-engine crash on sleep and wake.

### May 16, 2026: 1.0.19. "Small tunings"
Voice speaks the full reply, not a shortened one. Integration suggestion popups are capped at 3 a day. The notch waits a beat longer before expanding on hover.

### May 14, 2026: 1.0.16-18. "Notch follow-ups"
- **New:** Show in Dock toggle. Microphone selection in Settings.
- **Improved:**
  - Reliable agent follow-ups. Voice replies are no longer truncated.
  - The cursor is undocked by default again ("docked felt too radical").
  - Integration suggestions overhauled: full connector catalog, native Mac apps recognized, fewer false positives.
- **Fixed:** rejected agent handoffs no longer bill your quota.
- Notch hover dwell (per the 1.0.18 GitHub release note).

### May 13, 2026: 1.0.15. "A home in the notch"
- **The notch:** "a bit of a radical design and we're still testing it."
- **HeyClicky connects to your stuff:** Notion, Gmail, Linear "and a whole lot more". Examples: "Research new TikTokers for my product and put them in my Notion table", and "Take this bug report, make a Linear ticket, and then send it to Joshua in Slack".
- **New voices**, including kid-friendly ones.
- **Dock HeyClicky:** it stops following your cursor and takes refuge in the notch.
- **A new brain:** "replies much faster, has context of your agents… (we built our own lightweight agent harness in house)."

### May 4, 2026: 1.0.12. "HeyClicky can click"
- **"HeyClicky can now click:** Thanks to our friends at **Cua**, HeyClicky can use your computer. It controls your browser and more." Examples: SSD research then add to an Amazon cart, generate an OpenAI API key. "Sometimes it breaks."
- **HeyClicky Notes:** a personal notes wiki (bookmark icon). Removed in 1.0.21.
- **"HeyClicky types for you, anywhere:** Kinda like WisprFlow, but HeyClicky types for you. Say 'HeyClicky, type text in this box for me...' and it types wherever your cursor is."
- **No more saying "HeyClicky Agent":** it understands intent and either guides or does.
- **A cancel window:** agents wait 5 seconds before starting. The agent speaks follow-up questions aloud.

### Apr 30, 2026: 1.0.11. "Google Workspace, and shortcuts your way"
- **Google Suite:** Gmail, Drive, Sheets, Calendar, run in the background. "(By default, HeyClicky can't send emails for you.)"
- **Custom shortcuts:** push-to-talk and text-mode shortcuts are customizable, "including double-tap-modifier triggers."
- **"A fast intent classifier decides when a request should go to the agent, using your last few turns."**
- **"The agent can type directly into visible on-screen fields, and drives its own tinted overlay cursor. It is forbidden from moving your real pointer."**

### Apr 27, 2026: 1.0.10. "HeyClicky agents"
"The simplest interface in the world to talk to AI and spawn agents. Built for consumers, zero setup."
- **Spawn agents with your voice:** "It builds Mac apps. It does research to help you find IG micro-influencers. It interacts with native Apple Notes, Calendar, and Reminders."

### Apr 6, 2026: 1.0. "Introducing HeyClicky"
"An AI teacher that lives as a buddy next to your cursor. It can see your screen, talk to you, and even point at stuff." "Press a shortcut and talk to your computer. It sees your screen and answers out loud." It was used to learn DaVinci Resolve. Farza's first tweet was Apr 7: 3.0M views.

---

## 3. Deep dives

### A. Dictation

**Hotkeys**
- **Plain dictation:** hold **Fn + Control** and speak, and text streams into whatever field has the cursor. Release to finish.
- **Hands-free:** **double-tap Fn + Control** to start, and double-tap again to stop (Aug 25 wording).
- **Rebinding:** both are rebindable in *Settings → Shortcuts*. Since Aug 25 they accept "any held combo or a double-tap", so bindings like "Control Control" work. Cancel exists (Jul 13).
- **Screen-aware dictation** uses the main assistant key, **Control + Option**, plus a spoken instruction ("HeyClicky, type a reply to this person in the text box here"). Farza: "FN + CNTRL for simple dictation (fast). CNTRL + Option for screen-aware (slow)." (X, Jul 15).
- On Windows the assistant key is **Ctrl + Alt** [prior research]. No Windows dictation hotkey was found on the site [not found].

**How text is inserted (evolution)**
- **Jul 13:** "Text insertion now prefers typing directly into the field over the clipboard."
- **Jul 14:** fixed clipboard fallback in Electron apps like Discord.
- **Aug 13:** "inserts correctly in WeChat, WeCom, Chromium browsers (Chrome, Brave, Arc), and Electron apps like Slack, VS Code, and ChatGPT, instead of falling back to the clipboard."
- **Aug 25:**
  - "Paste now respects your keyboard layout (Dvorak and Colemak…)". This implies it synthesizes the ⌘V keystroke by key code mapping.
  - "the clipboard restore no longer races slow apps into pasting your old clipboard". So the flow is save clipboard, write text, paste, restore.
  - "clipboard managers stop archiving your dictated text". **[inference]** It probably marks the pasteboard item as transient or concealed.
  - "no more stray trailing space after Chinese, Japanese, or Thai."
  - **Terminal safety:** "Newlines are collapsed before insertion."
- **Jun 28:** "Text drafts that were claimed but never inserted (with a clipboard fallback just in case)."
- **Sep 12:** "Dictation… only lands in Home's composer when Home actually has focus. A background window never steals words meant for another app."
- **Sep 18:** "no longer pastes a stray `<transcript>` wrapper, or makes up text from a near-silent tap." **[inference]** The cleanup LLM's prompt wraps text in `<transcript>` tags, and silence gating was added.
- **Muted Mac:** voice replies (not dictation) go to the clipboard (Aug 25).

**Speed claims**
- "the text streams in at around 450ms" (changelog, Jul 14). Farza: "very fast, ~450ms" (X and YouTube description).
- "Streaming plus a faster engine made it about 3.4x faster" (Jul 13).
- "As fast as Wispr Flow, if not faster."
- Screen-aware replies: "this will take like 5 seconds" (demo video).
- Timing is "measured per utterance" (Jul 14, 1.0.38).

**Models and providers**
- **Privacy policy (Nov 10):** "AI: OpenAI, Anthropic and Google… and **Cerebras, Groq and Deepgram for dictation**." Some requests "go directly from the app to our AI providers, using short-lived access that we issue."
- **Jul 14 (1.0.38):** "two models, one for speech-to-text and one for cleanup."
- **Oct 30:** "Voice and dictation now hear you through **Google's newest speech model**."
- **[inference]** Before Oct 30, STT was most likely Deepgram (streaming), and cleanup most likely a fast open-weights LLM on Cerebras and/or Groq. Since Oct 30 STT is Google's model. HeyClicky never says which provider does which step [not found].
- Farza described plain dictation as "just straight speech to text" (X, Sep 26).

**Cleanup and formatting behavior**
- "Grammar and spelling get cleaned up for you" and "it formats your text nicely" (Jul 14).
- "Dictation cleanup no longer inserts em dashes" (Jul 15).
- "Faithful cleanup: No more rewriting or adding words you didn't say" (Aug 13).
- Newlines are collapsed in terminals (Aug 25).

**Languages**
- Jul 14: "auto-detects your language, with 50+ supported", with a default in *Settings → Dictation*.
- Oct 30: 83 languages in the picker, auto-detect plus mid-sentence switching ("English with Hindi or Urdu"), and "picking Urdu finally writes Urdu."
- Nov 6: "no longer guesses which language you'll speak, and it ignores stray bits of noise that came out in a language you never use."

**Custom vocabulary**
- "if a word comes out wrong, just edit it within about 20 seconds and it's added to your dictionary automatically (also editable in *Settings → Dictionary*)."
- Nov 6: *Settings > Dictation* shows the Dictionary above Language.
- **[inference]** The app watches the focused field for about 20 s after insertion and diffs the user's edit.

**Robustness**
- Sessions over 10 minutes are safe, with "every finished transcript gets a local backup".
- Interruptions (a call, a mic change) keep the partial text.
- Works with Home open.

**"Replies in your voice" (screen-aware dictation)**
- "It takes a screenshot, understands what you're replying to, and inserts a draft written in your voice, based on HeyClicky's memories of you" (PROFILE.md and VOLATILE.md, see E).
- Skills could steer style (the "Y-Combinator skill", "Write Like Farza"), but Skills were paused Sep 12.
- **Demo flow:**
  1. Gmail: "type a reply… say something like 'Thanks, appreciate you,' and ask him what his use cases are."
  2. The voice says "I pasted your reply." The draft appears in the Gmail reply box, signed "Farza".
  3. Claude Code terminal: "type a follow-up prompt in the terminal, and also explain it to me". It pastes the prompt and narrates.
  4. Google Slides with the YC skill.
- Stated user uses: Google Ads copy, resumes, Slack and LinkedIn replies.
- The May 4 precursor: "HeyClicky, type text in this box for me...".

**UI seen in video:** a "Dictating" pill in the notch while speaking. Text streams into the Apple Notes body in real time. During screen-aware typing there is a spinner near the caret. Pricing: unlimited dictation on Pro and Max, "plenty of dictation" or "a generous limit" on Free.

### B. 2D/3D drawing ("draws on screen", real-time graphics)

**Generations of the feature**

1. **Pointing (Apr 6, 1.0):** the buddy cursor flies to and points at UI. **[prior research]** The open-source Clicky emits `[POINT:x,y:label:screenN]` tags.
2. **Draw-on-screen guidance (May 30, 1.0.21):** "target rings, annotations, and narration, on by default."
3. **AI drawing tutor (Jun 16-19, 1.0.26):**
   - Farza: "Using Claude Opus we're able to draw polygons, point with pixel perfect accuracy, and walk users through complex steps." The YouTube description says "Claude Fable 5".
   - Video narration: "It can draw polygons, arrows, curved lines, and a lot more… it's going to take a screenshot to actually return coordinates of drawings that it's going to paint on my screen directly."
   - Per-app skill files are injected (see E). It "detects when you click where it told you to, and moves you to the next step."
   - **Visuals:**
     - Pythagorean demo on a Khan Academy video: red squares drawn on each triangle leg, small red pill labels ("hypotenuse C", "area 16", "area 9").
     - FL Studio: a dashed red rectangle around the Channel Rack, and red pills ("kick step five", "snare row") near the step buttons the user should click.
4. **Lifecycle rules (Jul 1, 1.0.31):** "A highlighted area now disappears after 2 seconds. If HeyClicky drew something like a polygon… it stays while it's speaking, and once it stops, everything clears." Jul 4: no longer capped at 3 shapes.
5. **Hand-drawn style (Jul 17, 1.0.40):** "shapes now look hand-drawn, Excalidraw-style, instead of machine-perfect." **[inference]** A rough.js-style jitter, or equivalent native path perturbation.
6. **2D + 3D "real-time graphics" (Oct 23 ship, Oct 28-29 announcement, 1.1.1):**
   - Changelog: "circles, points and sketches right on your screen while it talks. Explanations land on little cards with real photos, and when the answer is a real thing, like an engine, a molecule or a building, HeyClicky builds a **3D model you can drag around and click on to ask about any part**."
   - Farza (X, Oct 28, 1.27M views): "Using **Sol 6.1 Ultrafast** we can generate custom overlays, diagrams, and even interactive 3D scenes right on a user's screen, no chat."
   - Video: "Within just a couple of seconds… this is not pre-rendered. It's all done on the fly using **a rendering engine that we built in-house**."
   - Livestream (33:46): "this 3D engine that we're using is our own 3D engine that we built in-house… Jose… It took like two weeks for him to build it, but it's running our own extremely efficient 3D engine **natively on your Mac**… it's real time… You don't have to wait 10 minutes to create your 3D models."
   - Livestream (20:43): "are these responses in the files? No, this is all done in real time using a drawing system that we've been building for the last three weeks."
   - Farza reply (X, Oct 29): "all this is **surprisingly token efficient**, shoutout @4xiom_."
   - Livestream, on why they rebuilt it: users "would be very very very very very sad if we lost our drawing system", and they had "not touched [it] for almost like five months."

**What it can draw (as shown)**
- **2D explainer cards:**
  - "tensors and targets": "Make a question and its answer", Input tensor [18] → Target 47, [18, 47] → 56, "Both can be tensors", Guess → Compare → Adjust.
  - "One small task, enormous practice": token boxes "The / sky / is → blue", a mini network graph, "Learned weights".
  - "engine performance": "What 'powerful' means: Thrust ≈ airflow × speed gain".
  - "the chain rule": "Two operations, two derivatives".
  - "your first level": "Get Linux running first".
  - A guitar chord diagram (C minor).
  - A line chart, "Bitcoin today · USD", with cited sources (Yahoo Finance, Investing.com).
  - Spreadsheet-like tables.
- **On-screen annotation of the real content:** gold or yellow hand-drawn ellipses and rectangles circling code in a Colab notebook (`tensor([18, 47, 56, …])`), circling `ln(3x²+1)` on a lecture whiteboard, and arrows to UI elements.
- **3D models (livestream and video):**
  - F-35B (exterior, then a cutaway showing the lift fan, swivel nozzle and downturned exhaust, with blue airflow arrows).
  - A turbofan cross-section with numbered label chips "1 · Fan, 2 · Compressor, 3 · Combustor, 4 · Turbine, 5 · Nozzle" and an orange thrust arrow.
  - A Raspberry Pi 5 board with chips (USB ports, GPIO, RAM, microSD storage), plus an animated camera-ribbon insertion ("Camera", "22-pin end", "Gently lift the latch, insert…").
  - A DNA double helix. A sodium-potassium pump in a membrane. A LEGO Mercedes-AMG SL63 (identified from a webcam photo).
  - A piston/engine on Windows. A "gear turns that one, so the hands move" clock mechanism (slide).
  - Users also report motorbike engines (explained in Urdu) and "doodles" turned into 3D.

**How users invoke it**
- Just ask by voice (hold **Control + Option**, release to send) or type (**double-tap Control**). Examples: "Can you draw on my screen directly and show me?", "Show it to me in 3D", "Can you draw the full jet for me in 3D".
- It decides on its own when a drawing helps. The FAQ says it "draws right on your screen to point the way."
- Typed questions that get a drawing show their answer as captions (Oct 23).

**How it renders: overlay vs window**
- **Both.** Annotations and 3D models are drawn directly over the live screen with no visible chrome (3D models sit over web pages and X posts).
- Explainer **cards are separate floating windows** with macOS traffic-light buttons and a tiny title, on cream grid-paper with a handwritten font.
- Changelog evidence:
  - Nov 6: "A 3D figure in **a drawing's window** stopped turning after you clicked the window."
  - Oct 24 (Windows): "Dragging a drawing's cards, turning a 3D figure after moving its window."
  - So cards are draggable and 3D figures live in their own (transparent) window.
- The cursor buddy points at parts while it narrates. Elements build progressively in sync with the speech.

**Interactivity**
- Drag and rotate the 3D figure. Click any part to ask about it.
- Follow-up chips: "the next question, one tap away", e.g. "Where should I start?", "Show me a chord", "How do I change chords?".
- Continuous follow-ups that build on the visual ("How do I attach a camera…?").

**History, replay and export (livestream)**
- "drawings saved in the chat. you asked. replay it, or download it."
- The chat shows an entry like "✎ Drew Bitcoin today · 7:32 PM" with a duration ("0:18").
- **Replay** and **Download MP4** buttons. The replay player shows the user's spoken prompt, the captions and a scrubber (e.g. 0:10 / 0:27).

**Platform and GPU notes**
- Available on Mac and Windows.
- Windows 1.1.2: "3D drawings work on PCs whose graphics card can't draw them the usual way." **[inference]** This is a software or WARP fallback renderer.

**Technical hints**
- **Not found:** no mention anywhere (site, changelog, videos, Farza's or HeyClicky's X) of three.js, WebGL, canvas, SVG, Metal, SceneKit, RealityKit, a physics engine, a simulation engine, or the model writing code.
- The only three.js touchpoint is @heyclicky replying "wow" to an unrelated three.js app.
- A 2025 Farza reply about an early prototype: "just a native swift app, draws a transparent screen on my windows + draws on it."
- **[inference]** The evidence points to the model emitting a compact, declarative scene or timeline spec, not free-form code:
  - "token efficient", a couple of seconds' latency on an "Ultrafast" model, and an in-house native engine.
  - The spec would cover 2D primitives, text, photo slots, chart data, and 3D parts with labels and animation steps, timed to the speech.
  - It renders natively on each platform.
  - Replay and MP4 export fit a deterministic timeline.
- "Real photos" on cards come from web or image search (privacy policy search providers: Exa, Brave, Google, Wikipedia).
- **Physics/simulation:** none advertised. Motion is explanatory animation (airflow arrows, pump conformational change, cable insertion, gear turning).

**Videos to watch:** "introducing real-time graphics" (YlW_-hdw7hs, Oct 29, about 293K views); "we built an ai that draws on your screen" (nT16HPxYX-s, about 811K views); the launch livestream (xOkfw1_ePhg, 16:00-38:00 for drawing, 1:06:20 for history and replay).

**Community clones:** "/drawover" (an open-source skill for agents to draw 3D scenes, diagrams and overlays, Mac and Windows) and a "pop out" 3D feature built on open-source Clicky.

### C. Walkthroughs, circle-to-ask, spatial context

**Walkthroughs**
- **May 30:** first version, with target rings, annotations and narration.
- **Jun 19:** step-by-step with click detection ("detects when you click where it told you to, and moves you to the next step"), and per-app skill files.
- **Jun 23:** teaching skills for **89 apps** with browser-site matching.
- **Jul 4:** no 3-shape cap.
- **Jul 6:** fixed hanging on typed sessions.
- **Aug 13:** stale text in guided tours fixed.
- **Aug 25:** **up to 15 steps** (was 5). It remembers the goal and every completed step across a "continue" pause.
- **Oct 2:** "keeps a running log of what you've done, and waits for slow pages to finish loading before it looks again". It asks what you already have, never repeats a failed step, and frees the walkthrough cursor when you move the mouse.
- **Nov 6:** "checks your screen before giving the next step, so it stops repeating steps you've already done."
- **Livestream demo:** "show me how to change my email on LinkedIn". It guided through "Sign in & security".
- **[prior research]** Users say "continue" to advance after manual work.

**Circle-to-ask and spatial context**
- **Jun 18:** "Press Ctrl + Option and draw on your screen. Annotations are now always-on, so you can circle the thing you're asking about."
- **Jul 6-8 launch:** "a little trail of paint it leaves behind. Draw on your screen to point at or circle the specific thing you want the AI to focus on."
- Farza: "AI can easily analyze screenshots. But, it has no idea where exactly you want it to look. Now you can just show it."
- YouTube description: "Press the hotkey, circle it with your cursor, ask."
- **Demos:**
  - Circling a shoulder on an anatomy plate gives "that muscle is the deltoid. It has three parts…".
  - Circling a blank spot on a website and saying "add a button… right here": "The model then takes the area that I circled and passes it off to our agent, which will then add a button exactly where I circled." A green bubble reports "The Explore Programs button is back in the hero next to Start registration".
  - Visual: the cursor leaves a fading colored stroke (pink on anatomy, green on the website) while the key is held.
- **Onboarding** teaches it ("Circle anything, ask about it").

**Other spatial and temporal context**
- Whole-document understanding (Aug 13).
- "remembers the page you just left" (Oct 2).
- "remembers what was on your screen earlier in the conversation" (Oct 23). Slide: "it remembers what it saw", e.g. "$1,284, on your Stripe page at 10:42".
- Follow-ups to jobs bring a screenshot (Nov 6).
- **Privacy:** screenshots are only taken on the hotkey and "never stored" on their servers.

### D. Agents ("Clickys"), Drive, routines, connectors, MCP, Chrome extension

**Agents and Clickys timeline**
- **Apr 27:** spawn agents by voice. They build Mac apps, do research, and use Apple Notes, Calendar and Reminders.
- **Apr 30:**
  - A fast intent classifier routes to the agent using the last few turns.
  - The agent types into visible fields and "drives its own tinted overlay cursor… forbidden from moving your real pointer".
- **May 4:** a 5-second cancel window. Follow-up questions are spoken.
- **May 13:** "our own lightweight agent harness in house."
- **Jun 18:** acts on writes immediately and confirms only on deletes, emails and money.
- **Jul 1:** "The Codex we bundle inside HeyClicky" (agents ran on bundled Codex). Aug 25: support for IT-managed Codex policies.
- **Sep 12, Clickys:** persistent named agents, each with its own memory, conversation, files folder and face. **[prior research]** Defaults "Shippy" and "Research buddy". Onboarding makes 3 personalized ones.
- **Sep 14:** removed the AGENTS.md shortcut from the profile. **[inference]** Each Clicky has an AGENTS.md.
- **Sep 18:** up to 5 Clickys from one ask. Two-word names.
- **Sep 24:** "Clickys now run on **GPT-6 Luna**, and deep answers use **GPT-6 Sol**."
- **Oct 2:** "less than half the setup" per step, re-uses what was already read. Clickys ask one short set of questions.
- **Oct 23 (One brain / jobs):**
  - Livestream: "We only use GPT Sol as our core AI model."
  - Agents run as jobs that "hang from the notch as little windows that show their plan while they work".
  - The new harness is **"J1"**, built in-house by Jose "on top of Pi… we just really wanted to take off the bloat of Codex… It's faster, it's cheaper, and it's almost the same quality."
- **Oct 30:** job names ("Inbox Hunter"). ←/→ flips cards. Jobs past 20 minutes keep going on one message if within budget. Agents remember earlier work.
- **Nov 6:** long jobs "with notes on your goal and your rules that they read again as they go". Jobs keep history past 6 h idle. Follow-ups attach screenshots. Stop button. "How many messages do I have left?"

**Billing semantics**
- An agent message is counted per job.
- Follow-ups to a working agent aren't new messages (Oct 30). A job that never started is refunded.
- Stopping within 10 s refunds (Oct 2). Allow and Not now answers are free (Oct 2).
- Long tasks may ask for "more agent messages from your existing plan", with Always approve.
- Plans: Free 25 talk + 25 agent messages a month. Pro $20/mo (unlimited talk and dictation, 150 agent). Max $100/mo (1,000 agent). Yearly saves 20%. Student 50% off the first Pro month.

**Drive (computer control)**
- **History:** May 4 computer use "Thanks to our friends at Cua". Jun 19 "realtime computer-use system". Aug 25 "a faster native driver. Background clicks stay scoped to the target window and never move your real cursor". Sep 24 works in the background without moving the pointer, and the agent's floating cursor was removed.
- **Oct 23, "HeyClicky drive" (in-house, from scratch):**
  - "When something needs doing in an app… HeyClicky asks, and with your yes it moves the mouse and types while you watch. Move your mouse, talk or press Escape and you're back in control."
  - Livestream: "All you have to say is hey clicky and then drive… The key word is drive."
  - **Notch prompt (frame):** "Want me to drive Preview and make that crop? You watch. Esc takes it back. [Go ahead] [Not now]".
  - **While driving:** "HeyClicky is driving · I'll open File to create a separate copy. [esc] to take it back."
  - **[prior research]** A glowing screen border.
- **Permissions:**
  - Sep 12: "Allow once / Always allow / Not now", or by voice. Sep 24: a yes covers one conversation.
  - Nov 6: Not now suppresses re-asking for 30 min.
  - Mac needs Accessibility. It asks before opening Desktop, Documents and Downloads (privacy policy).
- Demos: cropping a photo in Preview, DaVinci Resolve title cards, Ableton.

**Routines**
- Sep 12: per-Clicky schedules. They run on this Mac while the app is open. Pause, resume, run now, delete. One catch-up after sleep.
- Sep 14: pause after 3 consecutive failures. Sep 18: wait for wake and internet.
- Oct 23: "Routines, just by asking" (*Settings > Routines*). Nov 6: set a schedule from a job's own chat (Mac).
- Results arrive silently in chat with an unread dot.

**Connectors**
- **Built-in:** Google Workspace (Apr 30). Notion, Gmail, Linear "and a whole lot more" (May 13). Google Calendar and Spotify via voice (May 30). Supabase, Stripe, Meta Ads (with your own Meta app ID), Slack (examples).
- **Auth** is held by **Composio** (privacy policy). "Sign-in details for apps you connect yourself are stored securely on your computer."
- **Multi-account** with labels (Oct 2). Reddit and Monday paused.
- **Custom MCP** (Sep 12): "server URL or a local command… sign in through your browser or use an API key. HeyClicky reads what the connector can do." Token validation with a Checking / Connected / "Token rejected" state (Sep 18).
- **Search providers:** Exa, Brave, Google, Wikipedia.

**Chrome extension**
- **Oct 23:** agents work in your own Chrome, "in their own tab group".
- **Oct 30:** published on the Chrome Web Store. Works in Edge, Brave, Arc and Vivaldi.
- **Nov 6:** file uploads (asks once, or *Always approve file uploads*). It self-updates when idle.
- **Chrome Web Store listing** (v0.6.5, updated Nov 7, 2026, 134 KiB, 5.0 from 5 ratings):
  - "Its tabs open in a blue tab group beside yours, named after the job… a soft glow around the page it's on and its cursor showing where it clicks."
  - "When the job is done, the tabs it only needed along the way close by themselves."
  - "Jobs hand passwords, verification codes and card numbers back to you to type."
  - "Chrome's own 'is debugging this browser' bar stops them too."
  - "Tabs a job borrowed go back where they were."
  - "Requires the HeyClicky app for Mac."
- **Privacy policy:** "communicates only with the heyclicky app on your computer, through **Chrome's native messaging**." It reads "address, title, text, structure and screenshots". Incognito isn't supported. It stores only the cursor setting, a random profile ID and its working-tab list.
- **[inference]** It uses the `chrome.debugger` (CDP) API, given the debugging bar, plus a native-messaging host.
- **Livestream:** "our Chrome extension lets us basically debug the browser for you in the background… I can do multiple at the same time" (Amazon cart, X doom-scroll summary).
- **Earlier (Sep 12):** a separate Chrome or Chromium window using your signed-in profile. Oct 2: one window per task.

**Suggestions and proactive features**
- Jul 6: proactive agents. Jul 15 and Aug 1: activity tracking removed.
- Sep 12: suggestions pipeline ("one researcher per connected app plus the public web… last 72 hours… editor").
- Sep 24: back-off rules.
- **Oct 23: "Suggestions are taking a break."**

### E. Memory (PROFILE.md, VOLATILE.md) and per-app skills

**Memory**
- **Jul 6:** "two files: PROFILE.md for your habits and general preferences, and VOLATILE.md for the project you're working on right now. Both get injected into the voice model and the agent." It remembers your name, language and "how you like your CSVs named".
- **Sep 12:** "remembers more of your recent conversations (40 messages, up from 20), plus everything you said in the onboarding interview." Each Clicky has its own memory.
- **Sep 24:** "Tell it 'you talk too much' and it remembers."
- **Oct 2:** "Clicky's memory of you could get cut off partway through, often losing how you like it to talk to you. It now keeps every section whole." **[inference]** PROFILE.md is sectioned (e.g. a communication-style section) and was being truncated to a budget.
- **Oct 23:**
  - One brain "remembers what was on your screen earlier in the conversation, and remembers your conversations from day to day."
  - Livestream: "we built this entire new system once again for better memory and context management" (Jose). Demo: it recalled "Faker" and "derivatives… chain rule" from earlier in the stream.
- **Oct 30:** jobs remember earlier work. **Nov 6:** answer-style preferences persist "today and next week". Jobs keep goal and rules notes.
- **Privacy:** "we do keep basic text summaries so heyclicky has context". "You can ask it to forget things." Conversations are stored, screenshots aren't.
- Screen-aware dictation drafts "in your voice, based on HeyClicky's memories of you."

**Per-app skills**
- **Jun 17 (Farza on X):** "we smartly inject a skill file for specific programs… if you use on blender, we detect the program (based on bundle-id) and inject a skill file we maintain based on program user is on."
- **Jun 19:** "skill files injected based on the program you're in."
- **Jun 23:** "teaching skills for 89 apps, with browser-site matching". UI: "one cursor bubble per app instead of a notch card every time" while learning.
- **Jul 6:** community **Skills Library** (~100 skills, one-click activate from the notch, "Create a skill").
- **Jul 13:** Skills 2.0 (capability-aware creation, routing, My Skills filter, creator approval emails).
- **Jul 14:** YC and "Write Like Farza" skills for screen-aware dictation.
- **Jul 23:** team-shared skills. **Aug 25:** it can see its own Skills Library window.
- **Sep 12: "Skills are on pause… we plan to bring them back in a new form."**
- Whether the 89 built-in per-app teaching skills are still injected after Sep 12 is **[not found]**. The Sep 24 "shared skill pages" restyle suggests the web side remains.
- **[prior research]** The Skills Library UI had Y Combinator.md (by Aaron Epstein) and categories (Design, Coding, Writing, Video).

### F. Always-on mode, captions, voices and languages, text box

**Always-on**
- Jun 19: "Try always-on mode by pressing **Control three times** (requires headphones)."
- Jun 1: barge-in. Jun 14: echo cancellation allows barging in over speakers.
- Jul 1: "Always On is headphones-only for now… still experimental." Jul 22: reliability fixes.
- Farza's viral "control my computer with just my voice… No hands" demo (May 30, 3.8M views) credits GPT-Realtime 2.0.
- No newer always-on changes after Jul 22 [not found].

**Voice pipeline and models**
- May 30: realtime voice surface as the default for voice and typed input.
- Jul 1: Claude Fable 5 as the default (screen understanding).
- Jul 6: gpt-realtime-2.1.
- Jul 31: router between a fast model and a frontier model.
- Aug 1: session and network prewarm.
- Aug 13: screen questions go to a deeper model, and the 60 s cap was removed.
- **Oct 23:** "One brain". The livestream says the old pipeline was "GPT realtime… a lighter model… would decide if we should give your task to a better model". Now "we only use GPT Sol as our core AI model."
- Oct 28: graphics on "Sol 6.1 Ultrafast". Oct 30: Google speech model for hearing.
- Answers start "a couple of seconds after you let go".

**Captions**
- Oct 23: *Settings > Voice > "Captions while HeyClicky talks"* shows text at the bottom of the screen. Typed questions with drawings answer in captions.
- Nov 6: closing the chat continues the answer as captions. Slide: "captions while it talks."

**Voices and languages**
- May 13: new hand-picked voices, including kid-friendly ones. May 30: picker with spoken previews.
- Jul 31: speed 0.5x-1.5x (*Settings → Voice*).
- Jun 19: 70+ languages. **Oct 30: 130+ languages, plus 30 new native-accent voices** (*Settings > Voice > Voices*, tap to preview).
- Sep 24: "talk slower" or "stop announcing yourself" leads to the setting.

**Text box**
- **Double-tap Control** opens the composer ("double-Control composer").
- Jun 8: opens instantly, with copy and selectable text. Jun 18: Caps Lock fix.
- Jul 6: "Library mode: typed replies stream as text and get read aloud."
- Sep 18: steadier composer. Oct 2: Control+C, arrow and scroll don't trigger it.
- Customizable since Apr 30 ("text-mode shortcuts… double-tap-modifier triggers").
- The Home and HeyClicky window also have an "Ask HeyClicky…" field next to a "Hold control + option to talk" pill.

**Audio handling:** Bluetooth pre-roll and profile-switch timing. Mic failover to the built-in mic. Lid-closed mic switch. Pro audio interfaces. Muted Mac puts the answer on the clipboard. "Quiet on calls" (call and screen-share detection). Recording apps aren't calls.

### G. Onboarding flow and settings

**Onboarding (current, Oct 23 onward)**
- "Onboarding skips the style step, shows HeyClicky driving and dictation, and ends by drawing where you're headed."
- **Windows screens (Nov 6):** a founder video card that "glides beside your cursor", then welcome, color, "give me a home", then "I live in your notch now".
- **Setup (for-mac):** "download the app, drag it into applications and sign in. allow the microphone, accessibility and screen recording… after that it updates itself."
- **Windows:** "download the installer, open it and sign in." The FAQ handles SmartScreen ("click more info, then run anyway").

**History**
- **Jul 17:** a 2-minute hands-on tutorial: say hello, watch it draw, circle and ask, draft an email reply by voice, dictate in a real text box.
- **Sep 12:** character style, four questions, three personalized Clickys. It doesn't spend your allowance.
- **Sep 18:** Replay the welcome tour. Skip the interview by voice. Automatic Termination opt-out.
- **Sep 24:** Farza's two default Clickys first. Three first tasks with different endings.
- **Oct 2:** first routine asks first. Interview freeze fixed.
- **[prior research, Sep 2026 reviews]:**
  1. Welcome with Google sign-in, then "How'd you find this?", "Give me a home", and (in July) "Pick a color" (red, blue, amber, green).
  2. The notch panel walks through Accessibility, then Screen Recording, then "Complete screen access", and adds a login item.
  3. A ~2-minute Farza bubble video plays while really acting on the Mac.
  4. A 7-step tutorial: mic test (warns Bluetooth mics are flaky), hold Control+Option, four questions leading to 3 agents, "I can draw on your screen", "Circle anything, ask about it", "Double-tap control to type".
  5. A notch and Home tour.
- Lenny Rachitsky (homepage testimonial): "my new favorite onboarding experience."

**Settings map** (compiled from the changelog):
- **General:** Quick peek on notch hover. Replay the welcome tour. Install & Relaunch / Check for Updates (inline result). Show in Dock. Login item behavior.
- **Voice:** Voices (130+ languages, 30 native voices, previews). Speed 0.5x-1.5x. Captions while HeyClicky talks.
- **Dictation:** Dictionary (shown first since Nov 6). Language (83 languages, default override).
- **Shortcuts:** push-to-talk, text mode, dictation and hands-free. Held combos or double-taps.
- **Cursor:** color picker. Customization. Hide floating cursor (formerly "Dock cursor").
- **Agents:** Announcements (spoken updates / Show updates beside the cursor). Always approve (agent messages). Always approve file uploads. Suggestions on/off.
- **Routines:** list, change, pause, delete.
- **Integrations:** per-app accounts, labels, Add another account, Reconnect, custom MCP connector (URL or command, browser auth or API key, token validation).
- **Files & Folders** permissions.
- **Account:** Log Out (shows email), Delete Account (also clears local Clickys, analytics and marketing list).
- **Support & Updates:** changelog link, Feature Request, Community (WhatsApp), Report a bug (attaches logs).
- **Invite & earn:** username and link.
- **Other:** legacy toggle (older work). Microphone selection. Cmd+, opens Settings.

**Global shortcuts (Mac)**

| Key | Action |
|---|---|
| Hold Control + Option, release | Talk (and draw a spatial-context trail while held) |
| Double-tap Control | Text box |
| Hold Fn + Control | Dictate |
| Double-tap Fn + Control | Hands-free dictation (again to stop) |
| Control ×3 | Always-on (headphones) |
| Control + Command + A | Open Home |
| Cmd + , | Settings |
| Escape | Take back control from a drive, close the panel, drop a card follow-up |
| ← / → | Flip agent cards under the notch |

On Windows the assistant key is Ctrl + Alt [prior research].

---

## 4. Other site facts relevant to parity
- **Platforms:** macOS Sonoma 14.2+ (Apple Silicon and Intel) and Windows 10/11. One account works on both. The Chrome extension listing says Mac only. **iOS:** Farza replied "ios next month" (Oct 29). The careers page lists a mobile engineer role.
- **Homepage claims:** "25,000+ happy users". Feature blocks: "finally do the thing" (FL Studio to Claude Code, it "draws on your screen and teaches you"), "use your screen as context", and "spawn agents with your voice… no terminal needed. connect your gmail or notion."
- **Trust page:**
  - It only sees your screen when asked. Screenshots aren't kept. Conversations are kept.
  - Providers: OpenAI, Anthropic, Google. No training on your data. No selling data.
  - "heyclicky doesn't track what you do." The Chrome extension only works in task tabs.
  - **No SOC 2 or ISO 27001 yet.**
- **Privacy policy (Nov 10, 2026):**
  - Infrastructure: Supabase, Cloudflare, Vercel. Stripe, Loops, PostHog, Sentry.
  - Ad pixels: Meta, Google, LinkedIn, X.
  - "a small helper that Chrome keeps open" (the native-messaging host) is the only thing running after quit.
  - Runs "lightweight checks, like noticing when you're on a call."
  - Ages 13+.
- **Terms:** Mac needs Accessibility for shortcuts and typing. Uninstall paths are given. "Don't reverse engineer… the desktop app."
- **About page:** a 2025 timeline (Sep 14, 2025 "the beginning"; Oct 2 "right by your cursor"; Nov 18 "it draws"; Dec 9 "hands-free"). This conflicts with the changelog's Apr 6, 2026 launch, so treat it as marketing.
- **Company:** Humansongs, Inc. (Delaware), San Francisco. YC-backed.
- **Careers:** product engineer, mobile engineer, designer, ads, IG + TikTok creator, intern (0.25-2.5% equity).
- **Open source:** github.com/farzaa/clicky is the original April codebase. "for all the new stuff I'm hacking on, gonna keep it private."

---

## 5. Parity checklist (my distillation for planning)
1. **Voice loop:** push-to-talk on modifier chords, realtime speech in and out, a single strong model ("one brain"), screenshot on the hotkey only, answers starting in about 2 s, barge-in and echo cancellation, captions, voice speed, 130+ language TTS with native voices.
2. **Dictation:** hold and hands-free chords, streaming STT (~450 ms), a separate cleanup LLM with a faithful no-rewrite prompt (no em dashes), direct field typing with a layout-aware paste fallback, transient clipboard handling, terminal newline collapse, auto-dictionary learned from edits within ~20 s, 83 languages with code-switching, local transcript backup, sessions over 10 minutes.
3. **Screen-aware writing:** screenshot plus memory plus optional style skill, inserted into the focused field.
4. **Drawing:**
   - Overlay layer for hand-drawn (rough) annotations anchored to screen coordinates, with lifecycle rules (2 s highlights, shapes clear after speech).
   - Floating draggable explainer cards (grid paper, handwritten font, progressive build, photos, charts).
   - A native 3D renderer for model-generated part-labeled scenes with rotate, drag and click-to-ask, plus a GPU fallback.
   - Speech-synced timeline, saved to chat with Replay and MP4 export, and follow-up chips.
5. **Walkthroughs:** per-app skill injection by bundle ID or site, target rings, click-detection to advance, up to 15 steps, a progress log, re-check of the screen before each step.
6. **Spatial context:** a cursor paint trail while the hotkey is held, sent as a region to the model and agents.
7. **Agents:** persistent named agents (memory, files, AGENTS.md), a minimal harness, a per-job message budget and refunds, routines (natural-language schedules, failure pause, wake and network gating), multi-account connectors (Composio-like), custom MCP (URL or stdio), suggestions pipeline (optional).
8. **Drive:** consent card, visible driving state, Escape/mouse/voice takeover, background-scoped clicks.
9. **Chrome extension:** native messaging, debugger-based control in a named tab group, page glow and agent cursor, secrets handed back to the user, file-upload consent.
10. **Memory:** PROFILE.md (sectioned, never truncated mid-section) and VOLATILE.md, injected into both the voice model and agents, plus a 40-message recent window and screen recall.
11. **Shell:** notch home with peek, a resizable window, ←/→ cards, settings as listed in G, Sparkle auto-update (idle 5 min), Windows installer and updater.
