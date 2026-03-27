# Operating an Azure Container App — User Guide

This guide covers how to monitor, alert, scale, and recover an Azure Container App in production. It is written for both developers and operators who need to understand the day-to-day operation of a containerized workload on Azure.

---

## Stack Overview

| Component | Service |
|---|---|
| Application runtime | Azure Container Apps |
| Metrics & logs | Azure Monitor + Log Analytics Workspace |
| Application telemetry | Application Insights (OpenTelemetry) |
| Alerting | Azure Monitor Metric Alerts + Activity Log Alerts |
| Availability monitoring | Application Insights Standard Web Test |
| Visualization | Azure Monitor Workbook |

---

## 1. Monitoring

### Which metrics to watch

Azure Container Apps expose infrastructure metrics. Application Insights collects application-level telemetry. Use both layers together for full observability.

| Metric | Namespace | What it measures | Recommended aggregation |
|---|---|---|---|
| `UsageNanoCores` | `Microsoft.App/containerApps` | CPU consumption per replica | **Maximum** — Average masks bursts |
| `WorkingSetBytes` | `Microsoft.App/containerApps` | Physical memory in use | **Average** |
| `Replicas` | `Microsoft.App/containerApps` | Number of running replicas | Average |
| `RestartCount` | `Microsoft.App/containerApps` | Container restarts (OOM, crash, probe failure) | **Total** |
| `requests/failed` | `microsoft.insights/components` | HTTP requests tracked as failures by App Insights | Count |
| `availabilityResults/availabilityPercentage` | `microsoft.insights/components` | % of availability test probes passing | Average |

> **Note on `WorkingSetBytes`:** This metric only reflects memory that has been written to (committed working set). Allocated but unwritten memory does not appear — this is expected behavior.

> **Note on CPU units:** `UsageNanoCores` is expressed in nanocores. 1 vCPU = 1,000,000,000 nanocores. Set your alert threshold accordingly (e.g., 80% of 0.5 vCPU = 400,000,000 nanocores).

---

### Where to look in the portal

| What you want to see | Where to find it |
|---|---|
| Live request rate and active failures | App Insights → **Live Metrics** |
| Failed requests with stack traces | App Insights → **Failures** |
| Individual request traces | App Insights → **Transaction search** |
| CPU and memory over time | Container App → **Metrics** |
| Replica count over time | Container App → **Metrics → Replicas** |
| Container stdout/stderr | Container App → **Log stream** |
| Availability test results per region | App Insights → **Availability** |
| All metrics in one view | Azure Monitor → **Workbooks** |
| Active and fired alerts | Azure Monitor → **Alerts** |

---

### How to query logs with KQL

Open **Log Analytics workspace → Logs** and use the following queries to investigate issues.

**Failed requests — last 30 minutes**
```kusto
requests
| where timestamp > ago(30m) and success == false
| project timestamp, name, resultCode, duration
| order by timestamp desc
```

**Request rate over time**
```kusto
requests
| where timestamp > ago(1h)
| summarize count() by bin(timestamp, 1m)
| render timechart
```

**Request rate by HTTP status code**
```kusto
requests
| where timestamp > ago(30m)
| summarize count() by bin(timestamp, 1m), resultCode
| render timechart
```

**Container restarts and OOM kills**
```kusto
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(1h)
| where Reason_s in ("BackOff", "OOMKilling")
| project TimeGenerated, ContainerAppName_s, Reason_s, Log_s
| order by TimeGenerated desc
```

---

## 2. Alerting

### What alerts to configure

Set up the following alerts to cover the most common failure modes. Thresholds in the table below are examples — adjust them based on your container's allocated CPU and memory.

| Alert | Source | Metric | Example condition | Severity |
|---|---|---|---|---|
| Availability down | App Insights | `availabilityResults/availabilityPercentage` Average | < 100% | 0 — Critical |
| HTTP 5xx spike | App Insights | `requests/failed` Count | > 10 in 5 min | 1 — Error |
| Container restarting | Container App | `RestartCount` Total | > 0 | 1 — Error |
| CPU high | Container App | `UsageNanoCores` Maximum | > 80% of allocation | 2 — Warning |
| Memory high | Container App | `WorkingSetBytes` Average | > 80% of allocation | 2 — Warning |
| App deleted | Activity Log | `Microsoft.App/containerApps/delete` | Any deletion | — |
| Environment deleted | Activity Log | `Microsoft.App/managedEnvironments/delete` | Any deletion | — |

> **Threshold guidance:** For a container with 0.5 vCPU / 1Gi allocated, 80% thresholds are 400,000,000 nanocores and 858,993,459 bytes. Scale proportionally for different allocations.

---

### How to configure alerts

All metric alerts should share the same evaluation settings for consistent behavior:

| Setting | Recommended value |
|---|---|
| Evaluation frequency | Every 1 minute |
| Aggregation window | 5 minutes |
| Notification channel | Email via action group |

**Key considerations:**
- **Activity Log alerts** (app/environment deleted) must be scoped to the **resource group**, not the individual resource, and require `location = "Global"`.
- **Availability alerts** must be scoped to the **Application Insights resource** (not the web test), using namespace `microsoft.insights/components`.
- **Metric alerts** on Container App metrics must be scoped to the **Container App resource**.

---

### How to respond to alerts

When an alert fires, follow the first steps below to triage quickly.

