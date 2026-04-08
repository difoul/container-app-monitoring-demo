resource "random_uuid" "workbook" {}

# Azure Monitor Workbook with resource pickers — works for any Container App deployment.
# Open it at: Monitor → Workbooks → "Container App Monitoring"
resource "azurerm_application_insights_workbook" "main" {
  name                = random_uuid.workbook.result
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  display_name        = "Container App Monitoring"
  source_id           = "azure monitor"
  tags                = local.common_tags

  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [

      # ── Parameters ──────────────────────────────────────────────────────────
      # Resource pickers use hardcoded resource IDs (available from Terraform)
      # so the workbook loads immediately without waiting for ARG queries to resolve.
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
      },

      # ── Section: Infrastructure ──────────────────────────────────────────────
      {
        type    = 1
        content = { json = "## Infrastructure" }
        name    = "infra-header"
      },

      {
        type        = 10
        customWidth = "50"
        content = {
          version                = "MetricsItem/2.0"
          size                   = 0
          chartType              = 2
          resourceType           = "microsoft.app/containerapps"
          metricScope            = 0
          resourceIds            = ["{ContainerApp}"]
          timeContextFromParameter = "TimeRange"
          metrics = [{
            namespace   = "microsoft.app/containerapps"
            metric      = "microsoft.app/containerapps--UsageNanoCores"
            aggregation = 3 # Maximum
            splitBy     = null
          }]
          title = "CPU Usage — Maximum"
        }
        name = "cpu"
      },

      {
        type        = 10
        customWidth = "50"
        content = {
          version                = "MetricsItem/2.0"
          size                   = 0
          chartType              = 2
          resourceType           = "microsoft.app/containerapps"
          metricScope            = 0
          resourceIds            = ["{ContainerApp}"]
          timeContextFromParameter = "TimeRange"
          metrics = [{
            namespace   = "microsoft.app/containerapps"
            metric      = "microsoft.app/containerapps--WorkingSetBytes"
            aggregation = 4 # Average
            splitBy     = null
          }]
          title = "Memory Usage — Average"
        }
        name = "memory"
      },

      {
        type        = 10
        customWidth = "50"
        content = {
          version                = "MetricsItem/2.0"
          size                   = 0
          chartType              = 2
          resourceType           = "microsoft.app/containerapps"
          metricScope            = 0
          resourceIds            = ["{ContainerApp}"]
          timeContextFromParameter = "TimeRange"
          metrics = [{
            namespace   = "microsoft.app/containerapps"
            metric      = "microsoft.app/containerapps--Replicas"
            aggregation = 4 # Average
            splitBy     = null
          }]
          title = "Replica Count"
        }
        name = "replicas"
      },

      {
        type        = 10
        customWidth = "50"
        content = {
          version                = "MetricsItem/2.0"
          size                   = 0
          chartType              = 2
          resourceType           = "microsoft.app/containerapps"
          metricScope            = 0
          resourceIds            = ["{ContainerApp}"]
          timeContextFromParameter = "TimeRange"
          metrics = [{
            namespace   = "microsoft.app/containerapps"
            metric      = "microsoft.app/containerapps--RestartCount"
            aggregation = 1 # Total
            splitBy     = null
          }]
          title = "Container Restarts — Total"
        }
        name = "restarts"
      },

      # ── Section: Application ─────────────────────────────────────────────────
      {
        type    = 1
        content = { json = "## Application" }
        name    = "app-header"
      },

      {
        type        = 10
        customWidth = "50"
        content = {
          version                = "MetricsItem/2.0"
          size                   = 0
          chartType              = 2
          resourceType           = "microsoft.insights/components"
          metricScope            = 0
          resourceIds            = ["{AppInsights}"]
          timeContextFromParameter = "TimeRange"
          metrics = [{
            namespace   = "microsoft.insights/components"
            metric      = "microsoft.insights/components--requests/failed"
            aggregation = 7 # Count
            splitBy     = null
          }]
          title = "HTTP Failed Requests — Count"
        }
        name = "failed-requests"
      },

      {
        type        = 10
        customWidth = "50"
        content = {
          version                = "MetricsItem/2.0"
          size                   = 0
          chartType              = 2
          resourceType           = "microsoft.insights/components"
          metricScope            = 0
          resourceIds            = ["{AppInsights}"]
          timeContextFromParameter = "TimeRange"
          metrics = [{
            namespace   = "microsoft.insights/components"
            metric      = "microsoft.insights/components--availabilityResults/availabilityPercentage"
            aggregation = 4 # Average
            splitBy     = null
          }]
          title = "Availability — Average %"
        }
        name = "availability"
      }

    ]
    "$schema" = "https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json"
  })
}
