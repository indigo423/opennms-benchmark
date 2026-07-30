# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "ubuntu" {
  name = var.ami_ssm_parameter
}

# One lookup per distinct instance type in play, so the ENI ceiling is read from
# AWS rather than assumed. The first real apply failed because t3a.small offers
# two interfaces and minion takes three -- a constraint that had been verified
# against m6i and never re-checked when the cheap tier was added.
data "aws_ec2_instance_type" "selected" {
  for_each = toset(values(local.instance_types))

  instance_type = each.value
}

locals {
  az = var.availability_zone != "" ? var.availability_zone : data.aws_availability_zones.available.names[0]

  name_prefix = "${var.environment}-${var.project_name}"

  # ── deployment spec → aws topology translation ────────────────────────────
  # Same spec the kvm provider consumes. This provider is spec-driven from the
  # first commit: it declares no per-host address variables, so it cannot join
  # the kvm/legacy divergence tracked in #161.
  spec = yamldecode(file("${path.root}/../../deployments/${var.deployment}/topology.yml"))

  # Spec role → provider role key (identity unless remapped). nl6 runs on netsim.
  provider_role = {
    loadgen = "netsim"
  }

  # Inverted, so errors name the role the author writes in topology.yml.
  spec_role_for = { for srole, prole in local.provider_role : prole => srole }

  role_shortname = {
    database   = "db", core = "core", kafka = "kafka", minion = "minion"
    netsim     = "netsim", monitoring = "mon", elasticsearch = "es"
    sentinel   = "sentinel", mimir = "mimir", victoriametrics = "vm"
    clickhouse = "ch", akvorado = "akvorado", rrd = "rrd"
    rustfs     = "rustfs", riptide = "riptide"
  }

  subnet_cidr = {
    mgmt  = var.subnet_mgmt
    db    = var.subnet_db
    kafka = var.subnet_kafka
    sim   = var.subnet_sim
  }

  # Address allocation matches terraform/kvm exactly: every role gets a
  # contiguous block of role_block_size addresses in every subnet. Keeping the
  # two providers on one scheme is the point — a second scheme is how kvm and
  # azure came to disagree (#161).
  role_block_size = 4
  role_block_base = 4
  role_order = [
    "database", "core", "kafka", "minion", "monitoring", "netsim",
    "elasticsearch", "sentinel", "rrd", "mimir", "victoriametrics",
    "clickhouse", "akvorado", "rustfs", "riptide",
  ]
  ip_offset = {
    for i, role in local.role_order : role => local.role_block_base + i * local.role_block_size
  }

  # ── cost profile ──────────────────────────────────────────────────────────
  smoke          = var.cost_profile == "smoke"
  instance_types = local.smoke ? var.instance_types_smoke : var.instance_types

  nodes = merge([
    for srole, cfg in local.spec.roles : {
      for i in range(try(cfg.count, 1)) :
      "${lookup(local.provider_role, srole, srole)}${try(cfg.count, 1) > 1 ? "-${i}" : ""}" => {
        prole = lookup(local.provider_role, srole, srole)
        index = i
        cfg   = cfg
      }
    }
  ]...)

  # Subnets any role in this spec asks for. `external` is the public subnet;
  # `lab` has no VPC analogue and is rejected by the precondition below.
  requested_subnets = distinct(flatten([for key, n in local.nodes : n.cfg.subnets]))
  vpc_subnets       = [for s in local.requested_subnets : s if contains(keys(local.subnet_cidr), s)]
  needs_public      = contains(local.requested_subnets, "external")

  # Single source of truth for "what address does node N hold on subnet S",
  # keyed only by the subnets a node declares. A lookup for an unattached subnet
  # yields nothing rather than a plausible number — the lesson from #171, where
  # two encodings of this rule drifted apart.
  node_address = {
    for key, n in local.nodes : key => {
      for subnet in n.cfg.subnets :
      subnet => try(n.cfg.addresses[subnet][n.index],
      contains(["external", "lab"], subnet) ? null : cidrhost(local.subnet_cidr[subnet], local.ip_offset[n.prole] + n.index))
    }
  }

  nodes_by_prole = {
    for prole in distinct([for key, n in local.nodes : n.prole]) :
    prole => sort([for key, n in local.nodes : key if n.prole == prole])
  }

  # ── the simulated network ─────────────────────────────────────────────────
  # netsim answers for every address in net_sim_cidr. On a hypervisor that is
  # free; in a VPC every source and destination is validated, so this address is
  # needed in TWO places: the guest route on the poller, and the VPC route table
  # entry targeting netsim's ENI. Derived once so the two cannot disagree.
  netsim_key         = try(local.nodes_by_prole["netsim"][0], null)
  netsim_sim_address = try(local.node_address[local.netsim_key]["sim"], null)

  named_routes = {
    net_sim = { to = var.net_sim_cidr, via = local.netsim_sim_address }
  }

  topology = {
    for key, n in local.nodes :
    key => {
      # "benchmark" is literal, matching terraform/kvm. Guest hostnames are a
      # cross-provider contract: deployment overlays reference them directly
      # (vm-single points at vm-benchmark-01, mimir-ha-min at
      # rustfs-benchmark-01), so deriving them from var.environment would break
      # those specs on this provider only. environment names AWS resources and
      # tags, not guests.
      name    = "${local.role_shortname[n.prole]}-benchmark-${format("%02d", n.index + 1)}"
      prole   = n.prole
      size    = n.cfg.size
      disk_gb = local.smoke ? min(lookup(var.disk_sizes_gb, n.prole, 30), var.smoke_max_disk_gb) : lookup(var.disk_sizes_gb, n.prole, 30)
      public  = try(n.cfg.public_ip, false)
      subnets = n.cfg.subnets
      # netsim must accept traffic for the whole simulated range without an
      # address per device: `ip route add local <cidr> dev lo` does that. This
      # is the first consumer of modules/cloud-init's local_routes.
      local_routes = n.prole == "netsim" ? [var.net_sim_cidr] : []
      interfaces = [
        for si, subnet in n.cfg.subnets : {
          subnet  = subnet
          address = local.node_address[key][subnet]
          # A named route resolving to nothing is dropped; the precondition
          # below fails the plan and a null next hop would only obscure it.
          routes = [
            for r in(try(n.cfg.routes[subnet], null) == null ? [] : [
              try(local.named_routes[n.cfg.routes[subnet]], n.cfg.routes[subnet])
            ]) : r
            if !(contains(keys(local.named_routes), try(tostring(n.cfg.routes[subnet]), "")) && try(r.via, null) == null)
          ]
        } if !contains(["external", "lab"], subnet)
      ]
    }
  }

  # hostname -> mgmt address, for /etc/hosts and the Ansible inventory.
  inv_hosts = {
    for key, n in local.nodes :
    local.topology[key].name => {
      ansible_host = try(local.node_address[key]["mgmt"], "")
      groups       = try(n.cfg.groups, [])
      # Derived, not hardcoded: the name follows the position of the sim NIC in
      # the spec's subnet list, so a spec ordering subnets differently does not
      # point the generator at the management interface.
      host_vars = merge(
        # Carried on every host so anything consuming the inventory — a report,
        # an experiment ledger — can tell that a run happened on infrastructure
        # that cannot produce valid numbers.
        { lab_cost_profile = var.cost_profile },
        n.prole == "netsim" ? {
          nl6_net_interface = try("ens${index([for i in local.topology[key].interfaces : i.subnet], "sim") + 5}", "")
        } : {}
      )
    }
  }

  hosts = { for h, v in local.inv_hosts : h => v.ansible_host }

  jump_node_key  = one([for key, n in local.nodes : key if try(n.cfg.public_ip, false)])
  jump_host_name = local.jump_node_key != null ? local.topology[local.jump_node_key].name : ""

  onms_stack_children = ["database", "core", "message_broker", "elasticsearch", "minion", "sentinel", "grafana"]

  # ── spec compatibility ────────────────────────────────────────────────────
  unsupported_lab = [
    for key, n in local.nodes :
    "${lookup(local.spec_role_for, n.prole, n.prole)} declares the 'lab' subnet"
    if contains(n.cfg.subnets, "lab")
  ]

  # A VPC route table entry targets exactly one ENI, so the simulated network
  # can only be served by one node. This matches every existing spec and the
  # reasoning in deployments/README.md: nl6 starts every generator at the same
  # nl6_auto_start_ip, so a second one duplicates rather than extends.
  too_many_generators = try(length(local.nodes_by_prole["netsim"]), 0) > 1

  # A public node carries one extra interface in the public subnet.
  eni_overcommit = [
    for key, n in local.topology :
    "${n.name} on ${local.instance_types[n.size]}: needs ${length(n.interfaces) + (n.public ? 1 : 0)} interfaces, type supports ${data.aws_ec2_instance_type.selected[local.instance_types[n.size]].maximum_network_interfaces}"
    if length(n.interfaces) + (n.public ? 1 : 0) > data.aws_ec2_instance_type.selected[local.instance_types[n.size]].maximum_network_interfaces
  ]

  unresolved_named_routes = distinct(flatten([
    for key, n in local.nodes : [
      for subnet in try(keys(n.cfg.routes), []) :
      "${lookup(local.spec_role_for, n.prole, n.prole)}.${subnet} -> \"${tostring(n.cfg.routes[subnet])}\""
      if contains(keys(local.named_routes), try(tostring(n.cfg.routes[subnet]), "")) && local.named_routes[tostring(n.cfg.routes[subnet])].via == null
    ]
  ]))
}

