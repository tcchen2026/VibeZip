#!/usr/bin/env python3
"""Prepare a staged app for MAS signing using only Python's standard library."""

import argparse
import datetime
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_plist(path):
    with path.open("rb") as stream:
        return plistlib.load(stream)


def write_plist(path, value):
    with path.open("wb") as stream:
        plistlib.dump(value, stream, sort_keys=False)


def verify_payload(app):
    require(app.is_dir(), "The packaged application is missing.")
    for path in [app, *app.rglob("*")]:
        if path.is_symlink():
            continue
        mode = stat.S_IMODE(path.stat().st_mode)
        required = 0o555 if path.is_dir() else 0o444
        require(mode & required == required,
                f"App contents must be readable by every user: {path.relative_to(app.parent)} ({mode:04o}).")
    for bundle in app.rglob("*.bundle"):
        info_path = bundle / "Contents/Info.plist"
        if not info_path.is_file():
            info_path = bundle / "Info.plist"
        require(info_path.is_file(), f"Missing resource bundle Info.plist: {bundle.name}")
        info = read_plist(info_path)
        require(re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", info.get("CFBundleIdentifier", "")),
                f"Missing or invalid resource bundle identifier: {bundle.name}")
        require(info.get("CFBundlePackageType") == "BNDL", f"Missing resource bundle type: {bundle.name}")
        require(info.get("CFBundleShortVersionString") and info.get("CFBundleVersion"),
                f"Missing resource bundle version: {bundle.name}")


def identities(codesigning=False):
    command = ["security", "find-identity", "-v"]
    if codesigning:
        command += ["-p", "codesigning"]
    if os.environ.get("VIBEZIP_MAS_KEYCHAIN"):
        command.append(os.environ["VIBEZIP_MAS_KEYCHAIN"])
    output = subprocess.check_output(command, text=True)
    return re.findall(r'^\s*\d+\) ([0-9A-Fa-f]{40}) "([^"]+)"', output, re.MULTILINE)


def choose_identity(candidates, requested, label):
    if requested:
        candidates = [(digest, name) for digest, name in candidates
                      if requested == name or requested.upper() == digest.upper()]
    require(len(candidates) == 1,
            f"Expected one matching {label} identity, found {len(candidates)}. "
            "Import its certificate and private key, or select it with VIBEZIP_MAS_"
            + ("APP_IDENTITY." if label == "application" else "INSTALLER_IDENTITY."))
    return candidates[0]


