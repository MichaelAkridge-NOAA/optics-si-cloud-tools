#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Google Cloud Workstations - CoralNet-Toolbox Docker GPU persistent installer
# =============================================================================
#
# Standalone usage from a fresh workstation:
#
#   wget -qO- <raw-script-url> | bash
#   curl -fsSL <raw-script-url> | bash
#
# The script keeps all durable state on the persistent home disk, then registers
# a Cloud Workstations customize_environment hook so the CoralNet Docker session
# returns after stop/start. It intentionally reuses the repository's KasmVNC
# Docker image instead of installing a second XFCE/TigerVNC/noVNC desktop stack.
# =============================================================================

SCRIPT_VERSION="0.1.1-coralnet-docker-gpu-persistent"

CORALNET_REPO_URL="${CORALNET_REPO_URL:-https://github.com/Jordan-Pierce/CoralNet-Toolbox.git}"
CORALNET_REF="${CORALNET_REF:-main}"
CORALNET_IMAGE="${CORALNET_IMAGE:-coralnet-toolbox:local}"
CORALNET_CONTAINER="${CORALNET_CONTAINER:-coralnet}"
CORALNET_PORT="${CORALNET_PORT:-${PORT:-80}}"
CORALNET_VNC_USER="${CORALNET_VNC_USER:-${VNC_USER:-user}}"
CORALNET_VNC_PW="${CORALNET_VNC_PW:-${VNC_PW:-password}}"
LOCKOUT_LEVEL="${LOCKOUT_LEVEL:-2}"
TORCH_CUDA="${TORCH_CUDA:-cu128}"
INSTALL_CHROME="${INSTALL_CHROME:-true}"
ALLOW_CPU_FALLBACK="${ALLOW_CPU_FALLBACK:-0}"
CORALNET_SKIP_PULL="${CORALNET_SKIP_PULL:-0}"
CORALNET_SKIP_BUILD="${CORALNET_SKIP_BUILD:-0}"
CORALNET_CONTEXT_PROBE="${CORALNET_CONTEXT_PROBE:-0}"

log() {
	echo
	echo "========================================"
	echo "$1"
	echo "========================================"
}

warn() {
	echo "WARNING: $*" >&2
}

die() {
	echo "ERROR: $*" >&2
	exit 1
}

run_privileged() {
	if [[ "$(id -u)" -eq 0 ]]; then
		"$@"
	else
		sudo "$@"
	fi
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

apt_get_update() {
	if ! run_privileged apt-get update; then
		warn "apt-get update reported errors, usually from a pre-existing third-party apt source. Continuing with available package indexes."
	fi
}

try_start_docker() {
	if run_privileged docker info >/dev/null 2>&1; then
		return 0
	fi
	if command -v service >/dev/null 2>&1; then
		run_privileged service docker start >/dev/null 2>&1 || true
	fi
	if command -v systemctl >/dev/null 2>&1; then
		run_privileged systemctl start docker >/dev/null 2>&1 || true
	fi
	run_privileged docker info >/dev/null 2>&1
}

install_base_packages() {
	log "1. Installing base packages"
	export DEBIAN_FRONTEND=noninteractive
	apt_get_update
	run_privileged apt-get install -y --no-install-recommends \
		ca-certificates \
		curl \
		git \
		gnupg \
		lsb-release
}

install_docker() {
	log "2. Installing or validating Docker"
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		echo "Docker CLI and Compose plugin already installed."
	else
		install -m 0755 -d /tmp/coralnet-docker-install
		run_privileged install -m 0755 -d /etc/apt/keyrings
		. /etc/os-release
		case "${ID}" in
			ubuntu|debian) DOCKER_DISTRO="${ID}" ;;
			*) die "Docker install is only automated for Ubuntu/Debian apt bases, got ID=${ID}. Use a Docker-capable workstation image, then rerun." ;;
		esac
		curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o /tmp/coralnet-docker-install/docker.asc
		run_privileged install -m 0644 /tmp/coralnet-docker-install/docker.asc /etc/apt/keyrings/docker.asc
		run_privileged chmod a+r /etc/apt/keyrings/docker.asc

		ARCH="$(dpkg --print-architecture)"
		CODENAME="${VERSION_CODENAME:-$(lsb_release -cs)}"
		echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_DISTRO} ${CODENAME} stable" \
			| run_privileged tee /etc/apt/sources.list.d/docker.list >/dev/null

		apt_get_update
		run_privileged apt-get install -y --no-install-recommends \
			docker-ce \
			docker-ce-cli \
			containerd.io \
			docker-buildx-plugin \
			docker-compose-plugin
	fi

	if ! try_start_docker; then
		die "Docker is installed but the daemon is unreachable. Use a Docker-capable/privileged Cloud Workstations image, then rerun this script."
	fi

	if getent group docker >/dev/null 2>&1; then
		run_privileged usermod -aG docker "${ACTUAL_USER}" || true
	fi
	run_privileged docker version --format 'Docker {{.Server.Version}}'
	docker compose version
}

