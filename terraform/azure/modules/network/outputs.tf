# NIC IDs keyed "<role>-<subnet>" (e.g. "core-kafka"), consumed by the compute module.
output "nic_ids" {
  value = { for k, nic in azurerm_network_interface.nic : k => nic.id }
}

output "monitoring_public_ip" {
  value = azurerm_public_ip.monitoring.ip_address
}
