# Disk sizes in GB per VM role — applies to kvm, proxmox, and vmware providers.
# Not used by azure (Azure manages disk size via VM SKU / storage account type).
# Pass alongside lab.tfvars: -var-file=../disk-sizes.tfvars

disk_sizes_gb = {
  database      = 50
  core          = 100
  kafka         = 50
  minion        = 20
  netsim        = 20
  monitoring    = 30
  elasticsearch = 50
}
