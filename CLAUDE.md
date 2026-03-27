# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

A Python FastAPI application deployed to Azure Container Apps to test and validate Azure monitoring capabilities. Exposes endpoints that generate CPU/memory load, HTTP errors, latency, and scaling events.

## Commands

**Local development** (always use the virtual env):
```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload         # dev server at http://localhost:8000
```

**Docker:**
```bash
docker build --platform linux/amd64 -t monitoring-demo .
docker run -p 8000:8000 monitoring-demo
```

**Build and push to ACR** (after `terraform apply`):
```bash
# --platform linux/amd64 required — Azure Container Apps only accepts amd64 images
docker build --platform linux/amd64 -t <acr_name>.azurecr.io/monitoring-demo:latest .
az acr login --name <acr_name>
docker push <acr_name>.azurecr.io/monitoring-demo:latest
```

**Terraform:**
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in values
terraform init
terraform plan
terraform apply
terraform output -json   # view all outputs including sensitive values
```

## Architecture

```
app/
├── main.py              # FastAPI app, registers all routers
└── routers/
    ├── load.py          # POST /load/cpu, POST /load/memory
    ├── errors.py        # GET /errors/{code}
    ├── latency.py       # GET /latency?ms=N
    └── scaling.py       # GET /burst?requests=N  (fires self-requests to /health)

terraform/
├── main.tf              # Resource group
├── acr.tf               # Azure Container Registry (Basic, admin enabled)
├── monitoring.tf        # Log Analytics Workspace + Application Insights
├── container_app.tf     # Container Apps Environment + Container App
├── alerts.tf            # Action group (email) + metric alerts + activity log alerts + availability test
└── outputs.tf
```

## Azure Resources Created

| Resource | Name | Notes |
|---|---|---|
| Resource Group | `rg-monitoring-demo` | configurable via variable |
| ACR | `var.acr_name` | globally unique, alphanumeric |
| Log Analytics | `law-monitoring-demo` | receives container stdout/stderr |
| Application Insights | `appi-monitoring-demo` | workspace-based, linked to Log Analytics |
| Container Apps Env | `cae-monitoring-demo` | linked to Log Analytics |
| Container App | `var.container_app_name` | HTTP scaling, 1–5 replicas |

## Alerts

All alerts notify via email (action group). Thresholds are based on container allocation (0.5 vCPU / 1Gi):

| Alert | Metric | Threshold |
|---|---|---|
| Availability | `availabilityResults/availabilityPercentage` (Web Test) | < 100% from any region |
| CPU high | `UsageNanoCores` (Container App) | > 400,000,000 (80% of 0.5 vCPU) |
| Memory high | `WorkingSetBytes` (Container App) | > 858,993,459 bytes (80% of 1Gi) |
| HTTP 5xx | `requests/failed` (App Insights) | > 10 in 5 min |
| Container restarts | `RestartCount` (Container App) | > 0 |
| App deleted | Activity Log `Microsoft.App/containerApps/delete` | Any deletion |
| Env deleted | Activity Log `Microsoft.App/managedEnvironments/delete` | Any deletion |

## Deployment Flow

1. `terraform apply` — provisions all Azure resources
2. `docker build` + `docker push` to ACR
3. Container App automatically pulls the new image (or force a new revision via Azure CLI)
