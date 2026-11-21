#!/usr/bin/env python3
"""Refuse les données personnelles et les secrets avant qu'ils n'entrent dans le dépôt.

Trois modes, un seul jeu de motifs :

  --staged          lignes ajoutées dans l'index git (hook pre-commit)
  --files A B ...   fichiers entiers (contrôle d'un arbre)
  --text FICHIER    texte libre, par exemple le corps d'une issue ou d'une PR

Le compte rendu ne cite jamais la valeur trouvée : le journal d'un dépôt public est
public lui-même. Il donne la catégorie, le fichier et la ligne.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys

# (catégorie, motif, exemple autorisé)
PATTERNS = [
    ("jeton GitHub", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"), None),
    ("clé privée", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----"), None),
    ("clé d'API", re.compile(r"\b(?:sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})\b"), None),
    ("adresse e-mail", re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"), None),
    # UDID d'iPhone : forme 8-16 en majuscules. Les empreintes SHA-1 de 40 caractères
    # hexadécimales pullulent dans les révisions de modèles, elles sont donc exclues.
    ("identifiant d'appareil", re.compile(r"\b[0-9A-F]{8}-[0-9A-F]{16}\b"), None),
    ("Team ID Apple", re.compile(r"DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}\b"), None),
    # Une adresse d'hôte, pas un bloc CIDR (10.0.0.0/8, 192.168.0.0/16) ni une adresse de réseau.
    ("adresse réseau privée", re.compile(r"\b(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}(?!/)\b"), None),
]

# Valeurs d'exemple documentées et adresses techniques : jamais signalées.
ALLOWED = re.compile(
    r"(@users\.noreply\.github\.com|@example\.(?:com|org)|@api\.openai|"
    r"\b192\.168\.1\.\d{1,3}\b|"  # exemple documenté du dépôt (192.168.1.x)
    r"\b(?:192\.0\.2|198\.51\.100|203\.0\.113)\.\d{1,3}\b|"  # plages de documentation RFC 5737
    r"\b(?:0{40}|f{40}|1234567890abcdef1234567890abcdef12345678)\b|"
    r"192\.168\.\d{1,3}\.x\b|192\.168\.x\.x\b|10\.0\.0\.x\b)",
    re.IGNORECASE,
)

SKIP_SUFFIXES = (".png", ".jpg", ".jpeg", ".gif", ".pdf", ".ipa", ".zip", ".xcresult")

# Un fichier de tests qui vérifie la politique réseau doit citer des adresses privées.
# L'exemption se déclare en tête de fichier et se justifie, elle reste greppable en revue.
FILE_EXEMPTION = "personal-data: allow-file"
EXEMPTION_WINDOW = 20


def exempt(path: str) -> bool:
    try:
        with open(path, encoding="utf-8", errors="ignore") as handle:
            head = [next(handle, "") for _ in range(EXEMPTION_WINDOW)]
    except (OSError, StopIteration):
        return False
    return any(FILE_EXEMPTION in line for line in head)


def findings(line: str) -> list[str]:
    hits = []
    for name, pattern, _ in PATTERNS:
        for match in pattern.finditer(line):
            if ALLOWED.search(match.group(0)):
                continue
            hits.append(name)
            break
    return hits


def scan_staged() -> list[tuple[str, int, list[str]]]:
    diff = subprocess.run(["git", "diff", "--cached", "--unified=0", "--no-color", "--no-ext-diff"],
                          capture_output=True, text=True, check=True).stdout
    results, current, last_line, checked = [], None, 0, {}
    for raw in diff.splitlines():
        if raw.startswith("+++ "):
            path = raw[6:].strip()
            current = None if path == "/dev/null" else (path[2:] if path.startswith("b/") else path)
            last_line = 0
        elif raw.startswith("@@") and current:
            m = re.search(r"\+(\d+)", raw)
            last_line = int(m.group(1)) if m else 0
        elif raw.startswith("+") and current:
            if current not in checked:
                checked[current] = exempt(current)
            hits = [] if checked[current] else findings(raw[1:])
            if hits:
                results.append((current, last_line, hits))
            last_line += 1
    return results


def scan_file(path: str) -> list[tuple[str, int, list[str]]]:
    if path.lower().endswith(SKIP_SUFFIXES) or exempt(path):
        return []
    try:
        with open(path, encoding="utf-8", errors="ignore") as handle:
            lines = handle.readlines()
    except OSError:
        return []
    return [(path, number, hits) for number, line in enumerate(lines, 1) if (hits := findings(line))]


def scan_text(path: str) -> list[tuple[str, int, list[str]]]:
    try:
        with open(path, encoding="utf-8", errors="ignore") as handle:
            lines = handle.readlines()
    except OSError:
        return []
    return [(path, number, hits) for number, line in enumerate(lines, 1) if (hits := findings(line))]


def report(results: list[tuple[str, int, list[str]]]) -> int:
    if not results:
        print("Données personnelles : rien à signaler.")
        return 0
    print("Données personnelles ou secrets détectés (la valeur n'est pas affichée) :")
    for path, line, hits in results[:40]:
        print(f"  {path}:{line} — {', '.join(sorted(set(hits)))}")
    print(f"{len(results)} ligne(s). Remplacer par un libellé neutre "
          "(« l'iPhone de test », « une adresse LAN privée ») ou une valeur d'exemple.")
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--staged", action="store_true", help="lignes ajoutées dans l'index")
    group.add_argument("--files", nargs="+", metavar="FICHIER", help="fichiers à analyser")
    group.add_argument("--text", metavar="FICHIER", help="texte libre à analyser")
    args = parser.parse_args()

    if args.staged:
        return report(scan_staged())
    if args.files:
        results = []
        for path in args.files:
            results += scan_file(path)
        return report(results)
    return report(scan_text(args.text))


if __name__ == "__main__":
    sys.exit(main())
