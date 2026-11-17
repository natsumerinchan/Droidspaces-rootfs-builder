# ImmortalWrt 24.10 minimal rootfs for Droidspaces macvlan side-router mode.
# Android kernels lack nf_tables, so this drops fw4/nftables for iptables-legacy
# + fw3.
#
# MACVLAN SIDE-ROUTER MODE (IPv6 PROXYING ENABLED):
#   - Container joins the upstream LAN (e.g. 192.168.1.0/24) via a macvlan
#     interface on eth0. It is a peer on the LAN, not a NAT router.
#   - LAN IP is STATIC so clients can reliably point their gateway/DNS at it.
#   - DHCPv4 is DISABLED. The main router keeps handing out IPv4 addresses.
#   - DHCPv6 is DISABLED (no address assignment). RA is ENABLED with
#     ra_default=2 so the side-router advertises itself as the IPv6 default
#     gateway. Clients keep the global IPv6 addresses they got from the main
#     router's SLAAC, but their default route points here.
#   - No masquerade, no NAT66, no ULA. IPv6 is forwarded, not translated.
#   - Clients must accept this router's RA (or have their IPv6 gateway set
#     manually to the side-router's link-local address) for IPv6 to be proxied.

ARG IMMORTALWRT_VERSION=24.10

# Stage 1: official ImmortalWrt ARM64 rootfs as a file source.
# NOTE: verify this tag exists. ImmortalWrt rootfs tags may differ from OpenWrt's.
# Check available tags: https://hub.docker.com/r/immortalwrt/rootfs/tags
FROM --platform=linux/aarch64_generic immortalwrt/rootfs:armsr-armv8-openwrt-${IMMORTALWRT_VERSION} AS iwrt

# Stage 2: customize on scratch (=build arch) so opkg below runs aarch64 binaries under QEMU
FROM scratch AS customizer
COPY --from=iwrt / /

RUN <<EOF_RUN
set -e
mkdir -p /var/lock /var/run /tmp
opkg update
# Swap fw4/nftables for fw3/iptables-legacy (Android kernel has x_tables, not nf_tables)
opkg remove --force-depends firewall4
opkg install iptables-zz-legacy ip6tables-zz-legacy firewall coreutils-base64 kmod-macvlan
opkg install kmod-tun kmod-inet-diag kmod-nft-tproxy kmod-nf-tproxy ucode-mod-digest ip-full
opkg install bash nano
ln -sf /usr/sbin/iptables-legacy  /usr/sbin/iptables
ln -sf /usr/sbin/ip6tables-legacy /usr/sbin/ip6tables

# Android AID groups: root needs these or the kernel blocks AF_INET sockets
grep -q '^aid_inet:'      /etc/group || echo 'aid_inet:x:3003:root'      >> /etc/group
grep -q '^aid_net_raw:'   /etc/group || echo 'aid_net_raw:x:3004:root'   >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:root' >> /etc/group

opkg install shadow-utils
usermod -a -G aid_inet,aid_net_raw,aid_net_admin root || true

# Argon Theme
opkg install luci-theme-argon
uci set luci.main.mediaurlbase='/luci-static/argon'
uci commit luci

# ---------------------------------------------------------------------------
# Network: single macvlan uplink, static IP on the upstream LAN.
# Replace ipaddr/gateway/dns with values matching your LAN if different.
# ---------------------------------------------------------------------------
cat > /etc/config/network <<'NETEOF'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config interface 'lan'
	option device 'eth0'
	option proto 'static'
	option ipaddr '192.168.1.10'
	option netmask '255.255.255.0'
	option gateway '192.168.1.1'
	list dns '192.168.1.1'

config interface 'lan6'
	option device 'eth0'
	option proto 'dhcpv6'
	option reqaddress 'try'
	option reqprefix 'no'
	option sourcefilter '0'
NETEOF

