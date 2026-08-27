locals {
  spec = yamldecode(file("${path.root}/../../deployments/${var.deployment}/topology.yml"))

  # t-shirt size class → memory (MiB) / vCPU. Same classes as terraform/kvm, and
  # deliberately the same numbers: a spec that means "medium" has to mean the
  # same thing on both, or a result carried between them describes nothing.
  size_map = {
    tiny   = { memory = 2048, vcpu = 2 }
    small  = { memory = 4096, vcpu = 2 }
    medium = { memory = 8192, vcpu = 2 }
    large  = { memory = 8192, vcpu = 4 }
    xlarge = { memory = 16384, vcpu = 4 }
  }

  subnet_cidr = {
    mgmt  = var.subnet_mgmt
    db    = var.subnet_db
    kafka = var.subnet_kafka
    sim   = var.subnet_sim
  }

  # Subnet → Proxmox bridge. The bridge carrying the hypervisor's own uplink is
  # `external`, NOT `mgmt`: on a single-uplink host that is the interface the
  # operator is connected over, and claiming it for a lab subnet cuts off the
  # host. bootstrap/roles/proxmox_hypervisor asserts against exactly that.
  subnet_bridge = {
    mgmt     = var.bridge_mgmt
    db       = var.bridge_db
    kafka    = var.bridge_kafka
    sim      = var.bridge_sim
    external = var.bridge_ext
  }

  # Default route for lab nodes is the management gateway. Nothing on Proxmox
  # supplies that address -- a Linux bridge is a layer 2 switch -- so the
  # hypervisor holds it and routes, which is what the prep role sets up. A node
  # with a public_ip routes out via its external NIC instead.
  gateway_mgmt = cidrhost(var.subnet_mgmt, 1)

  # ── deployment spec → node model ──────────────────────────────────────────
  nodes                   = module.topology.nodes
  node_address            = module.topology.node_address
  named_routes            = module.topology.named_routes
  unresolved_named_routes = module.topology.unresolved_named_routes
  all_addresses           = module.topology.all_addresses

  # Proxmox implements every subnet in the spec vocabulary that this lab uses:
  # the four internal ones as uplink-less bridges, and `external` as the
  # hypervisor's own bridge. `lab` is the exception -- it means a physical
  # network an off-hypervisor generator can reach, with site-specific addresses,
  # and this provider has no such concept.
  spec_unsupported = [
    for key, n in local.nodes :
    "${lookup(module.topology.spec_role_for, n.prole, n.prole)} declares the 'lab' subnet"
    if contains(n.cfg.subnets, "lab")
  ]

  # VM ids derive from the same role blocks as addresses, so two nodes cannot
  # collide as a role's count grows -- the defect that made the old static
  # role→id map unusable for any spec with count > 1. Offsets come from the
  # shared module rather than a second copy of the scheme.
  vm_id = {
    for key, n in local.nodes :
    key => var.vm_id_base + module.topology.ip_offset[n.prole] + n.index
  }

  topology = {
    for key, n in local.nodes :
    key => {
      vm_name = module.topology.vm_name[key]
      vm_id   = local.vm_id[key]
      memory  = local.size_map[n.cfg.size].memory
      vcpu    = local.size_map[n.cfg.size].vcpu
      disk_gb = module.topology.disk_gb[key]
      # Deliberately empty, including for netsim. nl6 >= v0.21 owns the
      # simulated range's host routing: it runs privileged with host networking
      # and routes the range into its own namespace via a veth pair. An
      # `ip route add local <cidr> dev lo` on netsim makes the kernel consult
      # the local table first, so that route swallows every SNMP packet and
      # nl6's devices never see it. Signature: snmpget times out on netsim
      # itself while the nl6 API reports the fleet running, and the pm sweep's
      # nodes_seen sticks at 2 while the fleet grows. Verified empirically on
      # AWS (2026-08-07); terraform/kvm sets none either.
      local_routes = []
      interfaces = [
        for si, subnet in n.cfg.subnets : {
          subnet = subnet
          # lookup() rather than an index: a spec on an unsupported subnet must
          # still render, or spec_unsupported below can never be read and the
          # operator gets "Invalid index ... object with 5 attributes" instead of
          # "use PROVIDER=kvm for this deployment". The precondition is what
          # actually blocks the apply.
          bridge = lookup(local.subnet_bridge, subnet, null)
          # ens18 is the first NIC in a Proxmox guest at PVE's DEFAULT machine
          # type (i440fx), ens19 the second, and so on. This does NOT hold for
          # machine=q35, where the same NIC lands on a PCIe bridge and appears
          # as enp6s18: netplan then configures a device that does not exist,
          # the guest sends no frames, and Terraform times out waiting for an
          # agent that can never install. The machine type lives in the
          # hand-built template, so nothing here can check it.
          iface_name = "ens${18 + si}"
          address    = local.node_address[key][subnet]
          prefix     = subnet == "external" ? null : 26
          gateway    = (subnet == "mgmt" && !try(n.cfg.public_ip, false)) ? local.gateway_mgmt : null
          # Resolves a named route first; an inline {to, via} fails that lookup
          # and falls through to itself. A conditional cannot express this: both
          # branches are type-checked, and for a named route the inline branch
          # is a bare string.
          routes = [
            for r in(try(n.cfg.routes[subnet], null) == null ? [] : [
              try(local.named_routes[n.cfg.routes[subnet]], n.cfg.routes[subnet])
            ]) : r
            if !(contains(keys(local.named_routes), try(tostring(n.cfg.routes[subnet]), "")) && try(r.via, null) == null)
          ]
          nameservers = null
        }
      ]
    }
  }

  hosts = { for h, v in local.inv_hosts : h => v.ansible_host }

  # ── inventory data derived from the topology ──────────────────────────────
  inv_hosts = {
    for key, n in local.nodes :
    local.topology[key].vm_name => {
      ansible_host = try([for i in local.topology[key].interfaces : i.address if i.subnet == "mgmt"][0], "")
      groups       = try(n.cfg.groups, [])
      host_vars = merge(
        # lab_<subnet>_ip, matching kvm and aws, because that is what the
        # consumers read: opennms-lab-vars.yml uses lab_db_ip and lab_kafka_ip,
        # and bootstrap/roles/kafka_ui uses lab_kafka_ip. Emitting
        # lab_address_<subnet> instead meant every lookup missed and fell back
        # to lab_mgmt_ip, so OpenNMS reached Postgres and Kafka over the
        # management subnet rather than their own -- silently, because the
        # fallback exists and the deploy succeeds. A run like that is not
        # comparable with kvm or aws, which is the point of the subnet split.
        #
        # mgmt is excluded because topology-inventory already emits it as
        # lab_mgmt_ip; emitting it here too would duplicate the YAML key.
        {
          for i in local.topology[key].interfaces :
          "lab_${i.subnet}_ip" => i.address
          if i.address != null && i.subnet != "mgmt"
        },
        n.prole == "netsim" ? {
          nl6_net_interface = try([for i in local.topology[key].interfaces : i.iface_name if i.subnet == "sim"][0], "")
        } : {},
      )
    }
  }

  # Parent group matching terraform/kvm, so an inventory from either provider
  # presents the same group tree to the plays.
  onms_stack_children = ["database", "core", "message_broker", "elasticsearch", "minion", "sentinel", "grafana"]

  jump_node_key  = one([for key, n in local.nodes : key if try(n.cfg.public_ip, false)])
  jump_host_name = local.jump_node_key != null ? local.topology[local.jump_node_key].vm_name : ""
}

