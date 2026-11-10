# App Store listing

Everything to paste into App Store Connect. Character limits are Apple's; every field here fits.
Where it says **Drift**, use the final name once it clears (`scripts/rename.py` updates the app and website; update this file too).

---

## App information

| Field | Value |
|---|---|
| **Name** (30) | Drift – Focus Timer *(placeholder until the name clears; e.g. "Driftwell – Focus Timer")* |
| **Subtitle** (30) | Calm timeboxing for your Mac |
| **Primary category** | Productivity |
| **Secondary category** | Utilities |
| **Bundle ID** | com.forthventures.drift *(permanent once uploaded; it never shows to customers)* |
| **SKU** (private, anything unique) | forth-drift-mac-1 |
| **Content rights** | Does not contain, show or access third-party content |
| **Age rating** | 4+ (answer "None" / "No" to every question; see `app-store-connect.md`) |
| **Copyright** | 2026 Forth Ventures Inc. *(the exact legal name from incorporation)* |

> "Drift Focus: Study Timer" and "DRIFT: Tide Focus Timer" are already on the App Store, and Drift.com/Salesloft own DRIFT for software. Keep "Mac" out of the name (it's fine in the subtitle). See the launch-plan doc, "Name and trademark".

## Pricing

The app is a **free download** that unlocks with in-app purchases. Price: **Free**. Availability: all countries and regions.

### In-app purchases (create these exactly; the IDs are in the code)

| Reference name | Product ID | Type | Price | Display name (30) | Description (45) |
|---|---|---|---|---|---|
| 7-Day Free Trial | `drift.trial` | Non-Consumable | Free | 7-Day Free Trial | Every feature, free for 7 days. No renewal. |
| Lifetime | `drift.lifetime` | Non-Consumable | $4.99 | Drift Lifetime | Every feature, forever. One-time purchase. |
| Pro Yearly | `drift.pro.yearly` | Auto-Renewable Subscription | $9.99 / 1 year | Drift Pro Yearly | Every feature. Renews every year. |
| Pro Monthly | `drift.pro.monthly` | Auto-Renewable Subscription | $1.99 / 1 month | Drift Pro Monthly | Every feature. Renews every month. |

- **Subscription group:** reference name "Drift Pro", display name "Drift Pro". Put Yearly at level 1 and Monthly at level 2.
- **No introductory offers** on the subscriptions: the free trial is the `drift.trial` purchase, which needs no card and never renews (App Review Guideline 3.1.1 allows this for a free trial).
- **Family Sharing:** turn on for Lifetime and both subscriptions.
- **Review screenshot** for each product: `50-paywall.png` from the `ci-snapshots` branch (the paywall as it appears in the app).
- **Review notes** for each product: "Unlocks every feature of the app. The paywall opens when you start a timer without an active plan, or from the menu bar icon → Unlock / Start Free Trial."
- **After launch week:** remove Lifetime from sale (Pricing and Availability → Remove from sale). The app hides it automatically and people who bought it keep it.

## URLs

| Field | Value |
|---|---|
| **Support URL** | https://nweinberg97.github.io/Drift/support.html *(move to your domain)* |
| **Marketing URL** | https://nweinberg97.github.io/Drift/ |
| **Privacy Policy URL** | https://nweinberg97.github.io/Drift/privacy.html |
| **License agreement** | Apple's Standard EULA (leave the default). The paywall links to it. |

For an app with subscriptions, the description must also include the Terms of Use (EULA) and privacy links: they're at the bottom of the description below.

---

## Promotional text (170, can change any time without review)

Launch week: lifetime price, launch week only.

```
Launch week: get Drift for life for $4.99, once. Or try every feature free for 7 days. Write what you're working on, and Drift keeps the time.
```

After launch:

```
Plan a work session on a timeline, line up time blocks that hand off on their own, and get back to work. Free for 7 days.
```

## Keywords (100, comma-separated, no spaces)

Don't repeat words already in the name or subtitle (focus, timer, timeboxing, Mac, calm).

```
pomodoro,time blocking,deep work,planner,routine,menu bar,productivity,schedule,countdown,study,adhd
```

## Description

```
Drift is a calm focus timer that lives in the corner of your screen.

Press ⌥ Space in any app, write what you're working on and for how long, and press Return. "Reply to emails 25m." "Draft proposal 45m." A small timer appears, named for your task, and you get back to work.

TRY EVERYTHING FREE FOR 7 DAYS
No card needed. Then choose Lifetime, Yearly or Monthly. Every feature is in every plan.

START, POMODORO OR PLAN
With nothing running, the widget offers three ways in:
• Start now: one tap for 25 minutes, a quick length, or the dial for any length.
• Pomodoro: 25/5, 50/10 or 90/15 cycles.
• Plan: a work session later today, a routine that repeats, or write your own.

TIME BLOCKS THAT HAND OFF ON THEIR OWN
• "Morning startup: inbox 10m, plan the day 10m, review calendar 5m." One session, three blocks.
• Each block starts as the one before it ends, with a short card saying what's next.
• Blocks don't stretch unless you allow it, so your day stays on plan.
• Named sessions are saved for one-click reuse.

PLAN A WORK SESSION ON A TIMELINE
• Drag either end to resize, the middle to move.
• Time blocks show as segments: drag a divider, or click + to add one.
• Step by 1, 5 or 10 minutes, or click a time and type it.
• Plan for later today, or make it a routine for your weekdays.
• When it's time, Drift asks. Ignore it and it starts by itself.

WRITE IT THE WAY YOU'D SAY IT
• "Client call at 2pm for 30m" is planned for later today.
• "Deep work 9–10:30 weekdays" becomes a routine.
• Durations light up in orange, times of day in blue, so you can see Drift understood.
• Press ⌥ Space twice and just say it. Speech is recognised on your Mac.

CHANGE IT WITHOUT STOPPING
• Click the name to rename it. Click the time to turn the dial, or double-click to type it.
• Add or take off five minutes, or run several timers at once.

HARD TO MISS WHEN TIME'S UP
• The widget shakes until you touch it, so you notice even with the sound off.
• A soft chime, a notification, and a big Done button.

STAYS OUT OF YOUR WAY
• No Dock icon and no windows to manage. ⌥ T hides the widget; the time moves to the menu bar.
• Turn off what you don't use (planning, Pomodoro, focus sounds, voice) and it disappears everywhere.
• Focus sounds made live on your Mac: rain, ocean, fireplace, lo-fi, Hush and more.

PRIVATE BY DESIGN
• No account, no ads, no analytics. The app has no network access.
• Timers, sessions, plans and settings stay on your Mac.

Works with Shortcuts, Siri and Raycast through drift:// links.

Subscriptions renew automatically until cancelled in your App Store account settings. Lifetime is a one-time purchase.
Terms of Use: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
Privacy: https://nweinberg97.github.io/Drift/privacy.html

Drift is made by Forth Ventures.
```

## What's New (for later versions)

```
First release.
```

---

## Screenshots (up to 10; use these 6 in this order)

All 2880 × 1800 (16:10), rendered from the app's real interface by CI on every push (`ci-snapshots` branch), copied into `appstore/screenshots/`.

| # | File | Headline on the image |
|---|---|---|
| 1 | `store-1-launcher.png` | Type your plan. Drift keeps the time. |
| 2 | `store-2-session.png` | Time blocks that hand off on their own. |
| 3 | `store-3-planner.png` | Plan a session. Drag it into place. |
| 4 | `store-4-today.png` | Today at a glance. Routines repeat. |
| 5 | `store-5-dial.png` | Click the time. Turn the dial. |
| 6 | `store-6-pomodoro.png` | Pomodoro and soft focus sounds. |

**App preview (optional, up to 3 × 30 s):** a 15–20 second screen recording: ⌥ Space → type "Inbox 1m, plan the day 1m" → Return → the hand-off card → Session complete. Record at 1920 × 1200 or larger; it autoplays muted, so no voice-over.

---

## App Review information

**Sign-in required:** No.

**Notes for the reviewer** (paste as is):

```
Drift is a menu-bar utility (no Dock icon). On first launch a "Welcome" window explains everything; reopen it from the menu bar icon → Help → Getting Started.

In-app purchases: the app is free to download. Starting a timer without a plan opens the paywall, which offers a free 7-day trial (a $0 non-consumable, no renewal), Lifetime (non-consumable) and Pro Monthly/Yearly (auto-renewable, one group). Restore Purchases, Terms of Use and Privacy links are on the paywall and in Settings → Purchase. The paywall is also in the menu bar → Start Free Trial / Unlock.

How to test in under a minute (start the free trial first):
1. Press Option-Space from any app. Type "Reply to emails 25m" and press Return. A timer appears in the widget at the top left.
2. Click the timer's name to rename it. Click its time to open the dial; double-click it to type a time.
3. Press Option-Space, type "Inbox 1m, plan the day 1m" and press Return. When the first block ends, a card shows what's next and starts it. At the end the widget shakes and shows Session complete.
4. In the widget with nothing running, choose Plan → Today. Drag the session on the timeline and click Plan it. When the time comes, Drift shows Start / In 5 min / Skip today; if ignored it starts by itself after a minute.
5. Option-T hides and shows the widget. Everything is also in the menu bar icon.

Microphone and speech recognition are optional: they're only requested if you press the microphone button or press Option-Space twice. Recognition is on-device.

The app has no network entitlement, no account and collects no data. Purchases use StoreKit only. drift:// links can only start, pause, resume, extend or show timers.
```

**Contact:** your name, phone and a support email on your domain (Apple uses these only to reach you about the review).