def prepare_signing(app, output, bundle_id, entitlements):
    profile_path = Path(os.environ.get("VIBEZIP_MAS_PROFILE", ""))
    require(profile_path.is_file(), "Set VIBEZIP_MAS_PROFILE to a Mac App Store Connect profile.")
    # Decode for build-time checks only; provisioning data is not parsed by the app.
    profile = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(profile_path)]))
    require("OSX" in profile.get("Platform", []), "The provisioning profile must be for macOS.")
    require("ProvisionedDevices" not in profile and not profile.get("ProvisionsAllDevices", False),
            "Use a Mac App Store Connect profile, not a development or Developer ID profile.")
    expiry = profile.get("ExpirationDate")
    require(isinstance(expiry, datetime.datetime)
            and expiry.replace(tzinfo=datetime.timezone.utc) > datetime.datetime.now(datetime.timezone.utc),
            "The provisioning profile is expired or has no expiration date.")
    allowed = profile.get("Entitlements", {})
    require(not allowed.get("com.apple.security.get-task-allow", False)
            and not allowed.get("get-task-allow", False), "A development profile cannot sign a store build.")
    teams = profile.get("TeamIdentifier", [])
    require(len(teams) == 1 and re.fullmatch(r"[A-Z0-9]{10}", teams[0]),
            "The profile must identify one Apple Developer team.")
    team = teams[0]
    require(allowed.get("com.apple.developer.team-identifier") == team,
            "The profile's team entitlement does not match its team identifier.")
    app_id = allowed.get("com.apple.application-identifier")
    expected_ids = [prefix + "." + bundle_id for prefix in profile.get("ApplicationIdentifierPrefix", [])]
    require(app_id in expected_ids, f"The profile must explicitly authorize {bundle_id}; wildcard profiles are not accepted.")

    certificate_hashes = {hashlib.sha1(cert).hexdigest().upper() for cert in profile.get("DeveloperCertificates", [])}
    application_candidates = [(digest, name) for digest, name in identities(codesigning=True)
                              if digest.upper() in certificate_hashes
                              and name.startswith(("Apple Distribution:", "3rd Party Mac Developer Application:",
                                                   "Mac App Distribution:"))
                              and name.endswith(f"({team})")]
    application_hash, _ = choose_identity(application_candidates, os.environ.get("VIBEZIP_MAS_APP_IDENTITY"), "application")
    # Installer identities are intentionally searched without -p codesigning.
    installer_candidates = [(digest, name) for digest, name in identities()
                            if name.startswith(("3rd Party Mac Developer Installer:", "Mac Installer Distribution:"))
                            and name.endswith(f"({team})")]
    _, installer_name = choose_identity(installer_candidates, os.environ.get("VIBEZIP_MAS_INSTALLER_IDENTITY"), "installer")
    (output / "application-identity.txt").write_text(application_hash + "\n")
    (output / "installer-identity.txt").write_text(installer_name + "\n")
    (output / "team-identifier.txt").write_text(team + "\n")
    entitlements["com.apple.application-identifier"] = app_id
    entitlements["com.apple.developer.team-identifier"] = team
    if "beta-reports-active" in allowed:
        entitlements["beta-reports-active"] = allowed["beta-reports-active"]
    embedded_profile = app / "Contents/embedded.provisionprofile"
    shutil.copyfile(profile_path, embedded_profile)
    # This public signing authorization is installed as root along with the app.
    # Every user must be able to read it, regardless of the private staging umask.
    embedded_profile.chmod(0o644)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--unsigned", action="store_true")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if args.verify_only:
        verify_payload(args.app)
        print("App payload permissions and resource bundle metadata verified.")
        return
    require(args.output is not None and args.output.is_dir(), "Provide an existing --output staging directory.")
    app, output = args.app, args.output
    info_path = app / "Contents/Info.plist"
    info = read_plist(info_path)
    bundle_id = info.get("CFBundleIdentifier", "")
    require(re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id), "Invalid app bundle identifier.")
    require(info.get("CFBundlePackageType") == "APPL" and info.get("CFBundleExecutable") == "VibeZip",
            "The package must contain the VibeZip application.")
    require(info.get("CFBundleSupportedPlatforms") == ["MacOSX"]
            and info.get("DTPlatformName") == "macosx" and info.get("DTXcodeBuild")
            and info.get("DTSDKName", "").startswith("macosx"),
            "Build metadata is missing; rebuild with the current build.sh before packaging.")
    require(info.get("LSMinimumSystemVersion") == "26.0", "The app's minimum macOS version must be 26.0.")
    require(info.get("LSApplicationCategoryType") == "public.app-category.utilities", "Missing Utilities store category.")
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", info.get("CFBundleShortVersionString", "")),
            "The store version must contain three numeric components.")
    build_number = os.environ.get("VIBEZIP_MAS_BUILD_NUMBER", "")
    require(args.unsigned or build_number, "Set VIBEZIP_MAS_BUILD_NUMBER for a signed store package.")
    build_number = build_number or info.get("CFBundleVersion", "")
    require(re.fullmatch(r"[1-9][0-9]*(?:\.(?:0|[1-9][0-9]*)){0,2}", build_number),
            "The build number must contain one to three integers without leading zeros, starting above zero.")
    info["CFBundleVersion"] = build_number

    resources = app / "Contents/Resources"
    for relative in ("AppIcon.icns", "PrivacyInfo.xcprivacy", "Privacy.txt",
                     "Source/7zip-source.tar.gz", "Source/rebuild-engine.sh",
                     "Licenses/THIRD_PARTY_NOTICES.txt", "Licenses/LGPL-2.1.txt", "Licenses/unRarLicense.txt"):
        require((resources / relative).is_file(), f"Missing bundled resource: {relative}")
    read_plist(resources / "PrivacyInfo.xcprivacy")
    for language in info.get("CFBundleLocalizations", []):
        require((resources / "VibeZip_VibeZipCore.bundle" / f"{language.lower()}.lproj/Localizable.strings").is_file(),
                f"Missing localization: {language}")
    resource_info_path = resources / "VibeZip_VibeZipCore.bundle/Info.plist"
    resource_info = read_plist(resource_info_path)
    require(resource_info.get("CFBundleIdentifier") == bundle_id + ".resources",
            "Resource bundle metadata is missing; rebuild with the current build.sh before packaging.")
    resource_info["CFBundleShortVersionString"] = info["CFBundleShortVersionString"]
    resource_info["CFBundleVersion"] = build_number
    entitlements = read_plist(Path(__file__).resolve().parent.parent / "Resources/VibeZip.entitlements")
    require(entitlements.get("com.apple.security.app-sandbox") is True
            and entitlements.get("com.apple.security.files.user-selected.read-write") is True
            and entitlements.get("com.apple.security.files.bookmarks.app-scope") is True,
            "The archive browser's sandbox and file-access entitlements must be enabled.")
    require(entitlements.get("com.apple.security.network.client") is False
            and entitlements.get("com.apple.security.network.server") is False,
            "Network access must remain disabled.")
    require(not entitlements.get("com.apple.security.get-task-allow", False), "Debugger access must be disabled.")
    if args.unsigned:
        # Reusing a store-signed app must not carry a profile into an ad-hoc package.
        (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    else:
        prepare_signing(app, output, bundle_id, entitlements)
    write_plist(info_path, info)
    write_plist(resource_info_path, resource_info)
    write_plist(output / "mas.entitlements", entitlements)
    write_plist(output / "requirements.plist", {"os": ["26.0"], "arch": ["arm64", "x86_64"]})
    verify_payload(app)
    print(f"{bundle_id}: version {info['CFBundleShortVersionString']}, build {build_number}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        print(f"MAS preparation failed: {error}", file=sys.stderr)
        sys.exit(1)
