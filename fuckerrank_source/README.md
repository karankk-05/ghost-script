# fuckerrank

An Apple silicon app for macOS 14 or later, with screenshot and AI workflows,
a floating answer window, six built-in keyboard actions, and offline activation
for each Mac. See [PRIVATE-DISTRIBUTION.md](PRIVATE-DISTRIBUTION.md) for installation,
activation, signing, and the limits of source-code protection.

This folder holds the separate distribution implementation. The owner's existing
source and running setup stay in place. The recipient installer contains compiled
code and embedded UI assets; it does not contain the original source files or the
owner's private license-signing key.

Run `make bundle` to compile and package without installing, launching, or testing
the app. The output is `../release/recipient/fuckerrank-AppleSilicon.pkg`. Keep
`../release/owner-only/` private, and back up its `issuer.key` securely.

The app has an ad-hoc signature by default. Apple Developer ID signing and
notarization require the owner's certificates; the owner guide explains the build
options and recipient approval flow. Apple's verification is separate from the
app's device activation.

Do not run `make run`, `make owner`, `make test`, or device diagnostics on the
owner's working Mac. Further runtime checks belong on a separate test Mac.
