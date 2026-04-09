output "vsphere_server" {
  value       = var.vsphere_server
  description = "vCenter Server hostname — used by deploy.sh to derive the SSH jump host for IP discovery"
}

output "ip_monitoring" {
  value       = var.ip_monitoring
  description = "Management IP of the monitoring VM"
}

output "admin_user" {
  value       = var.admin_user
  description = "Admin user on the VMs"
}
