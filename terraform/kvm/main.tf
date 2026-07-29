locals {
  # /etc/hosts map (hostname -> mgmt IP) for cloud-init, derived from the topology
  # below so it matches whatever deployment is selected.
  hosts = { for h, v in local.inv_hosts : h => v.ansible_host }

  # Default route for lab VMs is the mgmt network gateway (.1 of subnet_mgmt).
  # The monitoring VM is the exception: it routes out via its DHCP external NIC.
  gateway_mgmt = cidrhost(var.subnet_mgmt, 1)

  # ── deployment spec → kvm topology translation ────────────────────────────
  # Read the provider-agnostic spec (roles/count/size/subnets/groups/routes) and
  # translate it into the provider-specific topology the compute module consumes.
  spec = yamldecode(file("${path.root}/../../deployments/${var.deployment}/topology.yml"))

  # t-shirt size class → libvirt memory (MiB) / vCPU (see deployments/README.md).
  size_map = {
    # tiny exists for wiring/shape test beds only — enough to start a service,
    # not enough to measure one. See deployments/README.md.
    tiny   = { memory = 2048, vcpu = 2 }
    small  = { memory = 4096, vcpu = 2 }
    medium = { memory = 8192, vcpu = 2 }
    large  = { memory = 8192, vcpu = 4 }
    xlarge = { memory = 16384, vcpu = 4 }
  }

  # Spec role → provider role key (identity unless remapped). nl6 runs on netsim.
  provider_role = {
    loadgen = "netsim"
  }

  # Provider role → VM-name prefix ("<prefix>-benchmark-NN").
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

  # Per-subnet base IP offset per provider role; node i gets offset + i.
  # Baseline offsets reproduce the current lab.tfvars addresses exactly.
  # Address allocation: every role gets a contiguous block of role_block_size
  # addresses in every subnet, so a role can scale up to that many nodes without
  # walking into the next role's space.
  #
  # The previous scheme packed roles at adjacent per-subnet offsets, which
  # silently handed two VMs the same address as soon as a role had count > 1:
  # kafka(6) x3 ran into minion(7) and monitoring(8), elasticsearch(10) x3 into
  # sentinel(11) and rrd(12). Only mimir and victoriametrics escaped, because
  # they had been given gaps by hand when they were the multi-node roles that
  # had actually shipped. Deployment A could never have been provisioned.
  #
  # Offsets are now identical across subnets, so a role sits in the same block
  # wherever it appears — one number to reason about instead of four maps.
  role_block_size = 4
  # 0 is the network address and 1 the mgmt gateway; 2-3 are left spare.
  role_block_base = 4
  role_order = [
    "database", "core", "kafka", "minion", "monitoring", "netsim",
    "elasticsearch", "sentinel", "rrd", "mimir", "victoriametrics",
    "clickhouse", "akvorado", "rustfs", "riptide",
  ]
  ip_offset = {
    for i, role in local.role_order : role => local.role_block_base + i * local.role_block_size
  }

  named_routes = {
    net_sim = { to = var.net_sim_cidr, via = var.net_sim_gateway }
  }

  # Expand each spec role into `count` nodes, keyed by provider role (+ -N when >1).
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

  topology = {
    for key, n in local.nodes :
    key => {
      vm_name = "${local.role_shortname[n.prole]}-benchmark-${format("%02d", n.index + 1)}"
      memory  = local.size_map[n.cfg.size].memory
      vcpu    = local.size_map[n.cfg.size].vcpu
      disk_gb = lookup(var.disk_sizes_gb, n.prole, 30)
      interfaces = [
        for si, subnet in n.cfg.subnets : {
          subnet     = subnet
          iface_name = "enp${si + 1}s0"
          # 'lab' is the physical bridge (same libvirt network as external) with a
          # static, spec-supplied address — for VMs an off-hypervisor generator
          # must reach. Specs may also pin addresses on internal subnets.
          address = try(n.cfg.addresses[subnet][n.index],
          contains(["external", "lab"], subnet) ? null : cidrhost(local.subnet_cidr[subnet], local.ip_offset[n.prole] + n.index))
          prefix      = subnet == "external" ? null : (subnet == "lab" ? tonumber(split("/", var.subnet_lab)[1]) : 26)
          gateway     = subnet == "lab" ? cidrhost(var.subnet_lab, 1) : ((subnet == "mgmt" && !try(n.cfg.public_ip, false)) ? local.gateway_mgmt : null)
          nameservers = subnet == "lab" && length(var.lab_nameservers) > 0 ? var.lab_nameservers : null
          # A route value is either the name of a shared route or an inline
          # {to, via}. try() resolves the name first; an inline object fails that
          # lookup and falls through to itself. A conditional cannot express this:
          # both of its branches are type-checked, and for a named route the
          # inline branch is a bare string, which is not a route object.
          routes = try(n.cfg.routes[subnet], null) == null ? [] : [
            try(local.named_routes[n.cfg.routes[subnet]], n.cfg.routes[subnet])
          ]
        }
      ]
    }
  }

  # ── inventory data derived from the topology ──────────────────────────────
  # hostname -> ansible_host (mgmt IP), inventory groups, and host vars.
  inv_hosts = {
    for key, n in local.nodes :
    local.topology[key].vm_name => {
      # mgmt NIC address; "" if a role has no mgmt subnet (caught by the inventory
      # module precondition with a clear message rather than a cryptic index error).
      ansible_host = try([for i in local.topology[key].interfaces : i.address if i.subnet == "mgmt"][0],
      try([for i in local.topology[key].interfaces : i.address if i.subnet == "lab"][0], ""))
      groups = try(n.cfg.groups, [])
      # nl6 runs on the netsim host; expose its sim NIC name for the generator.
      host_vars = n.prole == "netsim" ? {
        nl6_net_interface = try([for i in local.topology[key].interfaces : i.iface_name if i.subnet == "sim"][0], "")
      } : {}
    }
  }

  # Every statically assigned address, used by the uniqueness precondition below.
  all_addresses = flatten([
    for key, n in local.topology : [
      for i in n.interfaces : i.address if i.address != null
    ]
  ])

  # The jump host is the public_ip node (its external DHCP IP is var.jump_host).
  # one() errors if a spec marks more than one node public_ip; null if none.
  jump_node_key  = one([for key, n in local.nodes : key if try(n.cfg.public_ip, false)])
  jump_host_name = local.jump_node_key != null ? local.topology[local.jump_node_key].vm_name : ""

  # Canonical opennms_stack membership. TSDB/flow backends (mimir, victoriametrics,
  # clickhouse, akvorado) are intentionally excluded — OpenNMS writes to them; they
  # are not orchestrated as part of the stack group. Children absent from the
  # selected deployment are dropped by the inventory module.
  onms_stack_children = ["database", "core", "message_broker", "elasticsearch", "minion", "sentinel", "grafana"]
}

