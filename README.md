# Encore

A private, on-device "TimeHop for your camera roll." Each day it surfaces the photos
you took on this calendar date (same month + day) in previous years, grouped by year,
with elegant shareable cards, on-device AI filtering of clutter, and calendar + location
context. Nothing leaves the phone: no backend, no accounts, no network calls except
fetching your own iCloud-stored originals.

- **App display name:** Encore  (App Store listing name: "Encore - On This Day")
- **Bundle ID:** `com.aarongrobinson.encore`
- **Xcode project:** `Encore.xcodeproj` (scheme/target: `Encore`); source in the `Encore/` folder
- **Location:** `Dropbox/Marching Ventures Projects/Encore - On This Day/`
- **Min iOS:** 17.0
- **Stack:** Swift + SwiftUI + PhotoKit + Vision + EventKit
- **Built/verified with:** Xcode 26.5

## Project layout
- `EncoreApp.swift` — app entry point
- `YearMemory.swift` — model for one year's group of photos
- `PhotoLibraryService.swift` — photo permission + the "on this day" query + image loading
- `ContentView.swift` — all UI (loaded / loading / empty / permission-denied states)
- `Assets.xcassets` — app icon slot (add a 1024×1024 PNG) + accent color

The project uses Xcode's file-system-synchronized groups: any `.swift` file dropped
into the `Encore/` folder is compiled automatically — no need to edit the project file.

## Run on your own iPhone (no paid account needed)
1. Open `Encore.xcodeproj` in Xcode.
2. Select the **Encore** target → **Signing & Capabilities**.
3. Under **Team**, add your personal Apple ID (free). Xcode auto-creates a signing cert.
4. Plug in your iPhone, pick it as the run destination, press **Run** (⌘R).
5. First launch on the phone: Settings → General → VPN & Device Management → trust your dev cert.
   (Free-signed apps stop working after 7 days; just re-run from Xcode to refresh.)

## Ship via TestFlight / App Store (needs the $99/yr Apple Developer Program)
1. Enroll at developer.apple.com (can take a day or two to approve).
2. In Xcode signing, switch Team to your enrolled team.
3. Product → Destination → **Any iOS Device (arm64)**, then Product → **Archive**.
4. In the Organizer, **Distribute App → App Store Connect → Upload**.
5. In App Store Connect → TestFlight: add yourself as an internal tester (no review, instant).
6. For the public App Store: fill metadata, screenshots, privacy label (declare
   **No Data Collected** — it's true), add a privacy-policy URL, then submit for review.

## Notes / next steps
- App Store display name should not be "TimeHop" (trademark). Pick a final marketing name
  at submission — code/bundle ID don't need to change.
- v2 ideas: daily local notification with memory count, WidgetKit "On This Day" widget,
  Live Photo playback, videos, favorites, share sheet.