# Shared with terraform/kvm and terraform/aws.
module "topology" {
  source = "../modules/topology"

  spec          = local.spec
  subnet_cidr   = local.subnet_cidr
  disk_sizes_gb = var.disk_sizes_gb

  named_route_spec = {
    net_sim = { to = var.net_sim_cidr, role = "netsim", subnet = "sim" }
  }
}

module "compute" {
  source = "./modules/compute"

  topology           = local.topology
  proxmox_node       = var.proxmox_node
  template_vm_id     = var.template_vm_id
  storage_pool       = var.storage_pool
  snippets_datastore = var.snippets_datastore
  admin_user         = var.admin_user
  ssh_public_key     = trimspace(file(pathexpand("${var.ssh_key_path}.pub")))
  hosts              = local.hosts
}

# Preconditions live on terraform_data rather than in the module block: a module
# block cannot carry a lifecycle stanza. Same pattern as terraform/kvm.

# Fails the plan if the spec cannot be provisioned on this provider at all.
resource "terraform_data" "spec_supported" {
  input = length(local.spec_unsupported)

  lifecycle {
    precondition {
      condition     = length(local.spec_unsupported) == 0
      error_message = "Deployment \"${var.deployment}\" cannot run on Proxmox: ${join("; ", local.spec_unsupported)}. The 'lab' subnet is a physical network with site-specific addresses; this provider has no equivalent. Use PROVIDER=kvm for this deployment."
    }
  }
}

# Fails the plan if two interfaces are handed the same address.
resource "terraform_data" "address_uniqueness" {
  input = length(local.all_addresses)

  lifecycle {
    precondition {
      condition     = length(distinct(local.all_addresses)) == length(local.all_addresses)
      error_message = "Duplicate IP addresses in the rendered topology: a role's node count exceeds its address block (role_block_size). Raise role_block_size or re-space role_order in ../modules/topology."
    }
  }
}

# Fails the plan if two nodes are handed the same Proxmox VM id. Distinct from
# the address check even though both derive from the same blocks: vm_id_base
# could be set so ids collide with the template, which addresses cannot.
resource "terraform_data" "vm_id_uniqueness" {
  input = length(local.vm_id)

  lifecycle {
    precondition {
      condition     = length(distinct(values(local.vm_id))) == length(local.vm_id)
      error_message = "Duplicate Proxmox VM ids in the rendered topology. Ids derive from the same role blocks as addresses, so raising role_block_size in ../modules/topology fixes both."
    }

    precondition {
      condition     = !contains(values(local.vm_id), var.template_vm_id)
      error_message = "A node's VM id collides with template_vm_id (${var.template_vm_id}). Move vm_id_base: with the default role blocks the highest id is vm_id_base + 51."
    }
  }
}

# Fails the plan if a named route's next hop does not resolve.
resource "terraform_data" "named_route_targets" {
  input = length(local.unresolved_named_routes)

  lifecycle {
    precondition {
      condition     = length(local.unresolved_named_routes) == 0
      error_message = "Deployment \"${var.deployment}\" declares named routes whose next hop does not resolve:\n  ${join("\n  ", local.unresolved_named_routes)}\nAdd the role, give it the required NIC, or use an inline { to, via } route if the next hop is outside this topology."
    }
  }
}

module "inventory" {
  source = "../modules/topology-inventory"

  hosts          = local.inv_hosts
  parent_groups  = { opennms_stack = local.onms_stack_children }
  admin_user     = var.admin_user
  ssh_key_path   = var.ssh_key_path
  jump_host      = var.jump_host
  jump_host_name = local.jump_host_name
}
