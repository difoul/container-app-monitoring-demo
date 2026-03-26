# Azure Container App Monitoring Demo

A FastAPI application for testing Azure Container Apps monitoring capabilities: CPU/memory load, HTTP errors, latency simulation, and scaling triggers.

---

## Testing the Application Locally

### 1. Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

The API is available at `http://localhost:8000`.
Interactive docs (Swagger UI) at `http://localhost:8000/docs`.

---

### 2. Endpoints

#### Health check
```bash
curl http://localhost:8000/health
```

#### CPU load
Burn CPU at a given intensity (%) for a given duration (seconds). Runs in the background — the endpoint returns immediately.
```bash
# 80% CPU for 30 seconds
curl -X POST "http://localhost:8000/load/cpu?duration=30&intensity=80"

# 100% CPU for 60 seconds
curl -X POST "http://localhost:8000/load/cpu?duration=60&intensity=100"
```

#### Memory load
Allocate a given number of megabytes for a given duration (seconds). Runs in the background.
```bash
# Allocate 512 MB for 30 seconds
curl -X POST "http://localhost:8000/load/memory?mb=512&duration=30"
```

#### HTTP errors
Return any HTTP error code to simulate error scenarios.
```bash
curl -i http://localhost:8000/errors/500   # Internal Server Error
curl -i http://localhost:8000/errors/503   # Service Unavailable
curl -i http://localhost:8000/errors/429   # Too Many Requests
curl -i http://localhost:8000/errors/404   # Not Found
```

#### Latency simulation
Respond after an artificial delay (milliseconds).
```bash
# 2 second delay
curl http://localhost:8000/latency?ms=2000

# 5 second delay
curl http://localhost:8000/latency?ms=5000
```

#### Burst
Fire N concurrent self-requests against `/health`. Useful for generating request telemetry in App Insights. **Does not trigger autoscaling** — use `hey` from your local machine for that (see below).
```bash
curl "http://localhost:8000/burst?requests=100"
```

---

## Build and Push the Docker Image to ACR

Deployment is a two-step process because the ACR image must exist before the Container App can run it.

### Prerequisites
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed and logged in
- Docker running locally

---

### Step 1 — Apply Terraform with the placeholder image

On the first apply, leave `container_image` unset (or commented out in `terraform.tfvars`). Terraform will deploy the Container App with a public placeholder image so all resources are created successfully.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in subscription_id, acr_name, alert_email
terraform init
terraform apply
```

---

### Step 2 — Build and push the actual image

**Log in to ACR:**
```bash
az acr login --name <acr_name>
```

**Build and push** (run from the project root):

> **Apple Silicon (M1/M2/M3) users:** Azure Container Apps requires `linux/amd64` images. Always include `--platform linux/amd64`.

```bash
docker build --platform linux/amd64 -t <acr_login_server>/monitoring-demo:latest .
docker push <acr_login_server>/monitoring-demo:latest
```

**Switch the Container App to the real image** by setting `container_image` in `terraform.tfvars`:
```hcl
container_image = "acrmonitoringdemo.azurecr.io/monitoring-demo:latest"
```

Then re-apply:
```bash
terraform apply
```

---

### Step 3 — Subsequent deploys

Use a unique tag each time to force Azure to pull the new image. Using `latest` without changing the tag will not trigger a new revision.

```bash
TAG=$(date +%s)
docker build --platform linux/amd64 -t <acr_login_server>/monitoring-demo:$TAG .
docker push <acr_login_server>/monitoring-demo:$TAG
az containerapp update \
  --name monitoring-demo \
  --resource-group rg-monitoring-demo \
  --image <acr_login_server>/monitoring-demo:$TAG
```

---

### Verify the deployment

```bash
terraform output container_app_url
curl https://<container_app_url>/health
curl https://<container_app_url>/docs
```

> **Note:** On first deploy the Container App may take 1–2 minutes to pull the image and start.

---

## Testing on Azure

Get the app URL once and reuse it:

```bash
export URL=https://$(az containerapp show \
  --name monitoring-demo \
  --resource-group rg-monitoring-demo \
  --query properties.configuration.ingress.fqdn -o tsv)
```

### HTTP errors (App Insights `requests/failed`)

```bash
# Single error
curl -i $URL/errors/500

# Repeat to exceed the alert threshold (>10 in 5 min)
for i in {1..15}; do curl -s $URL/errors/500; done
```

Check in App Insights → **Failures** blade or run in **Logs**:
```kusto
requests
| where timestamp > ago(30m)
| where resultCode >= 500
| project timestamp, name, resultCode, duration
| order by timestamp desc
```

---

### CPU load (triggers `UsageNanoCores` alert)

```bash
# 80% CPU for 60 seconds (alert threshold: >80% of 0.5 vCPU)
curl -X POST "$URL/load/cpu?duration=60&intensity=80"
```

---

### Memory load (triggers `WorkingSetBytes` alert)

```bash
# Allocate 900 MB for 60 seconds (alert threshold: >858 MB)
curl -X POST "$URL/load/memory?mb=900&duration=60"
```

---

### Autoscaling (HTTP scaling rule: >10 concurrent requests)

The scaling rule measures concurrent requests at the Azure ingress level. Use `hey` from your local machine — self-requests from within the container bypass the ingress and do not trigger scaling.

**Install hey:**
```bash
brew install hey   # macOS
```

**Trigger scale-out:**
```bash
# 50 concurrent for 60s — expect 2-3 replicas
hey -z 60s -c 50 $URL/health

# 100 concurrent for 120s — expect up to 5 replicas
hey -z 120s -c 100 $URL/health
```

**Watch replicas in real time (separate terminal):**
```bash
watch -n 5 'az containerapp replica list \
  --name monitoring-demo \
  --resource-group rg-monitoring-demo \
  --query "[].{name:name, state:properties.runningState}" \
  -o table'
```

Scale-in back to 1 replica happens automatically after ~5 minutes of low traffic.

---

### Mixed load (generate varied telemetry)

```bash
hey -z 30s -c 20 $URL/health &
hey -z 30s -c 20 "$URL/latency?ms=500" &
hey -z 30s -c 20 "$URL/errors/500" &
wait
```

---

## Monitoring in the Portal

| What to check | Where |
|---|---|
| Live request rate | App Insights → Live Metrics |
| Failed requests (5xx) | App Insights → Failures |
| Request telemetry | App Insights → Transaction search |
| Replica count over time | Container App → Metrics → Replica Count |
| CPU / Memory usage | Container App → Metrics → UsageNanoCores / WorkingSetBytes |
| Container logs | Container App → Log stream |
| Raw telemetry query | App Insights → Logs (KQL) |

**Useful KQL queries:**

```kusto
-- All requests in the last 30 minutes
requests
| where timestamp > ago(30m)
| summarize count() by bin(timestamp, 1m), resultCode
| render timechart

-- Failed requests only
requests
| where timestamp > ago(30m) and success == false
| project timestamp, name, resultCode, duration
| order by timestamp desc

-- Request rate over time
requests
| where timestamp > ago(30m)
| summarize count() by bin(timestamp, 30s)
| render timechart
```
