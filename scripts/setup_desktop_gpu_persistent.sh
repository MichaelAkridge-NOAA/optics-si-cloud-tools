#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Google Cloud Workstations — GPU + VirtualGL desktop with PERSISTENT auto-start
# =============================================================================
# Version: 2.0.0-gpu-persistent
#
# WHY THIS SCRIPT EXISTS
#   Cloud Workstations run as EPHEMERAL containers. On stop -> start the whole
#   container is recreated from the base image; ONLY the persistent home disk
#   (/home/<user>) survives. Anything written at runtime to /etc, /usr, /var —
#   including apt-installed packages and /etc/workstation-startup.d hooks — is
#   wiped. That is why a desktop set up by hand "works once" then never auto-
#   restarts after a stop/start.
#
#   This script fixes that WITHOUT requiring a custom Docker image by installing
#   a PERSISTENT boot hook at ~/.customize_environment. The stock base image
#   ships /etc/workstation-startup.d/030_customize-environment.sh, which runs
#   ~/.customize_environment as ROOT on EVERY container start. Because the home
#   disk persists, that hook survives restarts and re-provisions + relaunches the
#   GPU desktop automatically — no SSH, no manual step.
#
#   Tradeoff vs. a custom image: the hook re-runs apt-get on each boot if the
#   packages are missing, which adds time to first connect after a restart. For
#   the fastest startup, bake everything into an image instead (see ./docker).
#
# WHAT YOU GET
#   - XFCE desktop, TigerVNC, noVNC/websockify on port 80
#   - NVIDIA GPU detection + VirtualGL so `vglrun <app>` is hardware accelerated
#   - Auto-start that survives stop/start (persistent ~/.customize_environment)
#   - Immediate start for the current session
#
# USAGE
#   sudo bash setup_desktop_gpu_persistent.sh
#
# After install, launch 3D/OpenGL apps inside the noVNC desktop terminal with:
#   vglrun blender   vglrun qgis   vglrun paraview   vglrun glxgears
# =============================================================================

SCRIPT_VERSION="2.0.0-gpu-persistent"
VGL_VERSION="${VGL_VERSION:-3.1.1}"     # override: VGL_VERSION=3.0 sudo bash ...

DISPLAY_NUM="${DISPLAY_NUM:-1}"
VNC_GEOMETRY="${VNC_GEOMETRY:-1920x1080}"
VNC_DEPTH="${VNC_DEPTH:-24}"
NOVNC_PORT="${NOVNC_PORT:-80}"
NOVNC_WEB_DIR="/usr/share/novnc"

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

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "ERROR: required command not found: $1" >&2
		exit 1
	}
}

# Resolve the real (non-root) user even when invoked with sudo, plus their home.
ACTUAL_USER="${SUDO_USER:-${USER:-}}"
if [[ -z "${ACTUAL_USER}" || "${ACTUAL_USER}" == "root" ]]; then
	ACTUAL_USER="$(awk -F: '$3>=1000 && $3<60000 && $1!="nobody" {print $1; exit}' /etc/passwd)"
fi
if [[ -z "${ACTUAL_USER}" ]]; then
	echo "ERROR: could not determine a non-root user to own the persistent hook." >&2
	exit 1
fi
ACTUAL_HOME="$(eval echo "~${ACTUAL_USER}")"

log "setup_desktop_gpu_persistent.sh"
echo "Version       : ${SCRIPT_VERSION}"
echo "VirtualGL     : ${VGL_VERSION}"
echo "User / home   : ${ACTUAL_USER} / ${ACTUAL_HOME}"
echo "Display       : :${DISPLAY_NUM}"
echo "noVNC port    : ${NOVNC_PORT}"

require_cmd apt-get

