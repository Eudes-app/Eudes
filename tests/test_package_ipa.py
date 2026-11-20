import json
from pathlib import Path
import plistlib
import stat
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from package_ipa import package


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="Eudes delivery test ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "Eudes.app"
        self.widget = self.app / "PlugIns/EudesVoiceWidget.appex"
        for bundle, identifier in [(self.app, "fr.eudes.app"),
                                   (self.widget, "fr.eudes.app.voice-widget")]:
            bundle.mkdir(parents=True)
            with (bundle / "Info.plist").open("wb") as stream:
                plistlib.dump({"CFBundleShortVersionString": "1.112", "CFBundleVersion": "114",
                               "CFBundleIdentifier": identifier}, stream, fmt=plistlib.FMT_BINARY)
        executable = self.app / "Eudes"
        executable.write_bytes(b"fixture")
        executable.chmod(0o755)

    def change_widget(self, key, value):
        plist = self.widget / "Info.plist"
        info = plistlib.loads(plist.read_bytes())
        info[key] = value
        plist.write_bytes(plistlib.dumps(info))

    def package(self):
        return package(self.app, self.root / "output", "1.112", 114, "batch-one", "b" * 40, "12345", "2")

    def test_archive_and_manifest_identify_the_same_delivery(self):
        (self.app / "framework-link").symlink_to("Eudes")
        name = self.package()
        self.assertEqual(name, "eudes-1.112-build-114-unsigned-12345-2")
        output = self.root / "output"
        with zipfile.ZipFile(output / f"{name}.ipa") as archive:
            info = plistlib.loads(archive.read("Payload/Eudes.app/Info.plist"))
            self.assertEqual(info["CFBundleVersion"], "114")
            self.assertTrue(archive.getinfo("Payload/Eudes.app/Eudes").external_attr >> 16 & 0o111)
            self.assertTrue(stat.S_ISLNK(archive.getinfo("Payload/Eudes.app/framework-link").external_attr >> 16))
        manifest = json.loads((output / f"{name}.json").read_text())
        self.assertEqual(manifest["source_commit"], "b" * 40)
        self.assertEqual(manifest["delivery_id"], "batch-one")
        self.assertFalse(manifest["signed"])

    def test_mismatched_widget_blocks_packaging(self):
        for key, value in [("CFBundleVersion", "92"), ("CFBundleShortVersionString", "1.90"),
                           ("CFBundleIdentifier", "unexpected.app")]:
            with self.subTest(key=key):
                original = (self.widget / "Info.plist").read_bytes()
                self.change_widget(key, value)
                with self.assertRaises(ValueError):
                    self.package()
                self.assertFalse((self.root / "output").exists())
                (self.widget / "Info.plist").write_bytes(original)

    def test_missing_widget_blocks_packaging(self):
        self.widget.rename(self.widget.with_suffix(".missing"))
        with self.assertRaisesRegex(ValueError, "missing"):
            self.package()

    def test_stale_signed_product_is_rejected(self):
        (self.widget / "_CodeSignature").mkdir()
        with self.assertRaisesRegex(ValueError, "unsigned"):
            self.package()

    def test_existing_output_is_never_silently_repacked(self):
        self.package()
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.package()


if __name__ == "__main__":
    unittest.main()
