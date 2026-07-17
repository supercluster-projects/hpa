# Local computed values for the Talos cluster provisioning
# Defines node naming, IP assignment, cluster endpoint, and base image URL.
# NOTE: This file re-exports values from network-variables.tf for backwards compatibility.
# The network-variables.tf file contains all the canonical definitions in a single locals block.

# These are just documentation notes - the actual values are in network-variables.tf
# locals.gateway     = local.gateway  # from network-variables.tf
# locals.dns_servers = local.dns_servers  # from network-variables.tf
# locals.cidr_prefix = local.cidr_prefix  # from network-variables.tf