#!/usr/bin/env bash
set -euo pipefail

# Google Cloud Workstations desktop bootstrap:
# - Installs XFCE, TigerVNC, and noVNC/websockify
# - Starts Xvnc on DISPLAY, XFCE session, and noVNC proxy
# - Safe to re-run (idempotent process cleanup)

SCRIPT_VERSION="1.6.0"

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

detect_vnc_server() {
	if command -v Xvnc >/dev/null 2>&1; then
		echo "Xvnc"
		return 0
	fi

	if command -v Xtigervnc >/dev/null 2>&1; then
		echo "Xtigervnc"
		return 0
	fi

	echo "ERROR: neither Xvnc nor Xtigervnc is available after install." >&2
	exit 1
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
	patterns+=("yarnpkg")
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
	local update_rc=0

	set +e
	run_privileged apt-get update
	update_rc=$?
	set -e

	if [[ "${update_rc}" -eq 0 ]]; then
		return 0
	fi

	echo "apt-get update failed. Attempting fallback by disabling optional third-party repos with common key issues..."
	disable_problem_repo_lines
	run_privileged apt-get update
}

log "setup_desktop.sh"
echo "Version: ${SCRIPT_VERSION}"
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

VNC_SERVER_BIN="$(detect_vnc_server)"
require_cmd dbus-launch
require_cmd startxfce4
require_cmd websockify

log "3. NVIDIA GPU setup (if applicable)"
setup_nvidia() {
	# Check for NVIDIA GPU via lspci
	if ! lspci 2>/dev/null | grep -qi 'nvidia'; then
		echo "No NVIDIA GPU detected via lspci, skipping."
		return 0
	fi
	echo "NVIDIA GPU detected."

	# Test if nvidia-smi already works
	if nvidia-smi >/dev/null 2>&1; then
		echo "nvidia-smi OK."
		nvidia-smi --query-gpu=name,driver_version --format=csv,noheader || true
		return 0
	fi

	echo "nvidia-smi not functional. Attempting to load kernel module..."
	set +e
	run_privileged modprobe nvidia
	local mod_rc=$?
	set -e

	if [[ "${mod_rc}" -eq 0 ]] && nvidia-smi >/dev/null 2>&1; then
		echo "nvidia kernel module loaded successfully."
		nvidia-smi --query-gpu=name,driver_version --format=csv,noheader || true
		return 0
	fi

	# Determine recommended driver version and install it
	echo "Kernel module unavailable. Installing NVIDIA drivers..."
	local recommended=""
	if command -v ubuntu-drivers >/dev/null 2>&1; then
		recommended=$(ubuntu-drivers devices 2>/dev/null | awk '/recommended/{print $NF}' | head -1)
		echo "ubuntu-drivers recommended: ${recommended:-none}"
	fi

	if [[ -n "${recommended}" ]]; then
		run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y "${recommended}"
	else
		# Fallback: install latest signed driver available in apt
		local driver_pkg
		driver_pkg=$(apt-cache search '^nvidia-driver-[0-9]+$' 2>/dev/null \
			| awk '{print $1}' | sort -t- -k3 -V | tail -1)
		if [[ -z "${driver_pkg}" ]]; then
			echo "WARNING: could not find an nvidia-driver package in apt. Install manually."
			return 0
		fi
		echo "Installing fallback driver: ${driver_pkg}"
		run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y "${driver_pkg}"
	fi

	set +e
	run_privileged modprobe nvidia
	set -e

	if nvidia-smi >/dev/null 2>&1; then
		echo "nvidia-smi OK after driver install."
		nvidia-smi --query-gpu=name,driver_version --format=csv,noheader || true
	else
		echo "WARNING: nvidia-smi still not functional. A reboot may be required."
		echo "        Run: sudo reboot  -- then re-run this script."
	fi
}
setup_nvidia

