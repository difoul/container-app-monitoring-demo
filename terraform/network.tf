resource "azurerm_virtual_network" "main" {
  name                = "vnet-monitoring-demo"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = ["10.0.0.0/16"]
  tags                = local.common_tags
}

# /27 — 32 addresses, sufficient for all AMPLS private endpoint NICs
resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/27"]
}

# ── NSG: Container Apps subnet ────────────────────────────────────────────────
# NOTE: For an external workload profiles environment, public inbound traffic
# goes through the public IP in the Azure-managed ME_ resource group and does
# NOT pass through this subnet — inbound NSG rules here have no effect on
# public traffic. Outbound rules are fully effective.
#
# Required outbound rules per:
# https://learn.microsoft.com/azure/container-apps/firewall-integration
resource "azurerm_network_security_group" "container_apps" {
  name                = "nsg-container-apps"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.common_tags

  # Allow intra-subnet traffic — required for Envoy sidecar communication
  security_rule {
    name                       = "allow-intra-subnet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.0.0.0/23"
    destination_address_prefix = "10.0.0.0/23"
  }

  # Allow Azure Load Balancer health probes — required for backend pool checks
  security_rule {
    name                       = "allow-load-balancer-probes"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "30000-32767"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  # Outbound: intra-subnet
  security_rule {
    name                       = "allow-outbound-intra-subnet"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.0.0.0/23"
    destination_address_prefix = "10.0.0.0/23"
  }

  # Outbound: system container images from Microsoft Container Registry
  security_rule {
    name                       = "allow-mcr"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "MicrosoftContainerRegistry"
  }

  # Outbound: dependency of MicrosoftContainerRegistry service tag
  security_rule {
    name                       = "allow-afd-first-party"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "AzureFrontDoor.FirstParty"
  }

  # Outbound: ACR image pulls
  security_rule {
    name                       = "allow-acr"
    priority                   = 130
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "AzureContainerRegistry"
  }

  # Outbound: Azure Storage (required by ACR for layer blobs)
  security_rule {
    name                       = "allow-storage"
    priority                   = 140
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "Storage"
  }

  # Outbound: Azure Monitor (diagnostic settings + OTel telemetry)
  security_rule {
    name                       = "allow-azure-monitor"
    priority                   = 150
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "AzureMonitor"
  }

  # Outbound: Azure Active Directory (managed identity token requests)
  security_rule {
    name                       = "allow-aad"
    priority                   = 160
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "AzureActiveDirectory"
  }

  # Outbound: Azure DNS (must not be blocked — not subject to NSG unless using AzurePlatformDNS tag)
  security_rule {
    name                       = "allow-dns"
    priority                   = 170
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "53"
    source_address_prefix      = "*"
    destination_address_prefix = "168.63.129.16/32"
  }
}

resource "azurerm_subnet_network_security_group_association" "container_apps" {
  subnet_id                 = azurerm_subnet.container_apps.id
  network_security_group_id = azurerm_network_security_group.container_apps.id
}

# /23 is the minimum block required by Azure for zone-redundant Container Apps Environments
resource "azurerm_subnet" "container_apps" {
  name                 = "snet-container-apps"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.0.0/23"]

  delegation {
    name = "container-apps-delegation"

    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}
