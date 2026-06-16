#!/usr/bin/env python3
"""Extract internal-graph facts from debian/control for one DEB source node."""
from __future__ import annotations

import argparse
import re
from pathlib import Path


def parse_control(path: Path) -> list[dict[str, str]]:
    paragraphs: list[dict[str, str]] = []
    current: dict[str, str] = {}
    last_key: str | None = None
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw.strip():
            if current:
                paragraphs.append(current)
                current = {}
                last_key = None
            continue
        if raw[0].isspace() and last_key:
            current[last_key] += "\n" + raw.strip()
            continue
        if ":" not in raw:
            continue
        key, value = raw.split(":", 1)
        last_key = key.strip()
        current[last_key] = value.strip()
    if current:
        paragraphs.append(current)
    return paragraphs


def dep_names(expr: str) -> list[str]:
    out: list[str] = []
    if not expr:
        return out
    expr = expr.replace("\n", " ")
    for group in expr.split(","):
        for alt in group.split("|"):
            alt = re.sub(r"<[^>]*>", "", alt)
            alt = re.sub(r"\[[^\]]*\]", "", alt)
            alt = re.sub(r"\([^)]*\)", "", alt)
            name = alt.strip().split()[0] if alt.strip() else ""
            if not name or name.startswith("${"):
                continue
            name = name.split(":", 1)[0]
            if name and name not in out:
                out.append(name)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--control", required=True, type=Path)
    ap.add_argument("--node", required=True)
    ap.add_argument("--providers-out", required=True, type=Path)
    ap.add_argument("--raw-builddeps-out", required=True, type=Path)
    ap.add_argument("--raw-runtimedeps-out", required=True, type=Path)
    args = ap.parse_args()

    paragraphs = parse_control(args.control)
    if not paragraphs:
        raise SystemExit(f"empty or unreadable control file: {args.control}")

    source = paragraphs[0]
    binaries = [p for p in paragraphs[1:] if p.get("Package")]
    if not binaries:
        raise SystemExit(f"no binary package stanzas in {args.control}")

    args.providers_out.parent.mkdir(parents=True, exist_ok=True)
    with args.providers_out.open("a", encoding="utf-8") as providers:
        for p in binaries:
            pkg = p.get("Package", "").strip()
            if pkg:
                print(f"{pkg}\t{args.node}", file=providers)
            for provided in dep_names(p.get("Provides", "")):
                print(f"{provided}\t{args.node}", file=providers)

    with args.raw_builddeps_out.open("a", encoding="utf-8") as builddeps:
        for field in ("Build-Depends", "Build-Depends-Arch", "Build-Depends-Indep"):
            for dep in dep_names(source.get(field, "")):
                print(f"{args.node}\t{dep}\t{field}", file=builddeps)

    with args.raw_runtimedeps_out.open("a", encoding="utf-8") as runtimedeps:
        for p in binaries:
            for field in ("Pre-Depends", "Depends"):
                for dep in dep_names(p.get(field, "")):
                    print(f"{args.node}\t{dep}\t{field}", file=runtimedeps)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
