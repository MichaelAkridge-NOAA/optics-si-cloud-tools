#!/usr/bin/env bash
set -euo pipefail

# Google Cloud Workstations desktop bootstrap with persistent auto-start.
#
# - Installs XFCE, TigerVNC, noVNC/websockify
# - Starts the desktop now
# - Installs persistent boot hooks in ~/.workstation/customize_environment
#   (and ~/.customize_environment for older images)
# - Uses ~/.customize_environment.d so it coexists with other tools
# - Writes a rich noVNC splash page with system specs

SCRIPT_VERSION="2.3.0-persistent"
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

detect_vnc_server() {
	if command -v Xvnc >/dev/null 2>&1; then
		echo Xvnc
		return 0
	fi
	if command -v Xtigervnc >/dev/null 2>&1; then
		echo Xtigervnc
		return 0
	fi
	echo "ERROR: neither Xvnc nor Xtigervnc is available after install." >&2
	exit 1
}

setup_nvidia() {
	local nvidia_smi=""
	local candidate
	for candidate in \
		"$(command -v nvidia-smi 2>/dev/null)" \
		/var/lib/nvidia/bin/nvidia-smi \
		/usr/bin/nvidia-smi \
		/usr/local/nvidia/bin/nvidia-smi \
		/usr/local/bin/nvidia-smi; do
		[[ -n "${candidate}" && -x "${candidate}" ]] && { nvidia_smi="${candidate}"; break; }
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
	set -e

	if [[ -n "${nvidia_smi}" ]] && "${nvidia_smi}" >/dev/null 2>&1; then
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
		driver_pkg=$(apt-cache search '^nvidia-driver-[0-9]+$' 2>/dev/null | awk '{print $1}' | sort -t- -k3 -V | tail -1)
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
}

ACTUAL_USER="${SUDO_USER:-${USER:-}}"
if [[ -z "${ACTUAL_USER}" || "${ACTUAL_USER}" == "root" ]]; then
	ACTUAL_USER="$(awk -F: '$3>=1000 && $3<60000 && $1!="nobody" {print $1; exit}' /etc/passwd)"
fi
if [[ -z "${ACTUAL_USER}" ]]; then
	echo "ERROR: could not determine a non-root user." >&2
	exit 1
fi
ACTUAL_HOME="$(eval echo "~${ACTUAL_USER}")"

log "setup_desktop.sh"
echo "Version     : ${SCRIPT_VERSION}"
echo "User / home : ${ACTUAL_USER} / ${ACTUAL_HOME}"
echo "Display     : :${DISPLAY_NUM}"
echo "noVNC port  : ${NOVNC_PORT}"

require_cmd apt-get
require_cmd pkill

log "1. Updating package index"
export DEBIAN_FRONTEND=noninteractive
run_privileged apt-get update || echo "WARNING: apt-get update reported errors (continuing)."

log "2. Installing XFCE, TigerVNC, noVNC, and mesa utils"
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

VNC_SERVER_BIN="$(detect_vnc_server)"
require_cmd dbus-launch
require_cmd startxfce4
require_cmd websockify

log "3. NVIDIA GPU setup (if applicable)"
setup_nvidia

log "4. Preparing noVNC landing page"
SPEC_CPU="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//' || echo 'N/A')"
SPEC_CORES="$(nproc 2>/dev/null || echo 'N/A')"
SPEC_RAM="$(awk '/MemTotal/{printf "%.0f GB", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 'N/A')"
SPEC_DISK="$(df -h / 2>/dev/null | awk 'NR==2{print $4" free / "$2" total"}' || echo 'N/A')"
SPEC_HOST="$(hostname 2>/dev/null || echo 'N/A')"
SPEC_GPU="$(lspci 2>/dev/null | grep -i 'vga\|3d\|display' | head -1 | sed 's/.*: //' || echo 'N/A')"
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
	SPEC_GPU="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "${SPEC_GPU}")"
fi
SPEC_DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo '')"
SPEC_BADGE="$(if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then echo 'GPU Workstation'; else echo 'CPU Workstation'; fi)"

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
    <a href="https://michaelakridge-noaa.github.io/optics-si-cloud-tools/" target="_blank">📖 Codelabs</a>
    <a href="https://github.com/MichaelAkridge-NOAA/optics-si-cloud-tools" target="_blank">📦 GitHub</a>
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
nohup env DISPLAY=":${DISPLAY_NUM}" dbus-launch --exit-with-session \
	bash --login -c 'exec startxfce4' \
	> /tmp/xfce4.log 2>&1 &

log "6. Starting noVNC/websockify on port ${NOVNC_PORT}"
pkill -f "websockify.* ${NOVNC_PORT} " || true
if [[ "${NOVNC_PORT}" -lt 1024 ]]; then
	run_privileged nohup websockify --web "${NOVNC_WEB_DIR}" "${NOVNC_PORT}" "127.0.0.1:$((5900 + DISPLAY_NUM))" \
		> /tmp/websockify.log 2>&1 &
