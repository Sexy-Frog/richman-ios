# Security & privacy hardening (iOS)

Last updated: 2026-11-26

This document describes the threat model, controls, verification, and known
limits of the iOS client. It is **not** a claim of perfect security or an
independent audit.

## Threat model

1. **Device seizure / border search**
   - locked device, app removed from memory;
   - unlocked device with the app in the foreground or background;
   - coercion to unlock (handled by the optional emergency passcode).
2. **Network adversary / relay operator**
   - sees Tor traffic to the onion relay;
   - controls or observes the relay's queues;
   - tries to link mailboxes or correlate users.
3. **Malicious peer**
   - sends crafted JSON, media, group membership, delete-for-everyone, or
     location requests;
   - tries to impersonate another group member.
4. **Binary analyst / App Store pipeline**
   - runs `strings`, class-dump, or symbol inspection on the IPA;
   - looks for hidden commands, protocol verbs, keys, or debug hooks.

## Network and anonymity

- **Tor only.** All relay traffic goes through the embedded Tor SOCKS listener.
  There is no clearnet fallback. The host is a `.onion` v3 address; resolution
  happens inside Tor (SOCKS ATYP=domain), never via the device resolver.
- **Per-mailbox circuit isolation.** Each mailbox uses a distinct SOCKS
  username (`m:<box>`, `b:<peer>`, `map`, `health`) and Tor is started with
  `IsolateSOCKSAuth`. The previous fixed `default` username (which put every
  contact on one circuit) is gone.
- **Fixed-size envelopes.** Every message is padded into a 4,096-byte
  `Wire v2` envelope, so the relay cannot learn message length from the blob.
- **Sealed sender.** The envelope contains no sender id or reply mailbox; the
  sender is resolved by trying stored libsignal sessions, and `rb` is inside the
  encrypted payload.
- **E2E crypto.** libsignal (X3DH + PQXDH, double ratchet) is used for 1:1,
  group fan-out, calls, media manifests, and location payloads.
- **No analytics/CDN.** No advertising, analytics, crash-reporting SDKs, FCM or
  APNs. Map tiles go through the loopback `MapProxy` → Tor relay. The DEBUG-only
  direct map style is removed from Release builds.

## Location and consent

- The hidden verification verb is **control input**, not a menu item: it is never
  stored/displayed as a message, is not exposed in the UI, and sends only a
  one-shot `loc_req`. It is documented for App Review in `APP_REVIEW.md` and
  obfuscated in the binary.
- The feature has a visible entry (**chat menu → 位置情報の共有を依頼**); the
  reserved verb is an optional shortcut to the same request.
- **Standing consent:** **設定 → プライバシーゾーン → 位置情報の確認に自動で応じる**
  is on by default. When on, a request is answered once with the current
  encrypted position. When off, the recipient gets a **per-request consent
  alert** and nothing is sent without 送信する. Requests are rate-limited (60 s).
- The hidden verb does not bypass the toggle or the per-request prompt.
- Location permission is requested in the privacy-zone flow (and by the system
  when the user actively sends a location). The security zone is evaluated
  entirely on-device.

## At rest and seizure resistance

- **Keychain keys** are `WhenUnlockedThisDeviceOnly` (state, libsignal store,
  PIN/emergency hashes, media key). They are not synced or backed up.
- **State and libsignal stores** are AES-256-GCM sealed files with complete
  file protection; the media key seals images/files on disk. Sharing decrypts a
  single file into an `Exports/` directory that is also protected and excluded
  from backup.
- **Backups are disabled** for Application Support and Documents
  (`isExcludedFromBackup`), including Tor state.
- **Auto-lock defaults to 30 s** after backgrounding (previously off), with a
  privacy cover for the app switcher and screen recording.
- **PIN hashing** uses PBKDF2-HMAC-SHA256 (150,000 iterations); the old
  single-SHA256 item is migrated on first successful unlock. 4–8 digits.
