variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "rg-monitoring-demo"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "swedencentral"
}

variable "acr_name" {
  description = "Azure Container Registry name (globally unique, alphanumeric only, 5-50 chars)"
  type        = string
}

variable "container_app_name" {
  description = "Name of the Container App"
  type        = string
  default     = "monitoring-demo"
}

variable "container_image" {
  description = "Full image reference to deploy. Defaults to a public placeholder for the initial apply. Set to '<acr_login_server>/<container_app_name>:<tag>' after pushing to ACR."
  type        = string
  default     = "mcr.microsoft.com/k8se/quickstart:latest"
}

variable "alert_email" {
  description = "Email address to receive alert notifications"
  type        = string
}
