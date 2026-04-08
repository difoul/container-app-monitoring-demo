output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "vnet_id" {
  value = azurerm_virtual_network.main.id
}

output "container_apps_subnet_id" {
  value = azurerm_subnet.container_apps.id
}

output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "acr_admin_username" {
  value     = azurerm_container_registry.main.admin_username
  sensitive = true
}

output "acr_admin_password" {
  value     = azurerm_container_registry.main.admin_password
  sensitive = true
}

output "container_app_url" {
  value = "https://${azurerm_container_app.main.latest_revision_fqdn}"
}

output "application_insights_connection_string" {
  value     = azurerm_application_insights.main.connection_string
  sensitive = true
}

output "log_analytics_workspace_id" {
  value = module.law.workspace_customer_id
}

output "ampls_id" {
  value = module.law.ampls_id
}

output "law_security_mode" {
  value = module.law.security_mode
}

output "workbook_id" {
  value       = azurerm_application_insights_workbook.main.id
  description = "Azure Portal: Monitor → Workbooks → 'Container App Monitoring'"
}