# ----------------------------------------------------------------------------
# 1. Install the desktop + GPU stack
# ----------------------------------------------------------------------------
log "1. Installing XFCE, TigerVNC, noVNC, VirtualGL, mesa utils"
export DEBIAN_FRONTEND=noninteractive
run_privileged apt-get update || echo "WARNING: apt-get update reported errors (continuing)."
run_privileged apt-get install -y --no-install-recommends \
	xfce4 \
	xfce4-goodies \
	dbus-x11 \
	tigervnc-standalone-server \
	novnc \
	websockify \
	mesa-utils \
	iproute2 \
	wget \
	ca-certificates

# ----------------------------------------------------------------------------
# 2. NVIDIA GPU setup (best-effort — driver is host-injected on GPU configs)
# ----------------------------------------------------------------------------
log "2. NVIDIA GPU check"
find_nvidia_smi() {
	local c
	for c in \
		"$(command -v nvidia-smi 2>/dev/null)" \
		/var/lib/nvidia/bin/nvidia-smi \
		/usr/bin/nvidia-smi \
		/usr/local/nvidia/bin/nvidia-smi \
		/usr/local/bin/nvidia-smi; do
		[[ -n "${c}" && -x "${c}" ]] && { echo "${c}"; return 0; }
	done
	return 1
}
NVIDIA_SMI="$(find_nvidia_smi || true)"
if [[ -n "${NVIDIA_SMI}" ]] && "${NVIDIA_SMI}" >/dev/null 2>&1; then
	echo "NVIDIA GPU detected via ${NVIDIA_SMI}:"
	"${NVIDIA_SMI}" --query-gpu=name,driver_version --format=csv,noheader || true
else
	echo "WARNING: nvidia-smi not functional yet."
	echo "         On GPU workstation configs the driver is injected by the host."
	echo "         VirtualGL still installs; GPU rendering activates once the GPU is present."
fi

# ----------------------------------------------------------------------------
# 3. Install + configure VirtualGL
# ----------------------------------------------------------------------------
log "3. Installing VirtualGL ${VGL_VERSION}"
if command -v vglrun >/dev/null 2>&1; then
	echo "vglrun already installed: $(vglrun -version 2>&1 | head -1 || echo unknown)"
else
	VGL_DEB_URL="https://github.com/VirtualGL/virtualgl/releases/download/${VGL_VERSION}/virtualgl_${VGL_VERSION}_amd64.deb"
	TMP_DEB="/tmp/virtualgl_${VGL_VERSION}_amd64.deb"
	echo "Downloading ${VGL_DEB_URL}"
	if wget -q -O "${TMP_DEB}" "${VGL_DEB_URL}"; then
		run_privileged apt-get install -y "${TMP_DEB}" || echo "WARNING: VirtualGL install failed."
		rm -f "${TMP_DEB}"
	else
		echo "WARNING: VirtualGL download failed — desktop will start without GPU acceleration."
	fi
fi

# Configure the VGL server non-interactively (no-op if no display manager):
#   1 = GLX + EGL back ends, y/y/y = restrict to vglusers + disable XTEST, X = exit
if command -v vglserver_config >/dev/null 2>&1; then
	printf '1\ny\ny\ny\nX\n' | run_privileged vglserver_config || \
		echo "INFO: vglserver_config returned non-zero (normal without a running display manager)."
fi
# Allow the real user to use VirtualGL.
run_privileged usermod -aG vglusers "${ACTUAL_USER}" 2>/dev/null || true

# ----------------------------------------------------------------------------
# 4. Write the shared desktop launcher used by BOTH the boot hook and "start now"
# ----------------------------------------------------------------------------
log "4. Installing desktop launcher /usr/local/bin/start-gpu-desktop.sh"
run_privileged tee /usr/local/bin/start-gpu-desktop.sh >/dev/null <<LAUNCHER
#!/usr/bin/env bash
# Starts XFCE + TigerVNC + noVNC. Idempotent. Runs as root from the boot hook.
set -uo pipefail

LOG="/var/log/desktop-autostart.log"
echo "=== gpu desktop start \$(date '+%F %T') ===" >> "\$LOG"

