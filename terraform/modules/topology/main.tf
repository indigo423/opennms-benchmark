terraform {
  required_version = ">= 1.5"
}

# The provider-agnostic half of the deployment spec -> topology translation:
# which nodes exist, what address each holds on each subnet, and where a named
# route's next hop actually is.
#
# It stops short of rendering a provider's topology map, because that shape is
# genuinely provider-specific -- kvm needs memory/vcpu and an interface name,
# aws needs an instance size and a public flag, proxmox needs a bridge and a VM
# id. Forcing one shape on all three would trade this duplication for a worse
# one. What lives here is the part where a second copy is a defect rather than a
# difference: the address allocation and the route resolution, whose last drift
# was #171.

locals {
  # Expand each spec role into `count` nodes, keyed by provider role (+ -N when >1).
  nodes = merge([
    for srole, cfg in var.spec.roles : {
      for i in range(try(cfg.count, 1)) :
      "${lookup(var.provider_role, srole, srole)}${try(cfg.count, 1) > 1 ? "-${i}" : ""}" => {
        prole = lookup(var.provider_role, srole, srole)
        index = i
        cfg   = cfg
      }
    }
  ]...)

  # Every role gets a contiguous block of role_block_size addresses in every
  # subnet. Offsets are identical across subnets, so a role sits in the same
  # block wherever it appears -- one number to reason about instead of four maps.
  ip_offset = {
    for i, role in var.role_order : role => var.role_block_base + i * var.role_block_size
  }

  # The single source of truth for "what address does node N hold on subnet S".
  # Keyed only by the subnets a node actually declares, so a lookup for a subnet
  # the node is not attached to returns nothing rather than a plausible number.
  node_address = {
    for key, n in local.nodes : key => {
      for subnet in n.cfg.subnets :
      subnet => try(n.cfg.addresses[subnet][n.index],
      contains(var.unaddressed_subnets, subnet) ? null : cidrhost(var.subnet_cidr[subnet], local.ip_offset[n.prole] + n.index))
    }
  }

  # Spec role -> provider role is many-to-one (loadgen -> netsim). Invert it so
  # errors name the role the author actually writes in topology.yml.
  spec_role_for = { for srole, prole in var.provider_role : prole => srole }

  # Node keys per provider role, sorted so selection is stable across plans.
  nodes_by_prole = {
    for prole in distinct([for key, n in local.nodes : n.prole]) :
    prole => sort([for key, n in local.nodes : key if n.prole == prole])
  }

  named_routes = {
    for name, r in var.named_route_spec :
    name => {
      to = r.to
      # null when the role is absent, or present but not attached to the subnet
      # the route needs. Both cases are caught by the caller's preconditions.
      via = try(local.node_address[local.nodes_by_prole[r.role][0]][r.subnet], null)
    }
  }

  # Routes normalised once per node, so nothing below re-guards an absent or
  # non-mapping `routes:`. Reading n.cfg.routes inside the body was a real bug
  # (fixed in aa24178 before this module existed, and carried here rather than
  # lost to the extraction): the iteration is already empty for a node without
  # routes, but HCL evaluates the `if` clause's operands regardless of the guard
  # in front of them, so the access still errored with "n.cfg is object with 4
  # attributes".
  #
  # It survived on Terraform 1.12 and failed on the version CI resolves for
  # `~1.5`, so `make validate-topology` passed locally and failed in CI on the
  # same tree. A render-diff against a baseline cannot catch this class either,
  # for the same reason: both sides evaluate fine on the newer runtime.
  node_routes = { for key, n in local.nodes : key => try(n.cfg.routes, {}) }

  # Named routes a spec declares whose next hop did not resolve -- the role is
  # absent, or present without the NIC the route needs. Both render an address
  # no node holds, which is #171.
  #
  # Both operands of the `&&` are evaluable without error, deliberately. The
  # logical result is unchanged -- a route name absent from named_route_spec
  # still yields false -- but neither side can blow up when the other would have
  # excluded it, whatever a given Terraform version does about short-circuiting.
  unresolved_named_routes = distinct(flatten([
    for key, n in local.nodes : [
      for subnet in try(keys(local.node_routes[key]), []) :
      "${lookup(local.spec_role_for, n.prole, n.prole)}.${subnet} -> \"${tostring(local.node_routes[key][subnet])}\" needs a \"${lookup(local.spec_role_for, var.named_route_spec[tostring(local.node_routes[key][subnet])].role, var.named_route_spec[tostring(local.node_routes[key][subnet])].role)}\" role with a \"${var.named_route_spec[tostring(local.node_routes[key][subnet])].subnet}\" NIC"
      if contains(keys(var.named_route_spec), try(tostring(local.node_routes[key][subnet]), "")) && try(local.named_routes[tostring(local.node_routes[key][subnet])].via, null) == null
    ]
  ]))

  # Every address any node holds, on any subnet. Derived from the node model
  # rather than from a provider's rendered topology, so the topology check can
  # assert against it identically on every spec-driven provider -- the check
  # previously read a kvm-only local and so could only ever run there.
  all_addresses = flatten([
    for key, addrs in local.node_address : [
      for subnet, a in addrs : a if a != null
    ]
  ])

  # Disk per node, in priority order: what the spec asks for, then the per-role
  # pin, then a flat default. A spec can therefore size its own disks -- which is
  # what lets a small topology actually be small, rather than inheriting a
  # benchmark-scale core disk it will never fill.
  #
  # The last entry is deliberately NOT derived from the size class. See
  # disk_default_gb: doing so resizes every previously unpinned role, and a
  # capacity change replaces a libvirt volume.
  disk_gb = {
    for key, n in local.nodes :
    key => try(
      n.cfg.disk_gb,
      var.disk_sizes_gb[n.prole],
      var.disk_default_gb,
    )
  }

  # Guest hostnames are a cross-provider contract: deployment overlays reference
  # them literally (vm-single points at vm-benchmark-01), so they are built here
  # rather than per provider. "benchmark" is deliberately literal and does not
  # follow var.environment, which names provider resources rather than guests.
  vm_name = {
    for key, n in local.nodes :
    key => "${var.role_shortname[n.prole]}-benchmark-${format("%02d", n.index + 1)}"
  }
}
