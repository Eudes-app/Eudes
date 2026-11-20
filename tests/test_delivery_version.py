import base64
from concurrent.futures import ThreadPoolExecutor
import copy
import json
from pathlib import Path
import sys
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import delivery_version as delivery


BASELINE = {"version": "1.111", "build": 113}
COMMIT = "a" * 40


class FakeGitHub(delivery.GitHubRegistry):
    """Exercise the real HTTP adapter and optimistic writes without a remote mutation."""

    def __init__(self, race=False):
        super().__init__("example/eudes", "test-token")
        self.lock = threading.Lock()
        self.state = None
        self.pending_tree = None
        self.generation = 0
        self.writes = 0
        self.requests = []
        self.barrier = threading.Barrier(2) if race else None
        self.reads = 0
        self.fail_after_write = False
        self.reject_writes = None

    def request(self, method, path, data=None):
        wait = False
        with self.lock:
            self.requests.append((method, path))
            if path == f"git/ref/heads/{delivery.BRANCH}":
                if self.state is None:
                    raise delivery.APIError(404)
                return {"object": {"sha": "registry-commit"}}
            if path == "git/trees":
                self.pending_tree = json.loads(data["tree"][0]["content"])
                return {"sha": "tree"}
            if path == "git/commits":
                return {"sha": "commit"}
            if path == "git/refs":
                if self.state is not None:
                    raise delivery.APIError(422)
                self.state = copy.deepcopy(self.pending_tree)
                return {}
            if method == "GET":
                self.reads += 1
                wait = self.barrier is not None and self.reads <= 2
                result = {"type": "file", "encoding": "base64", "sha": str(self.generation),
                          "content": base64.b64encode(json.dumps(self.state).encode()).decode()}
            else:
                if self.reject_writes:
                    raise delivery.APIError(self.reject_writes)
                if data["sha"] != str(self.generation):
                    raise delivery.APIError(409)
                self.state = json.loads(base64.b64decode(data["content"]))
                self.generation += 1
                self.writes += 1
                if self.fail_after_write:
                    self.fail_after_write = False
                    raise RuntimeError("Connection lost after commit")
                return {}
        if wait:
            self.barrier.wait(timeout=5)
        return result


def reserve(registry, identifier="batch-one", commit=COMMIT, version=None):
    return delivery.reserve(registry, BASELINE, identifier, commit, version, pause=lambda _: None)


