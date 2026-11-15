# Postfalke

An IMAP/SMTP mail client for iOS (SwiftUI, iOS 17+) in the spirit of Thunderbird, with built-in OpenPGP.

The app's user interface is in German.

## Features

- Multiple accounts, automatic server settings via the Thunderbird autoconfig database
- Folders, message list, server-side search, reading plain text and HTML (remote content blocked by default, no JavaScript)
- Reply, reply all, forward, attachments, move, delete, flag
- OpenPGP (PGP/MIME, RFC 3156): sign, encrypt, decrypt, verify signatures, read inline PGP
- Encrypted subject (protected headers as in Thunderbird; the server only sees "...")
- Key management: generate (Ed25519/Curve25519), import (file, clipboard, from received mail, Autocrypt header), export
- Keys from contacts: reads the `KEY` field of vCards on a CardDAV server (e.g. Nextcloud) and assigns the key to every address on the card
- Private key import from Bitwarden: via clipboard (secure note) or "Share › Postfalke" (`.asc`/`.gpg` attachment)
- Background check for new mail with notifications (iOS decides when it runs)
- Undo send (configurable delay), schedule send ("Später senden" on a long press of the send button), and an outbox that retries when the network is back
- Drafts: saved locally while typing, stored in the server's Drafts folder (encrypted to your own key), reopened for editing
- Offline: folders and messages are kept on the device, only changes are synced, flag/move/delete work offline and are replayed later; the newest inbox messages are downloaded on Wi-Fi
- Conversations (by Message-ID references, with a subject fallback for replies)
- Recipients as chips with suggestions from earlier mail, CardDAV contacts and (optionally) iOS contacts; ⊕ picks from the iOS contacts without permission
- OpenPGP key lookup on request (Web Key Directory, keys.openpgp.org), key expiry (new keys: 3 years) and revocation, expiry warnings
- `postfalke://compose?to=…&subject=…&body=…` links (e.g. from Shortcuts), app icon badge with unread count, "mark as read"/"delete" actions on notifications
- Self-signed certificates (e.g. a home Nextcloud): the app shows the SHA-256 fingerprint and, once confirmed, trusts exactly that certificate for IMAP, SMTP or CardDAV
- Passwords, private keys and passphrases are stored in the iOS keychain (this device only)

## Layout

| Path | Contents |
| --- | --- |
| `App/` | SwiftUI app |
| `Packages/MailEngine/` | IMAP, SMTP, MIME, PGP/MIME and CardDAV logic (Swift package, testable on macOS) |
| `PGPCore/` | Rust library wrapping [rPGP](https://github.com/rpgp/rpgp), linked as `PGPCoreFFI.xcframework` |
| `UITests/` | End-to-end test of the app |
| `Tools/fakemail.py` | Small IMAP/SMTP/CardDAV test server |

## Building

Requirements: Xcode, [Rust](https://rustup.rs) and `xcodegen` (`brew install xcodegen`).

```sh
PGPCore/build-xcframework.sh   # builds the OpenPGP library (once, takes a few minutes)
xcodegen generate              # creates Postfalke.xcodeproj from project.yml
open Postfalke.xcodeproj
```

To run on a device, pick your team under *Signing & Capabilities* in Xcode.

`PGPCoreFFI.xcframework` is not checked in because of its size (about 160 MB); run the script again after changing anything in `PGPCore/`.

## Tests

```sh
# Rust
(cd PGPCore && cargo test)

# Mail engine, including send/receive and CardDAV against the test server
python3 Tools/fakemail.py 21143 21025 'p"äss wort' 21080 &
(cd Packages/MailEngine && MAIL_TEST_IMAP_PORT=21143 MAIL_TEST_SMTP_PORT=21025 MAIL_TEST_DAV_PORT=21080 swift test)

# App in the simulator (account, key, contact sync, send and read encrypted mail)
python3 Tools/fakemail.py 21143 21025 geheim123 21080 &
(cd Packages/MailEngine && MAIL_TEST_DAV_PORT=21080 MAIL_TEST_PASSWORD=geheim123 swift test --filter testCardDAV)  # creates the contact card
TEST_RUNNER_MAIL_TEST_SERVER=1 TEST_RUNNER_MAIL_TEST_DAV=1 xcodebuild -project Postfalke.xcodeproj -scheme Postfalke \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

The passwords above belong to the local test server only.

Self-signed certificates are tested against the same server running with TLS:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 30 -subj "/CN=nextcloud.local"
FP=$(openssl x509 -in cert.pem -noout -fingerprint -sha256 | cut -d= -f2)
FAKEMAIL_TLS_CERT=cert.pem FAKEMAIL_TLS_KEY=key.pem python3 Tools/fakemail.py 21993 21465 geheim123 21443 &
(cd Packages/MailEngine && MAIL_TEST_PASSWORD=geheim123 MAIL_TEST_TLS_IMAP_PORT=21993 MAIL_TEST_TLS_SMTP_PORT=21465 \
  MAIL_TEST_TLS_DAV_PORT=21443 MAIL_TEST_TLS_FINGERPRINT=$FP swift test --filter TLSTests)
TEST_RUNNER_MAIL_TEST_SERVER=1 TEST_RUNNER_MAIL_TEST_TLS=1 TEST_RUNNER_MAIL_TEST_PLAIN=0 xcodebuild -project Postfalke.xcodeproj \
  -scheme Postfalke -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:PostfalkeUITests/EndToEndTests/testSelfSignedCertificates
```

To check the fingerprint of your own server, run `openssl x509 -in <your cert> -noout -fingerprint -sha256` on the server
or look at the certificate in a browser.

## Known limitations

- Password or app-password login only (no OAuth for Gmail/Outlook)
- No push: new mail is only checked in the background when iOS grants the app time (never in the simulator; the launch argument `-simulateBackgroundRefresh` runs the same code there)
- Scheduled messages are sent by the app itself: if it is not running at that time, they go out when iOS wakes it in the background or when you open it
- `mailto:` links open Postfalke only once Apple grants the default-mail-app entitlement (`com.apple.developer.mail-client`, on request); until then use `postfalke://` links
- No share extension yet (it needs an App Group, which free developer accounts may not be able to sign)
- Bitwarden gives other iOS apps no direct access to the vault; import goes through the clipboard or the share sheet
- CardDAV is read-only; your own keys are not written to contacts
- No HTML composing, no S/MIME

## License

MIT, see [LICENSE](LICENSE).