| Alert | First steps |
|---|---|
| **Availability** | `curl https://<app_fqdn>/health` — if no response, check Log stream; if the app is gone, follow the recovery runbook |
| **HTTP 5xx** | App Insights → **Failures** → inspect stack traces and request details |
| **Container restarts** | Log Analytics → query `ContainerAppSystemLogs_CL` for OOM or crash reason |
| **CPU high** | Check for runaway threads or unexpected load; review App Insights Live Metrics for request rate |
| **Memory high** | Check for memory leaks; verify no load test is running; review `WorkingSetBytes` trend |
| **App/Env deleted** | Follow the recovery runbook — see section 4 |

---

## 3. High Availability

### How to configure HA

The following settings give you zone-redundant, fault-tolerant deployment with autoscaling.

| Setting | Recommended value | Purpose |
|---|---|---|
| Zone redundancy | Enabled | Replicas distributed across availability zones |
| VNet integration | Dedicated /23 subnet | Required for zone redundancy; network isolation |
| Min replicas | 2 | Survives a single zone failure without downtime |
| Max replicas | Set based on cost cap | Limits autoscaling spend |
| Scaling rule | HTTP — concurrent requests | Scales on real ingress traffic only |

> **Important:** Zone redundancy cannot be enabled or disabled after the environment is created. It must be set at creation time and requires a dedicated subnet.

---

### How health probes work

Configure both probes to target your health endpoint (e.g., `GET /health`). The container must return HTTP 200 for the probe to pass.

| Probe | Purpose | Typical check interval | Failure threshold | Action on failure |
|---|---|---|---|---|
| **Liveness** | Detect hung or deadlocked containers | 10 seconds | 3 consecutive failures | Container is restarted |
| **Readiness** | Gate traffic to healthy replicas | 10 seconds | 3 consecutive failures | Replica removed from load balancer |

Start with an `initial_delay` of 5–10 seconds to give the container time to start before probes begin.

---

### How autoscaling works

- **Scale-out** is triggered when concurrent HTTP requests at Azure ingress exceed the configured threshold.
- **Scale-in** happens automatically after ~5 minutes of low traffic, down to `min_replicas`.
- Self-requests made by the container to itself bypass Azure ingress and **do not** count toward the scaling metric. Use an external load generator (e.g., `hey`, `k6`) to test scale-out.

---

## 4. Backup and Recovery

### What the backup strategy is

Azure Container Apps are stateless infrastructure — the only "backup" needed is the code that provisions them. If your infrastructure is declared in Terraform (or equivalent IaC), you can recreate the full stack from code at any time.

The container image is stored separately in Azure Container Registry (ACR), which persists independently of the app or environment.

There is no stateful application data to back up in a typical Container App deployment. If your app uses a database or storage account, those resources require their own backup strategy.

---

### How deletion is detected

Activity Log alerts fire within ~1 minute of a deletion event, notifying the on-call team via email before they would otherwise know.

| Alert | Trigger | Detection time |
|---|---|---|
| `alert-container-app-deleted` | `Microsoft.App/containerApps/delete` | ~1 minute |
| `alert-environment-deleted` | `Microsoft.App/managedEnvironments/delete` | ~1 minute |

---

### How to recover — step by step

#### Scenario A — Container App deleted (environment still exists)

**Estimated recovery time: ~3 minutes**

The environment, networking, ACR image, and monitoring are intact. Only the app needs to be recreated.

```bash
cd terraform
terraform plan   # confirm only the app resource is missing
terraform apply
```

Verify recovery:
```bash
curl https://<app_fqdn>/health
```

---

#### Scenario B — Container Apps Environment deleted (app also gone)

**Estimated recovery time: ~10–15 minutes**

Environment provisioning takes several minutes. Networking, ACR, and monitoring are intact and do not need to be recreated.

```bash
cd terraform
terraform plan   # review all resources to be recreated
terraform apply
```

> If you have `prevent_destroy = true` on the environment, this protects against accidental `terraform destroy` but does not protect against manual deletions from the portal or CLI.

---

#### Scenario C — Bad image deployed (rollback needed)

```bash
# List available image tags in ACR
az acr repository show-tags \
  --name <acr_name> \
  --repository <image_name> \
  --orderby time_desc \
  --output table

# Roll back to a known-good tag
az containerapp update \
  --name <app_name> \
  --resource-group <resource_group> \
  --image <acr_login_server>/<image_name>:<previous_tag>
```

After rolling back, update the image tag in your Terraform variables file so the next `terraform apply` does not overwrite the rollback.

---

## 5. Quick Reference Commands

```bash
# Get the app's public URL (FQDN)
az containerapp show \
  --name <app_name> \
  --resource-group <resource_group> \
  --query properties.configuration.ingress.fqdn -o tsv

# List running replicas and their state
az containerapp replica list \
  --name <app_name> \
  --resource-group <resource_group> \
  --query "[].{name:name, state:properties.runningState}" \
  -o table

# Stream live container logs
az containerapp logs show \
  --name <app_name> \
  --resource-group <resource_group> \
  --follow

# Deploy a new image revision
TAG=$(date +%s)
az containerapp update \
  --name <app_name> \
  --resource-group <resource_group> \
  --image <acr_login_server>/<image_name>:$TAG

# Roll back to a previous image
az containerapp update \
  --name <app_name> \
  --resource-group <resource_group> \
  --image <acr_login_server>/<image_name>:<previous_tag>

# List ACR image tags (newest first)
az acr repository show-tags \
  --name <acr_name> \
  --repository <image_name> \
  --orderby time_desc \
  --output table
```
