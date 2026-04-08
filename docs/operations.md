# Operating an Azure Container App — User Guide

This guide covers how to monitor, alert, scale, and recover an Azure Container App in production. It is written for both developers and operators who need to understand the day-to-day operation of a containerized workload on Azure.

---

## Stack Overview

| Component | Service |
| --- | --- |
| Application runtime | Azure Container Apps |
| Metrics & logs | Azure Monitor + Log Analytics Workspace |
| Application telemetry | Application Insights (OpenTelemetry) |
| Alerting | Azure Monitor Metric Alerts + Activity Log Alerts |
| Availability monitoring | Application Insights Standard Web Test |
| Visualization | Azure Monitor Workbook |
| Multi-region routing & failover | Azure Front Door Standard |

---

## Before You Start

Before any monitoring, alerting, or log querying works, you must provision the required resources and wire up the Container App to send telemetry to them.

### Required resources

| Resource | Purpose | Terraform type |
| --- | --- | --- |
| Log Analytics Workspace | Receives container stdout/stderr and system logs; query target for KQL | `azurerm_log_analytics_workspace` (via `law-secure` module) |
| Application Insights | Collects application-level telemetry (requests, exceptions, traces, dependencies) | `azurerm_application_insights` |
| AMPLS + Private Endpoint | Secures log ingestion — only traffic from within the VNet reaches the workspace | provisioned by `law-secure` module |
| Private DNS Zones (×5) | Correct DNS resolution for `*.oms`, `*.ods`, `*.agentsvc`, `*.monitor`, `*.blob` from within the VNet | provisioned by `law-secure` module |

> **Important:** Application Insights must be **workspace-based** — link it to the Log Analytics Workspace at creation time via the `workspace_id` property. Classic (non-workspace) Application Insights is deprecated and cannot be linked.

> **Production recommendation:** Use the `law-secure` module in **hybrid** mode. This provisions an Azure Monitor Private Link Scope (AMPLS) that blocks public data ingestion while keeping query access public — analysts can use the Azure portal without VPN. Direct `log-analytics` destination mode does not support Private Link.

```hcl
# Dedicated subnet for AMPLS private endpoint — cannot share the Container Apps subnet
resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/27"]
}

# law-secure module: LAW + AMPLS + private endpoint + 5 private DNS zones + self-audit diagnostics
module "law" {
  source = "./modules/law-secure"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  workspace_name      = "law-<prefix>"
  security_mode       = "hybrid"   # private ingestion, public query

  retention_in_days = 30
  daily_quota_gb    = -1           # unlimited; set a value in production to cap costs

  subnet_id          = azurerm_subnet.private_endpoints.id
  virtual_network_id = azurerm_virtual_network.main.id

  enable_audit_diagnostics = true  # captures LAQueryLogs + SummaryLogs for compliance

  tags = local.common_tags
}

resource "azurerm_application_insights" "main" {
  name                = "appi-<prefix>"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  workspace_id        = module.law.workspace_id
  application_type    = "web"
  tags                = local.common_tags
}
```

---

### Required service configuration

#### Container Apps Environment — log routing via Azure Monitor + Diagnostic Settings

Set `logs_destination = "azure-monitor"` on the environment and create explicit diagnostic settings to route logs to the workspace. This is the production-recommended approach because it supports Private Link, allows up to 5 destinations (Log Analytics, Event Hub, storage, partner solutions), and uses resource-specific tables (`Dedicated` mode) instead of the legacy `AzureDiagnostics` table.

> **Important:** `logs_destination` can only be set at environment creation time — changing it later requires destroying and recreating the environment.

> **Do not** use `log_analytics_workspace_id` on the environment when `logs_destination = "azure-monitor"` — the two are mutually exclusive per the provider.

```hcl
resource "azurerm_container_app_environment" "main" {
  name                     = "cae-<prefix>"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  logs_destination         = "azure-monitor"
  infrastructure_subnet_id = azurerm_subnet.container_apps.id
  zone_redundancy_enabled  = true
  tags                     = local.common_tags

  lifecycle {
    ignore_changes = [
      infrastructure_resource_group_name,
      workload_profile,
    ]
  }
}

# Environment level: console logs + system logs + metrics → resource-specific tables
resource "azurerm_monitor_diagnostic_setting" "container_app_env" {
  name                           = "diag-cae-<prefix>"
  target_resource_id             = azurerm_container_app_environment.main.id
  log_analytics_workspace_id     = module.law.workspace_id
  log_analytics_destination_type = "Dedicated"   # resource-specific tables, not AzureDiagnostics

  enabled_log {
    category_group = "allLogs"   # ContainerAppConsoleLogs + ContainerAppSystemLogs
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# Container app level: metrics only (log categories are not supported at app level)
resource "azurerm_monitor_diagnostic_setting" "container_app" {
  name                           = "diag-ca-<prefix>"
  target_resource_id             = azurerm_container_app.main.id
  log_analytics_workspace_id     = module.law.workspace_id
  log_analytics_destination_type = "Dedicated"

  enabled_metric {
    category = "AllMetrics"
  }
}
```

> **Note:** Log categories (`ContainerAppConsoleLogs`, `ContainerAppSystemLogs`) are only configurable at the **environment** level. The container app–level diagnostic setting supports **metrics only**. Up to 5 diagnostic settings can be created per resource to fan out to additional destinations.

#### Container App — Application Insights connection string

