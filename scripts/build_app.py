#!/usr/bin/env python3
"""Build and ad-hoc sign a real macOS .app bundle. No Apple account is required."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = "cloud.doublewen.AskBaseMac"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--install", action="store_true", help="Install into ~/Applications")
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()
    configuration = "debug" if args.debug else "release"
    subprocess.run(["swift", "build", "-c", configuration, "--arch", "arm64", "--product", "AskBaseMac"], cwd=ROOT, check=True)
    output = subprocess.check_output(["swift", "build", "-c", configuration, "--arch", "arm64", "--show-bin-path"], cwd=ROOT, text=True)
    binary = Path(output.strip().splitlines()[-1]) / "AskBaseMac"
    architecture = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
    if architecture != "arm64":
        raise SystemExit(f"Refusing an arm64 package for unexpected binary architecture: {architecture}")
    distribution = ROOT / "dist"
    distribution.mkdir(exist_ok=True)
    staging = distribution / "build-products.noindex"
    staging.mkdir(exist_ok=True)
    bundle = staging / "AskBase Local.app"
    if bundle.exists():
        shutil.rmtree(bundle)
    macos = bundle / "Contents/MacOS"
    resources = bundle / "Contents/Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    shutil.copy2(binary, macos / "AskBaseMac")
    icon_directory = ROOT / "build"
    icon_directory.mkdir(exist_ok=True)
    subprocess.run(["swift", str(ROOT / "scripts/make_icon.swift"), str(icon_directory)], check=True)
    shutil.copy2(icon_directory / "AppIcon.icns", resources)
    shutil.copytree(ROOT / "Examples", resources / "Examples")
    for notice in ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md"):
        shutil.copy2(ROOT / notice, resources / notice)
    info = {
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleName": "AskBase Local",
        "CFBundleDisplayName": "AskBase Local",
        "CFBundleExecutable": "AskBaseMac",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.2.0",
        "CFBundleVersion": "3",
        "CFBundleIconFile": "AppIcon",
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
        "NSHumanReadableCopyright": "Copyright © 2026 wyatt88 and AskBase Local contributors. Apache-2.0.",
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
    }
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    archive = distribution / "AskBase-Local-0.2.0-macOS-arm64.zip"
    if archive.exists():
        archive.unlink()
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(bundle), str(archive)], check=True)
    if args.install:
        destination = Path.home() / "Applications" / bundle.name
        destination.parent.mkdir(exist_ok=True)
        if destination.exists():
            existing_info = destination / "Contents/Info.plist"
            if not existing_info.exists() or plistlib.loads(existing_info.read_bytes()).get("CFBundleIdentifier") != BUNDLE_ID:
                raise SystemExit("Destination belongs to another application; it was not replaced.")
            shutil.rmtree(destination)
        shutil.copytree(bundle, destination, symlinks=True)
        print(f"Installed: {destination}")
    print(f"App: {bundle}\nArchive: {archive}")


if __name__ == "__main__":
    main()
