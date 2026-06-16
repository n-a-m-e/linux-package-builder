#!/usr/bin/env python3
"""Strict effective build-time package graph sorter.

Input files are UTF-8 TSVs:
  nodes.tsv:        node_id\toptional display fields...
  builddeps.tsv:    provider_node_id\tdependent_node_id\toptional dependency name...
  runtimedeps.tsv:  provider_node_id\tdependent_node_id\toptional dependency name...

Output is one node_id per line in build order.

The effective build-time graph is strict:
  P must build after every provider of P's direct build dependencies, plus the
  runtime dependency closure of those providers. This is deliberately applied to
  both RPM and DEB, so a build cannot succeed merely because stale packages are
  already present in the target repository/buildroot.
"""
from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from heapq import heappop, heappush
from pathlib import Path


def read_nodes(path: Path) -> list[str]:
    nodes: list[str] = []
    seen: set[str] = set()
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        node = raw.split("\t", 1)[0].strip()
        if not node:
            continue
        if node in seen:
            raise SystemExit(f"duplicate graph node: {node}")
        seen.add(node)
        nodes.append(node)
    if not nodes:
        raise SystemExit("graph has no nodes")
    return nodes


def read_edges(path: Path, nodes: list[str], strict_unknown: bool) -> dict[str, set[str]]:
    node_set = set(nodes)
    graph: dict[str, set[str]] = defaultdict(set)
    for n in nodes:
        graph[n] |= set()
    if not path.exists():
        return graph
    for lineno, raw in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) < 2:
            raise SystemExit(f"{path}:{lineno}: expected provider<TAB>dependent")
        dep, pkg = parts[0].strip(), parts[1].strip()
        if not dep or not pkg or dep == pkg:
            continue
        if dep not in node_set or pkg not in node_set:
            if strict_unknown:
                raise SystemExit(f"{path}:{lineno}: edge references unknown node: {dep!r} -> {pkg!r}")
            continue
        # Stored as dependent -> providers needed before dependent.
        graph[pkg].add(dep)
    return graph


def tarjan(nodes: list[str], graph: dict[str, set[str]]) -> list[list[str]]:
    index = 0
    stack: list[str] = []
    on_stack: set[str] = set()
    idx: dict[str, int] = {}
    low: dict[str, int] = {}
    comps: list[list[str]] = []

    def visit(v: str) -> None:
        nonlocal index
        idx[v] = index
        low[v] = index
        index += 1
        stack.append(v)
        on_stack.add(v)
        for w in graph[v]:
            if w not in idx:
                visit(w)
                low[v] = min(low[v], low[w])
            elif w in on_stack:
                low[v] = min(low[v], idx[w])
        if low[v] == idx[v]:
            comp: list[str] = []
            while True:
                w = stack.pop()
                on_stack.remove(w)
                comp.append(w)
                if w == v:
                    break
            comps.append(comp)

    for n in nodes:
        if n not in idx:
            visit(n)
    return comps


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--nodes", required=True, type=Path)
    ap.add_argument("--builddeps", required=True, type=Path)
    ap.add_argument("--runtimedeps", required=True, type=Path)
    ap.add_argument("--effective-edges-out", type=Path)
    ap.add_argument("--strict-unknown-edges", action="store_true")
    args = ap.parse_args()

    nodes = read_nodes(args.nodes)
    stable_index = {n: i for i, n in enumerate(nodes)}
    build_graph = read_edges(args.builddeps, nodes, args.strict_unknown_edges)
    runtime_graph = read_edges(args.runtimedeps, nodes, args.strict_unknown_edges)

    runtime_closure_cache: dict[str, set[str]] = {}

    def runtime_closure(start: str) -> set[str]:
        if start in runtime_closure_cache:
            return set(runtime_closure_cache[start])
        out: set[str] = set()
        stack = list(runtime_graph[start])
        while stack:
            dep = stack.pop()
            if dep in out:
                continue
            out.add(dep)
            stack.extend(runtime_graph[dep] - out)
        runtime_closure_cache[start] = set(out)
        return out

    effective: dict[str, set[str]] = defaultdict(set)
    for pkg in nodes:
        for br_provider in build_graph[pkg]:
            if br_provider == pkg:
                continue
            effective[pkg].add(br_provider)
            for dep in runtime_closure(br_provider):
                if dep != pkg:
                    effective[pkg].add(dep)
        effective[pkg] |= set()

    if args.effective_edges_out:
        args.effective_edges_out.parent.mkdir(parents=True, exist_ok=True)
        with args.effective_edges_out.open("w", encoding="utf-8") as f:
            for pkg in nodes:
                for dep in sorted(effective[pkg], key=lambda n: stable_index[n]):
                    print(f"{dep}\t{pkg}", file=f)

    children: dict[str, set[str]] = defaultdict(set)
    indeg = {n: 0 for n in nodes}
    for pkg in nodes:
        for dep in effective[pkg]:
            children[dep].add(pkg)
            indeg[pkg] += 1

    ready: list[tuple[int, str]] = []
    for n in nodes:
        if indeg[n] == 0:
            heappush(ready, (stable_index[n], n))

    ordered: list[str] = []
    while ready:
        _, n = heappop(ready)
        ordered.append(n)
        for child in sorted(children[n], key=lambda x: stable_index[x]):
            indeg[child] -= 1
            if indeg[child] == 0:
                heappush(ready, (stable_index[child], child))

    if len(ordered) != len(nodes):
        ordered_set = set(ordered)
        remaining = [n for n in nodes if n not in ordered_set]
        remaining_set = set(remaining)
        print("ERROR: effective build-time dependency graph is cyclic.", file=sys.stderr)
        print("No package builds should be queued from this graph.", file=sys.stderr)
        print("", file=sys.stderr)
        print("Unorderable packages:", file=sys.stderr)
        for n in remaining:
            print(f"  {n}", file=sys.stderr)
        print("", file=sys.stderr)
        print("Effective edges inside unresolved group:", file=sys.stderr)
        any_effective = False
        for pkg in remaining:
            deps = sorted(effective[pkg] & remaining_set, key=lambda x: stable_index[x])
            if deps:
                any_effective = True
                print(f"  {pkg} needs: {', '.join(deps)}", file=sys.stderr)
        if not any_effective:
            print("  none", file=sys.stderr)
        print("", file=sys.stderr)
        print("Direct build dependency provider edges inside unresolved group:", file=sys.stderr)
        any_build = False
        for pkg in remaining:
            deps = sorted(build_graph[pkg] & remaining_set, key=lambda x: stable_index[x])
            if deps:
                any_build = True
                print(f"  {pkg} Build-Depends/BuildRequires providers: {', '.join(deps)}", file=sys.stderr)
        if not any_build:
            print("  none", file=sys.stderr)
        print("", file=sys.stderr)
        print("Runtime dependency provider edges inside unresolved group:", file=sys.stderr)
        any_runtime = False
        for pkg in remaining:
            deps = sorted(runtime_graph[pkg] & remaining_set, key=lambda x: stable_index[x])
            if deps:
                any_runtime = True
                print(f"  {pkg} runtime providers: {', '.join(deps)}", file=sys.stderr)
        if not any_runtime:
            print("  none", file=sys.stderr)
        return 1

    for n in ordered:
        print(n)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
