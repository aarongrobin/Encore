# Fastlane setup — Encore (one-time)

Goal: `fastlane beta` archives a signed Release build and uploads it to TestFlight, with no Xcode clicking and no 2FA prompt.

## 1. Generate an App Store Connect API key (interactive, your account)
1. Go to App Store Connect → **Users and Access** → **Integrations** → **App Store Connect API**.
2. Click **+** to generate a key. Give it the **App Manager** role.
3. Download the `.p8` file (you can only download it ONCE).
4. Note the **Key ID** and the **Issuer ID** shown on that page.

## 2. Drop the key in place
- Save the downloaded file as: `fastlane/AuthKey.p8` (in this folder).
- Copy `fastlane/.env.example` to `fastlane/.env` and fill in `ASC_KEY_ID` and `ASC_ISSUER_ID` (path can stay default).

Keep `AuthKey.p8` and `.env` private. (This project is not a git repo, so nothing is committed, but still treat them like passwords.)

## 3. Run it
From the project root (`Encore - On This Day/`):

```bash
fastlane beta
```

That archives Release, exports a signed `.ipa`, and uploads to TestFlight.

## Notes
- Build number: bump `CURRENT_PROJECT_VERSION` in the Xcode project before running (the Claude Code build step already does this each round). To auto-increment instead, we can add `increment_build_number` to the lane later.
- Apple still does **processing** (~5–15 min) after upload, and **external** testers still need the one-time **beta review**. fastlane removes the manual upload, not Apple's queue.
- First run may prompt to register/update a provisioning profile (`-allowProvisioningUpdates` handles most of this automatically).
- Reusable for other apps: copy the `fastlane/` folder into another app and change `app_identifier` / `project` / `scheme`.
