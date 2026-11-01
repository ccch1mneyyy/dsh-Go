#!/usr/bin/env python3
"""Check that the repo's version story agrees with itself (see docs/release.md).

Four things name the same version, and when they drift apart the failure is
silent: the app reports a version the repository has no source for, and
"check for updates" compares against a manifest nobody can rebuild.

  app/pubspec.yaml   the version name the APK is built with (versionName)
  docs/changelog.md  the newest heading; its body becomes the Release notes
  git tags           v<version name>, what the app downloads from GitHub
  update.json        the published manifest, when it is already out

1.0.5-1.0.7 shipped with all four tags on one commit while pubspec and the
changelog still said 1.0.4, so this runs as a check.

    python3 tooling/release_check.py                       # this checkout
    python3 tooling/release_check.py --update-json u.json  # plus a published manifest
    python3 tooling/release_check.py --root /path/to/clone

Exit codes: 0 agree, 1 problems (printed), 2 cannot judge (no tags, no git,
unreadable file).
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys

# Windows 的控制台默认不是 UTF-8（cp1252 / cp936），打印 ✓ / ✗ 会 UnicodeEncodeError。
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, 'reconfigure'):
        _stream.reconfigure(encoding='utf-8', errors='replace')

ROOT = pathlib.Path(__file__).resolve().parent.parent
VERSION_RE = re.compile(r"^(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?:\+(\d+))?$")
CHANGELOG_RE = re.compile(r"^##\s+(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\s*(?:·.*)?$", re.MULTILINE)


class CheckError(Exception):
    """Cannot judge: missing input, not a git checkout, no tags fetched."""


def parse_version(text: str) -> tuple[str, str | None]:
    """`1.2.0+10251234` -> ('1.2.0', '10251234'); raises CheckError on nonsense."""
    match = VERSION_RE.match(text.strip())
    if not match:
        raise CheckError(f"not a version name: {text!r}")
    return match.group(1), match.group(2)


def sort_key(name: str) -> tuple:
    """Semver ordering with pre-releases before their own release."""
    core, _, pre = name.partition('-')
    parts = tuple(int(p) for p in core.split('.'))
    return (parts, 0 if pre else 1, pre)


def pubspec_version(root: pathlib.Path) -> str:
    text = (root / "app" / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"^version:\s*(\S+)", text, re.MULTILINE)
    if not match:
        raise CheckError("version: not found in app/pubspec.yaml")
    return match.group(1)


def changelog_versions(root: pathlib.Path) -> list[str]:
    path = root / "docs" / "changelog.md"
    if not path.exists():
        raise CheckError("docs/changelog.md not found")
    return CHANGELOG_RE.findall(path.read_text(encoding="utf-8"))


def release_tags(root: pathlib.Path) -> dict[str, str]:
    """{version name: commit} for tags named `vX.Y.Z[-pre]`."""
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "for-each-ref", "--format=%(refname:short) %(objectname:short)", "refs/tags"],
            capture_output=True, text=True, check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise CheckError(f"cannot read git tags ({error}); is this a git checkout?") from error
    tags: dict[str, str] = {}
    for line in out.splitlines():
        tag, _, commit = line.partition(" ")
        match = re.fullmatch(r"v(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)", tag.strip())
        if match:
            tags[match.group(1)] = commit.strip()
    if not tags:
        raise CheckError("no v* release tags in this clone; run `git fetch --tags`")
    return tags


def check(pubspec: str, changelog: list[str], tags: dict[str, str], update: dict | None = None) -> list[str]:
    """Pure check: the problems, in the order a person would fix them."""
    problems: list[str] = []
    name, build = parse_version(pubspec)

    # 1. the changelog describes the version the source tree declares
    if not changelog:
        problems.append("docs/changelog.md has no '## X.Y.Z' heading")
    elif changelog[0] != name:
        problems.append(f"docs/changelog.md's newest entry is {changelog[0]}, but app/pubspec.yaml says {name}")
    if name not in changelog:
        problems.append(f"docs/changelog.md has no entry for {name}")

    # 2. the repository is not behind its own releases
    newest = max(tags, key=sort_key) if tags else None
    if newest is None:
        problems.append("no v* release tag found")
    elif sort_key(newest) > sort_key(name):
        problems.append(
            f"tag v{newest} is newer than app/pubspec.yaml's {name}: the repository has no source for that release"
        )

    # 3. one commit cannot be several releases
    by_commit: dict[str, list[str]] = {}
    for version, commit in tags.items():
        by_commit.setdefault(commit, []).append(version)
    for commit, versions in sorted(by_commit.items()):
        if len(versions) > 1:
            listed = ", ".join(f"v{v}" for v in sorted(versions, key=sort_key))
            problems.append(f"{listed} all point at commit {commit}: one commit cannot be several releases")

    # 4. a published manifest describes the version this tree declares
    if update is not None:
        published = str(update.get("version", ""))
        tag = str(update.get("tag", ""))
        try:
            published_name, _ = parse_version(published)
        except CheckError:
            problems.append(f"update.json's version is not a version name: {published!r}")
            published_name = ""
        if published_name and sort_key(published_name) > sort_key(name):
            problems.append(f"update.json publishes {published_name}, but app/pubspec.yaml says {name}")
        if tag and tag.lstrip('v') not in tags and tag != f"v{name}":
            problems.append(f"update.json points at tag {tag}, which the repository does not have")

    if build is None:
        problems.append(f"app/pubspec.yaml carries no +build placeholder ({pubspec!r})")
    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=pathlib.Path, default=ROOT, help="repository root (default: this checkout)")
    parser.add_argument("--update-json", type=pathlib.Path, help="also compare a published update.json")
    args = parser.parse_args(argv)

    try:
        pubspec = pubspec_version(args.root)
        changelog = changelog_versions(args.root)
        tags = release_tags(args.root)
    except (CheckError, OSError) as error:
        print(f"✗ {error}", file=sys.stderr)
        return 2

    update = None
    if args.update_json is not None:
        try:
            update = json.loads(args.update_json.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            print(f"✗ cannot read {args.update_json}: {error}", file=sys.stderr)
            return 2

    problems = check(pubspec, changelog, tags, update)
    if problems:
        print("\n".join(f"✗ {p}" for p in problems))
        print(f"✗ {len(problems)} problem(s); the version story does not agree (see docs/release.md)")
        return 1
    name, build = parse_version(pubspec)
    print(f"✓ {name} ({build}): pubspec, changelog, tags and manifest agree")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
