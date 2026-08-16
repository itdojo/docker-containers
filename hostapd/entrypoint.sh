#!/bin/bash
set -e

echo "Initializing container with environment variables..."
export AP_IFACE=${AP_IFACE:-wlan1}
export TO_INTERNET_IFACE=${TO_INTERNET_IFACE:-eth0}
export SSID=${SSID:-dojo-ap}
# config/hostapd.conf substitutes $WPA_PASSPHRASE, so that is the name that has
# to be exported — an AP_PASSPHRASE default never reached the template and left
# wpa_passphrase empty. No default on purpose: a fallback here would silently
# stand up an open-to-anyone-who-knows-it AP. Fail loudly instead.
: "${WPA_PASSPHRASE:?is unset — set it in .env (8-63 characters)}"
export WPA_PASSPHRASE
export CHANNEL=${CHANNEL:-1}
export LISTEN_ADDRESS=${LISTEN_ADDRESS:-172.16.16.1}
export DHCP_RANGE_START=${DHCP_RANGE_START:-172.16.16.100}
export DHCP_RANGE_END=${DHCP_RANGE_END:-172.16.16.200}
export DHCP_LEASE_TIME=${DHCP_LEASE_TIME:-12h}
export DNS_TO_SERVE=${DNS_TO_SERVE:-1.1.1.1}

echo "Assigning IP address $LISTEN_ADDRESS to $AP_IFACE..."
ip addr add "$LISTEN_ADDRESS"/24 dev "$AP_IFACE" || true  # Ignore errors if IP already exists
ip link set "$AP_IFACE" up

echo "Generating /etc/dnsmasq.conf..."
envsubst < /config_templates/dnsmasq.conf > /etc/dnsmasq.conf
#cat /etc/dnsmasq.conf  

echo "Generating /etc/hostapd/hostapd.conf..."
envsubst < /config_templates/hostapd.conf > /etc/hostapd/hostapd.conf
#cat /etc/hostapd/hostapd.conf

echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1

echo "Setting up NAT..."
iptables -t nat -A POSTROUTING -o "$TO_INTERNET_IFACE" -j MASQUERADE
iptables -A FORWARD -i "$TO_INTERNET_IFACE" -o "$AP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i "$AP_IFACE" -o "$TO_INTERNET_IFACE" -j ACCEPT

echo "Starting dnsmasq..."
dnsmasq -C /etc/dnsmasq.conf

echo "Starting hostapd..."
hostapd /etc/hostapd/hostapd.conf

echo "Starting supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
