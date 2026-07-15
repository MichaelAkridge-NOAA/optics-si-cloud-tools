# Local Ollama on Google Cloud Workstations (T4)

This project deploys Ollama with GPU support and a default Gemma 4 model.

Upstream source path: https://github.com/MichaelAkridge-NOAA/optics-si-cloud-tools/tree/main/docker/ollama

## Defaults

- Model: `gemma4:e4b`
- Ollama API on workstation: `127.0.0.1:11434`
- Persistent model storage: `/home/user/.ollama`

## Deploy on Workstation

Run on the workstation:

```bash
sudo bash cloud_bootstrap.sh
```

Optional explicit repo override (already the default in bootstrap):

```bash
sudo REPO_URL=https://github.com/MichaelAkridge-NOAA/optics-si-cloud-tools \
  REPO_SUBDIR=docker/ollama \
  bash cloud_bootstrap.sh
```

Then manage runtime:

```bash
bash cloud-install.sh start
bash cloud-install.sh list-models
```

## Local Connectivity for VS Code Extension

Your extension discovers Ollama at `http://127.0.0.1:11434` by default.
Keep that endpoint unchanged by creating a local tunnel to the workstation.

### Recommended: direct TCP tunnel

Run on your local machine:

```bash
gcloud workstations start-tcp-tunnel \
  --project=PROJECT_ID \
  --region=REGION \
  --cluster=CLUSTER_NAME \
  --config=CONFIG_NAME \
  --local-host-port=localhost:11434 \
  WORKSTATION_NAME \
  11434
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

Run on local machine (with tunnel active):

```bash
curl -sSf http://127.0.0.1:11434/api/tags
```
