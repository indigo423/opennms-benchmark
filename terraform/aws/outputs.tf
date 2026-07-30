# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0

output "jump_host" {
  value       = module.network.jump_host_public_ip
  description = "Public address of the jump host; empty when the deployment declares none."
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "instances" {
  value       = module.compute.private_ips
  description = "Node key -> primary private address."
}

output "console_url" {
  value       = "https://${var.region}.console.aws.amazon.com/resource-groups/group/${aws_resourcegroups_group.lab.name}?region=${var.region}"
  description = "Console view scoped to this deployment's resources and nothing else."
}

output "cost_profile" {
  value       = var.cost_profile
  description = "'smoke' means the instances are burstable and cannot produce valid measurements."
}

output "deployment" {
  value = var.deployment
}
