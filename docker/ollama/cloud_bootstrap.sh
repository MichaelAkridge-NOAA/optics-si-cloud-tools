#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_VERSION="2026.07.15-1"

# Cloud host bootstrap for Ollama.
# Purpose:
# - Install Docker and prerequisites on Debian/Ubuntu hosts
# - Install and configure NVIDIA container runtime for GPU workloads
# - Clone or update repository and use the target subdirectory
# - Start the Ollama Docker Compose stack
# - Install a systemd unit so the stack starts on reboot
#
# Common usage:
#   sudo bash cloud_bootstrap.sh
# Curl-and-run usage:
#   curl -SL https://raw.githubusercontent.com/MichaelAkridge-NOAA/optics-si-cloud-tools/main/docker/ollama/cloud_bootstrap.sh | sudo bash
# Optional override:
#   sudo REPO_URL=https://github.com/MichaelAkridge-NOAA/optics-si-cloud-tools REPO_SUBDIR=docker/ollama bash cloud_bootstrap.sh

# Deployment configuration (override via environment variables).
APP_NAME="${APP_NAME:-local-ollama}"
REPO_URL="${REPO_URL:-https://github.com/MichaelAkridge-NOAA/optics-si-cloud-tools}"
REPO_SUBDIR="${REPO_SUBDIR:-docker/ollama}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/${APP_NAME}}"
SERVICE_NAME="${SERVICE_NAME:-${APP_NAME}.service}"
COMPOSE_DIR="${INSTALL_DIR}/${REPO_SUBDIR}"
DEFAULT_MODEL="${DEFAULT_MODEL:-gemma4:e4b}"
AUTO_PULL_MODEL="${AUTO_PULL_MODEL:-1}"

