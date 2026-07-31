# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.56"
    }
  }
}

locals {
  # Flatten the topology into one ENI per (node, subnet). `external` is excluded
  # upstream: a public node reaches the internet through an EIP on its mgmt ENI
  # rather than a second interface, because a second default route in the guest
  # is a routing problem the hypervisor providers avoid with a DHCP NIC.
  enis = merge([
    for key, node in var.topology : {
      for iface in node.interfaces :
      "${key}-${iface.subnet}" => {
        node    = key
        subnet  = iface.subnet
        address = iface.address
        primary = iface.subnet == node.subnets[0]
      }
    }
  ]...)
}

resource "aws_vpc" "lab" {
  cidr_block           = var.lab_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

# One subnet per spec subnet, all in a single AZ: an ENI cannot span zones, and
# nodes here are multi-homed across mgmt/db/kafka/sim.
resource "aws_subnet" "lab" {
  for_each = var.subnet_cidrs

  vpc_id            = aws_vpc.lab.id
  cidr_block        = each.value
  availability_zone = var.availability_zone

  tags = { Name = "${var.name_prefix}-${each.key}" }
}

# The lab supernet fills its whole /24, so the public subnet comes from a
# secondary VPC CIDR rather than a slice of it.
resource "aws_vpc_ipv4_cidr_block_association" "public" {
  count = var.needs_public ? 1 : 0

  vpc_id     = aws_vpc.lab.id
  cidr_block = var.public_subnet_cidr
}

# The jump host needs a NIC here, not merely an EIP: an Elastic IP only works
# for an instance whose subnet routes 0.0.0.0/0 at an internet gateway. This
# subnet is also where the NAT gateway lives.
resource "aws_subnet" "public" {
  count = var.needs_public ? 1 : 0

  vpc_id                  = aws_vpc.lab.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  depends_on = [aws_vpc_ipv4_cidr_block_association.public]

  tags = { Name = "${var.name_prefix}-public" }
}

resource "aws_internet_gateway" "lab" {
  count = var.needs_public ? 1 : 0

  vpc_id = aws_vpc.lab.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

# Egress for the lab subnets. Without this every node except the jump host has
# no route off the VPC, and bootstrap fails on the first apt or docker pull:
# an internet gateway only serves instances that hold a public address, and
# only the jump host has one.
resource "aws_eip" "nat" {
  count = var.needs_public ? 1 : 0

  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-nat-eip" }
}

resource "aws_nat_gateway" "lab" {
  count = var.needs_public ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.lab]

  tags = { Name = "${var.name_prefix}-nat" }
}

# Two tables, because one subnet cannot route 0.0.0.0/0 at both an internet
# gateway and a NAT gateway: the public subnet needs the former for the jump
# host's inbound SSH, the lab subnets need the latter for outbound bootstrap.
resource "aws_route_table" "public" {
  count = var.needs_public ? 1 : 0

  vpc_id = aws_vpc.lab.id
  tags   = { Name = "${var.name_prefix}-rt-public" }
}

resource "aws_route" "internet" {
  count = var.needs_public ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.lab[0].id
}

resource "aws_route_table_association" "public" {
  count = var.needs_public ? 1 : 0

  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "${var.name_prefix}-rt" }
}

resource "aws_route" "nat" {
  count = var.needs_public ? 1 : 0

  route_table_id         = aws_route_table.lab.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.lab[0].id
}

# The simulated-device network. netsim answers for every address in this range
# via a local route on loopback, but the VPC will not deliver traffic addressed
# to it — nor accept traffic sourced from it — without both of these:
#
#   1. this route, sending the whole range at netsim's sim interface
#   2. source_dest_check = false on that interface (below)
#
# Neither has an analogue in the hypervisor providers, where the simulated
# network is just a private L2 segment nobody validates.
resource "aws_route" "net_sim" {
  # Guarded on the interface existing, not merely on a simulator being present:
  # a simulator declared without a `sim` NIC would otherwise fail here on an
  # invalid index rather than on the precondition that explains it.
  count = var.netsim_node != null && contains(keys(local.enis), "${var.netsim_node}-sim") ? 1 : 0

  route_table_id         = aws_route_table.lab.id
  destination_cidr_block = var.net_sim_cidr
  network_interface_id   = aws_network_interface.lab["${var.netsim_node}-sim"].id
}

