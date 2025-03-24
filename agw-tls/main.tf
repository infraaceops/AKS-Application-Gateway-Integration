provider "azurerm" {
  features {}
}

# Variables
variable "location" {
  default = "eastus"
}


variable "vnet_name" {
  default = "poc-vnet"
}

variable "subnet_name" {
  default = "poc-subnet"
}

variable "key_vault_name" {
  default = "poc-keyvault"
}

variable "static_dns_name" {
  default = "static.shadab.gops.net"
}

variable "api_dns_name" {
  default = "api.shadab.gops.net"
}

variable "storage_account_name" {
  default = "pocstorageaccount"
}

variable "app_gateway_name" {
  default = "poc-app-gateway"
}

variable "dns_name" {
  default = "static.shadab.gops.net"
}

# Virtual Network and Subnet
resource "azurerm_virtual_network" "vnet" {
  name                = var.vnet_name
  address_space       = ["10.0.0.0/16"]
  location            = "eastus"
  resource_group_name = "poc-shadab-rg"
}

resource "azurerm_subnet" "subnet" {
  name                 = var.subnet_name
  resource_group_name  = "poc-shadab-rg"
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Key Vault and Self-Signed Certificate
resource "azurerm_key_vault" "kv" {
  name                = var.key_vault_name
  location            = "eastus"
  resource_group_name = "poc-shadab-rg"
  sku_name            = "standard"
  tenant_id           = data.azurerm_client_config.current.tenant_id

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    certificate_permissions = [
      "Create", "Get", "List", "Import"
    ]
  }
}

resource "azurerm_key_vault_certificate" "self_signed_cert" {
  name         = "self-signed-cert"
  key_vault_id = azurerm_key_vault.kv.id

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }

    key_properties {
      exportable = true
      key_size   = 2048
      key_type   = "RSA"
      reuse_key  = true
    }

    secret_properties {
      content_type = "application/x-pkcs12"
    }

    x509_certificate_properties {
      subject            = "CN=${var.dns_name}"
      validity_in_months = 12

      subject_alternative_names {
        dns_names = [var.dns_name]
      }
    }
  }
}

# Storage Account and Static Website
resource "azurerm_storage_account" "storage" {
  name                     = var.storage_account_name
  resource_group_name      = "poc-shadab-rg"
  location                 = "eastus"
  account_tier             = "Standard"
  account_replication_type = "LRS"

  static_website {
    index_document = "index.html"
  }
}

# Private Endpoint for Storage Account
resource "azurerm_private_endpoint" "storage_private_endpoint" {
  name                = "storage-private-endpoint"
  location            = "eastus"
  resource_group_name = "poc-shadab-rg"
  subnet_id           = azurerm_subnet.subnet.id

  private_service_connection {
    name                           = "storage-private-connection"
    private_connection_resource_id = azurerm_storage_account.storage.id
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }
}

# Application Gateway
resource "azurerm_application_gateway" "appgw" {
  name                = var.app_gateway_name
  resource_group_name = "poc-shadab-rg"
  location            = "eastus"

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.subnet.id
  }

  frontend_port {
    name = "https-port"
    port = 443
  }

  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw_pip.id
  }

  ssl_certificate {
    name                = "self-signed-cert"
    key_vault_secret_id = azurerm_key_vault_certificate.self_signed_cert.secret_id
  }
  backend_address_pool {
    name = "static-backend-pool"
    ip_addresses = [azurerm_private_endpoint.storage_private_endpoint.private_service_connection.private_ip_address]
  }

  # Backend Pool for API (AKS Pod)
  backend_address_pool {
    name = "api-backend-pool"
    fqdns = [var.aks_api_fqdn]
  }
  
  backend_http_settings {
    name                  = "static-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
  }

  # Backend HTTP Settings for API (AKS Pod)
  backend_http_settings {
    name                  = "api-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
  }


  http_listener {
    name                           = "static-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "https-port"
    protocol                       = "Https"
    ssl_certificate_name           = "self-signed-cert"
    host_name                      = var.static_dns_name
  }

  # HTTP Listener for API
  http_listener {
    name                           = "api-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "https-port"
    protocol                       = "Https"
    ssl_certificate_name           = "self-signed-cert"
    host_name                      = var.api_dns_name
  }

  request_routing_rule {
    name                       = "static-routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "static-listener"
    backend_address_pool_name  = "static-backend-pool"
    backend_http_settings_name = "static-http-settings"
  }

  # Routing Rule for API
  request_routing_rule {
    name                       = "api-routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "api-listener"
    backend_address_pool_name  = "api-backend-pool"
    backend_http_settings_name = "api-http-settings"
  }
  
}

# Public IP for Application Gateway
resource "azurerm_public_ip" "appgw_pip" {
  name                = "appgw-pip"
  location            = "eastus"
  resource_group_name = "poc-shadab-rg"
  allocation_method   = "Static"
  sku                 = "Standard"
}

# DNS Record for Application Gateway
# resource "azurerm_dns_zone" "dns_zone" {
#   name                = "shadab.gops.net"
#   resource_group_name = "poc-shadab-rg"
# }

resource "azurerm_dns_a_record" "appgw_dns" {
  name                = "static"
  zone_name           = "shadab.gops.net"
  resource_group_name = "poc-shadab-rg"
  ttl                 = 300
  records             = [azurerm_public_ip.appgw_pip.ip_address]
}
resource "azurerm_dns_a_record" "api_dns" {
  name                = "api"
  zone_name           = "shadab.gops.net"
  resource_group_name = "poc-shadab-rg"
  ttl                 = 300
  records             = [azurerm_public_ip.appgw_pip.ip_address]
}

# Outputs
output "app_gateway_public_ip" {
  value = azurerm_public_ip.appgw_pip.ip_address
}

output "storage_account_url" {
  value = azurerm_storage_account.storage.primary_web_endpoint
}

output "app_gateway_dns_name" {
  value = "${azurerm_dns_a_record.appgw_dns.name}.shadab.gops.net"
}