To get application-level telemetry (requests, exceptions, traces), your container must be instrumented with the Azure Monitor OpenTelemetry SDK **and** receive the Application Insights connection string as an environment variable.

Pass it via a secret and reference it as an environment variable in the container definition:

```hcl
resource "azurerm_container_app" "main" {
  # ...
  secret {
    name  = "appinsights-connection-string"
    value = azurerm_application_insights.main.connection_string
  }

  template {
    container {
      # ...
      env {
        name        = "APPLICATIONINSIGHTS_CONNECTION_STRING"
        secret_name = "appinsights-connection-string"
      }
    }
  }
}
```

Your application code must then initialise the SDK on startup:

```python
# Python (azure-monitor-opentelemetry)
from azure.monitor.opentelemetry import configure_azure_monitor
configure_azure_monitor()  # reads APPLICATIONINSIGHTS_CONNECTION_STRING from env
```

```javascript
// Node.js (@azure/monitor-opentelemetry)
const { useAzureMonitor } = require("@azure/monitor-opentelemetry");
useAzureMonitor(); // reads APPLICATIONINSIGHTS_CONNECTION_STRING from env
```

> **Note:** Without this configuration, `requests/failed`, `availabilityResults/availabilityPercentage`, and all App Insights-based alerts will have no data.

---

## 1. Monitoring

### Which metrics to watch

Azure Container Apps expose infrastructure metrics. Application Insights collects application-level telemetry. Use both layers together for full observability.

| Metric | Namespace | What it measures | Recommended aggregation |
| --- | --- | --- | --- |
| `UsageNanoCores` | `Microsoft.App/containerApps` | CPU consumption per replica | **Maximum** — Average masks bursts |
| `WorkingSetBytes` | `Microsoft.App/containerApps` | Physical memory in use | **Average** |
| `Replicas` | `Microsoft.App/containerApps` | Number of running replicas | Average |
| `RestartCount` | `Microsoft.App/containerApps` | Container restarts (OOM, crash, probe failure) | **Total** |
| `requests/failed` | `microsoft.insights/components` | HTTP requests tracked as failures by App Insights | Count |
| `availabilityResults/availabilityPercentage` | `microsoft.insights/components` | % of availability test probes passing | Average |

> **Note for event-driven apps:** `requests/failed` and `availabilityResults/availabilityPercentage` are only meaningful for HTTP-facing apps. For event-driven consumers, focus on `RestartCount`, `WorkingSetBytes`, and `UsageNanoCores` from the Container App, and add service-specific metrics from your broker (e.g., Service Bus dead-letter count, Event Hubs consumer lag) via separate alerts.

> **Note on `WorkingSetBytes`:** This metric only reflects memory that has been written to (committed working set). Allocated but unwritten memory does not appear — this is expected behavior.

> **Note on CPU units:** `UsageNanoCores` is expressed in nanocores. 1 vCPU = 1,000,000,000 nanocores. Set your alert threshold accordingly (e.g., 80% of 0.5 vCPU = 400,000,000 nanocores).

---

### Where to look in the portal

| What you want to see | Where to find it |
| --- | --- |
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

#### Failed requests — last 30 minutes

```kusto
requests
| where timestamp > ago(30m) and success == false
| project timestamp, name, resultCode, duration
| order by timestamp desc
```

#### Request rate over time

```kusto
requests
| where timestamp > ago(1h)
| summarize count() by bin(timestamp, 1m)
| render timechart
```

#### Request rate by HTTP status code

```kusto
requests
| where timestamp > ago(30m)
| summarize count() by bin(timestamp, 1m), resultCode
| render timechart
```

#### Container restarts and OOM kills

```kusto
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(1h)
| where Reason_s in ("BackOff", "OOMKilling")
| project TimeGenerated, ContainerAppName_s, Reason_s, Log_s
| order by TimeGenerated desc
```

---

## 2. Dashboard

The Azure Monitor Workbook provides a single-pane view of all key infrastructure and application metrics without writing any queries. Open it at **Azure Monitor → Workbooks → "\<prefix\> Monitoring"**.

---

### How to open the dashboard

1. Go to **Azure Portal → Monitor → Workbooks**
2. Select the workbook named **"\<prefix\> Monitoring"**
3. Use the parameter bar at the top to select your **Subscription**, **Container App**, **Application Insights** resource, and **Time Range**
4. All charts update automatically based on your selections

---

### What the dashboard shows

| Section | Chart | Metric | Aggregation |
| --- | --- | --- | --- |
| Infrastructure | CPU Usage | `UsageNanoCores` | Maximum |
| Infrastructure | Memory Usage | `WorkingSetBytes` | Average |
| Infrastructure | Replica Count | `Replicas` | Average |
| Infrastructure | Container Restarts | `RestartCount` | Total |
| Application | HTTP Failed Requests | `requests/failed` | Count |
| Application | Availability | `availabilityResults/availabilityPercentage` | Average |

---

### How to provision the dashboard with Terraform

