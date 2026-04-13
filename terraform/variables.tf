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

  validation {
    condition     = var.container_image != "mcr.microsoft.com/k8se/quickstart:latest"
    error_message = "container_image is still set to the placeholder. Set it to your ACR image reference, e.g. '<acr_login_server>/monitoring-demo:latest'."
  }
}

variable "http_scale_threshold" {
  description = "Number of concurrent HTTP requests per replica that triggers a scale-out event. Lower values scale out earlier and reduce latency under load; higher values pack more traffic per replica and reduce cost."
  type        = number
  default     = 10

  validation {
    condition     = var.http_scale_threshold >= 1 && var.http_scale_threshold <= 1000
    error_message = "http_scale_threshold must be between 1 and 1000."
  }
}

variable "alert_email" {
  description = "Email address to receive alert notifications"
  type        = string
}
