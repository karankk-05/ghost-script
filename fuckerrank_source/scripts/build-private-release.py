#!/usr/bin/env python3
"""Build recipient and owner artifacts separately. Signing keys never enter staging."""
from __future__ import annotations
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[1]
RELEASE = PROJECT.parent / "release"
GENERATED = PROJECT / "Sources/fuckerrank/Generated"
VERSION = "0.2.0"
APP_ID = "io.karan.fuckerrank"


def run(*args: str, capture: bool = False) -> str:
    environment = os.environ.copy()
    environment["FUCKERRANK_ISSUER_KEY"] = str(RELEASE / "owner-only/issuer.key")
    result = subprocess.run(args, cwd=PROJECT, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None, env=environment)
    return result.stdout.strip() if capture else ""


def prepare() -> Path:
    GENERATED.mkdir(parents=True, exist_ok=True)
    # Placeholder permits SwiftPM target discovery when building only the owner tool.
    authority = GENERATED / "LicenseAuthority.swift"
    if not authority.exists():
        authority.write_text('enum LicenseAuthority { static let publicKeyBase64 = "" }\n')
    assets = GENERATED / "WebAssets.swift"
    if not assets.exists():
        assets.write_text('enum WebAssets { static let html = "" }\n')
    run("swift", "build", "-c", "release", "--product", "OwnerLicenseTool")
    binary_dir = Path(run("swift", "build", "-c", "release", "--show-bin-path", capture=True))
    owner = binary_dir / "OwnerLicenseTool"
    # The issuer key is an ignored, owner-only workspace artifact. No home-directory
    # preferences, app installs, or GUI launches are performed by this build tool.
    key_file = RELEASE / "owner-only/issuer.key"
    command = "public-key" if key_file.is_file() else "init-key"
    public_key = run(str(owner), command, capture=True)
    if not re.fullmatch(r"[A-Za-z0-9+/]{43}=", public_key):
        raise RuntimeError("Owner tool returned an invalid public key")
    authority.write_text(f'enum LicenseAuthority {{ static let publicKeyBase64 = "{public_key}" }}\n')
    web = PROJECT / "Sources/fuckerrank/Resources/Web"
    def read(name: str) -> str:
        return (web / name).read_text()
    html = read("notes.html")
    html = re.sub(r'<link rel="stylesheet" href="([^"]+)">',
                  lambda m: "<style>" + read(m[1]) + "</style>", html)
    html = re.sub(r'<script src="([^"]+)"></script>',
                  lambda m: "<script>" + read(m[1]).replace("</script", "<\\/script") + "</script>", html)
    html = html.replace("<body>", '<body class="white">')
    delimiter = "#####"
    if f'"""{delimiter}' in html:
        raise RuntimeError("Unexpected Swift string delimiter in web assets")
    assets.write_text('enum WebAssets {\n    static let html = ' + delimiter + '"""\n' + html +
                      '\n"""' + delimiter + '\n}\n')
    return binary_dir


