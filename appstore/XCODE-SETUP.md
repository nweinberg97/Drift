# Drift in Xcode, step by step

A walkthrough to follow on your Mac with HeyClicky watching your screen. Keep this page open beside Xcode. Each step says **what to do**, **what to say to Clicky** if you get stuck, and **how you know it worked**.

Time: about 45 minutes the first time, plus Apple's waiting times (enrollment and review).

**Before you start, you need:**

- A Mac on a recent macOS (the current Xcode needs macOS 15 or newer) with about 40 GB free.
- Your Apple ID with two-factor authentication on.
- For selling as Forth Ventures: the Apple Developer account enrolled as an **Organization** (see the launch plan). You can do Parts A–C with a free Apple ID while you wait for that.

---

## Part A: Get the project open

### A1. Install Xcode

1. Open the **App Store** app, search **Xcode**, click **Get** / **Install**.
2. When it finishes, open Xcode once. If it asks to install additional components or platforms, click **Install** (macOS is all you need).

> **Say to Clicky:** "I'm installing Xcode from the App Store, show me where to click."
>
> **It worked when:** Xcode opens to its "Welcome to Xcode" window.

### A2. Download the code

1. Open **Terminal** (⌘ Space, type Terminal, Return).
2. Paste this and press Return:

   ```
   cd ~/Developer 2>/dev/null || mkdir -p ~/Developer && cd ~/Developer
   git clone https://github.com/nweinberg97/Drift.git
   open Drift/Drift.xcodeproj
   ```

3. If macOS asks to install the command line developer tools, click **Install**, wait, then paste the lines again.
4. If the repo is private and Terminal asks for a password, run `gh auth login` first (or ask Clicky: "help me sign in to GitHub in Terminal").

> **Say to Clicky:** "I'm cloning a GitHub repo in Terminal and opening the Xcode project."
>
> **It worked when:** Xcode opens a window titled **Drift** with a file list on the left.

### A3. Know your way around (30 seconds)

