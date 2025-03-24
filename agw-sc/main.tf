provider "azurerm" {
  features {}
  subscription_id = "3b0f549f-0e89-4e6b-b010-0781de4d03e8"
}

# Variables
variable "location" {
  default = "eastus"
}

variable "resource_group_name" {
  default = "az104-resource-group"
}

variable "storage_account_name" {
  default = "az104staticwebsite"
}

variable "app_gateway_name" {
  default = "az104-app-gateway"
}

variable "public_ip_name" {
  default = "az104-app-gateway-ip"
}

# Create a resource group
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# Create a storage account with static website hosting enabled
resource "azurerm_storage_account" "storage" {
  for_each = var.container_registeries
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  static_website {
    index_document = "index.html"
  }
}

# Upload a sample index.html file to the $web container
resource "azurerm_storage_blob" "index" {
  source = ../../../
  name                   = "index.html"
  storage_account_name   = azurerm_storage_account.*.storage.name
  storage_container_name = "$web"
  type                   = "Block"
  content_type           = "text/html"
  source_content         = "<h1>Hello, Azure Static Website!</h1>"
}

# Create a public IP for the Application Gateway
resource "azurerm_public_ip" "appgw_ip" {
  name                = var.public_ip_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Create the Application Gateway
resource "azurerm_application_gateway" "appgw" {
  name                = var.app_gateway_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.appgw_subnet.id
  }

  frontend_port {
    name = "http-port"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw_ip.id
  }

  backend_address_pool {
    name  = "static-website-backend"
    fqdns = [azurerm_storage_account.storage.primary_web_host]
  }

  backend_http_settings {
    name                  = "https-setting"
    cookie_based_affinity = "Disabled"
    port                  = 443
    protocol              = "Https"
    request_timeout       = 60
  }

  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "http-port"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "static-website-rule"
    priority = 100
    rule_type                  = "Basic"
    http_listener_name         = "http-listener"
    backend_address_pool_name  = "static-website-backend"
    backend_http_settings_name = "http-setting"
  }
}

# Create a virtual network and subnet for the Application Gateway
resource "azurerm_virtual_network" "vnet" {
  name                = "az104-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "appgw_subnet" {
  name                 = "appgw-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Output the Application Gateway public IP
output "app_gateway_public_ip" {
  value = azurerm_public_ip.appgw_ip.ip_address
}

# Output the static website URL
output "static_website_url" {
  value = azurerm_storage_account.storage.primary_web_endpoint
}
resource "azurerm_network_security_group" "nsg" {
  name                = "nsg-buc-dev"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "AllowAppGatewayPorts"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["65200-65535"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowAppGatewayHttpPorts"
    priority                   = 101
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

    security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096  # Changed from 65500 to 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    }

}

resource "azurerm_subnet_network_security_group_association" "nsg_association" {
  subnet_id                 = azurerm_subnet.appgw_subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}
