#!/usr/bin/env python3
"""Promote only one approved PlatformLab SemVer image in the Helm values file.

No external Python modules required; fail if expected keys are absent.
"""
import argparse
import re
from pathlib import Path


def promote(text: str, owner: str, component: str, tag: str) -> str:
    owner = owner.lower()
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", owner):
        raise ValueError("Invalid GitHub owner")
    if component not in ("backend", "frontend"):
        raise ValueError("Invalid component")
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
        raise ValueError("Expected vMAJOR.MINOR.PATCH with no leading zeros")

    active = None
    inside_image = False
    seen = set()
    result = []
    for line in text.splitlines(keepends=True):
        if re.match(r"^[a-zA-Z][a-zA-Z0-9_-]*:\s*(?:#.*)?(?:\n)?$", line):
            active = line.split(":", 1)[0]
            inside_image = False
        elif (line.startswith("  ") and not line.startswith("    ")
              and line.strip() and not line.lstrip().startswith("#")):
            inside_image = line.strip().split(":", 1)[0] == "image"
        if active == component and inside_image:
            match = re.match(r"^(    )(repository|tag):[^\n\r]*(\r?\n)?$", line)
            if match:
                field = match.group(2)
                value = f"ghcr.io/{owner}/platformlab-{component}" if field == "repository" else tag
                line = f"    {field}: {value}{match.group(3) or ''}"
                if field in seen:
                    raise ValueError(f"Duplicate {component}.image.{field}")
                seen.add(field)
        result.append(line)

    if seen != {"repository", "tag"}:
        raise ValueError(f"Unexpected {component}.image values layout; found {seen}")
    return "".join(result)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--component", choices=("backend", "frontend"), required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--file", default="helm/platformlab/values.yaml")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    path = Path(args.file)
    old = path.read_text(encoding="utf-8")
    new = promote(old, args.owner, args.component, args.tag)
    if args.dry_run:
        print(new)
    elif new != old:
        path.write_text(new, encoding="utf-8")
        print(f"Updated {path}: {args.component} -> {args.tag}")
    else:
        print(f"Already up to date: {path}")


if __name__ == "__main__":
    main()
