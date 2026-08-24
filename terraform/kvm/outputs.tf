output "libvirt_host" {
  value       = regex("@([^/]+)/", var.libvirt_uri)[0]
  description = "Hostname of the KVM/libvirt host, extracted from libvirt_uri"
}

output "ip_monitoring" {
  value       = var.ip_monitoring
  description = "Management IP of the monitoring VM (reachable from the KVM host via NAT)"
}

# ip_monitoring is a static tfvars value, so it reports 192.0.2.200 even for a
# deployment that provisions no monitoring VM. The jump host is whichever node
# the spec marks public_ip, and on such a deployment that is some other node —
# probing ip_monitoring there just times out. Derive it from the topology
# instead. For every OpenNMS deployment the jump node IS monitoring, so this
# resolves to the same address ip_monitoring already returned.
output "ip_jump_host" {
  value       = local.jump_host_name != "" ? local.inv_hosts[local.jump_host_name].ansible_host : ""
  description = "Management IP of the deployment's jump host (the public_ip node), derived from the topology spec"
}

output "admin_user" {
  value       = var.admin_user
  description = "Admin user on the VMs"
}
