# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0

output "instance_ids" {
  value = { for k, i in aws_instance.lab : k => i.id }
}

output "private_ips" {
  value = { for k, i in aws_instance.lab : k => i.private_ip }
}
