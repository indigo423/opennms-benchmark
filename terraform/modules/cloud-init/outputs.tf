output "network_config" {
  value       = local.network_config
  description = "Rendered cloud-init network-config v2 YAML"
}

output "user_data" {
  value       = local.user_data
  description = "Rendered cloud-init user-data YAML"
}

output "user_data_base64" {
  value       = base64encode(local.user_data)
  description = "Base64-encoded user-data for Azure custom_data"
}
