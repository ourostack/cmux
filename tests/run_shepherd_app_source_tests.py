#!/usr/bin/env python3
"""Run the actual Shepherd app adapter without launching cmux or an app test host."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = Path(tempfile.mkdtemp(prefix="cmux-shepherd-app-source-"))
for directory in ("Sources/CmuxTerminal", "Sources/GhosttyKit", "Sources/cmux", "Tests/AdapterTests"):
    (PACKAGE / directory).mkdir(parents=True)
shutil.copy2(ROOT / "tests/shepherd_app_source/TerminalProbes.swift", PACKAGE / "Sources/CmuxTerminal")
shutil.copy2(ROOT / "tests/shepherd_app_source/GhosttyProbes.swift", PACKAGE / "Sources/GhosttyKit")
shutil.copy2(
    ROOT / "Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+ShepherdInput.swift",
    PACKAGE / "Sources/CmuxTerminal",
)
shutil.copy2(ROOT / "tests/shepherd_app_source/AppProbes.swift", PACKAGE / "Sources/cmux")
shutil.copy2(ROOT / "tests/shepherd_app_source/HookStoreProbes.swift", PACKAGE / "Sources/cmux")
producer = ROOT / "CLI/ClaudeHookSessionStore+Shepherd.swift"
if producer.exists():
    shutil.copy2(producer, PACKAGE / "Sources/cmux")
adapter = ROOT / "Sources/TerminalController+Shepherd.swift"
if adapter.exists():
    shutil.copy2(adapter, PACKAGE / "Sources/cmux")
for name in ("TerminalController+Capabilities.swift", "CmuxSocketEventMapper.swift",
             "WorkspaceRemoteRelayCommandRewriter.swift", "Workspace+RemoteRelayCommandRewrite.swift",
             "ShepherdProcessEvidence.swift", "TerminalWorkingDirectoryResolver.swift",
             "ShepherdRenderEvidence.swift"):
    if not (ROOT / "Sources" / name).exists():
        continue
    shutil.copy2(ROOT / "Sources" / name, PACKAGE / "Sources/cmux")
shutil.copy2(ROOT / "cmuxTests/TerminalControllerShepherdHostTests.swift", PACKAGE / "Tests/AdapterTests")
shutil.copy2(ROOT / "cmuxTests/ShepherdProcessEvidenceTests.swift", PACKAGE / "Tests/AdapterTests")
shutil.copy2(ROOT / "cmuxTests/ShepherdRenderEvidenceTests.swift", PACKAGE / "Tests/AdapterTests")
shutil.copy2(ROOT / "cmuxTests/ShepherdInputReservationTests.swift", PACKAGE / "Tests/AdapterTests")
shutil.copy2(ROOT / "cmuxTests/ShepherdHookProducerTests.swift", PACKAGE / "Tests/AdapterTests")
shutil.copy2(
    ROOT / "Packages/macOS/CmuxControlSocket/Tests/CmuxControlSocketTests/ShepherdHookReadinessTests.swift",
    PACKAGE / "Tests/AdapterTests",
)
(PACKAGE / "Package.swift").write_text(f'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ShepherdAppSourceTests", platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "{ROOT / 'Packages/macOS/CmuxControlSocket'}"),
        .package(path: "{ROOT / 'Packages/macOS/CmuxFoundation'}"),
        .package(path: "{ROOT / 'Packages/macOS/CMUXAgentLaunch'}"),
        .package(path: "{ROOT / 'Packages/Shared/CMUXMobileCore'}"),
        .package(path: "{ROOT / 'Packages/macOS/CmuxRemoteWorkspace'}")
    ],
    targets: [
        .target(name: "GhosttyKit"),
        .target(name: "CmuxTerminal", dependencies: ["GhosttyKit",
            .product(name: "CMUXMobileCore", package: "CMUXMobileCore")]),
        .target(name: "cmux", dependencies: ["CmuxTerminal",
            .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            .product(name: "CMUXAgentLaunch", package: "CMUXAgentLaunch"),
            .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
            .product(name: "CmuxControlSocket", package: "CmuxControlSocket"),
            .product(name: "CmuxRemoteWorkspace", package: "CmuxRemoteWorkspace")]),
        .testTarget(name: "AdapterTests", dependencies: ["cmux", "CmuxTerminal",
            .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            .product(name: "CMUXAgentLaunch", package: "CMUXAgentLaunch"),
            .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
            .product(name: "CmuxControlSocket", package: "CmuxControlSocket")],
            swiftSettings: [.define("SHEPHERD_SOURCE_TEST")])
    ], swiftLanguageModes: [.v5])
''')
args = ["swift", "test", "--build-system", "native", "--package-path", str(PACKAGE), "--disable-index-store", "--jobs", "2",
        "-Xswiftc", "-gnone"]
if scratch := os.environ.get("SHEPHERD_APP_SOURCE_SCRATCH"):
    args += ["--scratch-path", scratch]
print(f"Headless source package: {PACKAGE}", flush=True)
raise SystemExit(subprocess.run(args, check=False).returncode)
