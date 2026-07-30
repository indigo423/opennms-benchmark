# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0

output "network_interface_ids" {
  value       = { for k, eni in aws_network_interface.lab : k => eni.id }
  description = "ENI id per '<node>-<subnet>' key, consumed by the compute module."
}

output "jump_public_interface_ids" {
  value       = { for k, eni in aws_network_interface.jump_public : k => eni.id }
  description = "Public-subnet ENI per public node, attached last so lab NIC ordering is unaffected."
}

output "jump_eip_allocation_ids" {
  value       = { for k, e in aws_eip.jump : k => e.allocation_id }
  description = "Allocation id per public node; the compute module associates these once the instance is running."
}

output "jump_host_public_ip" {
  value       = try(values(aws_eip.jump)[0].public_ip, "")
  description = "Public address of the jump host, or empty when the deployment has none."
}

output "vpc_id" {
  value = aws_vpc.lab.id
}
