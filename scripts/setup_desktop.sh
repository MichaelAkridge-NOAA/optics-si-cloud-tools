#!/usr/bin/env bash
set -euo pipefail

# Google Cloud Workstations desktop bootstrap:
# - Installs XFCE, TigerVNC, and noVNC/websockify
# - Starts Xvnc on DISPLAY, XFCE session, and noVNC proxy
# - Safe to re-run (idempotent process cleanup)

SCRIPT_VERSION="1.9.0"

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
	# Probe known install locations — GCP T4 puts nvidia-smi at
	# /usr/local/nvidia/bin which is not in root's default sudo PATH.
	local nvidia_smi=""
	for _c in \
			"$(command -v nvidia-smi 2>/dev/null)" \
			/var/lib/nvidia/bin/nvidia-smi \
			/usr/bin/nvidia-smi \
			/usr/local/nvidia/bin/nvidia-smi \
			/usr/local/bin/nvidia-smi; do
		[[ -n "${_c}" && -x "${_c}" ]] && nvidia_smi="${_c}" && break
	done

	if [[ -n "${nvidia_smi}" ]] && "${nvidia_smi}" >/dev/null 2>&1; then
		echo "NVIDIA GPU detected via ${nvidia_smi}."
		"${nvidia_smi}" --query-gpu=name,driver_version --format=csv,noheader || true
		return 0
	fi

	if ! lspci 2>/dev/null | grep -qi 'nvidia'; then
		echo "No NVIDIA GPU detected (nvidia-smi unavailable, not in lspci). Skipping."
		return 0
	fi
	echo "NVIDIA GPU found via lspci. Attempting to load kernel module..."

	set +e
	run_privileged modprobe nvidia
	local mod_rc=$?
	set -e

	if [[ "${mod_rc}" -eq 0 ]] && [[ -n "${nvidia_smi}" ]] && "${nvidia_smi}" >/dev/null 2>&1; then
		echo "nvidia kernel module loaded successfully."
		"${nvidia_smi}" --query-gpu=name,driver_version --format=csv,noheader || true
		return 0
	fi

	echo "Kernel module unavailable. Installing NVIDIA drivers..."
	local recommended=""
	if command -v ubuntu-drivers >/dev/null 2>&1; then
		recommended=$(ubuntu-drivers devices 2>/dev/null | awk '/recommended/{print $NF}' | head -1)
		echo "ubuntu-drivers recommended: ${recommended:-none}"
	fi

	if [[ -n "${recommended}" ]]; then
		run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y "${recommended}"
	else
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

	if [[ -n "${nvidia_smi}" ]] && "${nvidia_smi}" >/dev/null 2>&1; then
		echo "nvidia-smi OK after driver install."
		"${nvidia_smi}" --query-gpu=name,driver_version --format=csv,noheader || true
	else
		echo "WARNING: nvidia-smi still not functional. A reboot may be required."
		echo "        Run: sudo reboot  -- then re-run this script."
	fi
}
setup_nvidia

log "4. Preparing noVNC landing page"
# Locate nvidia-smi — GCP T4 images often install it outside the default root PATH
NVIDIA_SMI=""
for _candidate in \
		"$(command -v nvidia-smi 2>/dev/null)" \
		/var/lib/nvidia/bin/nvidia-smi \
		/usr/bin/nvidia-smi \
		/usr/local/nvidia/bin/nvidia-smi \
		/usr/local/bin/nvidia-smi; do
	if [[ -n "${_candidate}" && -x "${_candidate}" ]]; then
		NVIDIA_SMI="${_candidate}"
		break
	fi
done

