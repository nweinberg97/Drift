# Getting Drift onto the Mac App Store

Everything that can be prepared without your Apple account is done. This is the part only you can do, in order. Budget about an hour of clicking, plus Apple's waits (enrollment: a day or two; review: usually one to three days).

What's in this folder:

| File | What it's for |
|---|---|
| `README.md` | This guide |
| `listing.md` | Name, subtitle, description, keywords, URLs, review notes, ready to paste |
| `app-store-connect.md` | Answers to App Store Connect's questionnaires (privacy, age rating, export, pricing) |
| `screenshots/` | Five 2880×1800 screenshots, rendered from the real app |

And in the repo:

| Path | What it is |
|---|---|
| `Drift.xcodeproj` | The App Store build. Open this in Xcode. |
| `packaging/AppStore/Config/Info.plist` | Store Info.plist (version, usage strings, export compliance) |
| `packaging/AppStore/Config/Drift.entitlements` | Sandbox + microphone. Nothing else. |
| `packaging/AppStore/Resources/` | App icon (asset catalog) and the privacy manifest |
| `scripts/gen-xcodeproj.py` | Regenerates the project; holds version, build number, team |
| `scripts/rename.py` | Renames the app everywhere if you pick a new name |

---

## 1. Join the Apple Developer Program ($99/year)

1. Go to **developer.apple.com/programs/enroll** and sign in with your Apple ID (it needs two-factor authentication turned on).
2. Choose **Individual** (your name shows as the seller; fastest) or **Organization** (your company name shows; needs a free D-U-N-S number first, which can take a week or more).
3. Pay and wait for the confirmation email.

## 2. Install Xcode

Free from the Mac App Store. It's large; start it while you wait for step 1. You need Xcode 16 or newer.

## 3. Get the code onto your Mac

In Terminal:

```bash
git clone https://github.com/nweinberg97/Drift.git
open Drift/Drift.xcodeproj
```

(If the repo is private by then, use GitHub Desktop or `gh repo clone nweinberg97/Drift`.)

## 4. Sign in and pick your team (once)

1. Xcode → **Settings → Accounts** → **+** → Apple ID → sign in.
2. In the project navigator click **Drift** (the blue project icon) → target **Drift** → **Signing & Capabilities**.
3. **Team:** choose your name or company. Leave "Automatically manage signing" on.
   Xcode registers the bundle ID `com.nweinberg.drift` for you.

Try it: press **⌘R**. Drift runs from Xcode exactly as the store version will (sandboxed). Quit it from its menu bar icon.

## 5. Create the app in App Store Connect

1. **appstoreconnect.apple.com → Apps → + → New App**
2. Platform **macOS**; Name from `listing.md`; Primary language English (U.S.); Bundle ID **com.nweinberg.drift**; SKU `drift-mac-1`; User access: Full.
3. Fill in, using `listing.md` and `app-store-connect.md`:
   - **App Information:** subtitle, categories, content rights, age rating
   - **Pricing and Availability:** $4.99, all regions
   - **App Privacy:** privacy policy URL, then "No, we do not collect data"
   - **macOS App → 1.0:** screenshots, promotional text, description, keywords, support and marketing URLs, copyright, review notes and your contact details

## 6. Upload the build

1. In Xcode's toolbar choose the **Drift** scheme and **Any Mac** as the destination.
2. **Product → Archive.** When it finishes, the Organizer opens.
3. **Distribute App → App Store Connect → Distribute.** Accept the defaults.
4. Wait for the email "has completed processing" (10–30 minutes).

## 7. Test it (recommended)

In App Store Connect → **TestFlight**, add yourself as an internal tester, then install the **TestFlight** app on your Mac and install Drift from it. This is exactly what buyers will get.

## 8. Submit for review

App Store Connect → your app → **macOS App 1.0** → **Build** → pick the build you uploaded → **Add for Review** → **Submit**.

Choose "Manually release" if you want to pick the launch moment, or "Automatically release" to go live as soon as it's approved.

## 9. After approval

Tell me the App Store link. I'll switch the website's Terminal install for an App Store button (it's already built in, just hidden) and update the README.

---

## Later: updates

1. Bump the version in `scripts/gen-xcodeproj.py` (`marketing_version`, e.g. 1.1, and `build`, e.g. 2), then run `python3 scripts/gen-xcodeproj.py`. Or just change Version and Build in Xcode's General tab.
2. Archive and upload as in step 6.
3. In App Store Connect add a new version, write "What's New", pick the build, submit.

Every upload needs a higher build number than the last.

## Later: a new name

```bash
python3 scripts/rename.py "New Name"
python3 scripts/gen-xcodeproj.py
```

That updates the app's name (menus, windows, the .app itself), the website and `listing.md`. The bundle ID stays the same, which is fine; it's never shown to anyone.

## If App Review pushes back

Most common for a menu-bar app is "we couldn't find the app's interface". The welcome window and the review notes in `listing.md` cover that; reply in Resolution Center pointing to the menu bar icon and Option-Space. Send me the message if anything else comes up.