```hcl
resource "azurerm_application_insights_workbook" "main" {
  name                = "<valid-uuid>"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  display_name        = "<prefix> Monitoring"
  source_id           = "azure monitor"

  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [
      {
        type = 9
        content = {
          version                 = "KqlParameterItem/1.0"
          crossComponentResources = ["{Subscription}"]
          parameters = [
            {
              id         = "p0-subscription"
              version    = "KqlParameterItem/1.0"
              name       = "Subscription"
              label      = "Subscription"
              type       = 6
              isRequired = true
              typeSettings = {
                additionalSubscriptionIds = []
                includeAll               = false
              }
            },
            {
              id                      = "p1-container-app"
              version                 = "KqlParameterItem/1.0"
              name                    = "ContainerApp"
              label                   = "Container App"
              type                    = 5
              isRequired              = true
              multiSelect             = false
              query                   = "where type == 'microsoft.app/containerapps'\n| project id, name"
              crossComponentResources = ["{Subscription}"]
              queryType               = 1
              resourceType            = "microsoft.resourcegraph/resources"
              typeSettings = {
                additionalResourceOptions = []
                showDefault               = false
              }
            },
            {
              id                      = "p2-app-insights"
              version                 = "KqlParameterItem/1.0"
              name                    = "AppInsights"
              label                   = "Application Insights"
              type                    = 5
              isRequired              = true
              multiSelect             = false
              query                   = "where type == 'microsoft.insights/components'\n| project id, name"
              crossComponentResources = ["{Subscription}"]
              queryType               = 1
              resourceType            = "microsoft.resourcegraph/resources"
              typeSettings = {
                additionalResourceOptions = []
                showDefault               = false
              }
            },
            {
              id      = "p3-time-range"
              version = "KqlParameterItem/1.0"
              name    = "TimeRange"
              label   = "Time Range"
              type    = 4
              value   = { durationMs = 3600000 }
            }
          ]
        }
        name = "parameters"
      }
    ]
    "$schema" = "https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json"
  })
}
```

> **Resource picker gotchas:** Each resource picker parameter (type 5) requires `queryType = 1`, `resourceType = "microsoft.resourcegraph/resources"`, and `crossComponentResources` set at the **parameter level**. The query must start with `where type == '...'` directly — do not prefix with `resources |`. Using `typeSettings.resourceTypeFilter` alone does not populate the dropdown.

---

## 3. Alerting

### What alerts to configure

Set up the following alerts to cover the most common failure modes. Thresholds in the table below are examples — adjust them based on your container's allocated CPU and memory.

| Alert | Source | Metric | Example condition | Severity |
| --- | --- | --- | --- | --- |
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
| --- | --- |
| Evaluation frequency | Every 1 minute |
| Aggregation window | 5 minutes |
| Notification channel | Email via action group |

#### Key considerations

- **Activity Log alerts** (app/environment deleted) must be scoped to the **resource group**, not the individual resource, and require `location = "Global"`.
- **Availability alerts** must be scoped to the **Application Insights resource** (not the web test), using namespace `microsoft.insights/components`.
- **Metric alerts** on Container App metrics must be scoped to the **Container App resource**.

---

### Terraform examples

#### Action group (shared by all metric alerts)

> **Note:** Action groups support other notification channels beyond email — including SMS, voice call, Azure app push notification, webhook, Azure Function, Logic App, and ITSM connectors (e.g., ServiceNow, PagerDuty). Add the corresponding receiver block (e.g., `sms_receiver`, `webhook_receiver`, `azure_function_receiver`) alongside or instead of `email_receiver` in the same action group.

```hcl
resource "azurerm_monitor_action_group" "email" {
  name                = "ag-<prefix>-email"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "<prefix>"

  email_receiver {
    name          = "oncall"
    email_address = var.alert_email
  }
}
```

#### Availability alert (web-test–specific criteria)

Use `application_insights_web_test_location_availability_criteria` instead of a generic `criteria` block. This is the correct resource type for web test alerts — it lets you alert on a failed location count rather than a percentage, and requires both the App Insights resource and the web test in `scopes`.

```hcl
resource "azurerm_monitor_metric_alert" "availability" {
  name                = "alert-availability-down"
  resource_group_name = azurerm_resource_group.main.name
  scopes = [
    azurerm_application_insights.main.id,
    azurerm_application_insights_standard_web_test.health.id,
  ]
  description = "Availability check failing from at least one region"
  severity    = 0
  frequency   = "PT1M"
  window_size = "PT5M"
  tags        = local.common_tags

  application_insights_web_test_location_availability_criteria {
    web_test_id           = azurerm_application_insights_standard_web_test.health.id
    component_id          = azurerm_application_insights.main.id
    failed_location_count = 1
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}
```

> **Note:** Using a generic `criteria` block with `availabilityResults/availabilityPercentage` works, but `application_insights_web_test_location_availability_criteria` is the semantically correct approach for web test alerts. It expresses intent clearly and supports `failed_location_count` for region-level precision.

#### HTTP 5xx spike alert

```hcl
resource "azurerm_monitor_metric_alert" "http_5xx" {
  name                = "alert-http-5xx"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_application_insights.main.id]
  description         = "More than 10 failed requests in 5 minutes"
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "microsoft.insights/components"
    metric_name      = "requests/failed"
    aggregation      = "Count"
    operator         = "GreaterThan"
    threshold        = 10
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}
```

#### Container restart alert

```hcl
resource "azurerm_monitor_metric_alert" "restarts" {
  name                = "alert-container-restarts"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_container_app.main.id]
  description         = "Container has restarted at least once"
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "RestartCount"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}
```

#### CPU high alert

```hcl
# Threshold: 80% of 0.5 vCPU = 400,000,000 nanocores. Scale proportionally.
resource "azurerm_monitor_metric_alert" "cpu_high" {
  name                = "alert-cpu-high"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_container_app.main.id]
  description         = "CPU exceeded 80% of allocation"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "UsageNanoCores"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = 400000000
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}
```