install_nvidia_toolkit() {
	log "3. Installing or validating NVIDIA Container Toolkit"
	if run_privileged docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q 'nvidia'; then
		echo "Docker NVIDIA runtime already configured."
		return 0
	fi

	if ! command -v nvidia-smi >/dev/null 2>&1 && [[ ! -x /var/lib/nvidia/bin/nvidia-smi ]]; then
		warn "nvidia-smi is not available on the workstation host yet."
	fi

	run_privileged install -m 0755 -d /usr/share/keyrings
	run_privileged rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
	curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
		| run_privileged gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
	curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
		| sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
		| run_privileged tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

	apt_get_update
	run_privileged apt-get install -y --no-install-recommends nvidia-container-toolkit
	run_privileged nvidia-ctk runtime configure --runtime=docker
	if command -v service >/dev/null 2>&1; then
		run_privileged service docker restart >/dev/null 2>&1 || true
	fi
	if command -v systemctl >/dev/null 2>&1; then
		run_privileged systemctl restart docker >/dev/null 2>&1 || true
	fi

	if ! run_privileged docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q 'nvidia'; then
		if [[ "${ALLOW_CPU_FALLBACK}" == "1" ]]; then
			warn "NVIDIA runtime is not configured; continuing because ALLOW_CPU_FALLBACK=1."
			return 0
		fi
		die "NVIDIA Docker runtime is unavailable. Fix the workstation GPU/runtime config or rerun with ALLOW_CPU_FALLBACK=1."
	fi
	echo "NVIDIA Docker runtime configured."
}

prepare_checkout() {
	log "4. Cloning or updating CoralNet-Toolbox"
	mkdir -p "$(dirname "${CORALNET_REPO_DIR}")"

	if [[ ! -d "${CORALNET_REPO_DIR}/.git" ]]; then
		git clone --branch "${CORALNET_REF}" --single-branch "${CORALNET_REPO_URL}" "${CORALNET_REPO_DIR}"
	else
		REMOTE_URL="$(git -C "${CORALNET_REPO_DIR}" config --get remote.origin.url || true)"
		if [[ -n "${REMOTE_URL}" && "${REMOTE_URL}" != "${CORALNET_REPO_URL}" ]]; then
			die "${CORALNET_REPO_DIR} is a git checkout for ${REMOTE_URL}, not ${CORALNET_REPO_URL}. Set CORALNET_REPO_DIR to another path."
		fi
		if [[ "${CORALNET_SKIP_PULL}" == "1" ]]; then
			echo "Skipping git pull because CORALNET_SKIP_PULL=1."
		else
			git -C "${CORALNET_REPO_DIR}" fetch origin "${CORALNET_REF}"
			git -C "${CORALNET_REPO_DIR}" checkout "${CORALNET_REF}"
			git -C "${CORALNET_REPO_DIR}" pull --ff-only origin "${CORALNET_REF}"
		fi
	fi

	[[ -f "${CORALNET_REPO_DIR}/Dockerfile" ]] || die "Dockerfile not found in ${CORALNET_REPO_DIR}."
	[[ -f "${CORALNET_REPO_DIR}/docker/custom_startup.sh" ]] || die "Docker startup files not found in ${CORALNET_REPO_DIR}."
	mkdir -p "${CORALNET_DATA_DIR}"
	chown -R "${ACTUAL_USER}:${ACTUAL_USER}" "${CORALNET_REPO_DIR}" "${CORALNET_DATA_DIR}" 2>/dev/null || true
}

