# KVM-specific variables
libvirt_uri        = "qemu+ssh://root@your-kvm.host/system" # Remote: "qemu+ssh://user@host/system"
storage_pool       = "default"
ubuntu_cloud_image = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
ssh_key_path       = "~/.ssh/id_rsa"
admin_user         = "ubuntu" # Ubuntu cloud image default user
bridge_name        = "br0"    # Host bridge for external DHCP access on monintoring VM
# jump_host        = ""      # Auto-discovered by deploy.sh from virsh domifaddr after VM boot
# Set manually only if auto-discovery fails: jump_host = "10.0.0.42"
