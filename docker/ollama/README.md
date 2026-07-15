# Local Ollama on Google Cloud Workstations (T4)

This project deploys Ollama with GPU support and a default Gemma 4 model.

## Defaults

- Model: `gemma4:e4b`
- Bootstrap auto-pulls default model: `enabled`
- Ollama API on workstation: `0.0.0.0:11434` (needed for Cloud Workstations TCP tunnel forwarding)
- Persistent model storage: `/home/user/.ollama`

## Deploy on Workstation

SSH to workstation
```bash
gcloud workstations ssh --project=PROJECT_ID --region=REGION --cluster=CLUSTER_NAME --config=CONFIG_NAME WORKSTATION_NAME 
```

Run on the workstation:
```bash
curl -SL https://raw.githubusercontent.com/MichaelAkridge-NOAA/optics-si-cloud-tools/main/docker/ollama/cloud_bootstrap.sh | sudo bash
```
By default, bootstrap waits for Ollama readiness and pulls `gemma4:e4b` if missing.

Override default model during bootstrap:

```bash
sudo DEFAULT_MODEL=gemma4:12b bash cloud_bootstrap.sh
```

Then manage runtime:

```bash
bash cloud-install.sh start
bash cloud-install.sh list-models
```

Other model installs:
```bash
cd /opt/local-ollama/docker/ollama
bash cloud-install.sh pull-model llama3.1:8b
bash cloud-install.sh pull-model gemma4:12b
```

## Local Connectivity for VS Code Extension

Your extension discovers Ollama at `http://127.0.0.1:11434` by default.
Keep that endpoint unchanged by creating a local tunnel to the workstation.

### Recommended: direct TCP tunnel

Run on your local machine:

```bash
gcloud workstations start-tcp-tunnel --project=PROJECT_ID --region=REGION --cluster=CLUSTER_NAME --config=CONFIG_NAME --local-host-port=localhost:11434 WORKSTATION_NAME 11434
```

Leave this command running. Your local `127.0.0.1:11434` traffic is forwarded to the workstation.

### Fallback: SSH with local forward

Run on your local machine:

```bash
gcloud workstations ssh \
  --project=PROJECT_ID \
  --region=REGION \
  --cluster=CLUSTER_NAME \
  --config=CONFIG_NAME \
  WORKSTATION_NAME \
  -- -L 11434:127.0.0.1:11434
```

## Quick Verification

Run on the workstation:

```bash
nvidia-smi
docker compose ps
curl -sSf http://127.0.0.1:11434/api/tags
```

## Streaming Verification

Generate with streaming from your local machine (with tunnel active):

```bash
curl -N -sS http://127.0.0.1:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma4:e4b","prompt":"Reply with exactly: streaming works","stream":true}'
```

Generate without streaming:

```bash
curl -sS http://127.0.0.1:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma4:e4b","prompt":"Reply with exactly: non streaming works","stream":false}'
```

Run on local machine (with tunnel active):

```bash
curl -sSf http://127.0.0.1:11434/api/tags
```

## Troubleshooting