module "network" {
  source = "./modules/network"

  subnet_db    = var.subnet_db
  subnet_kafka = var.subnet_kafka
  subnet_sim   = var.subnet_sim
  subnet_mgmt  = var.subnet_mgmt
  bridge_name  = var.bridge_name
}

module "compute" {
  source = "./modules/compute"

  storage_pool        = var.storage_pool
  ubuntu_cloud_image  = var.ubuntu_cloud_image
  admin_user          = var.admin_user
  ssh_public_key      = trimspace(file(pathexpand("${var.ssh_key_path}.pub")))
  hosts               = local.hosts
  network_db_id       = module.network.network_db_id
  network_kafka_id    = module.network.network_kafka_id
  network_sim_id      = module.network.network_sim_id
  network_mgmt_id     = module.network.network_mgmt_id
  network_external_id = module.network.network_external_id
  topology            = local.topology
}

module "diagram" {
  source = "../modules/diagram"

  subnet_mgmt  = var.subnet_mgmt
  subnet_db    = var.subnet_db
  subnet_kafka = var.subnet_kafka
  subnet_sim   = var.subnet_sim

  ip_monitoring    = var.ip_monitoring
  ip_database      = var.ip_database
  ip_core          = var.ip_core
  ip_kafka         = var.ip_kafka
  ip_minion        = var.ip_minion
  ip_netsim        = var.ip_netsim
  ip_elasticsearch = var.ip_elasticsearch

  ip_database_db  = var.ip_database_db
  ip_core_db      = var.ip_core_db
  ip_es_core      = var.ip_es_core
  ip_kafka_kafka  = var.ip_kafka_kafka
  ip_core_kafka   = var.ip_core_kafka
  ip_minion_kafka = var.ip_minion_kafka
  ip_minion_sim   = var.ip_minion_sim
  ip_netsim_sim   = var.ip_netsim_sim

  vm_names = var.vm_names
}

module "inventory" {
  source = "../modules/topology-inventory"

  hosts          = local.inv_hosts
  admin_user     = var.admin_user
  ssh_key_path   = var.ssh_key_path
  jump_host      = var.jump_host
  jump_host_name = local.jump_host_name
  parent_groups  = { opennms_stack = local.onms_stack_children }
}

# Fails the plan if two interfaces are assigned the same address. The previous
# offset scheme did this silently: three hosts shared 192.0.2.200, and the only
# symptom was a jump host that appeared to have no external NIC. A collision
# should stop the plan, not surface hours later as unexplained networking.
resource "terraform_data" "address_uniqueness" {
  input = length(local.all_addresses)

  lifecycle {
    precondition {
      condition     = length(distinct(local.all_addresses)) == length(local.all_addresses)
      error_message = "Duplicate IP addresses in the rendered topology: a role's node count exceeds its address block (role_block_size). Raise role_block_size or re-space local.role_order."
    }
  }
}
