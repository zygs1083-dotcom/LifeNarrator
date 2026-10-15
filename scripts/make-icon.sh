#!/bin/bash
# Requires Python 3, CairoSVG and Pillow: python3 -m pip install --user CairoSVG Pillow
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from io import BytesIO
from pathlib import Path
import struct

import cairosvg
from PIL import Image

image = Image.open(BytesIO(cairosvg.svg2png(url="Assets/AppIcon.svg"))).convert("RGBA")
sizes = {"icp4": 16, "icp5": 32, "icp6": 64, "ic07": 128, "ic08": 256,
         "ic09": 512, "ic10": 1024, "ic11": 32, "ic12": 64, "ic13": 256, "ic14": 512}
chunks = []
for kind, size in sizes.items():
    png = BytesIO()
    image.resize((size, size), Image.Resampling.LANCZOS).save(png, format="PNG")
    data = png.getvalue()
    chunks.append(kind.encode("ascii") + struct.pack(">I", len(data) + 8) + data)
body = b"".join(chunks)
Path("Assets/AppIcon.icns").write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
PY