# Collect machine specs to embed in splash page
SPEC_CPU="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//' || echo 'N/A')"
SPEC_CORES="$(nproc 2>/dev/null || echo 'N/A')"
SPEC_RAM="$(awk '/MemTotal/{printf "%.0f GB", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 'N/A')"
SPEC_DISK="$(df -h / 2>/dev/null | awk 'NR==2{print $4" free / "$2" total"}' || echo 'N/A')"
SPEC_HOST="$(hostname 2>/dev/null || echo 'N/A')"
SPEC_GPU="$([[ -n "${NVIDIA_SMI}" ]] && "${NVIDIA_SMI}" --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo '')"
if [[ -z "${SPEC_GPU}" ]]; then
	SPEC_GPU="$(lspci 2>/dev/null | grep -i 'vga\|3d\|display' | head -1 | sed 's/.*: //' || echo 'N/A')"
fi
SPEC_DRIVER="$([[ -n "${NVIDIA_SMI}" ]] && "${NVIDIA_SMI}" --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo '')"
SPEC_BADGE="$(if [[ -n "${NVIDIA_SMI}" ]] && "${NVIDIA_SMI}" >/dev/null 2>&1; then echo 'GPU Workstation'; else echo 'CPU Workstation'; fi)"

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
         min-height:100vh;text-align:center;padding:32px 16px}
    .logo{width:180px;margin-bottom:14px}
    h1{font-size:1.6rem;font-weight:600;color:#7ec8e3;margin-bottom:4px}
    h2{font-size:0.95rem;font-weight:400;color:#8aabb8;margin-bottom:12px}
    .badge{display:inline-block;background:#0e3a5e;border:1px solid #2a7ab8;
           color:#7ec8e3;font-size:0.75rem;font-weight:700;letter-spacing:.06em;
           padding:4px 14px;border-radius:20px;margin-bottom:22px;text-transform:uppercase}
    .badge.gpu-badge{background:#0d2318;border-color:#2a6a3a;color:#5ec87e}
    .grid{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;
          width:100%;max-width:860px;margin-bottom:22px}
    .card{background:#112236;border:1px solid #1e4a7a;border-radius:8px;
          padding:12px 16px;font-size:0.82rem;color:#b8d0de;text-align:left}
    .card b{display:block;color:#7ec8e3;font-size:0.68rem;text-transform:uppercase;
            letter-spacing:.07em;margin-bottom:4px}
    .card.gpu{border-color:#2a6a3a;background:#0d2318}
    .card.gpu b{color:#5ec87e}
    .links{margin-bottom:22px;font-size:0.82rem}
    .links a{color:#7ec8e3;text-decoration:none;margin:0 10px}
    .links a:hover{text-decoration:underline}
    .bottom{display:flex;align-items:center;gap:16px;margin-bottom:8px}
    .spinner{width:28px;height:28px;border:3px solid #1a3a5c;
             border-top:3px solid #7ec8e3;border-radius:50%;
             animation:spin 0.9s linear infinite;flex-shrink:0}
    @keyframes spin{to{transform:rotate(360deg)}}
    #msg{font-size:0.88rem;color:#5a8fa8}
    .btn{background:#0e3a5e;border:1px solid #2a7ab8;color:#7ec8e3;
         font-size:0.85rem;padding:7px 22px;border-radius:6px;cursor:pointer;
         font-family:inherit;transition:background .2s}
    .btn:hover{background:#1a5a8e}
    footer{margin-top:18px;font-size:0.72rem;color:#2e5470}
    @media(max-width:700px){.grid{grid-template-columns:repeat(2,1fr)}}
  </style>
</head>
<body>
  <img class="logo"
       src="https://raw.githubusercontent.com/MichaelAkridge-NOAA/optics-si-cloud-tools/refs/heads/main/docs/logo/optics_si_logo_v1.png"
       alt="Optics SI" onerror="this.style.display='none'">
  <h1>Optics SI Cloud Workstation</h1>
  <h2>NOAA &mdash; Google Cloud Workstations</h2>
  <div class="badge $(if [[ -n "${SPEC_GPU}" && "${SPEC_GPU}" != 'N/A' ]]; then echo 'gpu-badge'; fi)">${SPEC_BADGE}</div>
  <div class="grid">
    <div class="card"><b>Host</b>${SPEC_HOST}</div>
    <div class="card"><b>CPU</b>${SPEC_CPU}</div>
    <div class="card"><b>Cores</b>${SPEC_CORES} vCPU</div>
    <div class="card"><b>RAM</b>${SPEC_RAM}</div>
    <div class="card"><b>Disk (/)</b>${SPEC_DISK}</div>
    <div class="card gpu"><b>GPU</b>${SPEC_GPU:-N/A}</div>
    $(if [[ -n "${SPEC_DRIVER}" ]]; then echo "    <div class=\"card gpu\"><b>Driver</b>${SPEC_DRIVER}</div>"; fi)
    <div class="card"><b>noVNC Port</b>${NOVNC_PORT}</div>
    <div class="card"><b>Display</b>:${DISPLAY_NUM}</div>
    <div class="card"><b>Setup Version</b>${SCRIPT_VERSION}</div>
  </div>
  <div class="links">
    <a href="https://michaelakridge-noaa.github.io/optics-si-cloud-tools/" target="_blank">&#x1F4D6; Codelabs</a>
    <a href="https://github.com/MichaelAkridge-NOAA/optics-si-cloud-tools" target="_blank">&#x1F4E6; GitHub</a>
  </div>
  <div class="bottom">
    <div class="spinner"></div>
    <div id="msg">Auto-connecting in <b id="n">7</b>s&hellip;</div>
    <button class="btn" onclick="go()">Connect Now &rarr;</button>
  </div>
  <footer>NOAA Fisheries &bull; Pacific Islands Fisheries Science Center &bull; Optics SI</footer>
  <script>
    function go(){clearInterval(t);location.href='vnc.html?autoconnect=true&resize=remote';}
    var n=7,t=setInterval(function(){
      document.getElementById('n').textContent=--n;
      if(n<=0)go();
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

log "7. Configuring auto-start on boot"
install_autostart() {
	local display_num="${DISPLAY_NUM}"
	local novnc_port="${NOVNC_PORT}"
	local novnc_web_dir="${NOVNC_WEB_DIR}"
	local script_version="${SCRIPT_VERSION}"

	# --- Method 1: GCP Cloud Workstation hook (preferred) -------------------
	if [[ -d /etc/workstation-startup.d ]]; then
		local hook="/etc/workstation-startup.d/50-start-desktop"
		run_privileged tee "${hook}" >/dev/null <<HOOKEOF
#!/bin/bash
set -euo pipefail
LOG="/var/log/desktop-autostart.log"
echo "=== desktop autostart \$(date '+%Y-%m-%d %H:%M:%S') ===" >> "\$LOG"

DISPLAY_NUM="${display_num}"
NOVNC_PORT="${novnc_port}"
NOVNC_WEB="${novnc_web_dir}"
VNC_TARGET="127.0.0.1:\$((5900 + DISPLAY_NUM))"

# Wait up to 2 min for the persistent home disk to mount and VNC binaries to be visible.
# On GCP Workstations the home mount and /usr paths can lag a few seconds after boot.
for _i in \$(seq 1 24); do
    command -v Xvnc >/dev/null 2>&1 || command -v Xtigervnc >/dev/null 2>&1 && break
    echo "Waiting for VNC binary... (\${_i}/24)" >> "\$LOG"
    sleep 5
done

# Detect VNC binary
VNC_BIN=""
for b in Xvnc Xtigervnc; do command -v "\$b" >/dev/null 2>&1 && VNC_BIN="\$b" && break; done
if [[ -z "\$VNC_BIN" ]]; then echo "No VNC binary found after waiting" >> "\$LOG"; exit 1; fi

# Skip if already running (e.g. hook fired twice)
if pgrep -x "\$VNC_BIN" >/dev/null 2>&1 && pgrep -f websockify >/dev/null 2>&1; then
    echo "Desktop already running, skipping." >> "\$LOG"
    exit 0
fi

# Kill stale sessions
pkill "\$VNC_BIN" 2>/dev/null || true
pkill -f startxfce4 2>/dev/null || true
pkill -f xfce4-session 2>/dev/null || true
pkill -f websockify 2>/dev/null || true

# X11 socket dir
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
rm -f "/tmp/.X\${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X\${DISPLAY_NUM}"

# Start Xvnc
nohup "\$VNC_BIN" ":\${DISPLAY_NUM}" -SecurityTypes None \\
	-geometry 1920x1080 -depth 24 >> "\$LOG" 2>&1 &
sleep 2

# Start XFCE via login shell (sources /etc/profile.d/*)
nohup env DISPLAY=":\${DISPLAY_NUM}" dbus-launch --exit-with-session \\
	bash --login -c 'exec startxfce4' >> "\$LOG" 2>&1 &

# Start noVNC
nohup websockify --web "\${NOVNC_WEB}" "\${NOVNC_PORT}" "\${VNC_TARGET}" >> "\$LOG" 2>&1 &

echo "Desktop autostart complete (port \${NOVNC_PORT})" >> "\$LOG"
HOOKEOF
		run_privileged chmod +x "${hook}"
		echo "Auto-start: installed GCP hook: ${hook}"
		echo "            Log: /var/log/desktop-autostart.log"
		return 0
	fi

	# --- Method 2: systemd service -----------------------------------------
	if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
		run_privileged tee /etc/systemd/system/desktop-novnc.service >/dev/null <<SVCEOF
[Unit]
Description=Optics SI XFCE + noVNC Desktop
After=network.target

[Service]
Type=forking
ExecStart=/usr/bin/env bash -lc 'setup_desktop_autostart'
ExecStartPre=/bin/bash -c 'pkill Xvnc || true; pkill -f startxfce4 || true; pkill -f websockify || true'
Restart=on-failure
RestartSec=10s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
		# Write a helper script that systemd calls
		run_privileged tee /usr/local/bin/setup_desktop_autostart >/dev/null <<AUTOEOF
#!/bin/bash
export DISPLAY_NUM="${display_num}"
export NOVNC_PORT="${novnc_port}"
exec /bin/bash $(realpath "$0")
AUTOEOF
		run_privileged chmod +x /usr/local/bin/setup_desktop_autostart
		run_privileged systemctl daemon-reload
		run_privileged systemctl enable desktop-novnc.service
		echo "Auto-start: installed systemd service desktop-novnc.service"
		return 0
	fi

	# --- Method 3: .bashrc fallback -----------------------------------------
	local real_user="${SUDO_USER:-${USER:-}}"
	local bashrc="/home/${real_user}/.bashrc"
	[[ "${real_user}" == "root" || -z "${real_user}" ]] && bashrc="/root/.bashrc"
	# Remove any previous block
	sed -i '/# desktop-autostart-begin/,/# desktop-autostart-end/d' "${bashrc}" 2>/dev/null || true
	cat >> "${bashrc}" <<BRCEOF

# desktop-autostart-begin
if [[ \$- == *i* ]] && ! pgrep -x Xvnc >/dev/null 2>&1 && ! pgrep -x Xtigervnc >/dev/null 2>&1; then
	(nohup bash $(realpath "$0") >> /tmp/desktop-autostart.log 2>&1 &)
fi
# desktop-autostart-end
BRCEOF
	echo "Auto-start: added to ${bashrc} (fallback — activates on next login)"
}
install_autostart

log "Setup complete"
echo "Version              : ${SCRIPT_VERSION}"
echo "Display              : :${DISPLAY_NUM}"
echo "VNC target           : ${VNC_TARGET}"
echo "noVNC listen port    : ${NOVNC_PORT}"
echo "VNC server binary    : ${VNC_SERVER_BIN}"
echo "Logs                 : /tmp/xvnc.log, /tmp/xfce4.log, /tmp/websockify.log"
echo "Google Workstations  : map/expose NOVNC_PORT in workstation config if needed"