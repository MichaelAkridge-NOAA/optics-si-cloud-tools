#!/usr/bin/env bash
# Ollama Docker Setup Helper

set -euo pipefail

DEFAULT_MODEL="${DEFAULT_MODEL:-gemma4:e4b}"
OLLAMA_CONTAINER="${OLLAMA_CONTAINER:-ollama}"
CMD="${1:-help}"

echo "Ollama Docker Setup"
echo "==================="
echo ""

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "Docker is not installed. Please install Docker first."
    echo "   https://docs.docker.com/get-docker/"
    exit 1
fi

# Check if docker-compose is available
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    echo "Docker Compose is not installed. Please install it first."
    exit 1
fi

# Function to use the right compose command
compose_cmd() {
    if docker compose version &> /dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

wait_for_ollama() {
    echo "Waiting for Ollama API to become ready..."
    for _ in $(seq 1 60); do
        if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
            echo "Ollama API is ready."
            return 0
        fi
        sleep 2
    done

    echo "Ollama API did not become ready in time."
    return 1
}

model_installed() {
    local model="$1"
    docker exec "$OLLAMA_CONTAINER" ollama list 2>/dev/null \
        | awk 'NR>1 {print $1}' \
        | grep -Fxq "$model"
}

ensure_model() {
    local model="$1"
    if model_installed "$model"; then
        echo "Model already installed: $model"
        return 0
    fi

    echo "Pulling model: $model"
    docker exec "$OLLAMA_CONTAINER" ollama pull "$model"
}

case "$CMD" in
    start)
        echo "Starting Ollama service..."
        compose_cmd up -d

        wait_for_ollama
        ensure_model "$DEFAULT_MODEL"

        echo ""
        echo "Services started."
        echo "Ollama API: http://127.0.0.1:11434"
        echo "Default model ready: $DEFAULT_MODEL"
        ;;
    
    stop)
        echo "Stopping services..."
        compose_cmd down
        echo "Stopped."
        ;;
    
    logs)
        compose_cmd logs -f
        ;;
    
    pull-model)
        MODEL=${2:-$DEFAULT_MODEL}
        ensure_model "$MODEL"
        echo "Model ready: $MODEL"
        ;;
    
    list-models)
        echo "Installed models:"
        docker exec "$OLLAMA_CONTAINER" ollama list
        ;;
    
    rebuild)
        echo "Pulling latest Ollama image and restarting..."
        compose_cmd pull ollama
        compose_cmd up -d
        wait_for_ollama
        echo "Pulled and restarted."
        ;;
    
    *)
        echo "Usage: ./cloud-install.sh [command]"
        echo ""
        echo "Commands:"
        echo "  start        Start Ollama and ensure default model"
        echo "  stop         Stop all services"
        echo "  logs         View logs (Ctrl+C to exit)"
        echo "  pull-model   Pull an Ollama model (default: $DEFAULT_MODEL)"
        echo "  list-models  List installed models"
        echo "  rebuild      Rebuild and restart Ollama"
        echo ""
        echo "Examples:"
        echo "  ./cloud-install.sh start"
        echo "  ./cloud-install.sh pull-model gemma4:e4b"
        echo "  ./cloud-install.sh pull-model gemma4:12b"
        ;;
esac
