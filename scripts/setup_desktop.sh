#!/usr/bin/env bash
set -euo pipefail

# Google Cloud Workstations desktop bootstrap:
# - Installs XFCE, TigerVNC, and noVNC/websockify
# - Starts Xvnc on DISPLAY, XFCE session, and noVNC proxy
# - Safe to re-run (idempotent process cleanup)

DISPLAY_NUM="${DISPLAY_NUM:-1}"
VNC_GEOMETRY="${VNC_GEOMETRY:-1920x1080}"
VNC_DEPTH="${VNC_DEPTH:-24}"
NOVNC_PORT="${NOVNC_PORT:-80}"
VNC_TARGET="127.0.0.1:$((5900 + DISPLAY_NUM))"
NOVNC_WEB_DIR="/usr/share/novnc"

log() {
	echo
	echo "========================================"
	echo "$1"
	echo "========================================"
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "ERROR: required command not found: $1" >&2
		exit 1
	}
}

run_privileged() {
	if [[ "$(id -u)" -eq 0 ]]; then
		"$@"
	else
		sudo "$@"
	fi
}

disable_problem_repo_lines() {
	local patterns=()
	patterns+=("dl.yarnpkg.com")
	patterns+=("deb.nodesource.com")
	patterns+=("packages.adoptium.net")
	local apt_files=()
	local list_file=""
	local pattern=""

	if [[ -f /etc/apt/sources.list ]]; then
		apt_files+=("/etc/apt/sources.list")
	fi

	shopt -s nullglob
	for list_file in /etc/apt/sources.list.d/*.list; do
		apt_files+=("${list_file}")
	done
	for list_file in /etc/apt/sources.list.d/*.sources; do
		apt_files+=("${list_file}")
	done

	for list_file in "${apt_files[@]}"; do
		for pattern in "${patterns[@]}"; do
			if grep -qi "${pattern}" "${list_file}"; then
				run_privileged cp -n "${list_file}" "${list_file}.gcw-desktop.bak" || true

				if [[ "${list_file}" == *.sources ]]; then
					run_privileged mv "${list_file}" "${list_file}.disabled-by-setup_desktop"
					echo "Temporarily disabled apt source ${pattern} by renaming ${list_file}"
					break
				fi

				run_privileged sed -i -E "s|^([[:space:]]*deb .*${pattern}.*)$|# disabled-by-setup_desktop.sh: \\1|I" "${list_file}"
				run_privileged sed -i -E "s|^([[:space:]]*deb-src .*${pattern}.*)$|# disabled-by-setup_desktop.sh: \\1|I" "${list_file}"
				echo "Temporarily disabled apt source ${pattern} in ${list_file}"
			fi
		done
	done
	shopt -u nullglob
}

apt_update_with_fallback() {
	if run_privileged apt-get update; then
		return 0
	fi

	echo "apt-get update failed. Attempting fallback by disabling optional third-party repos with common key issues..."
	disable_problem_repo_lines
	run_privileged apt-get update
}

log "setup_desktop.sh"
require_cmd apt-get
require_cmd pkill

log "1. Updating package index"
apt_update_with_fallback

log "2. Installing XFCE, TigerVNC, and noVNC"
run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y \
	xfce4 \
	xfce4-goodies \
	dbus-x11 \
	tigervnc-standalone-server \
	novnc \
	websockify

log "3. Preparing noVNC landing page"
run_privileged tee "${NOVNC_WEB_DIR}/index.html" >/dev/null <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
	<meta charset="utf-8">
	<meta http-equiv="refresh" content="0; url=vnc.html?autoconnect=true&resize=remote">
	<title>Loading desktop...</title>
</head>
<body>Loading desktop...</body>
</html>
EOF

log "4. Starting Xvnc and XFCE on :${DISPLAY_NUM}"
pkill Xvnc || true
pkill Xtigervnc || true
pkill -f startxfce4 || true
pkill -f xfce4-session || true

run_privileged mkdir -p /tmp/.X11-unix
run_privileged chmod 1777 /tmp/.X11-unix
run_privileged rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"

nohup Xvnc ":${DISPLAY_NUM}" \
	-SecurityTypes None \
	-geometry "${VNC_GEOMETRY}" \
	-depth "${VNC_DEPTH}" \
	> /tmp/xvnc.log 2>&1 &

sleep 2
nohup env DISPLAY=":${DISPLAY_NUM}" dbus-launch --exit-with-session startxfce4 \
	> /tmp/xfce4.log 2>&1 &

log "5. Starting noVNC/websockify on port ${NOVNC_PORT}"
pkill -f "websockify.* ${NOVNC_PORT} " || true

if [[ "${NOVNC_PORT}" -lt 1024 ]]; then
	run_privileged nohup websockify --web "${NOVNC_WEB_DIR}" "${NOVNC_PORT}" "${VNC_TARGET}" \
		> /tmp/websockify.log 2>&1 &
else
	nohup websockify --web "${NOVNC_WEB_DIR}" "${NOVNC_PORT}" "${VNC_TARGET}" \
		> /tmp/websockify.log 2>&1 &
fi

log "Setup complete"
echo "Display              : :${DISPLAY_NUM}"
echo "VNC target           : ${VNC_TARGET}"
echo "noVNC listen port    : ${NOVNC_PORT}"
echo "Logs                 : /tmp/xvnc.log, /tmp/xfce4.log, /tmp/websockify.log"
echo "Google Workstations  : map/expose NOVNC_PORT in workstation config if needed"