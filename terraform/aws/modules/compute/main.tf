# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

resource "aws_key_pair" "lab" {
  key_name   = "${var.name_prefix}-key"
  public_key = var.ssh_public_key
}

# Packs instances close together for consistent, low inter-node latency. A
# distributed benchmark measuring replication or flow throughput is otherwise
# reading placement variance as a result.
#
# Benchmark profile only. Cluster placement is not supported by burstable
# instance types at all, and a wiring test has nothing to gain from latency
# guarantees -- attaching one to a t3a instance fails the RunInstances call.
resource "aws_placement_group" "lab" {
  count = var.cost_profile == "benchmark" ? 1 : 0

  name     = "${var.name_prefix}-pg"
  strategy = var.placement_strategy
}

module "cloud_init" {
  for_each = var.topology
  source   = "../../../modules/cloud-init"

  vm_name        = each.value.name
  admin_user     = var.admin_user
  ssh_public_key = var.ssh_public_key
  hosts          = var.hosts

  # EC2 delivers only user-data — there is no separate network-config channel
  # as on libvirt. It does not need one: the address is pinned on the ENI and
  # arrives over DHCP. Static routes ride in user-data as a systemd unit, the
  # same path Azure uses.
  network_config_supported = false

  # netsim answers for every simulated device. `ip route add local <cidr> dev lo`
  # makes the kernel accept the whole range without an address per device, which
  # is the only way this works inside a VPC: an ENI cannot carry ~1000 secondary
  # addresses. This is the first place in the repo that passes local_routes.
  local_routes = each.value.local_routes

  interfaces = [
    for idx, iface in each.value.interfaces : {
      name    = "ens${idx + 5}"
      address = iface.address
      prefix  = 26
      gateway = null
      routes  = iface.routes
    }
  ]
}

resource "aws_instance" "lab" {
  for_each = var.topology

  ami                         = var.ami_id
  instance_type               = var.instance_types[each.value.size]
  key_name                    = aws_key_pair.lab.key_name
  placement_group             = var.cost_profile == "benchmark" ? aws_placement_group.lab[0].name : null
  user_data                   = module.cloud_init[each.key].user_data
  user_data_replace_on_change = true

  # Interface 0 is the node's first declared subnet; the rest attach in spec
  # order, which is what the ens5, ens6, … naming above assumes.
  dynamic "network_interface" {
    for_each = each.value.interfaces
    content {
      network_interface_id = var.network_interface_ids["${each.key}-${network_interface.value.subnet}"]
      device_index         = network_interface.key
    }
  }

  # The public NIC attaches last, so it never shifts the index of a lab NIC and
  # the predictable ens5/ens6/… names stay aligned with the spec's subnet order.
  dynamic "network_interface" {
    for_each = contains(keys(var.jump_public_interface_ids), each.key) ? [1] : []
    content {
      network_interface_id = var.jump_public_interface_ids[each.key]
      device_index         = length(each.value.interfaces)
    }
  }

  root_block_device {
    volume_size = each.value.disk_gb
    volume_type = var.root_volume_type
    iops        = var.root_volume_type == "gp3" ? var.root_volume_iops : null
    throughput  = var.root_volume_type == "gp3" ? var.root_volume_throughput : null

    tags = { Name = "${each.value.name}-root" }
  }

  # Spot is refused under the benchmark profile: an interruption partway
  # through a run produces a partial result that still looks like a result.
  dynamic "instance_market_options" {
    for_each = var.spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        instance_interruption_behavior = "terminate"
        spot_instance_type             = "one-time"
      }
    }
  }

  tags = {
    Name         = each.value.name
    role         = each.value.prole
    cost-profile = var.cost_profile
  }
}

# The instance must be running before its address can be attached; aws_instance
# only returns once it is, so depending on it is what makes this correct.
resource "aws_eip_association" "jump" {
  for_each = var.jump_eip_allocation_ids

  allocation_id        = each.value
  network_interface_id = var.jump_public_interface_ids[each.key]

  depends_on = [aws_instance.lab]
}