build_image() {
	log "5. Building CoralNet-Toolbox Docker image"
	if [[ "${CORALNET_CONTEXT_PROBE}" == "1" ]]; then
		run_privileged docker build -f docker/context-probe.Dockerfile --progress=plain -t coralnet-context-probe "${CORALNET_REPO_DIR}"
	fi
	if [[ "${CORALNET_SKIP_BUILD}" == "1" ]]; then
		echo "Skipping docker build because CORALNET_SKIP_BUILD=1."
		return 0
	fi
	run_privileged docker build \
		--build-arg "TORCH_CUDA=${TORCH_CUDA}" \
		--build-arg "INSTALL_CHROME=${INSTALL_CHROME}" \
		-t "${CORALNET_IMAGE}" \
		"${CORALNET_REPO_DIR}"
	run_privileged docker image inspect "${CORALNET_IMAGE}" >/dev/null
}

write_launcher() {
	log "6. Installing persistent CoralNet Docker launcher"
	run_privileged tee /usr/local/bin/start-coralnet-docker-gpu.sh >/dev/null <<LAUNCHER
#!/usr/bin/env bash
set -euo pipefail

LOG="\${CORALNET_LOG:-/var/log/coralnet-docker-autostart.log}"
mkdir -p "\$(dirname "\$LOG")"
touch "\$LOG" 2>/dev/null || true
exec > >(tee -a "\$LOG") 2>&1

echo "=== coralnet docker start \$(date '+%F %T') ==="
echo "Launcher version: ${SCRIPT_VERSION}"
echo "GPU launch mode: nvidia-runtime"

IMAGE="\${CORALNET_IMAGE:-${CORALNET_IMAGE}}"
CONTAINER="\${CORALNET_CONTAINER:-${CORALNET_CONTAINER}}"
PORT="\${CORALNET_PORT:-${CORALNET_PORT}}"
DATA_DIR="\${CORALNET_DATA_DIR:-${CORALNET_DATA_DIR}}"
VNC_USER_VALUE="\${CORALNET_VNC_USER:-${CORALNET_VNC_USER}}"
VNC_PW_VALUE="\${CORALNET_VNC_PW:-${CORALNET_VNC_PW}}"
LOCKOUT_VALUE="\${LOCKOUT_LEVEL:-${LOCKOUT_LEVEL}}"
ALLOW_CPU="\${ALLOW_CPU_FALLBACK:-${ALLOW_CPU_FALLBACK}}"

if ! docker info >/dev/null 2>&1; then
	if command -v service >/dev/null 2>&1; then service docker start >/dev/null 2>&1 || true; fi
	if command -v systemctl >/dev/null 2>&1; then systemctl start docker >/dev/null 2>&1 || true; fi
fi
if ! docker info >/dev/null 2>&1; then
	echo "Docker daemon is unavailable."
	exit 1
fi

if ! docker image inspect "\${IMAGE}" >/dev/null 2>&1; then
	echo "Docker image \${IMAGE} was not found. Built images:"
	docker images --format '  {{.Repository}}:{{.Tag}}  {{.ID}}  {{.Size}}' || true
	exit 1
fi

if docker ps --filter "name=^\${CONTAINER}\$" --filter status=running --format '{{.Names}}' | grep -qx "\${CONTAINER}"; then
	echo "Container \${CONTAINER} already running."
	exit 0
fi

if docker ps -a --filter "name=^\${CONTAINER}\$" --format '{{.Names}}' | grep -qx "\${CONTAINER}"; then
	docker rm "\${CONTAINER}" >/dev/null
fi

PORT_HOLDER="\$(docker ps --filter "publish=\${PORT}" --format '{{.Names}}' | head -1)"
if [[ -n "\${PORT_HOLDER}" ]]; then
	echo "Port \${PORT} is already published by container \${PORT_HOLDER}."
	exit 1
fi

mkdir -p "\${DATA_DIR}"

GPU_ARGS=()
if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q 'nvidia'; then
	GPU_ARGS=(--runtime=nvidia -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all)
	echo "NVIDIA runtime enabled."
elif [[ "\${ALLOW_CPU}" == "1" ]]; then
	echo "NVIDIA runtime not found; starting CPU fallback."
else
	echo "NVIDIA runtime not found; refusing to start without ALLOW_CPU_FALLBACK=1."
	exit 1
fi

docker run -d \
	--name "\${CONTAINER}" \
	--restart unless-stopped \
	--shm-size=2g \
	-p "\${PORT}:6901" \
	-e "VNC_USER=\${VNC_USER_VALUE}" \
	-e "VNC_PW=\${VNC_PW_VALUE}" \
	-e "LOCKOUT_LEVEL=\${LOCKOUT_VALUE}" \
	-v "\${DATA_DIR}:/home/kasm-user/data" \
	"\${GPU_ARGS[@]}" \
	"\${IMAGE}"

docker ps --filter "name=^\${CONTAINER}\$" --format 'Started {{.Names}}: {{.Status}} {{.Ports}}'

echo "CoralNet-Toolbox running at https://localhost:\${PORT} (user: \${VNC_USER_VALUE})"
LAUNCHER
	run_privileged chmod +x /usr/local/bin/start-coralnet-docker-gpu.sh
	if run_privileged grep -q -- '--gpus' /usr/local/bin/start-coralnet-docker-gpu.sh; then
		die "generated launcher still contains --gpus; refusing to install stale GPU launch mode."
	fi
	if ! run_privileged grep -q -- '--runtime=nvidia' /usr/local/bin/start-coralnet-docker-gpu.sh; then
		die "generated launcher does not contain --runtime=nvidia."
	fi
	mkdir -p "${ACTUAL_HOME}/.local/share/coralnet-docker"
	run_privileged cp /usr/local/bin/start-coralnet-docker-gpu.sh "${ACTUAL_HOME}/.local/share/coralnet-docker/start-coralnet-docker-gpu.sh"
	run_privileged chown -R "${ACTUAL_USER}:${ACTUAL_USER}" "${ACTUAL_HOME}/.local/share/coralnet-docker"
}

