#!/bin/sh
# Pack this directory as rchromium-sandbox-kernel.{zip,tar.gz} in <outdir>
# (default: ../out). Regenerates nothing; the patches are checked in.
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/../out}
mkdir -p "$out"
out=$(cd "$out" && pwd)
cd "$here/.."
rm -f "$out/rchromium-sandbox-kernel.zip" "$out/rchromium-sandbox-kernel.tar.gz"
tar czf "$out/rchromium-sandbox-kernel.tar.gz" --exclude=make-kit.sh sandbox-kernel
if command -v zip >/dev/null; then
	zip -qr "$out/rchromium-sandbox-kernel.zip" sandbox-kernel -x sandbox-kernel/make-kit.sh
else
	python3 - "$out/rchromium-sandbox-kernel.zip" <<'PY'
import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk("sandbox-kernel"):
        dirs.sort()
        for f in sorted(files):
            if f != "make-kit.sh":
                z.write(os.path.join(root, f))  # keeps the mode bits
PY
fi
ls -l "$out"/rchromium-sandbox-kernel.*
