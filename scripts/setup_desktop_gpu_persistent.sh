#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Google Cloud Workstations — GPU + VirtualGL desktop with PERSISTENT auto-start
# =============================================================================
# Version: 2.3.2-gpu-persistent
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
#   a PERSISTENT boot hook at ~/.workstation/customize_environment (newer base
#   images) and ~/.customize_environment (older images). Cloud Workstations runs
#   that file ONCE per container start, AS THE `user` account. Because the home
#   disk persists, the hook survives restarts; a small dispatcher then runs the
#   real provisioning as ROOT via sudo and relaunches the GPU desktop
#   automatically — no SSH, no manual step.
#
#   Tradeoff vs. a custom image: the hook re-runs apt-get on each boot if the
#   packages are missing, which adds time to first connect after a restart. For
#   the fastest startup, bake everything into an image instead (see ./docker).
#
# WHAT YOU GET
#   - XFCE desktop, TigerVNC, noVNC/websockify on port 80 (with splash page)
#   - NVIDIA GPU detection + VirtualGL so `vglrun <app>` is hardware accelerated
#   - Auto-start that survives stop/start (persistent customize_environment)
#   - Immediate start for the current session
#
# USAGE
#   sudo bash setup_desktop_gpu_persistent.sh
#
# After install, launch 3D/OpenGL apps inside the noVNC desktop terminal with:
#   vglrun blender   vglrun qgis   vglrun paraview   vglrun glxgears
# =============================================================================

SCRIPT_VERSION="2.3.2-gpu-persistent"
VGL_VERSION="${VGL_VERSION:-3.1.1}"     # override: VGL_VERSION=3.0 sudo bash ...
WALLPAPER_URL="${WALLPAPER_URL:-https://cdn.oceanservice.noaa.gov/oceanserviceprod/wallpaper/ocean-vector-2880x1880.jpg}"

DISPLAY_NUM="${DISPLAY_NUM:-1}"
VNC_GEOMETRY="${VNC_GEOMETRY:-1920x1080}"
VNC_DEPTH="${VNC_DEPTH:-24}"
NOVNC_PORT="${NOVNC_PORT:-80}"
NOVNC_WEB_DIR="/usr/share/novnc"
BRAND_NAME="Optics SI Cloud Desktop"
BRAND_LOGO_URL="https://raw.githubusercontent.com/MichaelAkridge-NOAA/optics-si-cloud-tools/refs/heads/main/docs/logo/optics_si_logo_v1.png"

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
echo "Desktop port  : ${NOVNC_PORT}"
echo "Wallpaper URL : ${WALLPAPER_URL}"

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

# Build the runtime spec payload used by the richer splash page.
# Locate nvidia-smi at boot — its path on GCP T4 images isn't always on PATH.
NVIDIA_SMI=""
for _c in \\
		\$(command -v nvidia-smi 2>/dev/null) \\
		/var/lib/nvidia/bin/nvidia-smi \\
		/usr/bin/nvidia-smi \\
		/usr/local/nvidia/bin/nvidia-smi \\
		/usr/local/bin/nvidia-smi; do
	if [[ -n "\${_c}" && -x "\${_c}" ]]; then
		NVIDIA_SMI="\${_c}"; break
	fi
done
GPU_NAME=""
GPU_DRIVER=""
if [[ -n "\${NVIDIA_SMI}" ]] && "\${NVIDIA_SMI}" >/dev/null 2>&1; then
	GPU_NAME="\$("\${NVIDIA_SMI}" --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
	GPU_DRIVER="\$("\${NVIDIA_SMI}" --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)"
fi
VGL_VERSION_RUNTIME=""
if command -v vglrun >/dev/null 2>&1; then
	VGL_VERSION_RUNTIME="\$(vglrun -version 2>&1 | grep -oE '[0-9]+\\.[0-9]+(\\.[0-9]+)?' | head -1 || true)"
