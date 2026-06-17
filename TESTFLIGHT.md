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
