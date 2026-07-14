# Getting Encore onto your iPhone via TestFlight

You're enrolled in the Apple Developer Program, so this path needs **no Developer Mode
and no certificate-trust step** — TestFlight installs like a normal App Store app.

Your phone, your photos, the real location/calendar/screenshot features all light up here.

---

## One-time setup in App Store Connect (web, ~10 min)

1. Go to **[appstoreconnect.apple.com](https://appstoreconnect.apple.com)** → **My Apps** → the **＋** → **New App**.
2. Fill in:
   - **Platform:** iOS
   - **Name:** the public App Store name. "Encore" alone may be taken — if so, use something
     like **"Encore — On This Day"** or **"Encore: Memories."** (The name on your home screen
     stays just "Encore" regardless — that's set separately in the app.)
   - **Primary language:** English (U.S.)
   - **Bundle ID:** select **com.aarongrobinson.encore** from the dropdown. If it's not there
     yet, open `Encore.xcodeproj` and do one device build (or Product → Archive) first — Xcode
     auto-registers the App ID with your team.
   - **SKU:** any unique string, e.g. `encore-001`
   - **User access:** Full Access
3. Click **Create**. That's all the setup TestFlight needs — no screenshots or descriptions
   required for internal testing.

## Build + upload from Xcode (~10 min)

4. Open `Encore.xcodeproj`. At the top destination dropdown, choose **Any iOS Device (arm64)**
   (you can't archive while a Simulator is selected).
5. Menu bar: **Product → Archive**. Wait for it to finish — the **Organizer** window opens.
6. In the Organizer, select the new archive → **Distribute App** → **App Store Connect** →
   **Upload** → accept the defaults (automatic signing, include symbols) → **Upload**.
7. Wait for **"Upload Successful."**

## Turn on TestFlight (~5 min + processing wait)

8. Back in App Store Connect → your app → **TestFlight** tab. The build shows **"Processing"**
   for 10–30 min.
9. When it finishes, you may get an **Export Compliance** question. Encore uses no custom
   encryption (only standard HTTPS), so choose the **exempt / "None of the algorithms above"**
   option. This clears it instantly.
10. **Internal Testing** → create a group (e.g. "Me") → add yourself as a tester (your Apple ID).
    Internal testing needs **no Apple review** — it's available immediately.

## Install on your phone

11. On your iPhone, install the **TestFlight** app from the App Store.
12. Open TestFlight, sign in with your Apple ID → **Encore** appears → **Install**.
13. Open Encore, tap **Allow Full Access** → flip through your real memories.

---

### Notes
- **No Developer Mode, no trust step** — that's the whole point of going through TestFlight.
- TestFlight builds expire after **90 days** (vs. 7 for free direct-install). Re-upload to refresh.
- To ship a new version later: bump the build number in Xcode (or I can), re-Archive, re-Upload.

### What Claude can do for you
- Drive the **Archive + Upload from the command line** (so you skip steps 4–7) — this needs you
  to create an **App Store Connect API key** (Users and Access → Integrations → Team Keys), which
  you'd download and hand off. Optional; the Xcode GUI path above is simplest the first time.
- The web steps (create app record, add tester, export compliance) need your login, so those
  stay with you.

---

# Adding friends as testers (External testing)

Friends are **External testers**, not Internal. The difference:
- **Internal** = people added to your App Store Connect *team* (a login + a role). They can see the app's ASC settings. Builds reach them instantly with no review. Keep this for real collaborators, not friends.
- **External** = people you just invite to try the beta. They get *only* the TestFlight app + Encore, no account access. Up to 10,000, by email or a public link. The first external build needs a one-time **Beta App Review** (~24h), then it's fast.

For friends → External + a **public link** (they tap a URL, install TestFlight, join — no collecting emails).

## Already handled in the project
- `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` is set (both build configs), so the upload won't keep asking the export-compliance question.
- Privacy policy is **live**: https://aarongrobinson.com/encore/privacy/

## App Store Connect → TestFlight → Test Information (paste these)

### Beta App Description
Encore brings back the photos you took on this exact date in past years, like a daily time capsule from your own camera roll. Open it and you get a calm flip-through of your "on this day" memories from years past, picked and ordered on your device. Tap any photo to share it as a clean framed card. Everything happens on your phone. Your photos and calendar never leave your device and nothing is uploaded.

### What to Test (per-build notes)
Thanks for trying Encore. A few things to look at:
- The opening: the loading screen, then swipe up from the bouncing photo at the bottom to start flipping through your memories.
- Flipping through: swipe up and down between photos and years. Does it feel smooth and natural?
- Sharing: tap a photo and try sharing the framed card to Messages or anywhere else.
- The home screen: the grid of past years, the date up top, and the menu and gallery buttons.
- Tell me anything that feels slow, looks off, or that you wish it did. Screenshots help. Use the "Send Beta Feedback" option in TestFlight, or just text me.

Note: Encore only shows photos you actually took on today's date in past years, so if you have few photos from this date it will look sparse. Check back on a day you know you took a lot.

### Other fields
- **Feedback email:** aaron@marchingventures.com
- **Privacy Policy URL:** https://aarongrobinson.com/encore/privacy/
- **Beta App Review contact:** Aaron Robinson + email/phone (Apple only, not shown to testers)

## Steps
1. TestFlight tab → **Test Information** → paste the copy above + the privacy URL.
2. **External Testing** → create a group "Friends & Family".
3. Enable the **public link** for that group (or add friends' emails).
4. Add the latest build to the group → submit for **Beta App Review**.
5. Once approved, share the public link. New friends self-serve from then on.

## Tester logistics
- Friends need the free **TestFlight** app from the App Store.
- Builds **expire after 90 days** — re-upload to refresh.
- Feedback (screenshots + notes) comes through TestFlight → I can fold it into Linear.