#### Memory high alert

```hcl
# Threshold: 80% of 1Gi = 858,993,459 bytes. Scale proportionally.
resource "azurerm_monitor_metric_alert" "memory_high" {
  name                = "alert-memory-high"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_container_app.main.id]
  description         = "Memory exceeded 80% of allocation"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "WorkingSetBytes"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 858993459
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}
```

#### Activity log alerts (deletion events)

```hcl
# Both alerts must be scoped to the resource group (not individual resources)
# and require location = "Global" — Activity Log alerts are not regional.

resource "azurerm_monitor_activity_log_alert" "app_deleted" {
  name                = "alert-container-app-deleted"
  resource_group_name = azurerm_resource_group.main.name
  location            = "Global"
  scopes              = [azurerm_resource_group.main.id]
  description         = "Container App was deleted"

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.App/containerApps/delete"
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

resource "azurerm_monitor_activity_log_alert" "env_deleted" {
  name                = "alert-environment-deleted"
  resource_group_name = azurerm_resource_group.main.name
  location            = "Global"
  scopes              = [azurerm_resource_group.main.id]
  description         = "Container Apps Environment was deleted"

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.App/managedEnvironments/delete"
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}
```

---

### How to respond to alerts

When an alert fires, follow the first steps below to triage quickly.

| Alert | First steps |
| --- | --- |
| **Availability** | `curl https://<app_fqdn>/health` — if no response, check Log stream; if the app is gone, follow the recovery runbook |
| **HTTP 5xx** | App Insights → **Failures** → inspect stack traces and request details |
| **Container restarts** | Log Analytics → query `ContainerAppSystemLogs_CL` for OOM or crash reason |
| **CPU high** | Check for runaway threads or unexpected load; review App Insights Live Metrics for request rate |
| **Memory high** | Check for memory leaks; verify no load test is running; review `WorkingSetBytes` trend |
| **App/Env deleted** | Follow the recovery runbook — see section 5 |

---

## 4. High Availability

### How to configure HA

The following settings give you zone-redundant, fault-tolerant deployment with autoscaling.

| Setting | Recommended value | Purpose |
| --- | --- | --- |
| Zone redundancy | Enabled | Replicas distributed across availability zones |
| VNet integration | Dedicated /23 subnet | Required for zone redundancy; network isolation |
| Min replicas | 2 | Survives a single zone failure without downtime |
| Max replicas | Set based on cost cap | Limits autoscaling spend |
| Scaling rule | See options below | Depends on workload type |

> **Important:** Zone redundancy cannot be enabled or disabled after the environment is created. It must be set at creation time and requires a dedicated subnet.

---

### How to choose a scaling rule

Azure Container Apps supports several scaling triggers. Pick the one that matches your workload — you can also combine multiple rules, in which case the app scales out when any rule threshold is exceeded.

| Rule type | Trigger | Best for | How to test scale-out |
| --- | --- | --- | --- |
| **HTTP** | Concurrent requests at Azure ingress | Public-facing APIs | External load generator (e.g., `hey`, `k6`) |
| **TCP** | Concurrent TCP connections | gRPC, WebSockets, non-HTTP ingress | External connection flood tool |
| **Azure Service Bus** | Queue or topic message backlog | Event-driven consumers | Publish N messages to the queue |
| **Azure Event Hubs** | Partition lag (unprocessed events) | Stream processing | Produce events faster than the consumer processes them |
| **Azure Storage Queue** | Queue message count | Background job workers | Enqueue N messages |
| **CPU** | CPU utilization % | CPU-bound workloads | CPU load generator (e.g., `stress`) |
| **Memory** | Memory utilization % | Memory-bound workloads | Memory allocation load test |
| **Custom (KEDA)** | Any KEDA scaler metric | Any other trigger | Depends on the scaler |

> **Self-request caveat (HTTP rule):** If your container sends requests to itself, those bypass Azure ingress and do not count toward the HTTP scaling metric. Always use an external client to test HTTP scale-out.

#### Terraform example — HTTP rule

```hcl
http_scale_rule {
  name                = "http-scaling"
  concurrent_requests = "10"
}
```

#### Terraform example — Service Bus rule

```hcl
custom_scale_rule {
  name             = "servicebus-scaling"
  custom_rule_type = "azure-servicebus"
  metadata = {
    queueName    = "my-queue"
    namespace    = "my-servicebus-namespace"
    messageCount = "10"
  }
  authentication {
    secret_ref        = "servicebus-connection-string"
    trigger_parameter = "connection"
  }
}
```

#### Terraform example — CPU rule

```hcl
custom_scale_rule {
  name             = "cpu-scaling"
  custom_rule_type = "cpu"
  metadata = {
    type  = "Utilization"
    value = "70"
  }
}
```

---

### How health probes work

Both probes run on a fixed interval and take action when the container fails to respond correctly. The probe type and implementation depend on whether your app is HTTP-based or event-driven.

| Probe | Purpose | Typical check interval | Failure threshold | Action on failure |
| --- | --- | --- | --- | --- |
| **Liveness** | Detect hung or deadlocked containers | 10 seconds | 3 consecutive failures | Container is restarted |
| **Readiness** | Gate traffic to healthy replicas | 10 seconds | 3 consecutive failures | Replica removed from load balancer |

Start with an `initial_delay` of 5–10 seconds to give the container time to start before probes begin.

---

#### HTTP / API apps

Configure both probes as HTTP probes targeting `GET /health` on the app port.

