# App Store listing

Everything to paste into App Store Connect. Character limits are Apple's; every field here fits.
Where it says **Drift**, use the final name if it changes (`scripts/rename.py` updates the app and website; this file too).

---

## App information

| Field | Value |
|---|---|
| **Name** (30) | Drift: Focus Timer |
| **Subtitle** (30) | Timeboxing from any app |
| **Primary category** | Productivity |
| **Secondary category** | Utilities |
| **Bundle ID** | com.nweinberg.drift |
| **SKU** (private, anything unique) | drift-mac-1 |
| **Content rights** | Does not contain, show or access third-party content |
| **Age rating** | 4+ (answer "None" / "No" to every question; see `app-store-connect.md`) |
| **Copyright** | 2026 *your legal name or company* |

> "Drift" alone is very likely taken on the App Store, so the store name adds a short descriptor. The name on your Mac stays "Drift". If you rename, try `Name: Focus Timer` first.

## Pricing

| Field | Value |
|---|---|
| **Price** | $4.99 (USD), paid up front |
| **Availability** | All countries and regions |
| **In-app purchases** | None |

## URLs

| Field | Value |
|---|---|
| **Support URL** | https://nweinberg97.github.io/Drift/support.html |
| **Marketing URL** | https://nweinberg97.github.io/Drift/ |
| **Privacy Policy URL** | https://nweinberg97.github.io/Drift/privacy.html |

(When you get a domain, update these three and the website.)

---

## Promotional text (170, can change any time without review)

Press ⌥ Space, write what you're working on and for how long, and get back to it. Plan your day in plain words and each block starts on time.

## Keywords (100 bytes, comma-separated, no spaces needed)

```
timer,focus,pomodoro,timebox,time blocking,productivity,menu bar,planner,schedule,deep work,routine
```

## Description (4000)

```
Drift is a quiet focus timer that lives in the corner of your screen.

Press ⌥ Space from any app, write what you're working on and for how long, and press Return. "Write intro 45m". "Email 25m". "Reading for an hour and a half". The timer starts in a small widget at the top left, named for your task, and you get back to work.

WRITE IT THE WAY YOU'D SAY IT
• The time lights up as you type, so you can see Drift understood.
• Leave out the time and it offers your default. Press Tab to take it.
• In a hurry? Type 25. Name it later.
• Recent tasks are one click away.
• Press ⌥ Space twice and just say it. Speech is recognised on your Mac.

PLAN YOUR DAY
• Type when instead of how long: "Deep work 9–10:30 weekdays", "Gym 6–7pm mon wed fri", "Email at 1pm for 30m".
• When a block comes up, Drift asks: Start, five more minutes, or skip today. Ignore it and it starts by itself.
• Each block ends on schedule, so starting late keeps your time box.
• Drag a block on its timeline to move it, for today only or every day it repeats.

CHANGE IT WITHOUT STOPPING
• Click the name to rename it in place.
• Click the time to turn the dial: a minute per notch, or tap 5, 10, 15, 20, 25, 30, 45 minutes, 1 or 2 hours.
• Add or take off five minutes.
• Run several timers. One stays in view; the rest wait underneath.

STAYS OUT OF YOUR WAY
• No Dock icon and no windows to manage.
• ⌥ T hides the widget; the time moves to the menu bar.
• Pomodoro built in: focus, break, and a longer break every fourth round.
• A soft chime that repeats until you look, and a nudge if you want five more minutes.
• Optional focus sounds, made live on your Mac: rain, ocean, fireplace, lo-fi, ambient, soft pad, Hush, and binaural beats.

PRIVATE BY DESIGN
• No account. No analytics. No network access at all.
• Timers, plans and settings stay on your Mac.
• Voice works on-device and only while you're talking.

Works with Shortcuts, Siri and Raycast through drift:// links.

One price. No subscription.
```

## What's New (for later versions)

```
First release.
```

---

## Screenshots

Use the five files in `appstore/screenshots/` (2880 × 1800, Apple's largest Mac size; App Store Connect scales them for smaller sizes). Upload in this order:

1. `store-1-launcher.png`: Write the task. Drift keeps the time.
2. `store-3-plan.png`: Plan your day. Blocks start on time.
3. `store-2-dial.png`: Click the time. Turn the dial.
4. `store-4-several.png`: Name it in place. Run several at once.
5. `store-5-sound.png`: Soft focus sound, made on your Mac.

They're rendered from the app's real interface by CI on every push, so they stay current: see the `ci-snapshots` branch.

---

## App Review information

**Sign-in required:** No.

**Notes for the reviewer** (paste as is):

```
Drift is a menu-bar utility (no Dock icon). On first launch a "Welcome to Drift" window explains everything; it can be reopened any time from the menu bar icon → Getting Started.

How to test in under a minute:
1. Press Option-Space from any app. Type "Write intro 25m" and press Return. A timer appears in the small widget at the top left of the screen.
2. Click the timer's name to rename it. Click its time to open a dial for changing it.
3. Press Option-Space and type "Review at 3pm for 15m" (use a time a minute or two from now). When the time comes, Drift shows a card with Start / In 5 min / Skip today; if ignored it starts by itself after a minute.
4. Option-T hides and shows the widget. Everything is also in the menu bar icon.

Microphone and speech recognition are optional: they're only requested if you press the microphone button or press Option-Space twice to speak a timer. Recognition is on-device.

The app has no network access, no account and collects no data. drift:// links let Shortcuts start timers; links can only start, pause, resume, extend or show timers.
```

**Contact:** your name, phone and email (Apple uses these only to reach you about the review).
