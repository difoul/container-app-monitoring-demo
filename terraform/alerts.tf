resource "azurerm_monitor_action_group" "email" {
  name                = "ag-monitoring-demo"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "monitoringdm"
  tags                = local.common_tags

  email_receiver {
    name          = "alert-email"
    email_address = var.alert_email
  }
}

# CPU > 80% of 0.5 vCPU allocation (400,000,000 nanocores), using Maximum aggregation
resource "azurerm_monitor_metric_alert" "cpu" {
  name                = "alert-cpu-high"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_container_app.main.id]
  description         = "Container App CPU usage above 80% of allocated 0.5 vCPU"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = local.common_tags

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

# CPU sustained > 70% of 0.5 vCPU allocation (350,000,000 nanocores) over 15 minutes
# Complements the spike alert above — catches gradual saturation before it becomes critical
resource "azurerm_monitor_metric_alert" "cpu_sustained" {
  name                = "alert-cpu-sustained"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_container_app.main.id]
  description         = "Container App CPU average above 70% of allocated 0.5 vCPU for 15 minutes — consider scaling up"
  severity            = 3 # Informational — early warning before spike alert fires
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.common_tags

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "UsageNanoCores"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 350000000
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# Memory > 80% of 1Gi allocation (858,993,459 bytes)
resource "azurerm_monitor_metric_alert" "memory" {
  name                = "alert-memory-high"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_container_app.main.id]
  description         = "Container App memory usage above 80% of allocated 1Gi"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = local.common_tags

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

# HTTP 5xx errors via Application Insights (requires app instrumentation)
resource "azurerm_monitor_metric_alert" "http_5xx" {
  name                = "alert-http-5xx"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_application_insights.main.id]
  description         = "More than 10 failed HTTP requests in 5 minutes"
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = local.common_tags

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

# Container App deleted or environment deleted — triggers recovery runbook
resource "azurerm_monitor_activity_log_alert" "container_app_deleted" {
  name                = "alert-container-app-deleted"
  resource_group_name = azurerm_resource_group.main.name
  location            = "Global"
  scopes              = [azurerm_resource_group.main.id]
  description         = "Container App or Container Apps Environment was deleted — trigger recovery runbook"
  tags                = local.common_tags

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.App/containerApps/delete"
    level          = "Critical"
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

resource "azurerm_monitor_activity_log_alert" "environment_deleted" {
  name                = "alert-environment-deleted"
  resource_group_name = azurerm_resource_group.main.name
  location            = "Global"
  scopes              = [azurerm_resource_group.main.id]
  description         = "Container Apps Environment was deleted — full stack recovery required"
  tags                = local.common_tags

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.App/managedEnvironments/delete"
    level          = "Critical"
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# Availability test — pings /health from 5 Azure regions every 5 minutes
resource "azurerm_application_insights_standard_web_test" "health" {
  name                    = "avail-monitoring-demo"
  resource_group_name     = azurerm_resource_group.main.name
  location                = azurerm_resource_group.main.location
  application_insights_id = azurerm_application_insights.main.id
  frequency               = 300 # every 5 minutes
  tags                    = local.common_tags

  geo_locations = [
    "us-va-ash-azr",   # East US
    "us-ca-sjc-azr",   # West US
    "emea-nl-ams-azr", # West Europe
    "emea-gb-db3-azr", # North Europe
    "apac-sg-sin-azr", # Southeast Asia
  ]

  request {
    url                  = "https://${azurerm_container_app.main.latest_revision_fqdn}/health"
    expected_http_status = 200
  }
}

# Alert when availability fails from at least 1 region — uses the web-test-specific criteria block
resource "azurerm_monitor_metric_alert" "availability" {
  name                = "alert-availability"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_application_insights.main.id, azurerm_application_insights_standard_web_test.health.id]
  description         = "Container App /health endpoint is failing availability checks from at least one region"
  severity            = 0 # Critical
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = local.common_tags

  application_insights_web_test_location_availability_criteria {
    web_test_id           = azurerm_application_insights_standard_web_test.health.id
    component_id          = azurerm_application_insights.main.id
    failed_location_count = 1
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# Container restarts — any restart is worth alerting on
resource "azurerm_monitor_metric_alert" "restarts" {
  name                = "alert-container-restarts"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_container_app.main.id]
  description         = "Container App has restarted at least once"
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = local.common_tags

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