# ---------------------------------------------------------------------------
# DHCP / RA: DHCPv4 and DHCPv6 disabled; RA enabled to advertise this router
# as the IPv6 default gateway.
# ---------------------------------------------------------------------------
uci batch <<'DHCPEOF'
set dhcp.@dnsmasq[0].dhcp='disabled'
set dhcp.lan.dhcpv6='disabled'
set dhcp.lan.ra='server'
set dhcp.lan.ra_default='2'
set dhcp.lan.ra_slaac='0'
set dhcp.lan.ignore='1'
commit dhcp
DHCPEOF

cat > /etc/hotplug.d/net/30-droidspaces-claim <<'CLAIMEOF'
[ "$ACTION" = add ] || exit 0
for i in $(ubus call network.interface dump | jsonfilter -e "@.interface[@.device='$INTERFACE' && @.up=false && @.autostart=true].interface"); do
	logger -t droidspaces "retrying the claim of $INTERFACE for $i"
	ubus call network.interface."$i" up
done
CLAIMEOF

# ---------------------------------------------------------------------------
# Firewall: side-router. Everything is on the LAN; no NAT, no zone isolation.
# ---------------------------------------------------------------------------
cat > /etc/config/firewall <<'FWEOF'
config defaults
	option syn_flood '1'
	option input 'ACCEPT'
	option output 'ACCEPT'
	option forward 'ACCEPT'

config zone
	option name 'lan'
	option input 'ACCEPT'
	option output 'ACCEPT'
	option forward 'ACCEPT'
	list network 'lan'
	list network 'lan6'

config rule
	option name 'Allow-IPv6-Forward'
	option src 'lan'
	option dest 'lan'
	option family 'ipv6'
	option target 'ACCEPT'

config rule
	option name 'Allow-ICMPv6'
	option src 'lan'
	option proto 'icmp'
	option family 'ipv6'
	list icmp_type 'echo-request'
	list icmp_type 'echo-reply'
	list icmp_type 'destination-unreachable'
	list icmp_type 'packet-too-big'
	list icmp_type 'time-exceeded'
	list icmp_type 'bad-header'
	list icmp_type 'unknown-header-type'
	list icmp_type 'router-solicitation'
	list icmp_type 'neighbour-solicitation'
	list icmp_type 'router-advertisement'
	list icmp_type 'neighbour-advertisement'
	option target 'ACCEPT'
FWEOF

echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/30-ipv4-forward.conf
echo 'net.ipv6.conf.all.forwarding=1' > /etc/sysctl.d/31-ipv6-forward.conf

# debugfs has one superblock for the whole machine. Mounting it here without a
# mode option resets the host's /sys/kernel/debug to 0700, and Android's
# webview_zygote then dies on its next fork: Chrome and WebView stay broken
# until the phone reboots. Nothing in this image needs debugfs.
sed -i '/-t debugfs debugfs/d' /etc/init.d/boot
if grep -q debugfs /etc/init.d/boot; then echo "debugfs mount still in /etc/init.d/boot"; exit 1; fi
echo "ImmortalWrt macvlan side-router (IPv6 proxy) built on $(date)" > /etc/droidspaces

rm -rf /var/opkg-lists/* 2>/dev/null || true
EOF_RUN

# Stage 3: flatten to scratch for export
FROM scratch AS export
LABEL droidspaces.name="ImmortalWrt 24.10 - Macvlan Side-Router (IPv6 Proxy)" \
      droidspaces.distro="ImmortalWrt" \
      droidspaces.description="Minimal ImmortalWrt 24.10 side-router for Droidspaces macvlan mode, with IPv6 proxying. Joins the upstream LAN as a peer (static 192.168.1.10). DHCPv4/DHCPv6 disabled; RA enabled with ra_default=2 so the side-router advertises itself as the IPv6 default gateway while clients keep their main-router SLAAC addresses. IPv6 is forwarded, not NAT'd. Android-kernel compatible: iptables-legacy + fw3, no nftables, no debugfs mount." \
      droidspaces.author="Droidspaces developers"
COPY --from=customizer / /
