#!/usr/bin/env bash
# Renders the ISE Azure custom-data file: the plain key=value answer file
# Cisco's ISE Marketplace image reads at first boot (hostname, network,
# DNS, NTP, timezone, ERS/OpenAPI, and the admin password). Not cloud-init,
# but the same idea: az hands it to the VM once, unread by anything else.
#
#   source scripts/lib/ise-userdata.sh
#   render_ise_userdata OUT_FILE
#
# Required in the environment (already sourced from config/mcp-env/ise.env
# by the caller): ISE_HOSTNAME, ISE_ADMIN_PASSWORD, ISE_PRIVATE_IP, and
# APPS_SUBNET_CIDR (resolved by the caller from the persistent root's
# apps_subnet_cidr output, ADR 0003).
#
# Optional, defaulted for a lab with no site DNS or NTP of its own:
# ISE_DNS_SERVER (Azure's built-in recursive resolver, reachable from
# every VNet with no internet route needed), ISE_DNS_DOMAIN,
# ISE_NTP_SERVER, ISE_TIMEZONE.
#
# The admin password reaches this function only through the environment,
# never a function argument, so it is never visible in a process listing
# or an xtrace of the caller. The file is created with a restrictive
# umask before any content lands in it, then chmod 600 again to be sure.
# ADR 0004: no secret in a tracked file; this output path is gitignored.
#
# Must stay bash 3.2 compatible: this runs on macOS.

# netmask_for_cidr CIDR: dotted-decimal netmask for a CIDR's prefix
# length, e.g. 10.20.2.0/24 -> 255.255.255.0.
netmask_for_cidr() {
  python3 -c '
import ipaddress, sys
print(ipaddress.ip_network(sys.argv[1], strict=False).netmask)
' "$1"
}

# gateway_for_cidr CIDR: the network address plus one. Azure reserves
# this address as the implicit gateway on every subnet it creates.
gateway_for_cidr() {
  python3 -c '
import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1], strict=False)
print(net.network_address + 1)
' "$1"
}

render_ise_userdata() {
  local out_file="$1" mask gw
  : "${ISE_HOSTNAME:?ISE_HOSTNAME not set, see config/ise.env.example}"
  : "${ISE_ADMIN_PASSWORD:?ISE_ADMIN_PASSWORD not set, see config/mcp-env/ise.env}"
  : "${ISE_PRIVATE_IP:?ISE_PRIVATE_IP not set, see config/ise.env.example}"
  : "${APPS_SUBNET_CIDR:?APPS_SUBNET_CIDR not set, resolve it from terraform/persistent first}"
  mask="$(netmask_for_cidr "${APPS_SUBNET_CIDR}")"
  gw="$(gateway_for_cidr "${APPS_SUBNET_CIDR}")"
  (
    umask 077
    cat > "${out_file}" <<EOF
hostname=${ISE_HOSTNAME}
ipv4address=${ISE_PRIVATE_IP}
ipv4netmask=${mask}
ipv4gateway=${gw}
primarynameserver=${ISE_DNS_SERVER:-168.63.129.16}
dnsdomain=${ISE_DNS_DOMAIN:-cml-lab.local}
ntpserver=${ISE_NTP_SERVER:-pool.ntp.org}
timezone=${ISE_TIMEZONE:-Etc/UTC}
password=${ISE_ADMIN_PASSWORD}
ersapi=yes
openapi=yes
EOF
  )
  chmod 600 "${out_file}"
}