DISPLAY_NUM="\${DISPLAY_NUM:-${DISPLAY_NUM}}"
NOVNC_PORT="\${NOVNC_PORT:-${NOVNC_PORT}}"
NOVNC_WEB_DIR="\${NOVNC_WEB_DIR:-${NOVNC_WEB_DIR}}"
VNC_GEOMETRY="\${VNC_GEOMETRY:-${VNC_GEOMETRY}}"
VNC_DEPTH="\${VNC_DEPTH:-${VNC_DEPTH}}"
VNC_TARGET="127.0.0.1:\$((5900 + DISPLAY_NUM))"

VNC_BIN=""
for b in Xvnc Xtigervnc; do
	command -v "\$b" >/dev/null 2>&1 && VNC_BIN="\$b" && break
done
if [[ -z "\$VNC_BIN" ]]; then
	echo "ERROR: no Xvnc/Xtigervnc binary present" >> "\$LOG"
	exit 0
fi

# Already up? leave it.
if pgrep -x "\$VNC_BIN" >/dev/null 2>&1 && pgrep -f websockify >/dev/null 2>&1; then
	echo "Desktop already running, skipping." >> "\$LOG"
	exit 0
fi

pkill "\$VNC_BIN" 2>/dev/null || true
pkill -f startxfce4 2>/dev/null || true
pkill -f xfce4-session 2>/dev/null || true
pkill -f websockify 2>/dev/null || true

mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
rm -f "/tmp/.X\${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X\${DISPLAY_NUM}"

nohup "\$VNC_BIN" ":\${DISPLAY_NUM}" -SecurityTypes None \\
	-geometry "\${VNC_GEOMETRY}" -depth "\${VNC_DEPTH}" >> "\$LOG" 2>&1 &
sleep 2

# Login shell sources /etc/profile.d/* so nvidia-smi, CUDA, conda, vglrun are on PATH.
nohup env DISPLAY=":\${DISPLAY_NUM}" dbus-launch --exit-with-session \\
	bash --login -c 'exec startxfce4' >> "\$LOG" 2>&1 &

nohup websockify --web "\${NOVNC_WEB_DIR}" "\${NOVNC_PORT}" "\${VNC_TARGET}" >> "\$LOG" 2>&1 &

# Wait for the listener so the GCP ingress health check passes.
for _w in \$(seq 1 30); do
	if command -v ss >/dev/null 2>&1; then
		ss -ltn 2>/dev/null | grep -q ":\${NOVNC_PORT} " && break
	elif command -v netstat >/dev/null 2>&1; then
		netstat -ltn 2>/dev/null | grep -q ":\${NOVNC_PORT} " && break
	fi
	sleep 1
done

# Suppress screensaver / root lock warning once XFCE settles.
(
	sleep 10
	DISPLAY=":\${DISPLAY_NUM}" xfconf-query -c xfce4-screensaver   -p /saver/enabled -n -t bool -s false 2>/dev/null || true
	DISPLAY=":\${DISPLAY_NUM}" xfconf-query -c xfce4-screensaver   -p /lock/enabled  -n -t bool -s false 2>/dev/null || true
	DISPLAY=":\${DISPLAY_NUM}" xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac      -n -t int  -s 0 2>/dev/null || true
	DISPLAY=":\${DISPLAY_NUM}" xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-sleep -n -t uint -s 0 2>/dev/null || true
	DISPLAY=":\${DISPLAY_NUM}" xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-off   -n -t uint -s 0 2>/dev/null || true
) >> "\$LOG" 2>&1 &

echo "Desktop start complete (port \${NOVNC_PORT})" >> "\$LOG"
exit 0
LAUNCHER
run_privileged chmod +x /usr/local/bin/start-gpu-desktop.sh

