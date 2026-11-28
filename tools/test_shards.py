#!/usr/bin/env python3
"""Répartit les classes XCTest entre les shards de la CI iOS.

Les classes sont lues dans les sources, jamais recopiées : un fichier de tests
ajouté entre automatiquement dans la répartition, et `tests/test_test_shards.py`
échoue si une classe n'est attribuée à aucun shard.

Usage :
    python3 tools/test_shards.py --shards 3 --shard 2
    python3 tools/test_shards.py --list
"""

import argparse
from pathlib import Path
import re
import sys

REPO = Path(__file__).resolve().parents[1]
SOURCES = REPO / "ios"

# Une classe de tests se déclare `class NomTests: XCTestCase` et ses méthodes
# s'appellent `func test…`. Le nombre de méthodes sert d'estimation de durée.
CLASS_PATTERN = re.compile(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b")
METHOD_PATTERN = re.compile(r"\bfunc\s+(test\w*)\s*\(")


def collect_classes(paths):
    """Associe chaque classe XCTestCase au nombre de ses méthodes de test."""
    counts = {}
    for path in paths:
        current = None
        for line in path.read_text(encoding="utf-8").splitlines():
            declaration = CLASS_PATTERN.search(line)
            if declaration:
                current = declaration.group(1)
                counts.setdefault(current, 0)
                continue
            if current and METHOD_PATTERN.search(line):
                counts[current] += 1
    return counts


def source_files(root=SOURCES):
    return sorted(root.rglob("*.swift"))


def split(counts, shards):
    """Équilibre glouton : la classe la plus fournie va au shard le plus léger."""
    if shards < 1:
        raise ValueError("le nombre de shards doit être positif")
    names = sorted(counts, key=lambda name: (-counts[name], name))
    if len(names) < shards:
        raise ValueError(
            f"{len(names)} classes de tests pour {shards} shards : réduire le découpage"
        )
    buckets = [{"weight": 0, "names": []} for _ in range(shards)]
    for name in names:
        target = min(buckets, key=lambda bucket: (bucket["weight"], len(bucket["names"])))
        target["weight"] += counts[name]
        target["names"].append(name)
    return [sorted(bucket["names"]) for bucket in buckets]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shards", type=int, default=1, help="nombre total de shards")
    parser.add_argument("--shard", type=int, default=1, help="shard demandé, à partir de 1")
    parser.add_argument("--list", action="store_true", help="afficher les classes et leur poids")
    options = parser.parse_args(argv)

    counts = collect_classes(source_files())
    if not counts:
        print("Aucune classe XCTestCase trouvée dans ios/.", file=sys.stderr)
        return 1

    if options.list:
        for name in sorted(counts, key=lambda name: (-counts[name], name)):
            print(f"{counts[name]:4d}  {name}")
        return 0

    if not 1 <= options.shard <= options.shards:
        print(f"--shard doit être compris entre 1 et {options.shards}.", file=sys.stderr)
        return 2

    classes = split(counts, options.shards)[options.shard - 1]
    # Une ligne par classe : le workflow la convertit en -only-testing.
    print("\n".join(classes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