write_persistent_hook() {
	log "7. Installing Cloud Workstations persistent startup hook"
	HOOK_DIR="${ACTUAL_HOME}/.customize_environment.d"
	HOOK_FILE="${HOOK_DIR}/20-coralnet-docker-gpu.sh"
	mkdir -p "${HOOK_DIR}"
	cat > "${HOOK_FILE}" <<HOOK
#!/usr/bin/env bash
set -u

export CORALNET_REPO_URL="${CORALNET_REPO_URL}"
export CORALNET_REF="${CORALNET_REF}"
export CORALNET_REPO_DIR="${CORALNET_REPO_DIR}"
export CORALNET_DATA_DIR="${CORALNET_DATA_DIR}"
export CORALNET_IMAGE="${CORALNET_IMAGE}"
export CORALNET_CONTAINER="${CORALNET_CONTAINER}"
export CORALNET_PORT="${CORALNET_PORT}"
export CORALNET_VNC_USER="${CORALNET_VNC_USER}"
export CORALNET_VNC_PW="${CORALNET_VNC_PW}"
export LOCKOUT_LEVEL="${LOCKOUT_LEVEL}"
export TORCH_CUDA="${TORCH_CUDA}"
export INSTALL_CHROME="${INSTALL_CHROME}"
export ALLOW_CPU_FALLBACK="${ALLOW_CPU_FALLBACK}"

INSTALLER=""
for candidate in \
	"${CORALNET_REPO_DIR}/setup_test_docker_gpu_persistent.sh" \
	"${CORALNET_REPO_DIR}/setup_coralnet_docker_gpu_persistent.sh"; do
	if [[ -f "\${candidate}" ]]; then
		INSTALLER="\${candidate}"
		break
	fi
done
if [[ -n "\${INSTALLER}" ]]; then
	if command -v sudo >/dev/null 2>&1; then
		sudo -E bash "\${INSTALLER}" || true
	else
		bash "\${INSTALLER}" || true
	fi
	exit 0
fi

if [[ -x "${ACTUAL_HOME}/.local/share/coralnet-docker/start-coralnet-docker-gpu.sh" ]]; then
	if command -v sudo >/dev/null 2>&1; then
		sudo install -m 0755 "${ACTUAL_HOME}/.local/share/coralnet-docker/start-coralnet-docker-gpu.sh" /usr/local/bin/start-coralnet-docker-gpu.sh || true
	else
		install -m 0755 "${ACTUAL_HOME}/.local/share/coralnet-docker/start-coralnet-docker-gpu.sh" /usr/local/bin/start-coralnet-docker-gpu.sh || true
	fi
fi

if command -v sudo >/dev/null 2>&1; then
	sudo /usr/local/bin/start-coralnet-docker-gpu.sh || true
else
	/usr/local/bin/start-coralnet-docker-gpu.sh || true
fi
HOOK
	chmod +x "${HOOK_FILE}"

	install_dispatcher() {
		local dispatcher="$1"
		if [[ -f "${dispatcher}" ]] && ! grep -q 'customize_environment.d dispatcher' "${dispatcher}"; then
			cp "${dispatcher}" "${HOOK_DIR}/00-original-$(basename "${dispatcher}").sh"
			chmod +x "${HOOK_DIR}/00-original-$(basename "${dispatcher}").sh"
		fi
		cat > "${dispatcher}" <<'DISPATCHER'
#!/usr/bin/env bash
# customize_environment.d dispatcher - runs once per workstation start.
set -u

DROPIN_DIR="$HOME/.customize_environment.d"
if [[ -d "${DROPIN_DIR}" ]]; then
	for hook in "${DROPIN_DIR}"/*.sh; do
		[[ -f "${hook}" ]] || continue
		bash "${hook}" || true
	done
fi
DISPATCHER
		chmod +x "${dispatcher}"
	}

	for dispatcher in "${ACTUAL_HOME}/.workstation/customize_environment" "${ACTUAL_HOME}/.customize_environment"; do
		mkdir -p "$(dirname "${dispatcher}")"
		install_dispatcher "${dispatcher}"
	done

	chown -R "${ACTUAL_USER}:${ACTUAL_USER}" "${ACTUAL_HOME}/.customize_environment.d" "${ACTUAL_HOME}/.customize_environment" "${ACTUAL_HOME}/.workstation" 2>/dev/null || true
	echo "Persistent startup hook installed at ${HOOK_FILE}."
}

start_now() {
	log "8. Starting CoralNet-Toolbox now"
	if ! run_privileged /usr/local/bin/start-coralnet-docker-gpu.sh; then
		warn "CoralNet Docker launcher failed. Last launcher log lines:"
		run_privileged tail -80 /var/log/coralnet-docker-autostart.log 2>/dev/null || true
		exit 1
	fi
}

ACTUAL_USER="${SUDO_USER:-${USER:-}}"
if [[ -z "${ACTUAL_USER}" || "${ACTUAL_USER}" == "root" ]]; then
	ACTUAL_USER="$(awk -F: '$3>=1000 && $3<60000 && $1!="nobody" {print $1; exit}' /etc/passwd)"
fi
[[ -n "${ACTUAL_USER}" ]] || die "could not determine a non-root user for persistent Cloud Workstations hooks."
ACTUAL_HOME="$(eval echo "~${ACTUAL_USER}")"
CORALNET_REPO_DIR="${CORALNET_REPO_DIR:-${ACTUAL_HOME}/CoralNet-Toolbox}"
CORALNET_DATA_DIR="${CORALNET_DATA_DIR:-${ACTUAL_HOME}/coralnet-data}"

log "setup_test_docker_gpu_persistent.sh"
echo "Version       : ${SCRIPT_VERSION}"
echo "User / home   : ${ACTUAL_USER} / ${ACTUAL_HOME}"
echo "Repo URL      : ${CORALNET_REPO_URL}"
echo "Repo ref      : ${CORALNET_REF}"
echo "Repo dir      : ${CORALNET_REPO_DIR}"
echo "Data dir      : ${CORALNET_DATA_DIR}"
echo "Image         : ${CORALNET_IMAGE}"
echo "Container     : ${CORALNET_CONTAINER}"
echo "Port          : ${CORALNET_PORT}"
echo "Torch CUDA    : ${TORCH_CUDA}"
echo "Lockout level : ${LOCKOUT_LEVEL}"

require_cmd apt-get
if [[ "$(id -u)" -ne 0 ]]; then
	require_cmd sudo
fi

install_base_packages
install_docker
install_nvidia_toolkit
prepare_checkout
build_image
write_launcher
write_persistent_hook
start_now

log "Install complete"
echo "Open: https://localhost:${CORALNET_PORT}"
echo "User: ${CORALNET_VNC_USER}"
echo "Data: ${CORALNET_DATA_DIR} -> /home/kasm-user/data"
echo "Logs: /var/log/coralnet-docker-autostart.log and docker logs ${CORALNET_CONTAINER}"