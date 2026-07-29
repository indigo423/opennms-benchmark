variable "storage_pool" { type = string }
variable "ubuntu_cloud_image" { type = string }
variable "admin_user" { type = string }
variable "ssh_public_key" {
  type      = string
  sensitive = true
}
variable "hosts" { type = map(string) }
variable "extra_packages" {
  type    = list(string)
  default = ["qemu-guest-agent"]
}

variable "network_db_id" { type = string }
variable "network_kafka_id" { type = string }
variable "network_sim_id" { type = string }
variable "network_mgmt_id" { type = string }
variable "network_external_id" { type = string }

# Topology (keyed by node); see terraform/kvm/main.tf for how it is derived from
# the deployment spec. One interfaces list per node drives both the cloud-init
# network-config and the libvirt_domain network interfaces (in the same order).
variable "topology" {
  type = map(object({
    vm_name = string
    memory  = number
    vcpu    = number
    disk_gb = number
    interfaces = list(object({
      subnet      = string
      iface_name  = string
      address     = optional(string)
      prefix      = optional(number)
      gateway     = optional(string)
      routes      = optional(list(object({ to = string, via = string })), [])
      nameservers = optional(list(string))
    }))
  }))
}