> **Application requirement:** Your application must implement this endpoint. Azure does not provide one. If it is missing or returns non-200, the liveness probe will restart your container in a loop and the readiness probe will keep it out of the load balancer.

Minimum implementation: `GET /health` returns HTTP 200. Optionally add dependency checks (database, downstream services) to make the probe more meaningful.

```hcl
liveness_probe {
  transport               = "HTTP"
  path                    = "/health"
  port                    = 8000
  initial_delay           = 5
  interval_seconds        = 10
  failure_count_threshold = 3
}

readiness_probe {
  transport               = "HTTP"
  path                    = "/health"
  port                    = 8000
  interval_seconds        = 10
  failure_count_threshold = 3
  success_count_threshold = 1
}
```

---

#### Event-driven apps

Event-driven apps have no HTTP ingress — there is no built-in endpoint for Azure to probe. You must embed your own. You have three options — choose based on how much health signal you need:

| Option | Mechanism | Signal quality | Implementation effort |
| --- | --- | --- | --- |
| **Embedded HTTP health server** (recommended) | Run a lightweight HTTP server on a dedicated port alongside the consumer loop | High — can check consumer liveness, last-message age, broker connectivity | Medium |
| **TCP probe** | Azure checks that a port is open | Low — only detects crashes, not logical failures | Low |
| **Heartbeat file + exec probe** | Consumer writes a file every N seconds; probe checks file age | Medium — detects stuck consumers | Medium |

##### Option 1 — Embedded HTTP health server (recommended)

Run a background thread/task that exposes `GET /health` on a dedicated port (e.g., 8080). Return 200 only when all three conditions pass:

1. The consumer task is alive (not crashed or deadlocked)
2. The last message was processed within an acceptable window (e.g., 5× the expected message interval)
3. The broker connection is reachable

```hcl
liveness_probe {
  transport               = "HTTP"
  path                    = "/health"
  port                    = 8080   # dedicated health port, separate from any ingress
  initial_delay           = 10
  interval_seconds        = 10
  failure_count_threshold = 3
}
```

##### Option 2 — TCP probe

Useful when you only need crash detection and don't want to add an HTTP server.

```hcl
liveness_probe {
  transport               = "TCP"
  port                    = 8080
  initial_delay           = 5
  interval_seconds        = 10
  failure_count_threshold = 3
}
```

##### Option 3 — Heartbeat file

The consumer loop writes `/tmp/healthy` every 30 seconds. The probe checks that the file exists and is recent. Requires a custom exec probe — not natively supported in Azure Container Apps today; use this pattern on AKS instead.

> **Recommendation:** Use Option 1 for production. The embedded HTTP server gives you meaningful health signal (not just "the process is alive") and works natively with Azure Container Apps HTTP probes without any platform restrictions.

---

### How scale-in works

Regardless of the scaling rule type, scale-in behavior is the same:

- Azure waits ~5 minutes of sustained low activity before removing a replica
- The replica count never drops below `min_replicas`
- Scale-in is gradual — replicas are removed one at a time

---

## 5. Backup and Recovery

### What the backup strategy is

Azure Container Apps are stateless infrastructure — the only "backup" needed is the code that provisions them. If your infrastructure is declared in Terraform (or equivalent IaC), you can recreate the full stack from code at any time.

The container image is stored separately in Azure Container Registry (ACR), which persists independently of the app or environment.

There is no stateful application data to back up in a typical Container App deployment. If your app uses a database or storage account, those resources require their own backup strategy.

---

### How deletion is detected

Activity Log alerts fire within ~1 minute of a deletion event, notifying the on-call team via email before they would otherwise know.

| Alert | Trigger | Detection time |
| --- | --- | --- |
| `alert-container-app-deleted` | `Microsoft.App/containerApps/delete` | ~1 minute |
| `alert-environment-deleted` | `Microsoft.App/managedEnvironments/delete` | ~1 minute |

---

### How to recover — step by step

#### Scenario A — Container App deleted (environment still exists)

Estimated recovery time: ~3 minutes

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

Estimated recovery time: ~10–15 minutes

Environment provisioning takes several minutes. Networking, ACR, and monitoring are intact and do not need to be recreated.

```bash
cd terraform
terraform plan   # review all resources to be recreated
terraform apply
```

> If you have `prevent_destroy = true` on the environment, this protects against accidental `terraform destroy` but does not protect against manual deletions from the portal or CLI.

---

> **Note:** The scenarios above cover single-resource recovery within a region. For full region failure and multi-region failover, see section 6 (Disaster Recovery).

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

## 6. Disaster Recovery

### Architecture design

#### Why multi-region is necessary

Azure Container Apps is a **single-region service**. If the region becomes unavailable, the entire environment and all apps within it are also unavailable. Zone redundancy (section 4) protects against zone-level failures within a region, but it does not protect against a full regional outage.

To survive a region failure, the app must be deployed independently in a second region with a global routing layer in front that can detect the failure and redirect traffic automatically.

---

#### Deployment model: Active-Passive (Warm Standby)

| Model | Primary | Secondary | RTO | RPO | Cost |
| --- | --- | --- | --- | --- | --- |
| **Active-Passive (warm standby)** ← recommended | Handles all traffic | Deployed, min 1 replica running | ~1–3 min | ~0 (stateless) | Medium |
| Active-Active | Both regions handle traffic equally | Same as primary | ~0 | ~0 | High |
| Active-Passive (cold standby) | Handles all traffic | Not deployed until disaster | ~15–20 min | ~0 (stateless) | Low |

