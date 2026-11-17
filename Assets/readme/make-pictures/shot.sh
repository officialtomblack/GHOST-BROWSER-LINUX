#!/bin/bash
# shot.sh <html> <png> [width] [height] : 2x screenshot, transparent background, cropped to content
in="$1"; out="$2"; w="${3:-1400}"; h="${4:-1600}"
google-chrome --headless=new --disable-gpu --no-sandbox --hide-scrollbars --force-device-scale-factor=2 \
  --default-background-color=00000000 --window-size="$w,$h" --virtual-time-budget=2000 --screenshot="$out" "file://$in" 2>/dev/null
python3 -I - "$out" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGBA"); im = im.crop(im.getchannel("A").getbbox()); im.save(sys.argv[1]); print(sys.argv[1].rsplit("/", 1)[-1], im.size)
PY
