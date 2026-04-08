# ── Diagnostic Settings ──────────────────────────────────────────────────────
#
# Environment level: routes ContainerAppConsoleLogs + ContainerAppSystemLogs
# to Log Analytics using resource-specific tables (Dedicated mode) instead of
# the legacy AzureDiagnostics table. Up to 5 diagnostic settings can be added
# here to fan out to additional destinations (Event Hub, Storage, Datadog, …).
#
# Container app level: metrics only — Azure does not support log categories at
# the individual container app level, only at the environment level.

resource "azurerm_monitor_diagnostic_setting" "container_app_env" {
  name                           = "diag-cae-monitoring-demo"
  target_resource_id             = azurerm_container_app_environment.main.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.main.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "container_app" {
  name                           = "diag-ca-monitoring-demo"
  target_resource_id             = azurerm_container_app.main.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.main.id
  log_analytics_destination_type = "Dedicated"

  enabled_metric {
    category = "AllMetrics"
  }
}

# ── Observability Resources ───────────────────────────────────────────────────

resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-monitoring-demo"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.common_tags
}

resource "azurerm_application_insights" "main" {
  name                = "appi-monitoring-demo"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"
  tags                = local.common_tags
}
