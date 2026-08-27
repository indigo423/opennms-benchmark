variable "topology" {
  type = map(object({
    vm_name = string
    vm_id   = number
    memory  = number
    vcpu    = number
    disk_gb = number
    interfaces = list(object({
      subnet      = string
      bridge      = string
      iface_name  = string
      address     = optional(string)
      prefix      = optional(number)
      gateway     = optional(string)
      routes      = optional(list(object({ to = string, via = string })), [])
      nameservers = optional(list(string))
    }))
    local_routes = optional(list(string), [])
  }))
  description = "Rendered topology, one entry per node. Built in the provider root from ../../modules/topology plus the Proxmox-specific bridge, VM id and interface naming."
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node name that hosts the VMs"
}

variable "template_vm_id" {
  type        = number
  description = "VM ID of the cloud-init template to full-clone. Its machine type does not matter: proxmox_machine is set on the VM and overrides it."
}

variable "proxmox_machine" {
  type        = string
  description = "QEMU machine type. Set explicitly rather than inherited from the template, because the guest's NIC names depend on it."
}

variable "storage_pool" {
  type        = string
  description = "Datastore for VM disks"
}

variable "snippets_datastore" {
  type        = string
  description = "File-based datastore for cloud-init snippets. Must permit the 'snippets' content type, which a default PVE installation does not enable."
}

variable "admin_user" {
  type        = string
  description = "Admin username injected into cloud-init"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key for the admin user"
}

variable "hosts" {
  type        = map(string)
  description = "Hostname -> management IP, for /etc/hosts injection"
}

variable "extra_packages" {
  type        = list(string)
  default     = ["qemu-guest-agent"]
  description = "Packages cloud-init installs on every node. qemu-guest-agent is not optional here: the provider waits for the agent to report an address."
}
