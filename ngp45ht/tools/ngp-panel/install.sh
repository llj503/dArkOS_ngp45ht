#!/bin/bash
# install.sh [DESTDIR] — install the NGP45HT panel colour port and the CJK
# console font. Idempotent; safe to re-run.
#
#   ./install.sh            install on the running system (card update)
#   ./install.sh Arkbuild   install into an image build tree (finishing_touches)
#
# What lands where:
#   /opt/ngp-panel/panelprop.py    DRM connector property writer (ctypes+libdrm)
#   /opt/ngp-panel/paneladj.sh     paneladj port (set/up/down/value/values/restore)
#   /opt/ngp-panel/panel.conf      persisted values (ark-writable; never clobbered)
#   /opt/ngp-panel/README.md       provenance, mechanism, uninstall
#   /opt/system/屏幕色温.sh         ES system-menu front-end (Chinese dialog)
#   /usr/share/consolefonts/Unifont-CJK-panel.psf.gz   512-glyph CJK PSF2 font
#   /etc/systemd/system/ngp-panel-restore.service       boot-time restore (enabled)
#
# Ported from ROCKNIX (AveyondFly/distribution_rocknix) scripts/paneladj; see
# README.md for the mechanism and every trap hit on the way.

set -u
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-}"

install -D -m 0755 "$SRC/panelprop.py"            "$DEST/opt/ngp-panel/panelprop.py"
install -D -m 0755 "$SRC/paneladj.sh"             "$DEST/opt/ngp-panel/paneladj.sh"
install -D -m 0644 "$SRC/README.md"               "$DEST/opt/ngp-panel/README.md"
install -D -m 0755 "$SRC/屏幕色温.sh"              "$DEST/opt/system/屏幕色温.sh"
install -D -m 0644 "$SRC/Unifont-CJK-panel.psf.gz" "$DEST/usr/share/consolefonts/Unifont-CJK-panel.psf.gz"
install -D -m 0644 "$SRC/ngp-panel-restore.service" "$DEST/etc/systemd/system/ngp-panel-restore.service"

# default (neutral) settings — an existing file is the user's, keep it
if [ ! -f "$DEST/opt/ngp-panel/panel.conf" ]; then
  cat > "$DEST/opt/ngp-panel/panel.conf" <<'EOF'
# NGP45HT panel BCSH settings - 0-100, 50 = neutral (driver default).
brightness=50
contrast=50
saturation=50
hue=50
EOF
fi
chmod 0664 "$DEST/opt/ngp-panel/panel.conf"

if [ -z "$DEST" ]; then
  # running system: the menu front-end runs as ark and writes panel.conf
  chown ark:ark /opt/ngp-panel/panel.conf 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable ngp-panel-restore.service >/dev/null 2>&1
  systemctl start ngp-panel-restore.service >/dev/null 2>&1 || true
  echo "installed; current values:"
  /opt/ngp-panel/paneladj.sh values
else
  echo "installed into $DEST (enable ngp-panel-restore from the chroot)"
fi
