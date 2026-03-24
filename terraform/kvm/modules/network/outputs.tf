output "network_db_id" { value = libvirt_network.db.name }
output "network_kafka_id" { value = libvirt_network.kafka.name }
output "network_sim_id" { value = libvirt_network.sim.name }
output "network_mgmt_id" { value = libvirt_network.mgmt.name }
output "network_external_id" { value = libvirt_network.external.name }
