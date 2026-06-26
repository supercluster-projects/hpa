provider "libvirt" {
  uri = "qemu:///system"
}

# talos provider uses caller environment credentials (TALOS_ENDPOINT, TALOS_USERNAME, TALOS_PASSWORD)
# configured dynamically during bootstrap via talos_machine_secrets resources