# ----------------------------------------------------------------------------
# 5. PERSISTENT boot hook — survives stop/start via the home disk
# ----------------------------------------------------------------------------
# The base image runs ~/.customize_environment as root on every boot. To let
# multiple tools (this desktop, Label Studio, etc.) coexist, ~/.customize_environment
# is a small DISPATCHER that runs every executable in ~/.customize_environment.d/.
# Each tool drops its own file there instead of fighting over one file.
log "5. Installing persistent boot hook ${ACTUAL_HOME}/.customize_environment"
HOOK="${ACTUAL_HOME}/.customize_environment"
HOOK_DIR="${ACTUAL_HOME}/.customize_environment.d"
run_privileged mkdir -p "${HOOK_DIR}"

# Install/refresh the dispatcher only if it is not already our dispatcher, so we
# never clobber an existing hook that other tooling may rely on.
if ! { [[ -f "${HOOK}" ]] && grep -q 'customize_environment.d dispatcher' "${HOOK}"; }; then
	if [[ -f "${HOOK}" ]] && ! grep -q 'customize_environment.d dispatcher' "${HOOK}"; then
		# Preserve a pre-existing custom hook by moving it into the drop-in dir.
		run_privileged cp "${HOOK}" "${HOOK_DIR}/00-original-customize_environment.sh"
		run_privileged chmod +x "${HOOK_DIR}/00-original-customize_environment.sh"
	fi
	run_privileged tee "${HOOK}" >/dev/null <<'DISPATCH'
