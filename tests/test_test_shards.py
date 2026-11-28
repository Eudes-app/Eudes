import sys
from pathlib import Path
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import test_shards as shards

REPO = Path(__file__).resolve().parents[1]


class ShardCoverageTests(unittest.TestCase):
    """La répartition doit couvrir chaque classe une seule fois : c'est la garantie
    qu'aucun test ne disparaît de la CI quand on découpe la suite."""

    def setUp(self):
        self.counts = shards.collect_classes(shards.source_files())

    def test_sources_present_at_least_the_known_suites(self):
        for name in ("VoiceAssistantTests", "PrivateStorageTests", "WebSearchStoreTests"):
            self.assertIn(name, self.counts)

    def test_every_class_belongs_to_exactly_one_shard(self):
        for size in range(1, 5):
            covered = [name for bucket in shards.split(self.counts, size) for name in bucket]
            self.assertEqual(sorted(covered), sorted(self.counts), f"{size} shards")
            self.assertEqual(len(covered), len(set(covered)), f"{size} shards")

    def test_no_shard_is_empty(self):
        for size in range(1, 5):
            for bucket in shards.split(self.counts, size):
                self.assertTrue(bucket, f"un shard vide sur {size}")

    def test_split_is_deterministic(self):
        self.assertEqual(shards.split(self.counts, 3), shards.split(self.counts, 3))

    def test_split_refuses_more_shards_than_classes(self):
        counts = {"OneTests": 1, "TwoTests": 2}
        with self.assertRaises(ValueError):
            shards.split(counts, 3)

    def test_weights_stay_close(self):
        buckets = shards.split(self.counts, 3)
        weights = [sum(self.counts[name] for name in bucket) for bucket in buckets]
        self.assertLessEqual(max(weights) / max(min(weights), 1), 3)


class ParsingTests(unittest.TestCase):
    def parse(self, text):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "SampleTests.swift"
            path.write_text(text, encoding="utf-8")
            return shards.collect_classes([path])

    def test_counts_methods_per_class_in_a_shared_file(self):
        counts = self.parse(
            "final class FirstTests: XCTestCase {\n"
            "    func testOne() {}\n"
            "    func testTwo() {}\n"
            "}\n"
            "final class SecondTests: XCTestCase {\n"
            "    func testThree() {}\n"
            "    func helper() {}\n"
            "}\n"
        )
        self.assertEqual(counts, {"FirstTests": 2, "SecondTests": 1})

    def test_ignores_classes_that_are_not_test_cases(self):
        counts = self.parse(
            "final class Helper: XCTestCaseObserver {}\n"
            "final class RealTests: XCTestCase {}\n"
        )
        self.assertEqual(counts, {"RealTests": 0})


class CommandLineTests(unittest.TestCase):
    def run_cli(self, *arguments):
        import contextlib
        import io

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = shards.main(list(arguments))
        return code, output.getvalue()

    def test_a_shard_prints_one_bare_class_name_per_line(self):
        code, output = self.run_cli("--shards", "3", "--shard", "2")
        self.assertEqual(code, 0)
        names = output.split()
        self.assertTrue(names)
        for name in names:
            self.assertRegex(name, r"^[A-Za-z][A-Za-z0-9]*$")

    def test_an_out_of_range_shard_is_rejected(self):
        code, _ = self.run_cli("--shards", "3", "--shard", "4")
        self.assertEqual(code, 2)


class RepositoryTests(unittest.TestCase):
    """Le workflow doit rester aligné sur ce découpage."""

    def workflow(self):
        return (REPO / ".github" / "workflows" / "ios.yml").read_text(encoding="utf-8")

    def test_workflow_runs_three_shards_and_keeps_the_required_check_name(self):
        text = self.workflow()
        self.assertIn("shard: [1, 2, 3]", text)
        self.assertIn("test_shards.py", text)
        self.assertIn("name: XCTest · iPhone simulator\n", text)


if __name__ == "__main__":
    unittest.main()