module "network" {
  source = "./modules/network"

  name_prefix        = local.name_prefix
  lab_cidr           = var.lab_cidr
  availability_zone  = local.az
  subnet_cidrs       = { for s in local.vpc_subnets : s => local.subnet_cidr[s] }
  needs_public       = local.needs_public
  operator_cidr      = var.operator_cidr
  public_subnet_cidr = var.public_subnet_cidr
  topology           = local.topology
  net_sim_cidr       = var.net_sim_cidr
  netsim_node        = local.netsim_key
}

module "compute" {
  source = "./modules/compute"

  name_prefix    = local.name_prefix
  ami_id         = data.aws_ssm_parameter.ubuntu.value
  admin_user     = var.admin_user
  ssh_public_key = trimspace(file(pathexpand("${var.ssh_key_path}.pub")))
  instance_types = local.instance_types

  cost_profile = var.cost_profile

  spot                      = var.spot
  root_volume_type          = var.root_volume_type
  root_volume_iops          = var.root_volume_iops
  root_volume_throughput    = var.root_volume_throughput
  placement_strategy        = var.placement_group_strategy
  hosts                     = local.hosts
  topology                  = local.topology
  network_interface_ids     = module.network.network_interface_ids
  jump_public_interface_ids = module.network.jump_public_interface_ids
  jump_eip_allocation_ids   = module.network.jump_eip_allocation_ids
}

