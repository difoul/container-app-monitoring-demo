# Summary

A production-grade Python sample application deployed to Azure Container App to demonstrate and validate Azure monitoring, alerting, high availability, and backup/recovery capabilities.

# Goal

Provide a reference example for users on how to operate Azure Container Apps in production.

# Output

A Docker image deployed to Azure Container App via Terraform, covering:
- Monitoring and observability (App Insights + Log Analytics via AMPLS hybrid mode)
- Alerting (metric-based alerts + activity log alerts via Azure Monitor)
- High availability (zone redundancy, min replicas, health probes)
- Backup and recovery (deletion alerts + recovery runbook)
- Disaster recovery (multi-region design + AFD health probe simulation)

# Features

The application exposes public endpoints to generate load, errors, latency, and scaling events.

## Endpoints
- `POST /load/cpu` — burns CPU at a given intensity for a given duration
- `POST /load/memory` — allocates and touches memory (force-writes every page to commit working set)
- `GET /errors/{code}` — raises HTTPException (tracked by App Insights as failed requests)
- `GET /latency?ms=N` — simulates response latency
- `GET /burst?requests=N` — fires concurrent self-requests with semaphore(50)
- `GET /health` — health check; returns 503 when `dr._degraded=True` (triggers AFD failover)
- `GET /dr/region` — returns `REGION_NAME` + `INSTANCE_ROLE` env vars (identifies active region)
- `GET /dr/status` — returns current degraded state and region info
- `POST /dr/degrade` — sets `_degraded=True`; causes /health to return 503
- `POST /dr/recover` — clears `_degraded`; restores /health to 200

# Infrastructure (Terraform)

| Resource | Notes |
|---|---|
| Resource Group | `rg-monitoring-demo` |
| VNet | `vnet-monitoring-demo`, `10.0.0.0/16` |
| Subnet — Container Apps | `snet-container-apps`, `10.0.0.0/23`, delegated to `Microsoft.App/environments` |
| Subnet — Private Endpoints | `snet-private-endpoints`, `10.0.2.0/27`, for AMPLS private endpoint NIC |
| ACR | Basic, admin enabled (acceptable for demo; use managed identity in prod) |
| Log Analytics Workspace | Via `law-secure` module, hybrid mode — 30-day retention, private ingestion via AMPLS, public query |
| AMPLS | Azure Monitor Private Link Scope — blocks public data ingestion |
| Private Endpoint | Connects VNet to AMPLS on `snet-private-endpoints` |
| Private DNS Zones (×5) | `*.oms`, `*.ods`, `*.agentsvc`, `*.monitor`, `*.blob` — linked to VNet |
| Application Insights | Workspace-based, linked to LAW via `module.law.workspace_id` |
| Container Apps Environment | Zone-redundant, VNet-integrated, `logs_destination = "azure-monitor"`, `ignore_changes=[infrastructure_resource_group_name, workload_profile]` |
| Diagnostic Setting — Env | `allLogs` + `AllMetrics` → LAW, `Dedicated` mode (resource-specific tables) |
| Diagnostic Setting — App | `AllMetrics` only → LAW, `Dedicated` mode (log categories not supported at app level) |
| Container App | 0.5 vCPU / 1Gi, min 2 / max 5 replicas, HTTP scaling, liveness + readiness probes on `/health:8000` |
| Metric Alerts | CPU Maximum >400M nanocores, Memory Average >858MB, HTTP 5xx Count >10, RestartCount Total >0 |
| Activity Log Alerts | Container App deleted, Container Apps Environment deleted |
| Availability Web Test | Pings `/health` from 5 Azure regions every 5 min |
| Availability Alert | Uses `application_insights_web_test_location_availability_criteria`, `failed_location_count = 1` |
| Azure Monitor Workbook | `dashboard.tf` — resource-picker-based, 6 metric charts (CPU, Memory, Replicas, Restarts, HTTP failures, Availability), UUID from `random_uuid` |
| Common Tags | `environment=demo`, `project=container-app-monitoring`, `managed-by=terraform` on all resources |

# Status

## Done
- FastAPI app with all endpoints (load, errors, latency, scaling, DR)
- App Insights telemetry (OpenTelemetry + explicit FastAPIInstrumentor)
- Terraform review: tags on all resources, random_uuid for workbook, availability alert uses web-test criteria, `logs_destination` explicit, `infrastructure_subnet_id` removed from `ignore_changes`
- Switched from direct `log-analytics` to `azure-monitor` + diagnostic settings (Dedicated mode)
- `law-secure` module integrated in hybrid mode (AMPLS + private endpoint + 5 DNS zones + self-audit diagnostics)
- Infrastructure applied and verified — app running at `gbe123456789.salmonsky-9bbde29b.swedencentral.azurecontainerapps.io`
- Image pushed to ACR (`acrmonitoringdemo.azurecr.io/monitoring-demo:latest`), health check returns `{"status":"ok"}`
- `docs/operations.md` updated to reflect: law-secure module, azure-monitor diagnostic settings, web-test availability alert criteria

## In progress
Nothing — infrastructure is deployed, app is running, tests can be executed.

## Pending
- Run load/alert validation tests against the deployed app
- Terraform for second region + Azure Front Door (user to decide)
- Re-enable `prevent_destroy=true` on Container Apps Environment when moving to production

## Known issues / decisions
- `prevent_destroy=true` commented out on Container Apps Environment — re-enable before production deployment
- Container app deployed as `gbe123456789` (Azure-generated name) — `var.container_app_name = "monitoring-demo"` was not used; check tfvars
- `ME_cae-monitoring-demo_rg-monitoring-demo_swedencentral` resource group is Azure-managed (expected) — contains the load balancer and public IP for external ingress; do not delete
- `logs_destination` on Container Apps Environment is a creation-time setting — changing it requires destroy + recreate
- `log_analytics_workspace_id` on the environment is incompatible with `logs_destination = "azure-monitor"` — must not be set together
- Log categories (`ContainerAppConsoleLogs`, `ContainerAppSystemLogs`) are only configurable at environment level, not container app level
- Workbook resource pickers require `queryType=1`, `resourceType="microsoft.resourcegraph/resources"`, `crossComponentResources=["{Subscription}"]`, query starting with `where type == '...'`
- `FastAPIInstrumentor.instrument_app(app)` must be called explicitly after `app = FastAPI()` — `configure_azure_monitor()` alone does not attach to FastAPI
- DR endpoints require `REGION_NAME` and `INSTANCE_ROLE` env vars per deployment

## Last updated
2026-04-08
