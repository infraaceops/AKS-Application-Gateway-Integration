provider "azurerm" {
  features {}
}

# Variables
variable "location" {
  default = "eastus"
}

variable "resource_group_name" {
  default = "poc-shadab-rg"
}

variable "vnet_name" {
  default = "poc-vnet"
}

variable "subnet_name" {
  default = "poc-subnet"
}

variable "aks_cluster_name" {
  default = "poc-aks-cluster"
}

variable "app_gateway_name" {
  default = "poc-app-gateway"
}

variable "dns_name" {
  default = "static.shadab.gops.net"
}

variable "proxy_pod_dns" {
  default = "proxy.shadab.gops.net"
}

# Resource Group
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# Virtual Network and Subnet
resource "azurerm_virtual_network" "vnet" {
  name                = var.vnet_name
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "subnet" {
  name                 = var.subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# AKS Cluster
resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.aks_cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.aks_cluster_name

  default_node_pool {
    name       = "default"
    node_count = 2
    vm_size    = "Standard_DS2_v2"
  }

  identity {
    type = "SystemAssigned"
  }
}

# Public IP for Application Gateway
resource "azurerm_public_ip" "appgw_pip" {
  name                = "appgw-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Application Gateway
resource "azurerm_application_gateway" "appgw" {
  name                = var.app_gateway_name
  location            = var.location
  resource_group_name = var.resource_group_name

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

  backend_address_pool {
    name = "proxy-backend-pool"
    fqdns = [var.proxy_pod_dns] # Proxy Pod exposed via AKS service
  }

  backend_http_settings {
    name                  = "proxy-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
  }

  http_listener {
    name                           = "proxy-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "https-port"
    protocol                       = "Https"
    host_name                      = var.dns_name
  }

  request_routing_rule {
    name                       = "proxy-routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "proxy-listener"
    backend_address_pool_name  = "proxy-backend-pool"
    backend_http_settings_name = "proxy-http-settings"
  }
}

# Helm Deployment for NGINX Proxy Pod in AKS
resource "null_resource" "helm_nginx" {
  provisioner "local-exec" {
    command = <<EOT
      az aks get-credentials --resource-group ${var.resource_group_name} --name ${var.aks_cluster_name} --overwrite-existing
      helm repo add stable https://charts.helm.sh/stable
      helm install proxy-nginx stable/nginx-ingress --set controller.service.type=LoadBalancer --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-internal"="true"
    EOT
  }
}

# DNS Records
resource "azurerm_dns_a_record" "proxy_dns" {
  name                = "proxy"
  zone_name           = "shadab.gops.net"
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [azurerm_public_ip.appgw_pip.ip_address]
}

# Outputs
output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "app_gateway_public_ip" {
  value = azurerm_public_ip.appgw_pip.ip_address
}

output "proxy_pod_dns" {
  value = "proxy.shadab.gops.net"
}