**Rationale for active-passive warm standby:**
- Secondary is always running with 1 replica — ready to accept traffic within seconds of AFD detecting failure
- Lower cost than active-active (one region handles most traffic)
- RTO of ~1–3 minutes is acceptable for most non-critical workloads
- This app is stateless — RPO is effectively zero (no data to lose)

---

#### Why Azure Front Door over Traffic Manager

Both services provide multi-region routing. For this workload, Azure Front Door Standard is the correct choice:

| Criterion | Azure Front Door Standard | Azure Traffic Manager |
| --- | --- | --- |
| Protocol | HTTP/S (Layer 7) — matches this FastAPI app | DNS-based (any protocol) |
| Failover mechanism | Health probes + automatic rerouting at edge | DNS TTL-based rerouting (60s+ propagation delay) |
| Failover speed | ~1 min (probe interval + detection) | ~1–5 min + DNS TTL |
| WAF | Custom rules included (free) | Not included |
| TLS termination | At edge (offload from origin) | Not provided |
| Caching / acceleration | Yes | No |
| Cost | $35/month base + per-request | ~$0.60/million DNS queries |

> **Rule of thumb:** Use Azure Front Door for HTTP/S workloads. Use Traffic Manager for non-HTTP protocols or DNS-level routing of multi-tier architectures.

---

#### Architecture overview

```
                        ┌─────────────────────────────────────────────────────┐
                        │              Azure Front Door Standard               │
                        │                                                      │
                        │   Origin Group: priority routing                     │
                        │   ├── Origin 1 (priority 1): Primary app FQDN       │
                        │   └── Origin 2 (priority 2): Secondary app FQDN     │
                        │                                                      │
                        │   Health probe: GET /health every 30s                │
                        │   Failover: automatic when origin returns non-2xx    │
                        └───────────────┬─────────────────────┬────────────────┘
                                        │ normal               │ during failure
                                        ▼                      ▼
                   ┌─────────────────────────┐    ┌─────────────────────────┐
                   │   Primary Region        │    │   Secondary Region      │
                   │   (e.g. East US)        │    │   (e.g. West US 2)      │
                   │                         │    │                         │
                   │   Container Apps Env    │    │   Container Apps Env    │
                   │   ├── Zone-redundant    │    │   ├── Zone-redundant    │
                   │   ├── VNet /23          │    │   ├── VNet /23          │
                   │   └── Container App     │    │   └── Container App     │
                   │       min_replicas: 2   │    │       min_replicas: 1   │
                   │       max_replicas: 5   │    │       max_replicas: 5   │
                   │                         │    │                         │
                   │   Log Analytics (pri)   │    │   Log Analytics (sec)   │
                   │   App Insights (pri)    │    │   App Insights (sec)    │
                   └─────────────────────────┘    └─────────────────────────┘
                                        │                      │
                                        └──────────┬───────────┘
                                                   │
                                    ┌──────────────┴──────────────┐
                                    │    Azure Container Registry  │
                                    │    (single registry, or      │
                                    │     Premium + geo-replica)   │
                                    └──────────────────────────────┘
```

**Traffic flow:**
- Normal: AFD routes 100% of traffic to primary. Secondary runs idle at 1 replica.
- Failure detected: AFD health probes detect primary returning 503 (or timing out). AFD automatically routes 100% of traffic to secondary within ~1 minute.
- Recovery: Primary health probes return 200. AFD gradually restores traffic to primary (failback).

---

#### Key environment variables per deployment

These must be set as environment variables on each Container App to identify the deployment in DR status responses and logs:

| Variable | Primary value | Secondary value |
| --- | --- | --- |
| `REGION_NAME` | `eastus` | `westus2` |
| `INSTANCE_ROLE` | `primary` | `secondary` |

---

#### ACR options for multi-region image availability

| Option | How | Cost | Resilience |
| --- | --- | --- | --- |
| **Single Basic ACR** (default, demo-friendly) | Both regions pull from same ACR endpoint | $5/month | Fails if ACR region goes down |
| **ACR Premium + geo-replication** (production) | Upgrade to Premium, add replica in secondary region | ~$40/month | Images available even if primary ACR region fails |

> For production: always use ACR Premium with geo-replication. ACR Traffic Manager automatically routes image pulls to the nearest healthy replica.

---

### RTO and RPO targets

| Scenario | RTO | RPO | Notes |
| --- | --- | --- | --- |
| Primary region failure (AFD automatic failover) | ~1–3 min | 0 | AFD detects via health probe; stateless app loses no data |
| Manual forced failover | <1 min | 0 | Via AFD portal or CLI (drain primary origin) |
| Primary region recovery (failback) | ~1–3 min | 0 | AFD re-detects healthy origin and restores routing |
| ACR outage (with geo-replication) | 0 | 0 | ACR Traffic Manager routes pulls to secondary replica |
| ACR outage (without geo-replication) | Minutes to hours | 0 | New replicas cannot start; existing replicas unaffected |

---

### DR simulation endpoints

The application exposes four endpoints for testing and validating the DR failover flow without requiring an actual Azure region failure.

| Endpoint | Method | Purpose |
| --- | --- | --- |
| `GET /dr/region` | GET | Returns the region and role (`primary`/`secondary`) of this instance |
| `GET /dr/status` | GET | Returns health, region, role, and uptime — use to verify which region is serving traffic |
| `POST /dr/degrade` | POST | Sets `/health` to return 503 — triggers AFD failover to secondary |
| `POST /dr/recover` | POST | Resets `/health` to return 200 — triggers AFD failback to primary |