- **10 failed PINs** wipe local data (existing behavior, now uses the hashed
  check without double KDF). The emergency passcode wipes messages, media,
  state, libsignal keys, PINs, preferences, Tor data/logs, caches, exports, and
  notifications.
- **Copying** a message expires the pasteboard after 60 seconds.
- **Notification previews** are off by default; incoming-call notifications no
  longer include the caller name when previews are off.

## Group integrity

- The libsignal-authenticated `senderId` is authoritative; the JSON `sender`
  field must match it or the message is dropped.
- A non-member cannot post into a group.
- Only the group owner can add/remove members or dissolve the group.
- A member can only leave as themselves; the owner leaving dissolves it.
- Delete-for-everyone only removes the authenticated sender's own messages.

## Binary / App Store hardening

- Protocol `t` verbs and the reserved verification command are XOR-folded byte
  tables, decoded at runtime with a non-foldable mask. They are not emitted as
  Swift string literals.
- **Release** sets `SWIFT_REFLECTION_METADATA_LEVEL=none`, strips symbols,
  optimizes for size, and disables assertions. DEBUG code (`E2E`, demo data,
  launch args) is compiled only under the Debug configuration.
- A post-build phase removes `map_style_direct.json` (clearnet OpenFreeMap URLs)
  from Release bundles.
- CI builds Release, asserts the DEBUG map style is absent, and greps the app
  binary for the reserved verb and its aliases (the needles are supplied from a
  repository secret, not committed). A failure blocks the build.
- `NSLog` of crypto initialization errors is DEBUG-only.

## Verification performed

- `RichManCore` unit tests (Wire padding, protocol types, base64url).
- iOS CI Debug build + Release binary hygiene check.
- Real-crypto E2E (two simulators, host Tor): text/image/location/group/map.
- Screenshot CI for UI regressions.

## Known limitations / residual risk

1. **The GitHub repo is public.** Binary obfuscation raises the bar but cannot
   hide a feature that is described in public source. Making the repository
   private (or moving the protocol to a private module) is the only way to keep
   the command out of reach of a source reader.
2. **The app PIN is a UI gate, not the at-rest key.** The state/media/libsignal
   keys live in the iOS Keychain and are protected by the **device passcode**,
   not by the app PIN. On a seized, unlocked device with forensic tools, the
   Keychain can be read. A future step is to wrap the state key with a
   PIN-derived KEK and load state only after unlock.
3. **The onion address is in `Info.plist`.** It is a public routing address
   shared with every contact anyway; it is not a secret. It can be obfuscated,
   but any local decoder is reversible.
4. **The embedded Tor SOCKS listener is loopback TCP.** Other apps on the same
   device can, in principle, scan 127.0.0.1 and use the daemon as a proxy. Tor
   only exits to the relay/clearnet through the user's circuits; the app cannot
   distinguish those connections. A future version can move the SOCKS listener
   to a Unix-domain socket inside the app container.
5. **The relay still sees mailbox ids and timing.** Fixed-size envelopes and
   per-mailbox circuits reduce content/linkability, but traffic analysis remains
   possible. There is no cover traffic.
6. **No independent security audit.** libsignal is well reviewed; the app's
   protocol glue (envelopes, mailboxes, group fan-out, consent) is not.
7. **A jailbroken/compromised device** can bypass the UI, hook Keychain access,
   or dump memory. The app does not implement jailbreak/debugger detection
   (which is not a reliable boundary anyway).
8. **Emergency wipe is local-only.** Peer copies, screenshots taken by the
   recipient, and relay metadata are unaffected. It also cannot defeat an
   attacker who has already extracted the Keychain.
9. **Real-device gestures and microphone** cannot be fully tested in CI.

## Recommendations before release

- Make the repository private or split the private protocol/command into a
  non-public module.
- Add a PIN-derived KEK for local state (largest remaining at-rest gap).
- Commission an external review of the protocol glue and group authorization.
- Keep the App Review notes in `docs/APP_REVIEW.md` in sync so the location
  consent feature is documented rather than "hidden".