module "inventory" {
  source = "../modules/topology-inventory"

  hosts          = local.inv_hosts
  admin_user     = var.admin_user
  ssh_key_path   = var.ssh_key_path
  jump_host      = module.network.jump_host_public_ip
  jump_host_name = local.jump_host_name
  parent_groups  = { opennms_stack = local.onms_stack_children }
}

# The `lab` subnet is a libvirt physical bridge carrying site-pinned addresses
# and a route via a named machine on that LAN. There is no VPC analogue, and
# approximating one would silently produce a topology that does not match the
# spec. Refuse instead. clickhouse-riptide is the only affected deployment.
resource "terraform_data" "supported_spec" {
  input = length(local.unsupported_lab)

  lifecycle {
    precondition {
      condition     = length(local.unsupported_lab) == 0
      error_message = "Deployment \"${var.deployment}\" cannot run on AWS: ${join("; ", local.unsupported_lab)}. The 'lab' subnet is a physical bridge on the KVM host with site-specific addresses; it has no VPC equivalent. Use PROVIDER=kvm for this deployment."
    }
    precondition {
      condition     = !local.too_many_generators
      error_message = "Deployment \"${var.deployment}\" declares more than one load generator. A VPC route table entry for ${var.net_sim_cidr} targets exactly one network interface, so only one generator can serve the simulated network."
    }
  }
}

# A benchmark whose instances can vanish mid-run, or whose CPU allowance
# depletes partway through, produces numbers that look valid and are not. The
# smoke profile exists precisely so that trade is explicit; taking it silently
# under the benchmark profile is what this refuses.
resource "terraform_data" "measurement_grade" {
  input = var.cost_profile

  lifecycle {
    precondition {
      condition     = !(var.cost_profile == "benchmark" && var.spot)
      error_message = "cost_profile is 'benchmark' but spot is enabled. A spot interruption partway through a run yields a partial result that still looks like a result. Set cost_profile = \"smoke\" if you are testing the stack rather than measuring it."
    }
  }
}

# A console view scoped to exactly this lab. Every resource the provider creates
# carries project/environment/deployment via the provider's default_tags, so a
# tag query is enough -- nothing has to be registered as it is created. Resource
# groups are free, and one per deployment keeps two concurrent labs distinct.
resource "aws_resourcegroups_group" "lab" {
  name = "${local.name_prefix}-${var.deployment}"
  # Resource Groups restricts descriptions to [\sa-zA-Z0-9_.-]; no colons or commas.
  description = "OpenNMS benchmark lab - deployment ${var.deployment} - cost profile ${var.cost_profile}"

  resource_query {
    query = jsonencode({
      ResourceTypeFilters = ["AWS::AllSupported"]
      TagFilters = [
        { Key = "project", Values = [var.project_name] },
        { Key = "environment", Values = [var.environment] },
        { Key = "deployment", Values = [var.deployment] },
      ]
    })
  }
}

# Fails the plan when a node needs more interfaces than its instance type can
# attach. This surfaced as AttachmentLimitExceeded halfway through the first
# real apply, after the VPC and every ENI had already been created -- the sort
# of failure that is cheap at plan time and irritating at apply time.
resource "terraform_data" "eni_budget" {
  input = length(local.eni_overcommit)

  lifecycle {
    precondition {
      condition     = length(local.eni_overcommit) == 0
      error_message = "Deployment \"${var.deployment}\" asks for more network interfaces than the chosen instance types can attach:\n  ${join("\n  ", local.eni_overcommit)}\nRaise the type in instance_types (or instance_types_smoke), or reduce the role's subnets."
    }
  }
}

# Fails the plan when a named route's next hop does not resolve — the role is
# absent, or present without the NIC the route needs. Both would render an
# address no node holds, which is #171.
resource "terraform_data" "named_route_targets" {
  input = length(local.unresolved_named_routes)

  lifecycle {
    precondition {
      condition     = length(local.unresolved_named_routes) == 0
      error_message = "Deployment \"${var.deployment}\" declares named routes whose next hop does not resolve: ${join("; ", local.unresolved_named_routes)}. The route needs a generator with a 'sim' NIC in the same spec."
    }
  }
}
