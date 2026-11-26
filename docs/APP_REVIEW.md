# App Review notes — 緊急用パスコード（Emergency passcode）

This document is for the App Store Connect **Notes for Review** field and for
internal review. Keep it in sync with the build.

## What the feature is

- A **user-configured second passcode** entered on the lock screen.
- Entering it **immediately deletes all local data** (messages, media, local
  keys, PINs, preferences, security zone) and returns the app to onboarding.
- It is **not** a backdoor and never unlocks the app. It is a panic/emergency
  wipe for coercion or device-compromise situations.
- It is only available after the user sets it in **設定 → セキュリティ →
  緊急用パスコード**, authorizes with the current PIN, and confirms an
  irreversible-action dialog. It must differ from the normal PIN.
- The duress code is never sent to the server; the wipe is local-only.

## How to test (fresh install / disposable simulator)

1. Complete onboarding: display name → privacy zone (either enable or later) →
   4-digit PIN, e.g. `2468`.
2. Settings → セキュリティ → 緊急用パスコード.
3. Enter the current PIN `2468`, then a different emergency code, e.g. `1357`,
   twice. Confirm the warning dialog.
4. Lock the app (Settings → 今すぐロック) and enter `1357`.
5. The app wipes local state and shows onboarding again. The emergency code and
   normal PIN no longer work (both were deleted).

**Do not use a device with data you care about.** The wipe is irreversible.

## Policy mapping (App Store Review Guidelines)

- **2.5.19 (hidden, dormant, undocumented features)**: the feature is visible
  and documented in Settings, with a destructive-action warning and a
  confirmation dialog. It is not hidden in the binary. The lock screen itself
  does not label the code (a coercer must not know which code was entered), but
  the feature is discoverable and described in the privacy policy.
- **2.3.1(a) (describe features for review)**: this document provides the
  non-obvious behavior and exact test steps.
- **5.1.1(i) (privacy policy)**: the in-app policy states that data is stored
  locally and that the emergency passcode deletes it. No account is created, and
  no personal data is sent to the relay for this feature.
- **1.6 (data security)**: the wipe removes the local state, media, Keychain
  items (normal PIN, emergency code, state/media keys), libsignal store, Tor
  data/logs, and security-zone and TTL preferences. App data is excluded from
  iCloud/iTunes backups.
- **HIG / destructive actions**: the setup is protected by the current PIN and
  an explicit irreversible-action confirmation. The **entry** intentionally has
  no confirmation prompt because the threat model is coercion; this trade-off is
  documented here and in the in-app policy.

## Location identity check (位置情報の確認)

- A reserved verification verb typed in a 1:1 chat is treated as control input:
  it is never stored or displayed as a message, and sends a one-shot
  `loc_req` to the other side. It is **intentionally not exposed in the UI**;
  this document is the App Review disclosure.
  The exact verb and aliases are **not committed to this public repository**;
  paste them into App Store Connect → Notes for Review from the private
  operations note before submission. The shipped binary is checked against
  them in CI (needles come from a repository secret).
- **The toggle in the privacy-zone section is the consent.** **設定 → プライバシーゾーン
  → 位置情報の確認に自動で応じる** is **on by default** (users can turn it off).
  When it is on, a location request is answered **once** with the current
  encrypted position; when off, the request is ignored. There is no popup and no
  separate global toggle. Requests are rate-limited per peer (60 s). There is no
  background location and no continuous sharing.
- This is a deliberate, disclosed trade-off: anyone who knows the reserved verb
  and is a contact can obtain one current location while the toggle is on. Users
  who do not want this leave it off.
- Test: turn the toggle on for the recipient; send the reserved verb from the
  other account; one `loc_once` reply arrives. Turn it off; no reply.
- Policy: 2.5.19 (disclosed here for App Review), 2.3.1(a), 5.1.1(i) and 5.1.2
  (explicit in-app toggle with on-screen description is the consent; one-shot,
  no background tracking), 1.6 (encrypted in transit; no server-side location
  storage).

## Positioning / metadata

Describe the feature as **privacy protection for local data** (e.g. "a second
passcode that erases local data if you are forced to unlock"). Do **not**
market it as a way to evade law enforcement, destroy evidence, or bypass
security. Avoid "military-grade" or absolute anonymity claims.

## Known limitations to disclose in review notes

- Local-only wipe: messages already delivered to the peer remain on the peer's
  device. The relay's queued ciphertext is not addressed by this feature.
- The app has no server-side account, so there is no remote deletion endpoint.
- Real end-to-end crypto and Tor are in the same build; the relay never sees
  plaintext.
