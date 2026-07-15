# Local Ollama on Google Cloud Workstations (T4)

This project deploys Ollama with GPU support and a default Gemma 4 model.

Upstream source path: https://github.com/MichaelAkridge-NOAA/optics-si-cloud-tools/tree/main/docker/ollama

## Defaults

- Model: `gemma4:e4b`
- Bootstrap auto-pulls default model: `enabled`
- Ollama API on workstation: `0.0.0.0:11434` (needed for Cloud Workstations TCP tunnel forwarding)
- Persistent model storage: `/home/user/.ollama`

## Deploy on Workstation

Run on the workstation:
```bash
curl -SL https://raw.githubusercontent.com/MichaelAkridge-NOAA/optics-si-cloud-tools/main/docker/ollama/cloud_bootstrap.sh | sudo bash
```
OR if git clone then just:
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

### Error: CDI mode / NVIDIA runtime hook conflict

If container startup fails with a message similar to:

`Using requested mode 'cdi' ... use the NVIDIA Container Runtime ... --runtime=nvidia`

run on the workstation:

```bash
sudo nvidia-ctk config --set nvidia-container-runtime.mode=legacy --in-place
sudo nvidia-ctk runtime configure --runtime=docker
sudo service docker restart
```

Then restart Ollama from the compose directory:

```bash
cd /opt/local-ollama/docker/ollama
docker compose down
docker compose up -d
```

### Error: libnvidia-ml.so.1 missing

If startup fails with:

`nvidia-container-cli: initialization error: load library failed: libnvidia-ml.so.1`

the workstation does not currently have a usable NVIDIA driver stack for containers.

Verify on workstation:

```bash
nvidia-smi
sudo find /var/lib/nvidia /usr/local/nvidia /usr/local/cuda /usr/lib/x86_64-linux-gnu /usr/lib64 \
  -name libnvidia-ml.so.1 -print
```

If `nvidia-smi` works but Docker still cannot load `libnvidia-ml.so.1`, register the NVIDIA library directory and restart Docker:

```bash
NVML_DIR="$(dirname "$(sudo find /var/lib/nvidia /usr/local/nvidia /usr/local/cuda /usr/lib/x86_64-linux-gnu /usr/lib64 -name libnvidia-ml.so.1 -print -quit)")"
echo "$NVML_DIR"
sudo sh -c "printf '%s\n' '$NVML_DIR' > /etc/ld.so.conf.d/nvidia-container-runtime.conf"
sudo ldconfig
sudo service docker restart
cd /opt/local-ollama/docker/ollama
docker compose down
docker compose up -d
```

If `nvidia-smi` fails or no `libnvidia-ml.so.1` exists under `/var/lib/nvidia`, `/usr/local/nvidia`, `/usr/local/cuda`, `/usr/lib/x86_64-linux-gnu`, or `/usr/lib64`, fix workstation GPU/driver provisioning first (T4 attached and driver available), then rerun bootstrap.

Bootstrap now discovers these common Cloud Workstations NVIDIA paths, registers the detected library directory with `ldconfig`, and fails early with a clear message if the GPU stack is not usable. This mirrors the NVIDIA discovery pattern from `setup_desktop_gpu_persistent.sh`, which checks `/var/lib/nvidia/bin/nvidia-smi` before standard system paths.

For controlled debugging only, you can bypass preflight once:

```bash
sudo SKIP_GPU_PREFLIGHT=1 bash cloud_bootstrap.sh
```

### Error: tunnel reset (WinError 10054)

If the local gcloud tunnel reports connection reset:

1. Ensure Ollama is listening on workstation port 11434:

```bash
cd /opt/local-ollama/docker/ollama
docker compose ps
curl -sSf http://127.0.0.1:11434/api/tags
```

2. Restart service and then restart the local tunnel:

```bash
cd /opt/local-ollama/docker/ollama
docker compose down
docker compose up -d
```

3. Start tunnel again on local machine:

```bash
gcloud workstations start-tcp-tunnel --project=PROJECT_ID --region=REGION --cluster=CLUSTER_NAME --config=CONFIG_NAME --local-host-port=localhost:11434 WORKSTATION_NAME 11434
```

### Duplicate model entries

Seeing both `gemma4` and `gemma4:e4b` is usually an alias/tag duplication, not two separate downloads.

Check installed tags:

```bash
docker exec ollama ollama list
```

If you want a single canonical tag, remove the alias and keep `gemma4:e4b`:

```bash
docker exec ollama ollama rm gemma4
```


```bash
#Do this once on the workstation:

cd /opt/local-ollama/docker/ollama
bash cloud-install.sh pull-model gemma4:e4b
docker exec ollama ollama list
```