> **Multi-replica caveat:** The degraded state is per-process. In a multi-replica deployment, each replica must be independently degraded for AFD to fail over (AFD health probes use round-robin across replicas). Set `min_replicas=1` on the primary before running DR failover tests to ensure a single probe target.

---

### Cost estimation

The following costs are **additional** to the existing single-region deployment. All estimates use US East / US West 2 pricing and assume low demo-level traffic.

#### Monthly cost breakdown

| Component | Details | Estimated cost |
| --- | --- | --- |
| **Container App — secondary** | 1 replica × 0.5 vCPU × 1 GiB, warm standby 24/7 | ~$39/month |
| **Azure Front Door Standard** | Base fee $35 + ~$5 requests + ~$2 egress | ~$42/month |
| **Log Analytics — secondary** | Minimal log ingestion (<1 GB/month) | ~$3/month |
| **App Insights — secondary** | Minimal telemetry (<1 GB/month) | ~$3/month |
| **VNet + subnet — secondary** | Consumption-only VNet integration | ~$0/month |
| **ACR (Option A: keep Basic)** | No change, single ACR | $0 additional |
| **ACR (Option B: Premium + geo-replica)** | Upgrade from Basic ($5) to Premium + 1 replica | +$35/month |

#### Total additional monthly cost

| Configuration | Additional monthly cost |
| --- | --- |
| **Recommended (demo):** AFD + warm standby + single ACR | **~$87/month** |
| **Production:** AFD + warm standby + ACR Premium + geo-replica | **~$122/month** |

#### Secondary app cost breakdown

The secondary Container App runs on the Consumption plan. Pricing:
- vCPU: $0.000024/vCPU-second
- Memory: $0.000003/GiB-second
- Free grant: first 180,000 vCPU-seconds and 360,000 GiB-seconds per subscription per month

With 1 replica at 0.5 vCPU / 1 GiB running 24/7:
- vCPU: 0.5 × 86,400 × 30 = 1,296,000 vCPU-sec → $31.10/month
- Memory: 1 × 86,400 × 30 = 2,592,000 GiB-sec → $7.78/month
- Total before free grant: **~$38.88/month**

> Reduce secondary to `min_replicas=0` (cold standby) to bring this cost to ~$0, at the expense of increasing RTO to ~10–15 minutes (environment + container startup time).

#### Cost levers

| Action | Monthly saving | Trade-off |
| --- | --- | --- |
| Cold standby (min_replicas=0) | ~$39/month | RTO increases to 10–15 min |
| Skip ACR geo-replication | ~$35/month | Image pull fails if ACR region is down |
| AFD Standard vs Premium | $295/month | No managed WAF rules, no Private Link |

---

### Runbook: Scenario D — Primary region failure (automatic failover)

**Trigger:** Azure region hosting the primary Container App becomes fully unavailable (region outage, not just a single resource deletion).

**Detection:** AFD health probes to primary origin stop receiving 200 responses. AFD automatically begins routing all traffic to secondary within ~1 minute.

**Estimated RTO:** ~1–3 minutes (probe detection + routing propagation)

**Step-by-step response:**

1. **Confirm the failure** — check Azure Service Health for a regional outage:
   ```bash
   az rest --method GET \
     --url "https://management.azure.com/subscriptions/<subscription_id>/providers/Microsoft.ResourceHealth/events?api-version=2022-10-01" \
     --query "value[?properties.eventType=='ServiceIssue'].{title:properties.title, region:properties.impactedRegions[0].id}" \
     -o table
   ```

2. **Verify AFD has failed over** — confirm traffic is now served from secondary:
   ```bash
   # The response region should show the secondary region
   curl https://<afd_endpoint>.z01.azurefd.net/dr/region
   ```

3. **Verify secondary is healthy:**
   ```bash
   curl https://<afd_endpoint>.z01.azurefd.net/dr/status
   curl https://<afd_endpoint>.z01.azurefd.net/health
   ```

4. **Monitor secondary under full load** — check replica count and scale-out:
   ```bash
   az containerapp replica list \
     --name <secondary_app_name> \
     --resource-group <secondary_rg> \
     --query "[].{name:name, state:properties.runningState}" \
     -o table
   ```

5. **Notify stakeholders** — AFD fires no default alert on origin failure. Set up an AFD metric alert on `OriginHealthPercentage < 100` to get notified automatically.

6. **Wait for primary region recovery** — do not attempt manual recovery until Azure confirms the region is healthy. Follow Scenario F for failback.

---

### Runbook: Scenario E — DR test (simulate failure with `/dr/degrade`)

Use this runbook to validate the full failover path without a real outage.

**Pre-conditions:**
- Primary and secondary both deployed and registered as origins in AFD
- AFD health probes are active on both origins (`GET /health`, 30-second interval)
- Primary `min_replicas=1` (ensures only one probe target for clean test)

**Step-by-step:**

1. **Confirm baseline — both regions healthy:**
   ```bash
   curl https://<primary_fqdn>/dr/region    # should show primary
   curl https://<secondary_fqdn>/dr/region  # should show secondary
   curl https://<afd_endpoint>.z01.azurefd.net/dr/region  # should show primary
   ```

