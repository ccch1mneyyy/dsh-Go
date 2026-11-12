# TEMP (reverse/tawcroot-proto, never merge): pre-seed runtime/.cache/ubuntu/debs from the
# official Ubuntu archives when the tuna mirror has dropped a locked (superseded) version.
# Only the exact locked bytes are kept: every file is checked against the lock's sha256, and
# build-runtime.sh checks it again before use.
import hashlib
import json
import pathlib
import sys
import urllib.request

root = pathlib.Path(sys.argv[1])
arch = sys.argv[2]
lock = json.loads((root / f"runtime/locks/ubuntu-noble-{arch}.json").read_text())
cache = root / "runtime/.cache/ubuntu/debs"
cache.mkdir(parents=True, exist_ok=True)
# The lock dates from 2026-10-29; superseded versions stay in Ubuntu's snapshot service.
archive = "ubuntu-ports" if arch == "arm64" else "ubuntu"
bases = [f"https://snapshot.ubuntu.com/{archive}/{stamp}" for stamp in
         ("20261029T000000Z", "20261101T000000Z", "20261025T000000Z", "20261020T000000Z")]
bases += ["http://ports.ubuntu.com/ubuntu-ports"] if arch == "arm64" else ["http://azure.archive.ubuntu.com/ubuntu"]
errors = []
missing = []
for package in lock["packages"]:
    name = package["filename"].rsplit("/", 1)[-1]
    dest = cache / name
    if dest.exists() and hashlib.sha256(dest.read_bytes()).hexdigest() == package["sha256"]:
        continue
    for base in bases:
        try:
            data = urllib.request.urlopen(f"{base}/{package['filename']}", timeout=30).read()
        except Exception as error:  # diagnostics only; the hash below decides
            errors.append(f"{base}/{package['filename']}: {type(error).__name__} {error}")
            continue
        if hashlib.sha256(data).hexdigest() == package["sha256"]:
            dest.write_bytes(data)
            break
    else:
        missing.append(name)
print(*errors[:12], sep="\n")
print(f"seeded {len(lock['packages']) - len(missing)}/{len(lock['packages'])} locked debs; missing: {missing}")
