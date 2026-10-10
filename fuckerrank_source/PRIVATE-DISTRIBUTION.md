# fuckerrank — owner guide

An offline-licensed distribution for Apple silicon Macs running macOS 14 or later. The six keyboard actions are built in; Python, Conda, Homebrew, and exported Apple Shortcuts are not required.

## Build and distribute

Run `python3 scripts/build-private-release.py` from `fuckerrank_source` or use `make bundle`. It embeds the public license authority and web UI in the executable and creates the package without installing or launching the app, changing home-directory configuration, or running tests. Tests are opt-in with `--run-checks`, for a separate test Mac.

- `../release/recipient/fuckerrank-AppleSilicon.pkg` — the only file to share.
- `../release/owner-only/fuckerrank License Manager.app` — keep on your Mac.
- `../release/build-report.json` — signing status and installer checksum.

The private signing key is **`../release/owner-only/issuer.key`**, beside the owner's manager app, outside its bundle, excluded from Git, with permissions 0600. Back it up securely. Rebuilds reuse that key. Losing it prevents issuing licenses for this build. Replacing it changes the authority, so old licenses cannot authorize a build made with the replacement key. Do not copy the key or the owner-only folder to recipient Macs. The manager does not contain the key and cannot issue codes on another Mac unless the key is separately copied there.

The installer is built. Its app has an **ad-hoc signature**, but the installer has no Apple Developer ID signature and has not been notarized. These are Apple's publisher-verification and malware-check steps, separate from your offline activation system. Without them, recipient Macs may require manual approval. For distribution that passes the default Gatekeeper checks, obtain Developer ID Application and Developer ID Installer certificates through your Apple Developer Program account, then use:

```sh
python3 scripts/build-private-release.py \
  --application-identity 'Developer ID Application: Your Name (TEAMID)' \
  --installer-identity 'Developer ID Installer: Your Name (TEAMID)' \
  --notary-profile 'your-notarytool-keychain-profile'
```

The named notarization profile must already be configured in your Keychain. No Apple credentials are bundled. If a personally known recipient trusts the installer and macOS blocks it, Apple documents a per-app approval: attempt to open it, then go to **System Settings → Privacy & Security → Open Anyway**, and confirm **Open**. Approval may also be needed when opening the installed app. See [Apple's instructions](https://support.apple.com/en-in/102445). Managed Macs may restrict this option. Do not disable Gatekeeper globally.

Compilation and package inspection do not confirm first-install behavior on a recipient Mac. Further installation, activation, keyboard, and workflow tests must happen on a separate test Mac, as requested by the owner.

## Approve a recipient once

1. Double-click the installer and complete Apple's installation dialog. It opens the app as the logged-in user, never as root. If no GUI user is available, open the app from Applications later.
2. Copy the app's activation request, or use **Save Request…**.
3. On **your** Mac, open **fuckerrank License Manager**. Paste the request, enter the recipient's name, optionally enter an expiry, and generate the code.
4. Enter that code into the recipient's activation window and click **Activate This Mac**.
5. Complete Setup. **Install Antigravity** downloads and checksum-verifies Google's public CLI into the recipient's private data folder. **Sign In** opens Google's CLI in Terminal; follow its account prompts. Each recipient uses their own credentials; none are copied from the owner.
6. Grant macOS Screen Recording permission and relaunch when required. **Enable Open at Login** is optional and may require macOS approval.

Licensing needs no network. AI requests and initial Antigravity installation need internet and a provider account. Google's terms and privacy policy apply to provider use. Account authentication remains with Google's official CLI; no OAuth tokens are extracted or proxied.

Default model IDs preserve the scripts: `gemini-3.1-pro` and `gemini-3.8-flash`. Change them in Setup if those IDs are unavailable to a recipient. Requests use plan mode, sandboxing, disabled slash-command expansion, and a ten-minute timeout. Automatic approval of arbitrary tool operations is not enabled. Screenshots are retained after a failed or cancelled request.

## Keyboard actions

| Keys | Action |
| --- | --- |
| Control–Shift–S | Capture the main display, excluding this app's windows |
| Control–Shift–M | Margherita Pizza, main model |
| Control–Shift–R | Flash Pizza, fast model |
| Control–Shift–E | Show/hide the answer overlay |
| Control–Shift–Q | Cycle black, white, and green text |
| Control–Shift–D | Show/hide the custom prompt |

The app must remain running for global shortcuts. Hiding notes keeps the menu-bar app running. All actions are also in its menu. Disable pre-existing Apple Shortcuts claiming these combinations on the same Mac. The installer does not rewrite the user's Shortcuts database. Fresh recipient Macs need no shortcut imports.

Answers are saved to `~/Library/Application Support/fuckerrank/delivery/margherita_pizza.md` and copied to the clipboard. Screenshots go into `ss/`, then `ss/archive/` only after an answer is saved. The prompt defaults to `cpp`. Original workspace screenshots, notes, archives, and personal data are not packaged or migrated.

## Protection and limits

The app creates a Secure Enclave P-256 device key. Its serialized blob is encrypted for that Mac; the private key cannot be exported. Requests prove possession of the key. Licenses are Ed25519-signed by the owner's separate key and contain a hash of the device public key. The app checks the signature, device identity, and a fresh proof of device-key possession at startup and before workflow actions, plus periodically while running. There is no environment-variable, shared-password, or development bypass in the distributed app.

Forwarding an unmodified installer, app, or license does not activate another Mac. A copied data directory does not make the Secure Enclave key usable on another Mac. Deleting the device key requires a new activation. An unreadable existing key is never silently replaced.

This prevents ordinary copying. A skilled attacker can modify a local executable to bypass checks. Original `.py`, `.sh`, `.swift`, `.js`, `.html`, and `.css` source files are absent from the recipient app. Web content, styles, prompts, and the public key are executable constants and can still be reconstructed by a determined analyst. Standard installer glue and third-party license notices remain readable.

There is no remote revocation without a server. Optional expiry is exclusive, evaluated at midnight UTC on the entered date, and subject to local-clock tampering. Expiry is not required for a short-term deployment.

## Diagnostics

Do not run these on the owner's working Mac. The owner requested that further device tests happen on a separate Mac. The diagnostic commands create a device key when one is absent, so they are not a substitute for a pure build.

The app executable supports diagnostics without opening a window:

```sh
'.release-staging/fuckerrank.app/Contents/MacOS/fuckerrank' --activation-request
'.release-staging/fuckerrank.app/Contents/MacOS/fuckerrank' --check-license
'.release-staging/fuckerrank.app/Contents/MacOS/fuckerrank' --verify-code /path/to/code.txt
```

The first command creates a device key if absent, exactly like first launch. `--verify-code` checks a supplied license against this Mac without installing it. Diagnostics do not expose private key material or bypass licensing.
