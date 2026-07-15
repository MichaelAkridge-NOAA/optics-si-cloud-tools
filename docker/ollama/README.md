# Local Ollama on Google Cloud Workstations (T4)

This project deploys Ollama with GPU support and a default Gemma 4 model.

Upstream source path: https://github.com/MichaelAkridge-NOAA/optics-si-cloud-tools/tree/main/docker/ollama

## Defaults

- Model: `gemma4:e4b`
- Bootstrap auto-pulls default model: `enabled`
- Ollama API on workstation: `127.0.0.1:11434`
- Persistent model storage: `/home/user/.ollama`

## Deploy on Workstation

Run on the workstation:
```bash
curl -SL https://raw.githubusercontent.com/MichaelAkridge-NOAA/optics-si-cloud-tools/main/docker/ollama/cloud_bootstrap.sh | sudo bash
```
OR if git cloned then just:
```bash
sudo bash cloud_bootstrap.sh
```

By default, bootstrap waits for Ollama readiness and pulls `gemma4:e4b` if missing.

Disable model auto-pull for infra-only setup:

```bash
sudo AUTO_PULL_MODEL=0 bash cloud_bootstrap.sh
```

Override default model during bootstrap:

```bash
sudo DEFAULT_MODEL=gemma4:12b bash cloud_bootstrap.sh
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

## Troubleshooting

### Error: CDI mode / NVIDIA runtime hook conflict

If container startup fails with a message similar to:

`Using requested mode 'cdi' ... use the NVIDIA Container Runtime ... --runtime=nvidia`

run on the workstation:

```bash
sudo nvidia-ctk config --set nvidia-container-runtime.mode=legacy --in-place
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Then restart Ollama from the compose directory:

```bash
cd /opt/local-ollama/docker/ollama
docker compose down
docker compose up -d
```


```bash
#Do this once on the workstation:

cd /opt/local-ollama/docker/ollama
bash cloud-install.sh pull-model gemma4:e4b
docker exec ollama ollama list
```