#!/bin/bash
# customize_environment.d dispatcher — runs as root on every Cloud Workstation
# start. Executes each script in ~/.customize_environment.d/ so multiple tools
# can register persistent boot actions without overwriting each other.
set -uo pipefail
HOOK_DIR="$(dirname "$0")/.customize_environment.d"
[[ -d "$HOOK_DIR" ]] || exit 0
for _f in "$HOOK_DIR"/*; do
	[[ -f "$_f" && -x "$_f" ]] || continue
	"$_f" || true
done
DISPATCH
	run_privileged chmod +x "${HOOK}"
	run_privileged chown "${ACTUAL_USER}:${ACTUAL_USER}" "${HOOK}"
fi

# Drop in this desktop's boot action.
run_privileged tee "${HOOK_DIR}/50-gpu-desktop.sh" >/dev/null <<CUSTOMIZE
#!/bin/bash
# Re-provisions + launches the GPU desktop on every boot (container is recreated
# from the base image each start, so packages and /usr/local scripts are wiped).
set -uo pipefail

LOG="/var/log/desktop-autostart.log"
echo "=== customize_environment gpu-desktop \$(date '+%F %T') ===" >> "\$LOG"

export DEBIAN_FRONTEND=noninteractive
DISPLAY_NUM="${DISPLAY_NUM}"
NOVNC_PORT="${NOVNC_PORT}"
VGL_VERSION="${VGL_VERSION}"

# Reinstall the desktop stack if it was wiped by the container reset.
if ! command -v Xvnc >/dev/null 2>&1 && ! command -v Xtigervnc >/dev/null 2>&1; then
	echo "Reinstalling desktop packages..." >> "\$LOG"
	apt-get update >> "\$LOG" 2>&1 || true
	apt-get install -y --no-install-recommends \\
		xfce4 xfce4-goodies dbus-x11 tigervnc-standalone-server \\
		novnc websockify mesa-utils iproute2 wget ca-certificates >> "\$LOG" 2>&1 || true
fi

# Reinstall VirtualGL if missing.
if ! command -v vglrun >/dev/null 2>&1; then
	echo "Reinstalling VirtualGL \${VGL_VERSION}..." >> "\$LOG"
	TMP_DEB="/tmp/virtualgl_\${VGL_VERSION}_amd64.deb"
	if wget -q -O "\$TMP_DEB" \\
		"https://github.com/VirtualGL/virtualgl/releases/download/\${VGL_VERSION}/virtualgl_\${VGL_VERSION}_amd64.deb"; then
		apt-get install -y "\$TMP_DEB" >> "\$LOG" 2>&1 || true
		rm -f "\$TMP_DEB"
		printf '1\\ny\\ny\\ny\\nX\\n' | vglserver_config >> "\$LOG" 2>&1 || true
		usermod -aG vglusers "${ACTUAL_USER}" 2>/dev/null || true
	fi
fi

# The launcher itself lives in /usr/local/bin (ephemeral) — restore if missing.
if [[ ! -x /usr/local/bin/start-gpu-desktop.sh ]]; then
	echo "Launcher missing after reset; restoring from persistent copy." >> "\$LOG"
	if [[ -f "${ACTUAL_HOME}/.local/share/gpu-desktop/start-gpu-desktop.sh" ]]; then
		install -m 0755 "${ACTUAL_HOME}/.local/share/gpu-desktop/start-gpu-desktop.sh" \\
			/usr/local/bin/start-gpu-desktop.sh
	fi
fi

DISPLAY_NUM="\${DISPLAY_NUM}" NOVNC_PORT="\${NOVNC_PORT}" /usr/local/bin/start-gpu-desktop.sh
CUSTOMIZE
run_privileged chmod +x "${HOOK_DIR}/50-gpu-desktop.sh"
run_privileged chown -R "${ACTUAL_USER}:${ACTUAL_USER}" "${HOOK_DIR}"

# Keep a persistent copy of the launcher on the home disk so the hook can restore
# it after the /usr/local/bin copy is wiped on container reset.
PERSIST_DIR="${ACTUAL_HOME}/.local/share/gpu-desktop"
run_privileged mkdir -p "${PERSIST_DIR}"
run_privileged cp /usr/local/bin/start-gpu-desktop.sh "${PERSIST_DIR}/start-gpu-desktop.sh"
run_privileged chown -R "${ACTUAL_USER}:${ACTUAL_USER}" "${PERSIST_DIR}"

# ----------------------------------------------------------------------------
# 6. ALSO install the in-session GCP hook (covers the current boot if present)
# ----------------------------------------------------------------------------
log "6. Installing in-session GCP startup hook (if directory exists)"
if [[ -d /etc/workstation-startup.d ]]; then
	run_privileged tee /etc/workstation-startup.d/50-start-desktop >/dev/null <<HOOK
#!/bin/bash
DISPLAY_NUM="${DISPLAY_NUM}" NOVNC_PORT="${NOVNC_PORT}" /usr/local/bin/start-gpu-desktop.sh
HOOK
	run_privileged chmod +x /etc/workstation-startup.d/50-start-desktop
	echo "Installed /etc/workstation-startup.d/50-start-desktop (note: ephemeral, restored each boot by the persistent hook)."
fi

# ----------------------------------------------------------------------------
# 7. Start the desktop now
# ----------------------------------------------------------------------------
log "7. Starting the desktop for this session"
run_privileged env DISPLAY_NUM="${DISPLAY_NUM}" NOVNC_PORT="${NOVNC_PORT}" \
	/usr/local/bin/start-gpu-desktop.sh

sleep 2
log "Setup complete"
echo "Version            : ${SCRIPT_VERSION}"
echo "Persistent hook    : ${HOOK}"
echo "Launcher           : /usr/local/bin/start-gpu-desktop.sh"
echo "Persistent copy    : ${PERSIST_DIR}/start-gpu-desktop.sh"
echo "Log                : /var/log/desktop-autostart.log"
echo "noVNC URL          : open the workstation web preview on port ${NOVNC_PORT}"
echo
echo "GPU-accelerated OpenGL inside the noVNC desktop terminal:"
echo "  vglrun glxgears                                          # quick test"
echo "  DISPLAY=:${DISPLAY_NUM} vglrun glxinfo | grep 'OpenGL renderer'   # confirm GPU (not llvmpipe)"
echo "  vglrun blender / vglrun qgis / vglrun paraview"
echo
echo "Verify auto-start survives a restart:"
echo "  1) Stop then Start the workstation from the console (no SSH)."
echo "  2) Open the port ${NOVNC_PORT} preview — the desktop should already be up."
echo "  3) If needed: sudo tail -n 80 /var/log/desktop-autostart.log"
