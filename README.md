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

### Availability (App Insights web test)

An availability test pings `/health` from 5 Azure regions every 5 minutes. The alert fires (severity Critical) as soon as the endpoint fails from any single region.

**Check availability results in the portal:**
App Insights → **Availability** blade — shows pass/fail per region over time.

**Simulate a failure to test the alert:**
Stop the Container App replicas temporarily:
```bash
# Scale to 0 (triggers alert within ~5 minutes)
az containerapp update \
  --name monitoring-demo \
  --resource-group rg-monitoring-demo \
  --min-replicas 0 --max-replicas 0

# Restore
az containerapp update \
  --name monitoring-demo \
  --resource-group rg-monitoring-demo \
  --min-replicas 2 --max-replicas 5
```

> **Note:** Scaling to 0 will cause the availability test to fail, triggering the alert. Wait ~5–10 minutes for the alert to fire and the email to arrive.

---

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

---

## Backup and Recovery

### What is backed up

This stack is fully declared in Terraform. The Terraform code **is** the backup — every resource (Container App, Environment, networking, alerts, monitoring) can be recreated from it. The container image is stored in ACR and survives independently of the Container App.

There is no stateful application data to back up: the Container App is stateless.

---

### Deletion alerts

Two Activity Log alerts fire immediately when a deletion is detected:

| Alert | Trigger |
|---|---|
| `alert-container-app-deleted` | `Microsoft.App/containerApps/delete` operation |
| `alert-environment-deleted` | `Microsoft.App/managedEnvironments/delete` operation |

Both alert via email (same action group as metric alerts). Activity Log alerts fire within ~1 minute of the deletion event.

---

### Recovery runbook

#### Scenario A — Container App deleted (environment still exists)

This is the most likely accidental deletion. The environment, networking, monitoring, and ACR image are intact.

**Estimated recovery time: ~3 minutes**

```bash
cd terraform
terraform apply
```

Terraform detects the missing Container App and recreates it using the image currently referenced in `terraform.tfvars`. Verify:

```bash
terraform output container_app_url
curl https://<container_app_url>/health
```

---

#### Scenario B — Container Apps Environment deleted (app also gone)

The environment cannot be deleted while the app exists, so both are gone. Networking, ACR, and monitoring are intact.

**Estimated recovery time: ~10–15 minutes** (environment provisioning takes time)

```bash
cd terraform
terraform apply
```

Terraform recreates the environment and the Container App. The environment has `prevent_destroy = true` in the Terraform config — this prevents accidental `terraform destroy` from removing it, but a manual deletion (portal/CLI) bypasses this protection.

Verify:

```bash
terraform output container_app_url
curl https://<container_app_url>/health
```

> **Note:** If the environment was deleted manually (not via Terraform), run `terraform plan` first to confirm the full list of resources Terraform will recreate before applying.

---

#### Scenario C — Wrong image deployed (rollback)

If a bad image was pushed and deployed, roll back to a previous image tag:

```bash
# List available tags in ACR
az acr repository show-tags \
  --name <acr_name> \
  --repository monitoring-demo \
  --orderby time_desc \
  --output table

# Roll back to a previous tag
az containerapp update \
  --name monitoring-demo \
  --resource-group rg-monitoring-demo \
  --image <acr_login_server>/monitoring-demo:<previous_tag>
```

Then update `container_image` in `terraform.tfvars` to match, so the next `terraform apply` does not overwrite it.

---

### Testing the deletion alert

To verify the alert fires without destroying production infrastructure, use a test Container App:

```bash
# Create a throwaway container app
az containerapp create \
  --name monitoring-demo-test \
  --resource-group rg-monitoring-demo \
  --environment cae-monitoring-demo \
  --image mcr.microsoft.com/azuredocs/containerapps-helloworld:latest \
  --ingress external --target-port 80

# Delete it — this should trigger the alert-container-app-deleted alert
az containerapp delete \
  --name monitoring-demo-test \
  --resource-group rg-monitoring-demo \
  --yes
```

Check the alert fired: Azure Portal → Monitor → Alerts → Alert history.