resource "aws_route_table_association" "lab" {
  for_each = aws_subnet.lab

  subnet_id      = each.value.id
  route_table_id = aws_route_table.lab.id
}

resource "aws_security_group" "lab" {
  name        = "${var.name_prefix}-lab"
  description = "Intra-lab traffic, plus operator SSH to the jump host"
  vpc_id      = aws_vpc.lab.id

  tags = { Name = "${var.name_prefix}-lab" }
}

# Everything inside the lab supernet talks freely; this is a benchmark bed, and
# per-service rules would be a second topology to keep in sync with the spec.
resource "aws_vpc_security_group_ingress_rule" "intra_lab" {
  security_group_id = aws_security_group.lab.id
  cidr_ipv4         = var.lab_cidr
  ip_protocol       = "-1"
  description       = "All traffic within the lab supernet"
}

# Simulated devices source traffic from outside the VPC CIDR, so the collectors
# must accept it explicitly.
resource "aws_vpc_security_group_ingress_rule" "net_sim" {
  security_group_id = aws_security_group.lab.id
  cidr_ipv4         = var.net_sim_cidr
  ip_protocol       = "-1"
  description       = "Traffic sourced from simulated devices"
}

resource "aws_vpc_security_group_ingress_rule" "operator_ssh" {
  count = var.needs_public ? 1 : 0

  security_group_id = aws_security_group.lab.id
  cidr_ipv4         = var.operator_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "Operator SSH to the jump host"
}

# Traefik fronts Grafana, Prometheus, Jaeger and Kafka UI on the monitoring
# node over TLS. Without this the lab deploys successfully and every dashboard
# is unreachable. Azure's NSG opens 22 and 443 for the same reason.
resource "aws_vpc_security_group_ingress_rule" "operator_https" {
  count = var.needs_public ? 1 : 0

  security_group_id = aws_security_group.lab.id
  cidr_ipv4         = var.operator_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Operator HTTPS to the lab UIs"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.lab.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All egress"
}

# Static addressing comes from the platform: the address is pinned on the ENI
# and DHCP hands the guest exactly that. This is why network_config_supported
# is false for this provider — the netplan document is unnecessary.
resource "aws_network_interface" "lab" {
  for_each = local.enis

  subnet_id       = aws_subnet.lab[each.value.subnet].id
  private_ips     = [each.value.address]
  security_groups = [aws_security_group.lab.id]

  # netsim forwards for addresses that are not its own in both directions, so
  # the VPC's source/destination validation has to be disabled on its sim NIC.
  source_dest_check = !(each.value.node == var.netsim_node && each.value.subnet == "sim")

  tags = { Name = "${var.name_prefix}-${each.key}" }
}

# The jump host gets an extra interface in the public subnet. An EIP attached
# to a lab-subnet ENI would be inert: that subnet routes 0.0.0.0/0 at the NAT
# gateway, so inbound SSH would never arrive.
resource "aws_network_interface" "jump_public" {
  for_each = { for key, node in var.topology : key => node if node.public }

  subnet_id       = aws_subnet.public[0].id
  security_groups = [aws_security_group.lab.id]

  tags = { Name = "${var.name_prefix}-${each.key}-public" }
}

# Allocated here, associated in the compute module. Associating at allocation
# time attaches the address to an interface whose instance is still pending,
# which AWS rejects with IncorrectInstanceState -- the association has to wait
# for the instance to be running, and only the compute module can express that.
resource "aws_eip" "jump" {
  for_each = { for key, node in var.topology : key => node if node.public }

  domain = "vpc"

  tags = { Name = "${var.name_prefix}-${each.key}-eip" }

  depends_on = [aws_internet_gateway.lab]
}