- **Left sidebar (Navigator):** the files. The blue **Drift** icon at the top is the project.
- **Top bar:** the **▶ Run** button, then the **scheme** (should say **Drift**) and the **destination** (should say **My Mac**).
- **Middle:** the editor. **Right sidebar:** inspectors (you won't need them).

> **Say to Clicky:** "Point out the Run button, the scheme menu and the project navigator."

---

## Part B: Sign in and run it

### B1. Add your Apple ID to Xcode

1. Menu bar: **Xcode → Settings…** (⌘ ,) → **Accounts** tab.
2. Click **+** at the bottom left → **Apple ID** → **Continue** → sign in.
3. Close Settings.

> **It worked when:** your name (and later "Forth Ventures") is listed under Accounts with a team.

### B2. Pick your team for signing

1. In the left sidebar click the blue **Drift** project icon.
2. In the middle, under **TARGETS**, click **Drift** (not DriftCore).
3. Click the **Signing & Capabilities** tab.
4. Check **Automatically manage signing** is on.
5. **Team:** choose **Forth Ventures** (or your personal team until the organization account is ready).
6. **Bundle Identifier** should read **com.forthventures.drift**. Don't change it: it's permanent once uploaded.

> **Say to Clicky:** "I'm on Signing & Capabilities for the Drift target; help me pick my team."
>
> **It worked when:** no red errors show under Signing. ("Provisioning profile: Xcode Managed Profile" is good.)

You'll also see **App Sandbox** (with Audio Input ticked) and **Hardened Runtime** here. Leave them as they are.

### B3. Run it with test purchases

1. Top bar: scheme **Drift**, destination **My Mac**.
2. Check the purchases test file is attached: **Product → Scheme → Edit Scheme…** → **Run** (left) → **Options** tab → **StoreKit Configuration** should say **Drift.storekit**. If it says None, pick **Drift.storekit** from the menu. Click **Close**.
3. Press **▶ Run** (⌘ R). The first build takes a minute or two.
4. If you already have Drift installed from the install script, quit it first (menu bar icon → Quit) so the two don't fight over ⌥ Space.

> **It worked when:** the Drift icon appears in your menu bar and the Welcome window opens.

### B4. Test the paywall and purchases (no real money)

With Drift.storekit attached, every purchase is fake and free.

1. Press **⌥ Space**, type `Test 1m`, press Return. The **Unlock Drift** window should open (no trial or plan yet).
2. Click **Try everything free for 7 days** → confirm. The window closes; start the timer again and it runs.
3. Test buying: menu bar: **Debug → StoreKit → Manage Transactions…** shows what you've "bought". Select the trial and click the **delete** (trash) button to remove it, then repeat step 1 and buy **Yearly** or **Lifetime** instead.
4. Test the trial running out: in **Manage Transactions**, delete the trial, or in the Edit Scheme StoreKit options set a faster time rate for subscriptions.
5. **Settings → Purchase** should show your plan, **Restore Purchases**, and **Manage Subscription** for a subscription.

> **Say to Clicky:** "I'm testing StoreKit purchases in Xcode. Show me the Manage Transactions window."
>
> **It worked when:** each plan unlocks Drift, and deleting the transaction locks it again.

**Take the review screenshot now:** with the paywall open, press **⌘ Shift 4**, then **Space**, then click the paywall window. Save it; App Store Connect asks for it on each in-app purchase.

---

## Part C: App Store Connect setup (in the browser)

Needs your paid developer account. Open **appstoreconnect.apple.com**.

### C1. Agreements, tax and banking

1. **Business** (or **Agreements, Tax, and Banking**) → **Paid Apps** → **View and Agree to Terms**.
2. Add the **bank account** and the **tax forms** (W-8BEN-E for a Canadian company).
3. Then apply for the **App Store Small Business Program** at developer.apple.com/app-store/small-business-program (15% instead of 30%).

> **It worked when:** Paid Apps shows **Active**. (Can take a day.)

### C2. Create the app record

1. **Apps → + → New App**.
2. **Platforms:** macOS. **Name:** your cleared name, e.g. "Driftwell – Focus Timer" (see `listing.md`). **Primary language:** English (U.S.). **Bundle ID:** com.forthventures.drift. **SKU:** forth-drift-mac-1. **User access:** Full.
3. Click **Create**. The name is now reserved for you.

> **Say to Clicky:** "I'm creating a new macOS app in App Store Connect; help me fill the form."

### C3. Create the four in-app purchases

Use the table in `appstore/listing.md` → Pricing. The **Product IDs must match exactly**.

1. Left sidebar: **Monetization → In-App Purchases → +**: create **drift.trial** (Non-Consumable, price **Free**) and **drift.lifetime** (Non-Consumable, $4.99).
2. **Monetization → Subscriptions → Create** a group **Drift Pro**, then add **drift.pro.yearly** (1 year, $9.99) and **drift.pro.monthly** (1 month, $1.99). Don't add introductory offers.
3. For each one: display name, description, **Review Screenshot** (from B4), review notes from `listing.md`.
4. Turn on **Family Sharing** for Lifetime and both subscriptions.

> **It worked when:** all four show **Ready to Submit**. (They're submitted together with the first app version.)

### C4. Fill in the listing

From `appstore/listing.md` and `appstore/app-store-connect.md`: subtitle, promotional text, description, keywords, support / marketing / privacy URLs, category, age rating (4+), App Privacy (**Data Not Collected**), copyright, and the six screenshots in `appstore/screenshots/` in the listed order.

---

## Part D: Upload a build

### D1. Set the version

In `scripts/gen-xcodeproj.py`, `marketing_version` is **1.0** and `build` is **1**. For every new upload, raise `build` (2, 3, …) and run `python3 scripts/gen-xcodeproj.py` in Terminal from the Drift folder. Or change **Version** / **Build** in the Drift target's **General** tab.

### D2. Archive

1. Top bar destination: choose **Any Mac (Apple Silicon, Intel)**.
2. Menu: **Product → Archive**. Wait for **Archive Succeeded**; the **Organizer** window opens.

> **Say to Clicky:** "Where do I choose Any Mac as the destination, and where's Product → Archive?"

### D3. Upload

1. In the Organizer, select the new archive → **Distribute App**.
2. Choose **App Store Connect** → **Distribute** (keep the defaults: upload symbols, automatic signing).
3. Wait for "Uploaded". Apple emails you when the build has finished processing (10–30 minutes).

> **It worked when:** App Store Connect → your app → **TestFlight** shows build 1.0 (1).

### D4. TestFlight (recommended)

1. **TestFlight → Internal Testing → +** → add yourself → install **TestFlight** from the Mac App Store → install Drift from it.
2. Purchases in TestFlight use the sandbox: free, and subscriptions renew every few minutes.
3. Add external testers (friends, the waitlist) with a public link; the first external build gets a quick Beta Review.

---

## Part E: Submit

1. App Store Connect → your app → **macOS App → 1.0 Prepare for Submission**.
2. **Build:** click **+** and pick the uploaded build.
3. **In-App Purchases and Subscriptions:** add all four so they're reviewed with the app.
4. **App Review Information:** contact details and the reviewer notes from `listing.md`.
5. **Version Release:** choose **Manually release** so you control launch day.
6. Click **Add for Review** → **Submit**.

Review usually takes one to three days. If it comes back with questions, the "If App Review pushes back" section of `appstore/README.md` has answers for the usual ones.

---

## If something goes wrong

| What you see | What to do |
|---|---|
| Red "No account for team" or "Signing requires a development team" | Part B1–B2 again; pick a team. |
| "No such module" or build errors after pulling new code | **Product → Clean Build Folder** (⌘ ⇧ K), then Run. Still failing? Copy the first red error and send it to Claude. |
| Paywall shows "The App Store didn't respond" when running from Xcode | Edit Scheme → Run → Options → StoreKit Configuration → **Drift.storekit**. |
| ⌥ Space does nothing | Another Drift (or Raycast/Alfred) has it. Quit the other one. |
| Upload says the bundle ID isn't available | The App Store Connect app record (C2) must use com.forthventures.drift, under the same team as in Xcode. |
| "Invalid binary: missing purpose string" | Shouldn't happen (they're in Info.plist). Send the email to Claude. |