fi
cat > /tmp/desktop-specs.json \<\<'JSONEOF'
{
	"gpu": "\${GPU_NAME}",
	"driver": "\${GPU_DRIVER}",
	"vgl": "\${VGL_VERSION_RUNTIME}",
	"port": "\${NOVNC_PORT}",
	"display": ":\${DISPLAY_NUM}",
	"version": "${SCRIPT_VERSION}"
}
JSONEOF
chmod 644 /tmp/desktop-specs.json

# Restore the web app assets if missing (the web dir is ephemeral and reset
# on every container start).
if [[ ! -s "\${NOVNC_WEB_DIR}/index.html" ]]; then
	if [[ -f "${ACTUAL_HOME}/.local/share/gpu-desktop/index.html" ]]; then
		install -m 0644 "${ACTUAL_HOME}/.local/share/gpu-desktop/index.html" \\
			"\${NOVNC_WEB_DIR}/index.html" 2>/dev/null || true
	fi
fi
if [[ ! -s "\${NOVNC_WEB_DIR}/site.webmanifest" ]]; then
	if [[ -f "${ACTUAL_HOME}/.local/share/gpu-desktop/site.webmanifest" ]]; then
		install -m 0644 "${ACTUAL_HOME}/.local/share/gpu-desktop/site.webmanifest" \\
			"\${NOVNC_WEB_DIR}/site.webmanifest" 2>/dev/null || true
	fi
fi
if [[ ! -s "\${NOVNC_WEB_DIR}/optics-si-logo.png" ]]; then
	if [[ -f "${ACTUAL_HOME}/.local/share/gpu-desktop/optics-si-logo.png" ]]; then
		install -m 0644 "${ACTUAL_HOME}/.local/share/gpu-desktop/optics-si-logo.png" \\
			"\${NOVNC_WEB_DIR}/optics-si-logo.png" 2>/dev/null || true
	fi
fi
if [[ -f "${ACTUAL_HOME}/.local/share/gpu-desktop/vnc.html" ]]; then
	install -m 0644 "${ACTUAL_HOME}/.local/share/gpu-desktop/vnc.html" \
		"\${NOVNC_WEB_DIR}/vnc.html" 2>/dev/null || true
fi

# Ensure vnc.html itself is branded so Chrome app install metadata does not
# fall back to upstream noVNC naming/icon when users install from the client page.
if [[ -f "\${NOVNC_WEB_DIR}/vnc.html" ]]; then
	sed -i "s#<title>.*</title>#<title>${BRAND_NAME}</title>#" "\${NOVNC_WEB_DIR}/vnc.html" 2>/dev/null || true
	sed -i 's#\${BRAND_NAME}#Optics SI Cloud Desktop#g' "\${NOVNC_WEB_DIR}/vnc.html" 2>/dev/null || true
	if ! grep -q 'site.webmanifest' "\${NOVNC_WEB_DIR}/vnc.html"; then
		sed -i '/<head>/a \
  <link rel="manifest" href="/site.webmanifest">\
  <link rel="icon" href="/optics-si-logo.png" type="image/png">\
	<meta name="application-name" content="Optics SI Cloud Desktop">\
	<meta name="apple-mobile-web-app-title" content="Optics SI Cloud Desktop">\
  <meta name="theme-color" content="#0d1b2a">' "\${NOVNC_WEB_DIR}/vnc.html" 2>/dev/null || true
	fi
fi

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

	# Apply a default branded wallpaper if present on persistent storage.
	WALLPAPER_FILE="${ACTUAL_HOME}/.local/share/gpu-desktop/wallpaper.jpg"
	if [[ -f "\${WALLPAPER_FILE}" ]]; then
		# Update all discovered XFCE last-image paths.
		while IFS= read -r _prop; do
			DISPLAY=":\${DISPLAY_NUM}" xfconf-query -c xfce4-desktop -p "\${_prop}" -s "\${WALLPAPER_FILE}" 2>/dev/null || true
		done < <(DISPLAY=":\${DISPLAY_NUM}" xfconf-query -c xfce4-desktop -l 2>/dev/null | grep '/last-image$' || true)

		# Set common fallback properties for XFCE virtual monitor layouts.
		DISPLAY=":\${DISPLAY_NUM}" xfconf-query -c xfce4-desktop -p /backdrop/single-workspace-mode -n -t bool -s true 2>/dev/null || true
		DISPLAY=":\${DISPLAY_NUM}" xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor0/image-path -n -t string -s "\${WALLPAPER_FILE}" 2>/dev/null || true
		DISPLAY=":\${DISPLAY_NUM}" xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor0/workspace0/last-image -n -t string -s "\${WALLPAPER_FILE}" 2>/dev/null || true
		DISPLAY=":\${DISPLAY_NUM}" xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitorVirtual1/image-path -n -t string -s "\${WALLPAPER_FILE}" 2>/dev/null || true
		DISPLAY=":\${DISPLAY_NUM}" xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitorVirtual1/workspace0/last-image -n -t string -s "\${WALLPAPER_FILE}" 2>/dev/null || true
	fi
) >> "\$LOG" 2>&1 &