log "4. Preparing noVNC landing page"
run_privileged tee "${NOVNC_WEB_DIR}/index.html" >/dev/null <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Optics SI Cloud Workstation</title>
  <style>
    *{margin:0;padding:0;box-sizing:border-box}
    body{background:#0d1b2a;color:#e0e8f0;font-family:'Segoe UI',Arial,sans-serif;
         display:flex;flex-direction:column;align-items:center;justify-content:center;
         min-height:100vh;text-align:center;padding:24px}
    .logo{width:200px;margin-bottom:20px}
    h1{font-size:1.55rem;font-weight:600;color:#7ec8e3;margin-bottom:6px}
    h2{font-size:0.95rem;font-weight:400;color:#8aabb8;margin-bottom:28px}
    .info{background:#112236;border:1px solid #1e4a7a;border-radius:8px;
          padding:14px 28px;margin-bottom:28px;font-size:0.82rem;line-height:2;
          color:#b8d0de}
    .info b{color:#7ec8e3}
    .info a{color:#7ec8e3;text-decoration:none}
    .spinner{width:36px;height:36px;border:4px solid #1a3a5c;
             border-top:4px solid #7ec8e3;border-radius:50%;
             animation:spin 0.9s linear infinite;margin:0 auto 14px}
    @keyframes spin{to{transform:rotate(360deg)}}
    #msg{font-size:0.88rem;color:#5a8fa8}
    footer{position:fixed;bottom:14px;font-size:0.72rem;color:#2e5470}
  </style>
</head>
<body>
  <img class="logo"
       src="https://raw.githubusercontent.com/MichaelAkridge-NOAA/optics-si-cloud-tools/refs/heads/main/docs/logo/optics_si_logo_v1.png"
       alt="Optics SI"
       onerror="this.style.display='none'">
  <h1>Optics SI Cloud Workstation</h1>
  <h2>NOAA &mdash; Google Cloud Workstations</h2>
  <div class="info">
    <b>Version:</b> ${SCRIPT_VERSION} &nbsp;|&nbsp;
    <b>Display:</b> :${DISPLAY_NUM} &nbsp;|&nbsp;
    <b>Port:</b> ${NOVNC_PORT}<br>
    <a href="https://michaelakridge-noaa.github.io/optics-si-cloud-tools/" target="_blank">&#x1F4D6; Optics SI Codelabs &amp; Setup Guides</a>
  </div>
  <div class="spinner"></div>
  <div id="msg">Connecting to desktop in <b id="n">3</b>s&hellip;</div>
  <footer>NOAA Fisheries &bull; Pacific Islands Fisheries Science Center &bull; Optics SI</footer>
  <script>
    var n=3,t=setInterval(function(){
      document.getElementById('n').textContent=--n;
      if(n<=0){clearInterval(t);location.href='vnc.html?autoconnect=true&resize=remote';}
    },1000);
  </script>
</body>
</html>
EOF

log "5. Starting Xvnc and XFCE on :${DISPLAY_NUM}"
pkill Xvnc || true
pkill Xtigervnc || true
pkill -f startxfce4 || true
pkill -f xfce4-session || true

run_privileged mkdir -p /tmp/.X11-unix
run_privileged chmod 1777 /tmp/.X11-unix
run_privileged rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"

nohup "${VNC_SERVER_BIN}" ":${DISPLAY_NUM}" \
	-SecurityTypes None \
	-geometry "${VNC_GEOMETRY}" \
	-depth "${VNC_DEPTH}" \
	> /tmp/xvnc.log 2>&1 &

sleep 2
# Use a login shell so /etc/profile.d/* is sourced — this ensures PATH includes
# nvidia-smi, cuda tools, conda, etc. inside the noVNC desktop terminal.
nohup env DISPLAY=":${DISPLAY_NUM}" dbus-launch --exit-with-session \
	bash --login -c 'exec startxfce4' \
	> /tmp/xfce4.log 2>&1 &

# Disable screensaver and screen lock in background after XFCE finishes loading.
# This suppresses the 'running as root' screensaver warning on Cloud Workstations.
(
	sleep 10
	DISPLAY=":${DISPLAY_NUM}" xfconf-query -c xfce4-screensaver -p /saver/enabled  -n -t bool -s false 2>/dev/null || true
	DISPLAY=":${DISPLAY_NUM}" xfconf-query -c xfce4-screensaver -p /lock/enabled   -n -t bool -s false 2>/dev/null || true
	DISPLAY=":${DISPLAY_NUM}" xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac       -n -t int -s 0 2>/dev/null || true
	DISPLAY=":${DISPLAY_NUM}" xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-sleep  -n -t uint -s 0 2>/dev/null || true
	DISPLAY=":${DISPLAY_NUM}" xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-off    -n -t uint -s 0 2>/dev/null || true
	echo "XFCE screensaver/lock disabled."
) &

log "6. Starting noVNC/websockify on port ${NOVNC_PORT}"
pkill -f "websockify.* ${NOVNC_PORT} " || true

if [[ "${NOVNC_PORT}" -lt 1024 ]]; then
	run_privileged nohup websockify --web "${NOVNC_WEB_DIR}" "${NOVNC_PORT}" "${VNC_TARGET}" \
		> /tmp/websockify.log 2>&1 &
else
	nohup websockify --web "${NOVNC_WEB_DIR}" "${NOVNC_PORT}" "${VNC_TARGET}" \
		> /tmp/websockify.log 2>&1 &
fi

sleep 1
if ! pgrep -f "${VNC_SERVER_BIN} :${DISPLAY_NUM}" >/dev/null 2>&1; then
	echo "WARNING: ${VNC_SERVER_BIN} may not be running. Check /tmp/xvnc.log"
fi

if ! pgrep -f "websockify.* ${NOVNC_PORT} " >/dev/null 2>&1; then
	echo "WARNING: websockify may not be running. Check /tmp/websockify.log"
fi

if command -v ss >/dev/null 2>&1; then
	if ! ss -ltn | grep -q ":${NOVNC_PORT} "; then
		echo "WARNING: no listener detected on port ${NOVNC_PORT}. Check /tmp/websockify.log"
	fi
fi

log "Setup complete"
echo "Version              : ${SCRIPT_VERSION}"
echo "Display              : :${DISPLAY_NUM}"
echo "VNC target           : ${VNC_TARGET}"
echo "noVNC listen port    : ${NOVNC_PORT}"
echo "VNC server binary    : ${VNC_SERVER_BIN}"
echo "Logs                 : /tmp/xvnc.log, /tmp/xfce4.log, /tmp/websockify.log"
echo "Google Workstations  : map/expose NOVNC_PORT in workstation config if needed"