else
	nohup websockify --web "${NOVNC_WEB_DIR}" "${NOVNC_PORT}" "127.0.0.1:$((5900 + DISPLAY_NUM))" \
		> /tmp/websockify.log 2>&1 &
fi

sleep 1
if command -v ss >/dev/null 2>&1 && ! ss -ltn | grep -q ":${NOVNC_PORT} "; then
	echo "WARNING: no listener detected on port ${NOVNC_PORT}. Check /tmp/websockify.log"
fi

log "7. Configuring persistent auto-start on boot"
install_autostart() {
	local real_user="${SUDO_USER:-${USER:-}}"
	if [[ -z "${real_user}" || "${real_user}" == "root" ]]; then
		real_user="$(awk -F: '$3>=1000 && $3<60000 && $1!="nobody" {print $1; exit}' /etc/passwd)"
	fi
	if [[ -z "${real_user}" ]]; then
		echo "ERROR: could not determine a non-root user for persistent autostart" >&2
		return 1
	fi
	local real_home
	real_home="$(eval echo ~${real_user})"
	local persist_dir="${real_home}/.local/share/desktop"
	local hook_dir="${real_home}/.customize_environment.d"
	run_privileged mkdir -p "${persist_dir}" "${hook_dir}" "${real_home}/.workstation"
	run_privileged cp "$0" "${persist_dir}/setup_desktop.sh" 2>/dev/null || true
	run_privileged chown -R "${real_user}:${real_user}" "${persist_dir}" "${hook_dir}" "${real_home}/.workstation"

	install_dispatcher() {
		local hook="$1"
		if [[ -f "${hook}" ]] && ! grep -q 'customize_environment.d dispatcher' "${hook}"; then
			run_privileged cp "${hook}" "${hook_dir}/00-original-$(basename "${hook}").sh" 2>/dev/null || true
			run_privileged chmod +x "${hook_dir}/00-original-$(basename "${hook}").sh" 2>/dev/null || true
		fi
		run_privileged tee "${hook}" >/dev/null <<'DISPATCH'
#!/bin/bash
# customize_environment.d dispatcher — runs as user once per workstation start.
set -uo pipefail
HOOK_DIR="${HOME}/.customize_environment.d"
[ -d "$HOOK_DIR" ] || exit 0
for _f in "$HOOK_DIR"/*; do
	[ -f "$_f" ] || continue
	if command -v sudo >/dev/null 2>&1; then
		sudo -n bash "$_f" || true
	else
		bash "$_f" || true
	fi
done
DISPATCH
		run_privileged chmod +x "${hook}"
		run_privileged chown "${real_user}:${real_user}" "${hook}"
	}

	install_dispatcher "${real_home}/.workstation/customize_environment"
	install_dispatcher "${real_home}/.customize_environment"

	run_privileged tee "${hook_dir}/50-start-desktop.sh" >/dev/null <<'BOOTEOF'
#!/bin/bash
set -uo pipefail
LOG_FILE="/var/log/desktop-autostart.log"
echo "=== desktop autostart $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"

REAL_USER="${SUDO_USER:-${USER:-}}"
if [[ -z "${REAL_USER}" || "${REAL_USER}" == "root" ]]; then
	REAL_USER=$(awk -F: '$3>=1000 && $3<60000 && $1!="nobody" {print $1; exit}' /etc/passwd)
fi
REAL_HOME=$(eval echo ~${REAL_USER})
SCRIPT_COPY="${REAL_HOME}/.local/share/desktop/setup_desktop.sh"

if [[ -x "$SCRIPT_COPY" ]]; then
	bash "$SCRIPT_COPY" >> "$LOG_FILE" 2>&1 || true
else
	echo "Persistent installer not found at $SCRIPT_COPY" >> "$LOG_FILE"
fi
BOOTEOF
	run_privileged chmod +x "${hook_dir}/50-start-desktop.sh"
	run_privileged chown -R "${real_user}:${real_user}" "${hook_dir}"
	echo "Auto-start: installed persistent customize_environment hooks"
	echo "            Dispatcher: ${real_home}/.workstation/customize_environment"
	echo "            Drop-in: ${hook_dir}/50-start-desktop.sh"
}
install_autostart

log "Setup complete"
echo "Version              : ${SCRIPT_VERSION}"
echo "Display              : :${DISPLAY_NUM}"
echo "VNC target           : 127.0.0.1:$((5900 + DISPLAY_NUM))"
echo "noVNC listen port    : ${NOVNC_PORT}"
echo "VNC server binary    : ${VNC_SERVER_BIN}"
echo "Logs                 : /tmp/xvnc.log, /tmp/xfce4.log, /tmp/websockify.log"