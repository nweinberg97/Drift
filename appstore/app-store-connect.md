# App Store Connect answers

The questionnaires App Store Connect asks, with Drift's answers. Each one is true because of how the app is built; the reason is beside it.

## App Privacy ("nutrition label")

**Do you or your third-party partners collect data from this app?** → **No, we do not collect data from this app.**

That's the whole questionnaire: the label will read **Data Not Collected**.

Why it's true: the app has no network entitlement (it physically can't send anything), no analytics or crash-reporting SDKs, and no account. Timers, plans and settings stay in the app's own container on the Mac. Voice is recognised on-device (`requiresOnDeviceRecognition`) and never stored. The bundled `PrivacyInfo.xcprivacy` says the same: no tracking, no collected data, and one "required reason" API (UserDefaults, reason CA92.1: the app's own settings).

## Age rating

Answer **None** to every content question (violence, profanity, horror, mature themes, gambling, etc.) and **No** to:

- Unrestricted web access → No
- User-generated content / messaging → No
- Contests, gambling → No
- Medical or treatment information → No

Result: **4+**.

## Export compliance

The Info.plist sets `ITSAppUsesNonExemptEncryption = NO`, so App Store Connect won't ask on each upload. If it ever does: **"None of the algorithms mentioned above"**. Drift uses no encryption of its own (and no network at all).

## Content rights

**Does your app contain, show, or access third-party content?** → **No.** All sounds are generated live by the app; there are no bundled recordings, fonts or images from others.

## Pricing and availability

- Price: **USD 4.99** (Apple shows the matching price in each country)
- Availability: **All countries or regions**
- Pre-order: off (optional)

## Mac App Store specifics

- **Category:** Productivity (secondary: Utilities)
- **Minimum macOS:** 13 Ventura (set in the project)
- **Apple silicon and Intel:** both (universal build by default when archiving)
- **App Sandbox:** on. Entitlements: `app-sandbox`, `device.audio-input` (microphone, only for voice). Nothing else.
- **Uses Apple Sign In / Game Center / In-App Purchase / iCloud:** No

## Things that are yours to fill in

- **Copyright line** (e.g. "2026 Your Name")
- **App Review contact** (name, phone, email)
- **Support contact on the support page**: Apple requires the Support URL to lead to a way to reach you. The support page has a spot for an email address; tell me which address to use (a new one like `drift.support@…` keeps your personal inbox private).
