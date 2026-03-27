# Summary

A production-grade Python sample application deployed to Azure Container App to demonstrate and validate Azure monitoring, alerting, high availability, and backup/recovery capabilities.

# Goal

Provide a reference example for users on how to operate Azure Container Apps in production.

# Output

A Docker image deployed to Azure Container App via Terraform, covering:
- Monitoring and observability (App Insights + Log Analytics)
- Alerting (metric-based alerts + activity log alerts via Azure Monitor)
- High availability (zone redundancy, min replicas, health probes)
- Backup and recovery (deletion alerts + recovery runbook)

# Features

The application exposes public endpoints to generate load, errors, latency, and scaling events.

## Endpoints
- `POST /load/cpu` — burns CPU at a given intensity for a given duration
- `POST /load/memory` — allocates and touches memory (force-writes every page to commit working set)
- `GET /errors/{code}` — raises HTTPException (tracked by App Insights as failed requests)
- `GET /latency?ms=N` — simulates response latency
- `GET /burst?requests=N` — fires concurrent self-requests with semaphore(50)
- `GET /health` — health check (used by probes and scaling)

# Infrastructure (Terraform)

| Resource | Notes |
|---|---|
| Resource Group | `rg-monitoring-demo` |
| VNet + Subnet | `vnet-monitoring-demo`, `/23` delegated to `Microsoft.App/environments` |
| ACR | Basic, admin enabled |
| Log Analytics Workspace | 30-day retention |
| Application Insights | Workspace-based, linked to LAW |
| Container Apps Environment | Zone-redundant, VNet-integrated, `prevent_destroy=true`, `ignore_changes=[infrastructure_subnet_id]` |
| Container App | 0.5 vCPU / 1Gi, min 2 / max 5 replicas, HTTP scaling, liveness + readiness probes on `/health:8000` |
| Metric Alerts | CPU Maximum >400M nanocores, Memory Average >858MB, HTTP 5xx Count >10, RestartCount Total >0 |
| Activity Log Alerts | Container App deleted, Container Apps Environment deleted |
| Availability Web Test | Pings `/health` from 5 Azure regions every 5 min; alert fires when < 100% pass |
| Azure Monitor Workbook | `dashboard.tf` — resource-picker-based, 6 metric charts (CPU, Memory, Replicas, Restarts, HTTP failures, Availability) |

# Status

## Done
- FastAPI app with all endpoints
- App Insights telemetry (OpenTelemetry + explicit FastAPIInstrumentor)
- Autoscaling tested with `hey`
- HTTP 5xx alert validated
- HA: zone redundancy + VNet + min_replicas=2 + health probes — applied and verified
- Environment protected with `prevent_destroy=true` lifecycle; drift fixed (`ignore_changes` includes `infrastructure_resource_group_name` + `workload_profile`)
- Backup and recovery: Activity Log alerts for deletion detection + full recovery runbook in docs
- Availability web test (5 regions) + availability metric alert (severity 0)
- Azure Monitor Workbook deployed (`terraform/dashboard.tf`)
- Operations user guide created (`docs/operations.md`) — generic, Confluence-ready

## Pending
- Redeploy app image with memory page-touch fix, then re-test CPU, memory, and restart alerts
- Fix Workbook resource picker dropdowns (empty on load — user to recreate in portal and export JSON)
