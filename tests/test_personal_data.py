# personal-data: allow-file — ce fichier vérifie les motifs du garde-fou, il doit donc les citer.
import json
import os
import subprocess
import sys
import tempfile
import unittest

TOOLS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools")
TOOL = os.path.join(TOOLS, "check_personal_data.py")
sys.path.insert(0, TOOLS)
import check_personal_data as guard  # noqa: E402


class PatternsTests(unittest.TestCase):
    def test_detects_a_device_identifier(self):
        self.assertIn("identifiant d'appareil", guard.findings("udid 00008030-000A1C2E3A8A802E"))

    def test_detects_a_real_mailbox(self):
        self.assertIn("adresse e-mail", guard.findings("contact jean.dupont@gmail.com"))

    def test_detects_a_token(self):
        self.assertIn("jeton GitHub", guard.findings("token ghp_abcdefghijklmnopqrstuvwxyz0123456789"))

    def test_detects_a_team_identifier(self):
        self.assertIn("Team ID Apple", guard.findings("DEVELOPMENT_TEAM = AB12CD34EF"))

    def test_detects_a_private_host_address(self):
        self.assertIn("adresse réseau privée", guard.findings("server http://192.168.254.254:8000/v1"))

    def test_documented_examples_are_allowed(self):
        for line in ("http://192.168.1.20:8000/v1",
                     "http://192.168.1.5:8000/v1",
                     "http://192.0.2.7/",
                     "268676963+adrienncl@users.noreply.github.com",
                     "contact@example.com"):
            self.assertEqual(guard.findings(line), [], line)

    def test_network_blocks_are_not_host_addresses(self):
        self.assertEqual(guard.findings("\t\t\t<key>192.168.0.0/16</key>"), [])
        self.assertEqual(guard.findings("\t\t\t<key>10.0.0.0/8</key>"), [])

    def test_commit_hashes_of_model_revisions_are_not_device_identifiers(self):
        self.assertEqual(guard.findings('revision: "cd0c74c575b5c416f3011b5b4c298077f26ca8c2"'), [])

    def test_a_line_can_carry_several_categories(self):
        hits = guard.findings("mail a@b.fr ip 10.4.12.7")
        self.assertEqual(sorted(set(hits)), ["adresse e-mail", "adresse réseau privée"])


class ReportTests(unittest.TestCase):
    def test_report_never_prints_the_value(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8") as handle:
            handle.write("udid 00008030-000A1C2E3A8A802E\n")
            path = handle.name
        try:
            result = subprocess.run([sys.executable, TOOL, "--text", path],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("identifiant d'appareil", result.stdout)
            self.assertNotIn("00008030", result.stdout)
        finally:
            os.unlink(path)

    def test_clean_text_passes(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8") as handle:
            handle.write("Rien à signaler, l'iPhone de test et 192.168.1.20.\n")
            path = handle.name
        try:
            result = subprocess.run([sys.executable, TOOL, "--text", path],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout)
        finally:
            os.unlink(path)


class ExemptionTests(unittest.TestCase):
    def test_a_test_file_can_declare_its_exemption(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "Policy.swift")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("// personal-data: allow-file — politique réseau\nlet blocked = [\"10.0.0.1\"]\n")
            self.assertTrue(guard.exempt(path))
            self.assertEqual(guard.scan_file(path), [])

    def test_without_the_marker_the_file_is_scanned(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "Leak.md")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("adresse http://10.4.12.7:8000\n")
            self.assertFalse(guard.exempt(path))
            self.assertEqual(len(guard.scan_file(path)), 1)


class StagedTests(unittest.TestCase):
    def test_detects_a_leak_in_the_index_only(self):
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                subprocess.run(["git", *args], cwd=directory, check=True,
                               capture_output=True, text=True)

            git("init", "-q")
            git("config", "user.email", "268676963+adrienncl@users.noreply.github.com")
            git("config", "user.name", "guard")
            with open(os.path.join(directory, "notes.md"), "w", encoding="utf-8") as handle:
                handle.write("serveur http://10.4.12.7:8000\n")
            git("add", "notes.md")
            previous = os.getcwd()
            os.chdir(directory)
            try:
                results = guard.scan_staged()
            finally:
                os.chdir(previous)
            self.assertEqual(len(results), 1)
            self.assertEqual(results[0][0], "notes.md")
            self.assertIn("adresse réseau privée", results[0][2])


if __name__ == "__main__":
    unittest.main()