def assemble(binary: Path, app: Path, identifier: str, display_name: str,
             identity: str, owner: bool = False) -> None:
    if app.exists():
        shutil.rmtree(app)
    macos = app / "Contents/MacOS"
    resources = app / "Contents/Resources"
    macos.mkdir(parents=True); resources.mkdir()
    shutil.copy2(binary, macos / binary.name)
    run("/usr/bin/strip", "-S", "-x", str(macos / binary.name))
    info = {
        "CFBundleExecutable": binary.name, "CFBundleIdentifier": identifier,
        "CFBundleName": display_name, "CFBundleDisplayName": display_name,
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": VERSION,
        "CFBundleVersion": "2", "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
    }
    if not owner:
        info.update({
            "LSUIElement": True,
            "NSAppleEventsUsageDescription": "Open Google's Antigravity sign-in in Terminal.",
            "CFBundleURLTypes": [{"CFBundleURLName": APP_ID, "CFBundleURLSchemes": ["fuckerrank"]}],
            "CFBundleDocumentTypes": [{"CFBundleTypeName": "Markdown Document", "CFBundleTypeRole": "Viewer",
                "LSHandlerRank": "Alternate", "LSItemContentTypes": ["net.daringfireball.markdown", "public.plain-text"]}],
        })
        notices = "fuckerrank bundles markdown-it and highlight.js under their respective MIT and BSD licenses.\n\n"
        for filename in ["markdown-it.min.js", "highlight.min.js"]:
            text = (PROJECT / "Sources/fuckerrank/Resources/Web/vendor" / filename).read_text()
            notices += "\n" + filename + "\n" + "\n".join(re.findall(r"/\*[\s\S]*?\*/", text)[:2]) + "\n"
        # Full third-party license texts are maintained alongside packaging sources.
        for license_file in sorted((PROJECT / "packaging/licenses").glob("*.txt")):
            notices += "\n" + license_file.read_text() + "\n"
        (resources / "Third-Party-Notices.txt").write_text(notices)
    with (app / "Contents/Info.plist").open("wb") as file:
        plistlib.dump(info, file)
    (app / "Contents/PkgInfo").write_bytes(b"APPL????")
    # Remove build-machine metadata only from our newly generated artifacts.
    run("/usr/bin/xattr", "-cr", str(app))
    args = ["/usr/bin/codesign", "--force", "--options", "runtime", "--sign", identity]
    if identity != "-":
        args.append("--timestamp")
    if not owner:
        args += ["--entitlements", str(PROJECT / "packaging/private.entitlements")]
    run(*args, str(app))
    run("/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(app))


def audit(app: Path, owner_app: Path) -> None:
    forbidden = {".py", ".pyc", ".sh", ".swift", ".js", ".html", ".css", ".key", ".fuckerrankrequest"}
    for file in app.rglob("*"):
        if file.is_file() and file.suffix.lower() in forbidden:
            raise RuntimeError(f"Source or private data found in recipient app: {file.name}")
    secret = (RELEASE / "owner-only/issuer.key").read_bytes()
    retired_brand = b"ghost" + b"screen"
    for bundle in [app, owner_app]:
        for file in bundle.rglob("*"):
            if retired_brand in str(file).lower().encode():
                raise RuntimeError("Retired branding found in an artifact path")
            if file.is_file():
                data = file.read_bytes()
                if secret in data:
                    raise RuntimeError("Private signing key found in a distributable artifact")
                if retired_brand in data.lower():
                    raise RuntimeError("Retired branding found in an artifact")
    print("Artifact inspection passed: no original source files, private signing key, or retired branding in either app.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--run-checks", action="store_true", help="Opt-in checks; omit on the owner's working Mac")
    parser.add_argument("--application-identity", default="-")
    parser.add_argument("--installer-identity")
    parser.add_argument("--notary-profile")
    options = parser.parse_args()
    if options.notary_profile and (options.application_identity == "-" or not options.installer_identity):
        parser.error("Notarization needs both Developer ID Application and Developer ID Installer identities")
    binary_dir = prepare()
    if options.prepare_only:
        print("Generated embedded web assets and public license authority."); return
    # Tests are opt-in: the owner asked not to test on this working Mac.
    if options.run_checks:
        run("swift", "run", "-c", "release", "LicenseChecks")
    run("swift", "build", "-c", "release", "--product", "fuckerrank")
    recipient = RELEASE / "recipient"
    owner_dir = RELEASE / "owner-only"
    recipient.mkdir(parents=True, exist_ok=True); owner_dir.mkdir(parents=True, exist_ok=True)
    staging = PROJECT / ".release-staging"
    staging.mkdir(exist_ok=True)
    app = staging / "fuckerrank.app"
    assemble(binary_dir / "fuckerrank", app, APP_ID, "fuckerrank", options.application_identity)
    owner_app = owner_dir / "fuckerrank License Manager.app"
    assemble(binary_dir / "OwnerLicenseTool", owner_app, APP_ID + ".owner", "fuckerrank License Manager", options.application_identity, owner=True)
    audit(app, owner_app)
    pkg = recipient / "fuckerrank-AppleSilicon.pkg"
    scripts = staging / "installer-scripts"
    scripts.mkdir(exist_ok=True)
    # Public installation glue only. No original workflow scripts or private data.
    (scripts / "postinstall").write_text('''#!/bin/sh
console_user=$(/usr/bin/stat -f '%Su' /dev/console)
case "$console_user" in root|loginwindow|_mbsetupuser|'') exit 0 ;; esac
console_uid=$(/usr/bin/id -u "$console_user")
/bin/launchctl asuser "$console_uid" /usr/bin/sudo -H -u "$console_user" /usr/bin/open -a "/Applications/fuckerrank.app" >/dev/null 2>&1 || true
exit 0
''')
    (scripts / "postinstall").chmod(0o755)
    args = ["/usr/bin/pkgbuild", "--component", str(app), "--install-location", "/Applications",
            "--identifier", APP_ID, "--version", VERSION, "--scripts", str(scripts)]
    if options.installer_identity:
        args += ["--sign", options.installer_identity]
    run(*args, str(pkg))
    if options.notary_profile:
        run("xcrun", "notarytool", "submit", str(pkg), "--keychain-profile", options.notary_profile, "--wait")
        run("xcrun", "stapler", "staple", str(pkg))
        run("/usr/sbin/spctl", "--assess", "--type", "install", "--verbose=2", str(pkg))
    status = "Developer ID signed" if options.application_identity != "-" else "Ad-hoc signed; no Apple Developer ID signature"
    report = {"version": VERSION, "architecture": "arm64", "macOSMinimum": "14.0", "signing": status,
              "notarized": bool(options.notary_profile), "installerSHA256": hashlib.sha256(pkg.read_bytes()).hexdigest(),
              "licenseChecksRunDuringBuild": bool(options.run_checks),
              "licenseAuthoritySHA256": hashlib.sha256((GENERATED / "LicenseAuthority.swift").read_bytes()).hexdigest()}
    import json
    (RELEASE / "build-report.json").write_text(json.dumps(report, indent=2) + "\n")
    (owner_dir / "OWNER-ONLY.txt").write_text("Do not distribute this folder. The recipient installer is in ../recipient/.\n"
        "Your private signing key is issuer.key beside this app, outside the app bundle.\n"
        "Back up that key securely. Losing it prevents issuing licenses for this build.\n"
        "Open fuckerrank License Manager, paste the request, enter the recipient's name, and generate a code.\n")
    print(f"\nRecipient installer: {pkg}\nOwner tool: {owner_app}\nSigning: {status}")


if __name__ == "__main__":
    main()