echo "Desktop start complete (port \${NOVNC_PORT})" >> "\$LOG"
exit 0
LAUNCHER
run_privileged chmod +x /usr/local/bin/start-gpu-desktop.sh
echo "✓ Desktop launcher installed and executable"

# ----------------------------------------------------------------------------
# 4b. noVNC splash page (fixes the "directory listing" instead of landing page)
# ----------------------------------------------------------------------------
# /usr/share/novnc is ephemeral, so we write the page now AND keep a persistent
# copy in the home disk that the launcher restores on every boot.
log "4b. Writing desktop splash page + web app metadata"
# Collect static machine specs to embed in the page body.
SPEC_CPU="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//' || echo 'N/A')"
SPEC_CORES="$(nproc 2>/dev/null || echo 'N/A')"
SPEC_RAM="$(awk '/MemTotal/{printf "%.0f GB", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 'N/A')"
SPEC_DISK="$(df -h / 2>/dev/null | awk 'NR==2{print $4" free / "$2" total"}' || echo 'N/A')"
SPEC_HOST="$(hostname 2>/dev/null || echo 'N/A')"
SPEC_BADGE="GPU Workstation + VirtualGL"

run_privileged tee "${NOVNC_WEB_DIR}/index.html" >/dev/null <<NOVNC_INDEX
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
	<meta name="viewport" content="width=device-width, initial-scale=1">
	<title>${BRAND_NAME}</title>
	<meta name="application-name" content="${BRAND_NAME}">
	<meta name="apple-mobile-web-app-title" content="${BRAND_NAME}">
	<meta name="theme-color" content="#0d1b2a">
	<meta name="description" content="Optics SI Cloud Desktop on Google Cloud Workstations.">
	<meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
	<meta http-equiv="Pragma" content="no-cache">
	<meta http-equiv="Expires" content="0">
	<link rel="manifest" href="/site.webmanifest">
	<link rel="icon" href="/optics-si-logo.png" type="image/png">
	<link rel="apple-touch-icon" href="/optics-si-logo.png">
  <style>
		*{margin:0;padding:0;box-sizing:border-box}
		body{background:#0d1b2a;color:#e0e8f0;font-family:'Segoe UI',Arial,sans-serif;
				 display:flex;flex-direction:column;align-items:center;justify-content:center;
				 min-height:100vh;text-align:center;padding:32px 16px}
		.logo{width:180px;margin-bottom:14px}
		h1{font-size:1.6rem;font-weight:600;color:#7ec8e3;margin-bottom:4px}
		h2{font-size:0.95rem;font-weight:400;color:#8aabb8;margin-bottom:12px}
		.badge{display:inline-block;background:#0d2318;border:1px solid #2a6a3a;
					 color:#5ec87e;font-size:0.75rem;font-weight:700;letter-spacing:.06em;
					 padding:4px 14px;border-radius:20px;margin-bottom:22px;text-transform:uppercase}
		.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;
					width:100%;max-width:860px;margin-bottom:22px}
		.card{background:#112236;border:1px solid #1e4a7a;border-radius:8px;
					padding:12px 16px;font-size:0.82rem;color:#b8d0de;text-align:left}
		.card b{display:block;color:#7ec8e3;font-size:0.68rem;text-transform:uppercase;
						letter-spacing:.07em;margin-bottom:4px}
		.card.gpu{border-color:#2a6a3a;background:#0d2318}
		.card.gpu b{color:#5ec87e}
		.vglbox{background:#0d1f14;border:1px solid #2a6a3a;border-radius:8px;
						padding:10px 20px;margin-bottom:20px;font-size:0.8rem;
						color:#a0d8b0;max-width:860px;width:100%;text-align:left}
		.vglbox b{color:#5ec87e}
		.vglbox code{background:#071510;padding:2px 7px;border-radius:4px;font-size:0.78rem}
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
			 src="/optics-si-logo.png"
			 alt="Optics SI" onerror="this.style.display='none'">
	<h1>${BRAND_NAME}</h1>
	<h2>NOAA &mdash; Google Cloud Workstations</h2>
	<div class="badge">${SPEC_BADGE}</div>
	<div class="grid" id="specs-grid">
		<div class="card"><b>Host</b>${SPEC_HOST}</div>
		<div class="card"><b>CPU</b>${SPEC_CPU}</div>
		<div class="card"><b>Cores</b>${SPEC_CORES} vCPU</div>
		<div class="card"><b>RAM</b>${SPEC_RAM}</div>
		<div class="card"><b>Disk (/)</b>${SPEC_DISK}</div>
		<div class="card gpu" id="card-gpu" style="display:none"><b>GPU</b><span id="spec-gpu"></span></div>
		<div class="card gpu" id="card-driver" style="display:none"><b>Driver</b><span id="spec-driver"></span></div>
		<div class="card gpu" id="card-vgl" style="display:none"><b>VirtualGL</b><span id="spec-vgl"></span></div>
		<div class="card" id="card-port" style="display:none"><b>Desktop Port</b><span id="spec-port"></span></div>
		<div class="card" id="card-display" style="display:none"><b>Display</b><span id="spec-display"></span></div>
		<div class="card" id="card-version" style="display:none"><b>Setup Version</b><span id="spec-version"></span></div>
	</div>
	<div class="vglbox">
		<b>Hardware-accelerated OpenGL via VirtualGL</b> &mdash;
		prefix 3D apps with <code>vglrun</code> in the desktop terminal:<br>
		<code>vglrun blender</code> &nbsp; <code>vglrun qgis</code> &nbsp;
		<code>vglrun paraview</code> &nbsp; <code>vglrun glxgears</code>
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
    function addLaunchTs(url){
		const u = new URL(url, window.location.origin);
		u.searchParams.set('launch_ts', String(Date.now()));
		return u.pathname + '?' + u.searchParams.toString();
	}
    function go(){clearInterval(t);location.href=addLaunchTs('vnc.html?autoconnect=true&resize=remote');}
		
		// Installed app launches can carry stale cache. Add a one-time launch token
		// so each open resolves to a fresh URL key.
		(function ensureFreshLaunch(){
			if (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches) {
				const url = new URL(window.location.href);
				if (!url.searchParams.has('launch_ts')) {
					url.searchParams.set('launch_ts', String(Date.now()));
					window.location.replace(url.toString());
				}
			}
		})();
		var n=7,t=setInterval(function(){
      document.getElementById('n').textContent=--n;
      if(n<=0)go();
    },1000);

		fetch('/tmp/desktop-specs.json')
			.then(r => r.json())
			.then(specs => {
				const specs_map = {
					'gpu': 'card-gpu',
					'driver': 'card-driver',
					'vgl': 'card-vgl',
					'port': 'card-port',
					'display': 'card-display',
					'version': 'card-version'
				};
				for (const [key, card_id] of Object.entries(specs_map)) {
					if (specs[key] && specs[key] !== 'N/A' && specs[key] !== '') {
						document.getElementById('spec-' + key).textContent = specs[key];
						document.getElementById(card_id).style.display = 'block';
					}
				}
			})
			.catch(e => {
				console.log('Could not load specs: ' + e);
			});
  </script>
</body>
</html>
NOVNC_INDEX

run_privileged tee "${NOVNC_WEB_DIR}/site.webmanifest" >/dev/null <<NOVNC_MANIFEST
{
	"name": "${BRAND_NAME}",
	"short_name": "Optics SI",
	"description": "Optics SI Cloud Desktop on Google Cloud Workstations",
	"start_url": "/index.html?app=optics-si&v=${SCRIPT_VERSION}",
	"scope": "/",
	"display": "standalone",
	"background_color": "#0d1b2a",
	"theme_color": "#0d1b2a",
	"icons": [
		{
			"src": "/optics-si-logo.png",
			"sizes": "192x192",
			"type": "image/png",
			"purpose": "any"
		},
		{
			"src": "/optics-si-logo.png",
			"sizes": "512x512",
			"type": "image/png",
			"purpose": "any"
		}
	]
}
NOVNC_MANIFEST

if ! run_privileged wget -q -O "${NOVNC_WEB_DIR}/optics-si-logo.png" "${BRAND_LOGO_URL}"; then
	echo "WARNING: could not download Optics SI logo from ${BRAND_LOGO_URL}."
	echo "         Web app icon will use browser fallback until logo is available."
fi

# Brand the underlying noVNC client page too, since Chrome app install can be
# initiated while on /vnc.html after auto-connect.
if [[ -f "${NOVNC_WEB_DIR}/vnc.html" ]]; then
	run_privileged sed -i "s#<title>.*</title>#<title>${BRAND_NAME}</title>#" "${NOVNC_WEB_DIR}/vnc.html" || true
	run_privileged sed -i 's#\${BRAND_NAME}#Optics SI Cloud Desktop#g' "${NOVNC_WEB_DIR}/vnc.html" || true
	if ! run_privileged grep -q 'site.webmanifest' "${NOVNC_WEB_DIR}/vnc.html"; then
		run_privileged sed -i '/<head>/a \
  <link rel="manifest" href="/site.webmanifest">\
  <link rel="icon" href="/optics-si-logo.png" type="image/png">\
	<meta name="application-name" content="Optics SI Cloud Desktop">\
	<meta name="apple-mobile-web-app-title" content="Optics SI Cloud Desktop">\
	<meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">\
	<meta http-equiv="Pragma" content="no-cache">\
	<meta http-equiv="Expires" content="0">\
  <meta name="theme-color" content="#0d1b2a">' "${NOVNC_WEB_DIR}/vnc.html" || true
	fi
fi

# Persistent copy so the launcher can restore the splash after each container reset.
run_privileged mkdir -p "${ACTUAL_HOME}/.local/share/gpu-desktop"
run_privileged cp "${NOVNC_WEB_DIR}/index.html" "${ACTUAL_HOME}/.local/share/gpu-desktop/index.html"
run_privileged cp "${NOVNC_WEB_DIR}/site.webmanifest" "${ACTUAL_HOME}/.local/share/gpu-desktop/site.webmanifest"
if [[ -f "${NOVNC_WEB_DIR}/optics-si-logo.png" ]]; then
	run_privileged cp "${NOVNC_WEB_DIR}/optics-si-logo.png" "${ACTUAL_HOME}/.local/share/gpu-desktop/optics-si-logo.png"
fi
if [[ -f "${NOVNC_WEB_DIR}/vnc.html" ]]; then
	run_privileged cp "${NOVNC_WEB_DIR}/vnc.html" "${ACTUAL_HOME}/.local/share/gpu-desktop/vnc.html"
fi
run_privileged chown -R "${ACTUAL_USER}:${ACTUAL_USER}" "${ACTUAL_HOME}/.local/share/gpu-desktop"
echo "✓ Desktop splash + web app metadata installed (persistent copy at ${ACTUAL_HOME}/.local/share/gpu-desktop)"

# ----------------------------------------------------------------------------
# 5. PERSISTENT boot hook — survives stop/start via the home disk
# ----------------------------------------------------------------------------
# Cloud Workstations runs ~/.workstation/customize_environment (newer base
# images) or ~/.customize_environment (older images) ONCE per start, AS THE
# `user` ACCOUNT (not root). We install a small DISPATCHER to BOTH paths that
# runs each drop-in in ~/.customize_environment.d/ as ROOT via sudo, so multiple
# tools (this desktop, Label Studio, etc.) can register persistent privileged
# boot actions that survive stop/start without overwriting each other.
log "5. Installing persistent boot hook (~/.workstation/customize_environment)"
HOOK_DIR="${ACTUAL_HOME}/.customize_environment.d"
run_privileged mkdir -p "${HOOK_DIR}"
run_privileged mkdir -p "${ACTUAL_HOME}/.workstation"

install_dispatcher() {
	local hook="$1"
	# Preserve a pre-existing non-dispatcher hook by moving it into the drop-in dir.
	if [[ -f "${hook}" ]] && ! grep -q 'customize_environment.d dispatcher' "${hook}"; then
		run_privileged cp "${hook}" "${HOOK_DIR}/00-original-$(basename "${hook}").sh"
		run_privileged chmod +x "${HOOK_DIR}/00-original-$(basename "${hook}").sh"
	fi
	run_privileged tee "${hook}" >/dev/null <<'DISPATCH'
#!/bin/bash
# customize_environment.d dispatcher — runs as `user` once per workstation start.
# Executes each drop-in in ~/.customize_environment.d/ as ROOT (sudo) so multiple
# tools can register persistent privileged boot actions without overwriting
# each other.
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
	run_privileged chown "${ACTUAL_USER}:${ACTUAL_USER}" "${hook}"
}
install_dispatcher "${ACTUAL_HOME}/.workstation/customize_environment"
install_dispatcher "${ACTUAL_HOME}/.customize_environment"
run_privileged chown "${ACTUAL_USER}:${ACTUAL_USER}" "${ACTUAL_HOME}/.workstation"

# Drop in this desktop's boot action (executed as root by the dispatcher).
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
PERSIST_WALLPAPER="${PERSIST_DIR}/wallpaper.jpg"
run_privileged mkdir -p "${PERSIST_DIR}"
run_privileged cp /usr/local/bin/start-gpu-desktop.sh "${PERSIST_DIR}/start-gpu-desktop.sh"

# Keep a branded default wallpaper on persistent storage so each recreated
# container can re-apply the same desktop background.
if run_privileged wget -q -O "${PERSIST_WALLPAPER}" "${WALLPAPER_URL}"; then
	echo "✓ Wallpaper downloaded to ${PERSIST_WALLPAPER}"
else
	echo "WARNING: wallpaper download failed from ${WALLPAPER_URL} (continuing)."
	run_privileged rm -f "${PERSIST_WALLPAPER}" || true
fi

run_privileged chown -R "${ACTUAL_USER}:${ACTUAL_USER}" "${PERSIST_DIR}"
echo "✓ Persistent boot hook installed (survives stop/start via home disk)"

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
	echo "✓ GCP session startup hook installed at /etc/workstation-startup.d/50-start-desktop (ephemeral; restored by persistent hook on boot)"
else
	echo "ℹ /etc/workstation-startup.d not found (not a Cloud Workstations env, or older base image)"
fi

# ----------------------------------------------------------------------------
# 7. Start the desktop now
# ----------------------------------------------------------------------------
log "7. Starting the desktop for this session"
if run_privileged env DISPLAY_NUM="${DISPLAY_NUM}" NOVNC_PORT="${NOVNC_PORT}" \
	/usr/local/bin/start-gpu-desktop.sh; then
	echo "✓ Desktop launcher executed successfully"
else
	echo "✗ Desktop launcher returned an error (check /var/log/desktop-autostart.log)"
fi

sleep 2
log "Setup complete"
echo "Version            : ${SCRIPT_VERSION}"
echo "Persistent hooks   : ${ACTUAL_HOME}/.workstation/customize_environment"
echo "                     ${ACTUAL_HOME}/.customize_environment (legacy)"
echo "Drop-in            : ${HOOK_DIR}/50-gpu-desktop.sh (run as root via sudo)"
echo "Launcher           : /usr/local/bin/start-gpu-desktop.sh"
echo "Persistent copies  : ${PERSIST_DIR}/start-gpu-desktop.sh, splash index.html"
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
