#!/usr/bin/env bash
set -euo pipefail

# VirtualGL setup for Google Cloud Workstations (noVNC + TigerVNC)
# Run AFTER setup_desktop.sh has completed successfully.
# Enables hardware-accelerated OpenGL inside the VNC session via vglrun.
#
# Usage:
#   sudo bash setup_virtualgl.sh
#
# After install, launch GPU-accelerated apps with:
#   vglrun <app>       e.g.  vglrun glxgears
#                            vglrun blender
#                            vglrun qgis

SCRIPT_VERSION="1.0.0"
VGL_VERSION="${VGL_VERSION:-3.1.1}"   # override: VGL_VERSION=3.0 sudo bash setup_virtualgl.sh
DISPLAY_NUM="${DISPLAY_NUM:-1}"
VGL_DEB_URL="https://github.com/VirtualGL/virtualgl/releases/download/${VGL_VERSION}/virtualgl_${VGL_VERSION}_amd64.deb"
TMP_DEB="/tmp/virtualgl_${VGL_VERSION}_amd64.deb"

log() {
  echo
  echo "========================================"
  echo "$1"
  echo "========================================"
}

run_privileged() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

require_nvidia() {
  if ! nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: nvidia-smi not functional. Run setup_desktop.sh first and ensure the GPU driver is working." >&2
    exit 1
  fi
}

log "setup_virtualgl.sh v${SCRIPT_VERSION}"
echo "VirtualGL version    : ${VGL_VERSION}"
echo "Display              : :${DISPLAY_NUM}"

log "1. Checking prerequisites"
require_nvidia
echo "GPU OK:"
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader || true

log "2. Installing VirtualGL ${VGL_VERSION}"
if command -v vglrun >/dev/null 2>&1; then
  INSTALLED_VER="$(vglrun -version 2>&1 | grep -oP '\d+\.\d+(\.\d+)?' | head -1 || true)"
  echo "vglrun already installed (${INSTALLED_VER}). Skipping download."
else
  echo "Downloading ${VGL_DEB_URL}"
  wget -q --show-progress -O "${TMP_DEB}" "${VGL_DEB_URL}" || {
    echo "ERROR: download failed. Check VGL_VERSION or network access." >&2
    exit 1
  }
  run_privileged apt-get install -y "${TMP_DEB}"
  rm -f "${TMP_DEB}"
  echo "VirtualGL installed."
fi

log "3. Installing glxinfo / test utilities"
run_privileged apt-get install -y mesa-utils 2>/dev/null || true

log "4. Configuring VirtualGL server"
# vglserver_config sets up /etc/X11/xorg.conf and X server permissions
# for GPU-accelerated rendering. Flags:
#   +s = allow all local users to use VirtualGL (no strict auth)
#   +f = disable framebuffer device restrictions (needed on GCP)
#   -t = disable TCP transport (we use Unix sockets via VNC)
run_privileged vglserver_config +s +f -t || {
  echo "WARNING: vglserver_config returned non-zero. This may be harmless if Xorg is not running."
  echo "         VirtualGL can still work in VNC-only mode without a bare-metal Xorg server."
}

log "5. Smoke test"
set +e
DISPLAY=":${DISPLAY_NUM}" vglrun glxinfo 2>/dev/null | grep -E "OpenGL vendor|OpenGL renderer|OpenGL version" || \
  echo "INFO: glxinfo smoke test skipped (XFCE session may not be running yet — re-run after desktop starts)."
set -e

log "Setup complete"
echo "Version              : ${SCRIPT_VERSION}"
echo "VirtualGL            : $(vglrun -version 2>&1 | head -1 || echo 'installed')"
echo ""
echo "To launch a GPU-accelerated app inside the noVNC desktop terminal:"
echo "  vglrun glxgears          # basic OpenGL test"
echo "  vglrun blender           # 3D authoring"
echo "  vglrun qgis              # GIS with 3D"
echo "  vglrun paraview          # scientific visualization"
echo ""
echo "Check GPU rendering is active:"
echo "  DISPLAY=:${DISPLAY_NUM} vglrun glxinfo | grep 'OpenGL renderer'"
echo "  (should show Tesla T4, not llvmpipe/software)"
