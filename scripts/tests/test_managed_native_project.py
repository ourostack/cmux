"""Validate native managed sources in the actual parsed app-target build graph."""

from pathlib import Path
import plistlib
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ManagedNativeProjectTests(unittest.TestCase):
    def test_app_target_compiles_both_reservation_and_rpc_boundary_exactly_once(self):
        project = plistlib.loads(subprocess.check_output([
            "plutil", "-convert", "xml1", "-o", "-", str(ROOT / "cmux.xcodeproj/project.pbxproj"),
        ]))
        objects = project["objects"]
        target = next(value for value in objects.values()
                      if value.get("isa") == "PBXNativeTarget" and value.get("name") == "cmux")
        source_paths = [
            objects[objects[build_id]["fileRef"]]["path"]
            for phase_id in target["buildPhases"]
            if objects[phase_id]["isa"] == "PBXSourcesBuildPhase"
            for build_id in objects[phase_id]["files"]
            if "fileRef" in objects[build_id]
        ]
        for name in ["AgentSessionManagedRendererReservation.swift", "AgentSessionManagedShepherdBoundary.swift"]:
            with self.subTest(source=name):
                self.assertEqual(source_paths.count("Panels/" + name), 1,
                                 f"{name} is missing, duplicated, or aliased in the real app build graph")


if __name__ == "__main__":
    unittest.main()
