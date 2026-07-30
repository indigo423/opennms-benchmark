# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0

variable "name_prefix" { type = string }
variable "ami_id" { type = string }
variable "admin_user" { type = string }
variable "ssh_public_key" { type = string }
variable "instance_types" { type = map(string) }
variable "cost_profile" { type = string }
variable "spot" { type = bool }
variable "root_volume_type" { type = string }
variable "root_volume_iops" { type = number }
variable "root_volume_throughput" { type = number }
variable "placement_strategy" { type = string }

variable "hosts" {
  type        = map(string)
  description = "Hostname -> mgmt address, rendered into /etc/hosts by cloud-init."
}

variable "network_interface_ids" {
  type        = map(string)
  description = "ENI id per '<node>-<subnet>' key, from the network module."
}

variable "jump_public_interface_ids" {
  type        = map(string)
  default     = {}
  description = "Public-subnet ENI per public node. Attached after the lab NICs so predictable interface naming is unaffected."
}

variable "jump_eip_allocation_ids" {
  type        = map(string)
  default     = {}
  description = "Elastic IP allocation id per public node, associated here rather than in the network module so it can wait for the instance."
}

variable "topology" {
  description = "Rendered topology consumed per node."
  type = map(object({
    name         = string
    prole        = string
    size         = string
    disk_gb      = number
    public       = bool
    subnets      = list(string)
    local_routes = list(string)
    interfaces = list(object({
      subnet  = string
      address = string
      routes  = list(object({ to = string, via = string }))
    }))
  }))
}
