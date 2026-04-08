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
  log_analytics_workspace_id     = module.law.workspace_id
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
  log_analytics_workspace_id     = module.law.workspace_id
  log_analytics_destination_type = "Dedicated"

  enabled_metric {
    category = "AllMetrics"
  }
}

# ── Observability Resources ───────────────────────────────────────────────────

# Hybrid mode: private ingestion (AMPLS + private endpoint) with public query.
# Analysts can query from the Azure portal without VPN; the data pipeline is
# fully protected — nothing can be injected from outside the VNet.
module "law" {
  source = "./modules/law-secure"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  workspace_name      = "law-monitoring-demo"
  security_mode       = "hybrid"

  retention_in_days = 30
  daily_quota_gb    = -1

  subnet_id          = azurerm_subnet.private_endpoints.id
  virtual_network_id = azurerm_virtual_network.main.id

  enable_audit_diagnostics = true

  tags = local.common_tags
}

resource "azurerm_application_insights" "main" {
  name                = "appi-monitoring-demo"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  workspace_id        = module.law.workspace_id
  application_type    = "web"
  tags                = local.common_tags
}

# App Insights must be explicitly scoped to the AMPLS — without this, the
# Container App (running inside the VNet) cannot reach the App Insights
# ingestion endpoint when AMPLS ingestion_access_mode = "PrivateOnly".
resource "azurerm_monitor_private_link_scoped_service" "app_insights" {
  count = module.law.ampls_name != null ? 1 : 0

  name                = "scoped-appi-monitoring-demo"
  resource_group_name = azurerm_resource_group.main.name
  scope_name          = module.law.ampls_name
  linked_resource_id  = azurerm_application_insights.main.id
}
