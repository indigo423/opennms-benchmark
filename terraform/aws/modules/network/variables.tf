# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0

variable "name_prefix" { type = string }
variable "lab_cidr" { type = string }
variable "availability_zone" { type = string }

variable "subnet_cidrs" {
  type        = map(string)
  description = "Spec subnet name -> CIDR, for the subnets this deployment actually uses."
}

variable "needs_public" {
  type        = bool
  description = "Whether any node is marked public_ip, requiring an internet gateway and an EIP."
}

variable "operator_cidr" { type = string }

variable "public_subnet_cidr" {
  type        = string
  description = "CIDR for the public subnet, added to the VPC as a secondary block. The lab supernet fills its whole /24, so this cannot be a slice of it. Hosts the NAT gateway and the jump host's internet-facing NIC."
}
variable "net_sim_cidr" { type = string }

variable "netsim_node" {
  type        = string
  default     = null
  description = "Node key of the simulator, or null when the deployment has none. Its sim interface is the route target for net_sim_cidr and the only one with source/dest checking disabled."
}

variable "topology" {
  description = "Rendered topology: node key -> { name, subnets, public, interfaces[{subnet, address, routes}] }."
  type = map(object({
    name    = string
    subnets = list(string)
    public  = bool
    interfaces = list(object({
      subnet  = string
      address = string
      routes  = list(object({ to = string, via = string }))
    }))
  }))
}
