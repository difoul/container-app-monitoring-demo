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
| VNet + Subnet | `vnet-monitoring-demo`, `/23` delegated to `Microsoft.App/environments` |
| ACR | Basic, admin enabled |
| Log Analytics Workspace | 30-day retention |
| Application Insights | Workspace-based, linked to LAW |
| Container Apps Environment | Zone-redundant, VNet-integrated, `prevent_destroy` commented out, `ignore_changes=[infrastructure_subnet_id, infrastructure_resource_group_name, workload_profile]` |
| Container App | 0.5 vCPU / 1Gi, min 2 / max 5 replicas, HTTP scaling, liveness + readiness probes on `/health:8000` |
| Metric Alerts | CPU Maximum >400M nanocores, Memory Average >858MB, HTTP 5xx Count >10, RestartCount Total >0 |
| Activity Log Alerts | Container App deleted, Container Apps Environment deleted |
| Availability Web Test | Pings `/health` from 5 Azure regions every 5 min; alert fires when < 100% pass |
| Azure Monitor Workbook | `dashboard.tf` — resource-picker-based, 6 metric charts (CPU, Memory, Replicas, Restarts, HTTP failures, Availability) |

# Status

## Done
- FastAPI app with all endpoints (load, errors, latency, scaling, DR)
- App Insights telemetry (OpenTelemetry + explicit FastAPIInstrumentor)
- Autoscaling tested with `hey`
- HTTP 5xx alert validated
- HA: zone redundancy + VNet + min_replicas=2 + health probes — applied and verified
- Environment: `prevent_destroy` commented out (was blocking `terraform destroy`); `ignore_changes` on subnet/RG/workload_profile prevents drift
- Backup and recovery: Activity Log alerts for deletion detection + full recovery runbook in docs
- Availability web test (5 regions) + availability metric alert (severity 0)
- Azure Monitor Workbook deployed (`terraform/dashboard.tf`)
- Operations user guide created (`docs/operations.md`) — generic, Confluence-ready
- DR simulation feature: `app/routers/dr.py` + updated `app/main.py` + DR section in `docs/operations.md`
- Skills converted to SKILL.md format: `~/.claude/plugins/marketplaces/local-skills/skills/az-ops-plan/` and `az-ops-build/` (updated with azurerm v4, workload profiles v2, managed identity for ACR, Key Vault secret refs, KEDA managed identity, Grafana/AMW options)

## Uncommitted changes (need commit)
- `app/main.py` — dr router import + /health 503 logic (staged)
- `app/routers/dr.py` — DR simulation endpoints (untracked)
- `docs/operations.md` — DR section added (unstaged)

## Pending
- Commit DR feature changes
- Terraform for second region + Azure Front Door (user to decide)
- Re-enable `prevent_destroy=true` on Container Apps Environment when redeploying to production

## Known issues / decisions
- `prevent_destroy=true` commented out on Container Apps Environment — was preventing `terraform destroy` during testing; re-enable before production deployment
- Workbook resource pickers require `queryType=1`, `resourceType="microsoft.resourcegraph/resources"`, `crossComponentResources=["{Subscription}"]`, query starting with `where type == '...'` — `typeSettings.resourceTypeFilter` alone does NOT populate dropdowns
- Container Apps Environment LAW linkage cannot be changed after creation
- `FastAPIInstrumentor.instrument_app(app)` must be called explicitly after `app = FastAPI()` — `configure_azure_monitor()` auto-instrumentation alone does not attach to FastAPI
- DR endpoints require `REGION_NAME` and `INSTANCE_ROLE` env vars per deployment
- Infrastructure was destroyed 2026-03-27 after testing; Terraform state is clean

## Last updated
2026-04-02
