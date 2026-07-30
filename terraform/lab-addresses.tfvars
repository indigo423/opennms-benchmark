# Per-host addresses for the fixed-topology providers.
#
# azure, proxmox and vmware hardcode a seven-role lab and address each host
# from these values. kvm declares them too, but only to feed the diagram
# module — it derives the addresses it actually provisions from the deployment
# spec. aws does not read this file at all.
#
# This is the legacy allocation scheme tracked in #161. It is split out so the
# providers that have moved past it do not receive values they deliberately do
# not declare, and so that retiring it is a matter of deleting one file rather
# than picking values out of a shared one.

# Management IPs (subnet-mgmt) — used by Ansible, Prometheus, operator SSH
ip_database      = "192.0.2.196"
ip_core          = "192.0.2.197"
ip_kafka         = "192.0.2.198"
ip_minion        = "192.0.2.199"
ip_monitoring    = "192.0.2.200"
ip_netsim        = "192.0.2.201"
ip_elasticsearch = "192.0.2.202"

# Internal IPs per subnet
ip_database_db  = "192.0.2.4"
ip_core_db      = "192.0.2.5"
ip_kafka_kafka  = "192.0.2.68"
ip_core_kafka   = "192.0.2.69"
ip_minion_kafka = "192.0.2.70"
ip_minion_sim   = "192.0.2.133"
ip_netsim_sim   = "192.0.2.134"
ip_es_core      = "192.0.2.6"

# Next hop for the simulated network. Correct for the fixed-topology providers,
# whose netsim really is at ip_netsim_sim. kvm derives this instead (#171).
net_sim_gateway = "192.0.2.134"

# VM names
vm_names = {
  database      = "db-benchmark-01"
  core          = "core-benchmark-01"
  kafka         = "kafka-benchmark-01"
  minion        = "minion-benchmark-01"
  netsim        = "netsim-benchmark-01"
  monitoring    = "mon-benchmark-01"
  elasticsearch = "es-benchmark-01"
}