2. **Trigger simulated failure on primary:**
   ```bash
   curl -X POST https://<primary_fqdn>/dr/degrade
   # Response: {"status": "degraded", "message": "..."}
   ```

3. **Confirm /health on primary now returns 503:**
   ```bash
   curl -i https://<primary_fqdn>/health
   # HTTP/1.1 503 Service Unavailable
   ```

4. **Wait for AFD to detect failure** (~30–60 seconds based on probe interval):
   ```bash
   # Poll until region switches
   watch -n 5 "curl -s https://<afd_endpoint>.z01.azurefd.net/dr/region"
   ```

5. **Confirm traffic is now served from secondary:**
   ```bash
   curl https://<afd_endpoint>.z01.azurefd.net/dr/region
   # {"region": "westus2", "role": "secondary"}
   ```

6. **Recover primary and test failback:**
   ```bash
   curl -X POST https://<primary_fqdn>/dr/recover
   # Wait 30–60 seconds for AFD to detect recovery
   curl https://<afd_endpoint>.z01.azurefd.net/dr/region
   # {"region": "eastus", "role": "primary"}
   ```

7. **Record results** — document actual detection time, failover time, and failback time against RTO targets.

---

### Runbook: Scenario F — Failback after primary region recovery

Use this runbook after the primary region recovers from a real outage (following Scenario D).

1. **Confirm primary region is available** via Azure Service Health.

2. **Verify primary Container App is healthy** — check the primary directly (bypassing AFD):
   ```bash
   curl https://<primary_app_fqdn>/health    # must return 200
   curl https://<primary_app_fqdn>/dr/status # confirm region + healthy=true
   ```

3. **Wait for AFD automatic failback** — AFD re-enables the primary origin once health probes pass. No manual action is required. This typically takes 1–3 minutes.

4. **Confirm AFD is routing to primary:**
   ```bash
   curl https://<afd_endpoint>.z01.azurefd.net/dr/region
   # {"region": "eastus", "role": "primary"}
   ```

5. **If AFD does not fail back automatically** — force it via the portal or CLI:
   ```bash
   # Re-enable primary origin in the AFD origin group if it was manually disabled
   az afd origin update \
     --resource-group <rg> \
     --profile-name <afd_profile> \
     --origin-group-name <origin_group> \
     --origin-name primary \
     --enabled-state Enabled
   ```

6. **Scale secondary back to min_replicas=1** if it was scaled up during the outage:
   ```bash
   az containerapp update \
     --name <secondary_app_name> \
     --resource-group <secondary_rg> \
     --min-replicas 1
   ```

---

### Runbook: Scenario G — ACR unavailability

**Impact:** Existing replicas continue running normally. The problem surfaces only when new replicas need to be started (scale-out, restart, or revision deployment). New replicas fail to pull the image and enter a `Waiting` state.

**Detection:**
```bash
# Check for replicas stuck in Waiting/Failed state
az containerapp replica list \
  --name <app_name> \
  --resource-group <rg> \
  --query "[?properties.runningState!='Running'].{name:name, state:properties.runningState}" \
  -o table

# Check system logs for image pull errors
az containerapp logs show \
  --name <app_name> \
  --resource-group <rg> \
  --type system \
  --follow
```

**Recovery options:**

| Option | When to use | Steps |
| --- | --- | --- |
| Wait for ACR to recover | Short outage expected | Monitor ACR health; replicas will pull successfully once ACR recovers |
| ACR geo-replication | Already configured | No action — ACR Traffic Manager fails over to secondary replica automatically |
| Push image to secondary ACR | Second ACR exists in another region | Update Container App to reference secondary ACR; `az containerapp update --image <secondary_acr>/<image>:<tag>` |

> **Prevention:** Upgrade ACR to Premium and enable geo-replication in the secondary region. Cost: ~$35/month additional over Basic ACR.

---

## 7. Permissions

### Who needs what access

Two identities need Azure permissions to operate this stack: the **human operator** (the person running `terraform apply` or using the portal) and the **Terraform service principal** (the identity Terraform authenticates as in CI/CD).

#### Human operator — minimum roles

| Role | Scope | Why needed |
| --- | --- | --- |
| Contributor | Resource group | Create and manage all resources in the stack |
| User Access Administrator | Resource group | Assign roles (e.g., AcrPull to the Container App identity) |
| Monitoring Contributor | Resource group | Create and manage alerts, action groups, workbooks |
| Log Analytics Contributor | Log Analytics workspace | Query logs and manage workspace settings |

> **Note:** If you are not assigning roles via Terraform, you can drop **User Access Administrator** and assign `AcrPull` manually from the portal.

#### Terraform service principal — minimum roles

| Role | Scope | Why needed |
| --- | --- | --- |
| Contributor | Resource group | Provision all Azure resources |
| User Access Administrator | Resource group | Assign `AcrPull` role to the Container App managed identity |

> **Least privilege tip:** If your organisation forbids User Access Administrator, assign the `AcrPull` role manually once and remove the role assignment resources from Terraform. Use `ignore_changes` on the identity block so Terraform does not drift.

---

### How to verify access

Check your current role assignments before running `terraform apply`:

```bash
# List your own role assignments on the resource group
az role assignment list \
  --assignee $(az ad signed-in-user show --query id -o tsv) \
  --resource-group <resource_group> \
  --output table

# List role assignments for the Terraform service principal
az role assignment list \
  --assignee <service_principal_object_id> \
  --resource-group <resource_group> \
  --output table
```

---

## 8. Quick Reference Commands

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
