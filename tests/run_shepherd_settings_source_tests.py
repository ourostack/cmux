#!/usr/bin/env python3
"""Run actual qualified-settings transformation without launching cmux or an app host."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = Path(tempfile.mkdtemp(prefix="cmux-shepherd-settings-source-"))
for directory in ("Sources/cmux", "Tests/SettingsTests"):
    (PACKAGE / directory).mkdir(parents=True)
shutil.copy2(ROOT / "CLI/ShepherdHookSettings.swift", PACKAGE / "Sources/cmux")
shutil.copy2(ROOT / "tests/shepherd_settings_source/CLIProbes.swift", PACKAGE / "Sources/cmux")
shutil.copy2(ROOT / "cmuxTests/ShepherdHookSettingsTests.swift", PACKAGE / "Tests/SettingsTests")
(PACKAGE / "Package.swift").write_text(f'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ShepherdSettingsSourceTests", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "{ROOT / 'Packages/macOS/CMUXAgentLaunch'}")],
    targets: [
        .target(name: "cmux", dependencies: [
            .product(name: "CMUXAgentLaunch", package: "CMUXAgentLaunch")]),
        .testTarget(name: "SettingsTests", dependencies: ["cmux",
            .product(name: "CMUXAgentLaunch", package: "CMUXAgentLaunch")],
            swiftSettings: [.define("SHEPHERD_SOURCE_TEST")])
    ], swiftLanguageModes: [.v5])
''')
args = ["swift", "test", "--build-system", "native", "--package-path", str(PACKAGE),
        "--disable-index-store", "--jobs", "2", "-Xswiftc", "-gnone"]
if scratch := os.environ.get("SHEPHERD_SETTINGS_SOURCE_SCRATCH"):
    args += ["--scratch-path", scratch]
print(f"Settings source package: {PACKAGE}", flush=True)
raise SystemExit(subprocess.run(args, check=False).returncode)