class DeliveryTests(unittest.TestCase):
    def test_first_delivery_is_above_previously_prepared_version(self):
        registry = FakeGitHub()
        result = reserve(registry)
        self.assertEqual((result["version"], result["build"]), ("1.112", 114))
        self.assertEqual(registry.writes, 1)

    def test_rebuild_and_corrected_commit_keep_the_same_numbers(self):
        registry = FakeGitHub()
        first = reserve(registry)
        self.assertEqual(reserve(registry, commit="b" * 40), first)
        self.assertEqual(registry.writes, 1)
        self.assertEqual(reserve(registry, "batch-two")["build"], 115)
        self.assertEqual(reserve(registry), first)

    def test_minor_version_is_an_integer_not_a_decimal(self):
        self.assertEqual(delivery.next_numbers({"version": "1.99", "build": 101}),
                         {"version": "1.100", "build": 102})

    def test_concurrent_different_deliveries_have_distinct_numbers(self):
        registry = FakeGitHub(race=True)
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda identifier: reserve(registry, identifier), ["one", "two"]))
        self.assertEqual({r["build"] for r in results}, {114, 115})
        self.assertEqual(registry.writes, 2)
        delivery.validate_registry(registry.state)

    def test_concurrent_same_delivery_is_reserved_once(self):
        registry = FakeGitHub(race=True)
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: reserve(registry), range(2)))
        self.assertEqual(results[0], results[1])
        self.assertEqual(registry.writes, 1)

    def test_unknown_write_result_is_recovered_by_same_id(self):
        registry = FakeGitHub()
        registry.fail_after_write = True
        with self.assertRaisesRegex(RuntimeError, "Connection lost"):
            reserve(registry)
        self.assertEqual(reserve(registry)["build"], 114)
        self.assertEqual(registry.writes, 1)

    def test_tag_reuses_existing_delivery_without_creating_alias(self):
        registry = FakeGitHub()
        first = reserve(registry)
        self.assertEqual(reserve(registry, "tag-v1.112", version="1.112"), first)
        self.assertEqual(registry.writes, 1)
        self.assertEqual(reserve(registry, "tag-v1.113", version="1.113")["build"], 115)

    def test_tag_cannot_silently_receive_a_different_version(self):
        registry = FakeGitHub()
        with self.assertRaisesRegex(ValueError, "next version"):
            reserve(registry, "tag-v1.90", version="1.90")
        self.assertEqual(registry.writes, 0)

    def test_invalid_input_cannot_create_registry(self):
        for identifier in ["", "../path", "bad\nversion=9.0", "$(command)", "a" * 81]:
            with self.subTest(identifier=identifier):
                registry = FakeGitHub()
                with self.assertRaises(ValueError):
                    reserve(registry, identifier)
                self.assertEqual(registry.requests, [])
        registry = FakeGitHub()
        with self.assertRaises(ValueError):
            reserve(registry, commit="main")
        self.assertEqual(registry.requests, [])

    def test_tag_and_existing_id_must_agree_even_when_version_exists(self):
        registry = FakeGitHub()
        reserve(registry, "one")
        reserve(registry, "two")
        with self.assertRaisesRegex(ValueError, "disagree"):
            reserve(registry, "two", version="1.112")
        self.assertEqual(registry.writes, 2)

    def test_corrupt_registry_never_restarts_from_baseline(self):
        for corrupt in [None, {"schema": 2}, {"schema": 1, "baseline": BASELINE, "deliveries": {}}]:
            registry = FakeGitHub()
            registry.initialize(BASELINE)
            # JSON null is a corrupt existing file, not an absent branch.
            registry.state = corrupt if corrupt is not None else {"schema": 1}
            with self.assertRaises((ValueError, KeyError)):
                reserve(registry)
            self.assertEqual(registry.writes, 0)

    def test_sequence_gaps_and_duplicate_ids_are_rejected(self):
        registry = FakeGitHub()
        reserve(registry)
        registry.state["deliveries"][0]["build"] = 150
        with self.assertRaisesRegex(ValueError, "sequence"):
            reserve(registry, "another")
        registry.state["deliveries"][0]["build"] = 114
        registry.state["deliveries"].append(copy.deepcopy(registry.state["deliveries"][0]))
        with self.assertRaisesRegex(ValueError, "duplicate"):
            reserve(registry, "another")
        self.assertEqual(registry.writes, 1)

    def test_changed_baseline_requires_explicit_migration(self):
        registry = FakeGitHub()
        registry.initialize({"version": "1.110", "build": 112})
        with self.assertRaisesRegex(ValueError, "migration"):
            reserve(registry)
        self.assertEqual(registry.writes, 0)

    def test_permission_failure_never_falls_back_to_local_version(self):
        registry = FakeGitHub()
        registry.reject_writes = 403
        with self.assertRaisesRegex(delivery.APIError, "403"):
            reserve(registry)
        self.assertEqual(registry.writes, 0)

    def test_repeated_conflicts_fail_without_returning_unreserved_numbers(self):
        registry = FakeGitHub()
        registry.reject_writes = 409
        with self.assertRaisesRegex(RuntimeError, "remained busy"):
            reserve(registry)
        self.assertEqual(registry.reads, 8)
        self.assertEqual(registry.writes, 0)

    def test_build_limit_stops_instead_of_reusing_a_number(self):
        with self.assertRaises(ValueError):
            delivery.next_numbers({"version": "1.99", "build": 9999})


if __name__ == "__main__":
    unittest.main()
