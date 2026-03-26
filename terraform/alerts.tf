resource "azurerm_monitor_action_group" "email" {
  name                = "ag-monitoring-demo"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "monitoringdm"

  email_receiver {
    name          = "alert-email"
    email_address = var.alert_email
  }
}

# CPU > 50% of 0.5 vCPU allocation (250,000,000 nanocores)
resource "azurerm_monitor_metric_alert" "cpu" {
  name                = "alert-cpu-high"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_container_app.main.id]
  description         = "Container App CPU usage above 50% of allocated 0.5 vCPU"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "UsageNanoCores"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 250000000
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

# Container restarts — any restart is worth alerting on
resource "azurerm_monitor_metric_alert" "restarts" {
  name                = "alert-container-restarts"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_container_app.main.id]
  description         = "Container App has restarted at least once"
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