compose_path() {
	if [[ -f "${COMPOSE_DIR}/docker-compose.yml" ]]; then
		echo "${COMPOSE_DIR}/docker-compose.yml"
	elif [[ -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
		echo "${INSTALL_DIR}/docker-compose.yml"
	else
		echo ""
	fi
}

require_root() {
	if [[ "$(id -u)" -ne 0 ]]; then
		echo "Run this script as root: sudo bash cloud_bootstrap.sh" >&2
		exit 1
	fi
}

log() {
	echo
	echo "==> $1"
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "Missing required command: $1" >&2
		exit 1
	}
}

has_systemd() {
	command -v systemctl >/dev/null 2>&1 || return 1
	[[ "$(ps -p 1 -o comm= 2>/dev/null || true)" == "systemd" ]]
}

clone_or_update_repo() {
	if [[ -d "${INSTALL_DIR}/.git" ]]; then
		git -C "${INSTALL_DIR}" fetch origin "${BRANCH}"
		git -C "${INSTALL_DIR}" checkout "${BRANCH}"
		git -C "${INSTALL_DIR}" reset --hard "origin/${BRANCH}"
	else
		git clone --branch "${BRANCH}" "${REPO_URL}" "${INSTALL_DIR}"
	fi
}

install_prerequisites() {
	local need_install=0

	if ! command -v git >/dev/null 2>&1; then
		need_install=1
	fi

	if ! command -v docker >/dev/null 2>&1; then
		need_install=1
	elif ! docker compose version >/dev/null 2>&1; then
		need_install=1
	fi

	if [[ "${need_install}" -eq 1 ]]; then
		log "Installing prerequisites (git, docker, compose plugin)"
		apt-get update
		apt-get install -y ca-certificates curl gnupg git docker.io docker-compose-plugin
	fi

	if has_systemd; then
		if ! systemctl enable --now docker; then
			echo "systemctl is present but not functional; falling back to non-systemd docker startup." >&2
			if command -v service >/dev/null 2>&1; then
				service docker start || true
			fi
		fi
	elif command -v service >/dev/null 2>&1; then
		service docker start || true
	fi

	if ! docker info >/dev/null 2>&1; then
		echo "Docker daemon is not reachable. Start Docker manually on this host and rerun bootstrap." >&2
		exit 1
	fi
}

install_nvidia_container_toolkit() {
	if command -v nvidia-ctk >/dev/null 2>&1; then
		log "NVIDIA container toolkit already installed"
		return
	fi

	log "Installing NVIDIA container toolkit"
	install -m 0755 -d /etc/apt/keyrings
	curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
		| gpg --dearmor -o /etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg

	curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
		| sed 's#deb https://#deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
		| tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

	apt-get update
	apt-get install -y nvidia-container-toolkit
}

configure_nvidia_runtime() {
	if ! command -v nvidia-ctk >/dev/null 2>&1; then
		echo "nvidia-ctk not found after installation. Aborting." >&2
		exit 1
	fi

	log "Configuring Docker NVIDIA runtime"
	# Some hosts default NVIDIA runtime to CDI mode, which conflicts with Docker GPU flags.
	# Force legacy runtime mode for broad Docker Compose compatibility.
	nvidia-ctk config --set nvidia-container-runtime.mode=legacy --in-place || true
	nvidia-ctk runtime configure --runtime=docker

	if has_systemd; then
		systemctl restart docker
	elif command -v service >/dev/null 2>&1; then
		service docker restart || true
	fi

	if ! docker info >/dev/null 2>&1; then
		echo "Docker daemon is not reachable after NVIDIA runtime configuration." >&2
		exit 1
	fi
}

write_systemd_unit() {
	local compose_file
	compose_file="$(compose_path)"
	if [[ -z "${compose_file}" ]]; then
		echo "docker-compose.yml not found under ${COMPOSE_DIR} or ${INSTALL_DIR}." >&2
		exit 1
	fi

	local unit_path="/etc/systemd/system/${SERVICE_NAME}"
	cat > "${unit_path}" <<EOF
[Unit]
Description=Ollama compose stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$(dirname "${compose_file}")
ExecStart=/usr/bin/docker compose -f ${compose_file} up -d
ExecStop=/usr/bin/docker compose -f ${compose_file} down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload
	systemctl enable "${SERVICE_NAME}"
}

start_compose_stack() {
	local compose_file
	compose_file="$(compose_path)"
	if [[ -z "${compose_file}" ]]; then
		echo "docker-compose.yml not found under ${COMPOSE_DIR} or ${INSTALL_DIR}." >&2
		exit 1
	fi

	log "Starting compose stack from ${compose_file}"
	docker compose -f "${compose_file}" up -d
}

wait_for_ollama_api() {
	log "Waiting for Ollama API readiness"
	for _ in $(seq 1 60); do
		if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
	done

	echo "Ollama API did not become ready in time." >&2
	return 1
}

model_installed() {
	local model="$1"
	docker exec ollama ollama list 2>/dev/null \
		| awk 'NR>1 {print $1}' \
		| grep -Fxq "$model"
}

ensure_default_model() {
	if [[ "${AUTO_PULL_MODEL}" != "1" ]]; then
		log "Skipping default model pull (AUTO_PULL_MODEL=${AUTO_PULL_MODEL})"
		return
	fi

	wait_for_ollama_api

	if model_installed "${DEFAULT_MODEL}"; then
		log "Default model already present: ${DEFAULT_MODEL}"
		return
	fi

	log "Pulling default model: ${DEFAULT_MODEL}"
	docker exec ollama ollama pull "${DEFAULT_MODEL}"
}

main() {
	require_root
	require_cmd apt-get

	echo "Ollama bootstrap version: ${BOOTSTRAP_VERSION}"

	log "Preparing host"
	install_prerequisites
	install_nvidia_container_toolkit
	configure_nvidia_runtime

	log "Cloning or updating repository"
	mkdir -p "$(dirname "${INSTALL_DIR}")"
	clone_or_update_repo

	start_compose_stack
	ensure_default_model

	log "Installing boot-time service"
	if has_systemd; then
		write_systemd_unit
		systemctl start "${SERVICE_NAME}"
	else
		echo "systemd not detected; skipping system service installation."
		echo "Use this command after reboot/login to bring stack up:"
		echo "  cd ${INSTALL_DIR} && docker compose up -d"
	fi

	echo
	echo "Ollama deployment is ready."
	echo "Bootstrap : ${BOOTSTRAP_VERSION}"
	echo "Service   : ${SERVICE_NAME}"
	echo "Install   : ${INSTALL_DIR}"
	echo "Subdir    : ${REPO_SUBDIR}"
	echo "Endpoint  : http://127.0.0.1:11434"
	echo "Model     : ${DEFAULT_MODEL}"
	echo "Auto pull : ${AUTO_PULL_MODEL} (1=enabled)"
	if has_systemd; then
		echo "Restart   : systemctl restart ${SERVICE_NAME}"
		echo "Status    : systemctl status ${SERVICE_NAME}"
	else
		echo "Restart   : docker compose -f $(compose_path) up -d"
		echo "Status    : docker compose -f $(compose_path) ps"
	fi
}

main "$@"
