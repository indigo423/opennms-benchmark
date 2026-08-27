output "proxmox_endpoint" {
  value       = var.proxmox_endpoint
  description = "Proxmox VE API endpoint. deploy.sh derives the hypervisor's SSH host from it."
}

# The jump host is whichever node the spec marks public_ip, derived from the
# topology rather than assumed to be monitoring. For every OpenNMS deployment
# that is monitoring, but a spec is free to put it elsewhere.
output "ip_jump_host" {
  value       = local.jump_host_name != "" ? local.inv_hosts[local.jump_host_name].ansible_host : ""
  description = "Management IP of the deployment's jump host (the public_ip node), derived from the topology spec"
}

output "admin_user" {
  value       = var.admin_user
  description = "Admin user on the VMs"
}

# deploy.sh hops through the hypervisor to probe the jump host's external
# address. Without a user it uses the invoking operator's local username, which
# on a Proxmox node does not exist -- discovery then failed for two minutes
# against a host it could never log into. The provider already needs this
# account for snippet uploads, so it is the same answer twice.
output "hypervisor_ssh_user" {
  value       = var.proxmox_ssh_username
  description = "SSH user for the hypervisor itself, for jump-host discovery"
}
