#!/bin/bash
#
# require:
#		ip: sys-apps/iproute2
#		iw: net-wireless/iw
#		ipcalc: net-misc/ipcalc
#		rfkill: net-wireless/rfkill
#		nft: net-firewall/nftables
#
# ipv4 private address:
#	A:	10.0.0.0/8		10.0.0.0	– 10.255.255.255
# 	B:	172.16.0.0/12	172.16.0.0	– 172.31.255.255
# 	C:	192.168.0.0/16	192.168.0.0	– 192.168.255.255
# ipv6 unique local address:
#		fc00::/7


# {{{ wait_dot && ip_cal
# wait_dot [timeout:-2s] {dt:-1s}
wait_dot() {
	local count="${1:-2s}" dt="${2:-1s}"
	local counts="${count%s}" dts="${dt%s}"
	while [ "$counts" -gt "0" ]; do
		printf '.' && sleep "$dt"
		(( counts = counts - dts ))
	done
}

# ip_cal [addr4] [ Network | Netmask | Broadcast ]
ip_cal() {
	ipcalc "$1" | grep "$2" | awk '{print $2}'
}
# }}}

# {{{1 wifi_info, unblock_wifi, wifi_opts
# wifi_info [dev]	[ scan|ssid|channel|isup|isblock ]
#+ for isblock, dev should be iw_phy, or related unique str
wifi_info() {
	case "_$2" in
		_scan)
			iw dev "$1" scan | \
			sed -n 's/^BSS.*/--/p; /SSID/p;
					/signal:/h; /last seen:/H; /set: channel/{G;p};' ;;
		_ssid)
			iw dev "$1" info | grep 'ssid' | awk '{print $2}' ;;
		_channel)
			iw dev "$1" info | grep 'channel' | awk '{print $2}' ;;
		_isup)
			ip link show "$1" 2>&1 | grep -q 'UP'
			(( $?==0 )) && echo 'up' || echo 'down' ;;
		_isblock)
			rfkill list | grep -A 1 "$1" | grep 'blocked' | awk '{print $3}' ;;
		*)
			printf -- 'wifi_info [dev]	[ scan|ssid|channel|isup|isblock ]\n'
			return 1 ;;
	esac
}

unblock_wifi() { #{{{1
	if [ "_$(wifi_info "$iw_phy" isblock)" == "_yes" ]; then
		printf -- "unblock wifi.."
		rfkill unblock wifi
		wait_dot 4s; printf '\n'
	fi
}

# {{{1 wifi_opts [scan [dev] | connect [dev] [ssid] ]
wifi_opts() {
	unblock_wifi

	if [ "_$(wifi_info "$2" isup)" == "_down" ]; then
		printf "$2 is down now, set up!\n"
		ip link set dev "$2" up  &&  sleep 0.4s
	fi

	case "_$1" in
		_scan)
			wifi_info "$2" scan ;;
		_connect)
			iw dev "$2" connect "$3" && dhcpcd "$2" ;;
	esac
	printf '\n'
} #}}}

_help() { #{{{1
	printf -- 'usage:  ap|fw|ap_fw | reset | scan\n'
}

env_opts() { #{{{1

	iw_phy="phy0"
	if_wlan="wlp3s4"

	vif_0="APTX4869"
	vif_0_mac="$(openssl rand -hex 6 | sed 's/\(..\)/\1:/g; s/:$//')"
	vif_0_addr4="192.168.100.1/24"
	vif_0_addr6="fd00:56:db::1/64"
	vif_0_4_Network="$(ip_cal "$vif_0_addr4" Network)"
	vif_0_6_Network="${vif_0_addr6/::*\//::/}"

	# hostapd
	ssid="${vif_0/[- ]/_}"
	keywd="$(echo "ZWUyZDVjMWRkYzM1ZDYyZgo=" | base64 -d)"

	hw_mode='g'				# a = IEEE 802.11a (5 GHz); g = IEEE 802.11g (2.4 GHz)
	country_code="US"		# NZ for New Zealand, or using US
	channel_default='1'		# or 0 for acs_survey

	#hw_mode='a'			# a = IEEE 802.11a (5 GHz); g = IEEE 802.11g (2.4 GHz)
	#country_code="US"		# NZ for New Zealand, or using US
	#channel_default='40'	# or 0 for acs_survey

	# create temperary directory
	tmp_dir="/tmp/ip_iw" && mkdir -p "$tmp_dir"
} #}}}

vif_create() { #{{{1

	if [ -n "$(iw dev | grep $vif_0)" ]; then
		echo "$vif_0 exsit!" && return 1
	fi

	unblock_wifi

	printf -- "create virtual interface .."
	iw phy "$iw_phy" interface add "$vif_0" type managed 4addr on
	wait_dot 2s; printf '\n'

	if [ "_$(wifi_info "$vif_0" isup)" == "_up" ]; then
		## set down to assign a mac
		ip link set dev "$vif_0" down  &&  sleep 0.4s
	fi

	# assign mac, ip
	ip link set dev "$vif_0" address "$vif_0_mac"
	ip addr add "$vif_0_addr4" dev "$vif_0"
	ip addr add "$vif_0_addr6" dev "$vif_0"
}

hostapd_cal() { #{{{1
	printf -- "calling hostapd ..\n"

	local channel=${channel:-$channel_default}
	local hostapd_cfg="$tmp_dir/hostapd_${vif_0}.conf"
	local hostapd_log="$tmp_dir/hostapd_${vif_0}.log"

# {{{2 hostapd.conf
	cat - <<EOF > "$hostapd_cfg"
interface=$vif_0
driver=nl80211
#bridge=br0
hw_mode=$hw_mode

channel=$channel
#chanlist=40 48 56 120 128 144 165
# ACS tuning - Automatic Channel Selection
#channel=acs_survey
acs_num_scans=7
acs_chan_bias=1:0.4 6:0.6 11:0.8

utf8_ssid=1
ssid=${ssid}
# or with this commond
#ssid2="_${ssid}_"

# Maximum number of stations allowed in station table
max_num_sta=32

# WDS (4-address frame) mode with per-station virtual interfaces
# (only supported with driver=nl80211)
wds_sta=1

# used with driver=hostap or driver=nl80211
# 0 = accept unless in deny list
# 1 = deny unless in accept list
# 2 = use external RADIUS server (accept/deny lists are searched first)
macaddr_acl=0

# This is a bit field where the first bit (1) is for open auth,
#+ the second bit (2) is for Shared key auth (wep) and both (3) is both.
auth_algs=1

wpa=2
# wpa_psk (dot11RSNAConfigPSKValue)
# wpa_passphrase (dot11RSNAConfigPSKPassPhrase)
#wpa_psk=2c2c8c7833ce0c662000941a90377a863f30ca3a52e1ca9e43b3b7b6c4cf0324
wpa_passphrase=$keywd

wpa_key_mgmt=WPA-PSK WPA-EAP
wpa_pairwise=CCMP TKIP
rsn_pairwise=CCMP

# limit available channels and transmit power
country_code=$country_code
ieee80211d=1
ieee80211h=1
local_pwr_constraint=4

#beacon_int=100
#dtim_period=2
#rts_threshold=2347
#fragm_threshold=2346


# Enable Hotspot 2.0 support
hs20=1

# Send empty SSID in beacons and ignore probe request frames that do not
# specify full SSID, i.e., require stations to know SSID.
# default: disabled (0)
# 1 = send empty (length=0) SSID in beacon and ignore probe request for
#	 broadcast SSID
# 2 = clear SSID (ASCII 0), but keep the original length (this may be required
#	 with some clients that do not support empty SSID) and ignore probe
#	 requests for broadcast SSID
ignore_broadcast_ssid=1

# 802.11n Setting
wmm_enabled=1
ieee80211n=1
ht_capab=[HT40-][HT40+][SMPS-DYNAMIC][SHORT-GI-20][SHORT-GI-40][TX-STBC][RX-STBC1][DSSS_CCK-40]
#require_ht=1
obss_interval=8

# IEEE 802.11ac
ieee80211ac=1
#require_vht=1
#vht_capab=[SHORT-GI-80][SU-BEAMFORMEE][RX-ANTENNA-PATTERN][TX-ANTENNA-PATTERN]
#vht_oper_chwidth=1
#vht_oper_centr_freq_seg0_idx=40
#vht_oper_centr_freq_seg1_idx=144

#
# WMM-PS Unscheduled Automatic Power Save Delivery [U-APSD]
# Enable this flag if U-APSD supported outside hostapd (eg., Firmware/driver)
#uapsd_advertisement_enabled=1
#
# Low priority / AC_BK = background
wmm_ac_bk_cwmin=4
wmm_ac_bk_cwmax=10
wmm_ac_bk_aifs=7
wmm_ac_bk_txop_limit=0
wmm_ac_bk_acm=0
# Note: for IEEE 802.11b mode: cWmin=5 cWmax=10
#
# Normal priority / AC_BE = best effort
wmm_ac_be_aifs=3
wmm_ac_be_cwmin=4
wmm_ac_be_cwmax=10
wmm_ac_be_txop_limit=0
wmm_ac_be_acm=0
# Note: for IEEE 802.11b mode: cWmin=5 cWmax=7
#
# High priority / AC_VI = video
wmm_ac_vi_aifs=2
wmm_ac_vi_cwmin=3
wmm_ac_vi_cwmax=4
wmm_ac_vi_txop_limit=94
wmm_ac_vi_acm=0
# Note: for IEEE 802.11b mode: cWmin=4 cWmax=5 txop_limit=188
#
# Highest priority / AC_VO = voice
wmm_ac_vo_aifs=2
wmm_ac_vo_cwmin=2
wmm_ac_vo_cwmax=3
wmm_ac_vo_txop_limit=47
wmm_ac_vo_acm=0
# Note: for IEEE 802.11b mode: cWmin=3 cWmax=4 burst=102

ctrl_interface=/var/run/hostapd
ctrl_interface_group=wheel

logger_syslog=-1
logger_syslog_level=2
logger_stdout=-1
logger_stdout_level=2

EOF
# 2}}}

	hostapd -B "$hostapd_cfg" -f "$hostapd_log"
}

dhcpd_cal() { #{{{1
	printf -- "calling dhcpd ..\n"

	local dhcpd_cfg_v4="$tmp_dir/dhcpd_${vif_0}.v4.conf"
	local dhcpd_cfg_v6="$tmp_dir/dhcpd_${vif_0}.v6.conf"
	local dhcpd_lease_v4="$tmp_dir/dhcpd_${vif_0}.v4.lease"
	local dhcpd_lease_v6="$tmp_dir/dhcpd_${vif_0}.v6.lease"
	local dhcpd_pid_v4="$tmp_dir/dhcpd_${vif_0}.v4.pid"
	local dhcpd_pid_v6="$tmp_dir/dhcpd_${vif_0}.v6.pid"

	local ip4_if="${vif_0_addr4%/*}"
	local ip4_pfx="${vif_0_addr4%.*}"
	local ip6_if="${vif_0_addr6%/*}"
	local ip6_pfx="${vif_0_6_Network}"

	# {{{2 dhcpd.conf
	cat - <<EOF > "$dhcpd_cfg_v4"
authoritative;
ddns-update-style none;

default-lease-time 3600;
max-lease-time 7200;

subnet ${ip4_pfx}.0 netmask 255.255.255.0 {
	range ${ip4_pfx}.20 ${ip4_pfx}.99;

	option routers ${ip4_if};
	option domain-name-servers ${ip4_if};
}
EOF

	cat - <<EOF > "$dhcpd_cfg_v6"
authoritative;
ddns-update-style none;

default-lease-time 3600;
max-lease-time 7200;

subnet6 ${ip6_pfx} {
	range6 ${ip6_pfx%%::*}::100 ${ip6_pfx%%::*}::400;

	option routers ${ip6_if};
	option domain-name-servers ${ip6_if};
}
EOF
# 2}}}

	touch "$dhcpd_lease_v4" && chown dhcp:dhcp "$dhcpd_lease_v4"
	touch "$dhcpd_lease_v6" && chown dhcp:dhcp "$dhcpd_lease_v6"

	dhcpd -4 -q -user dhcp -group dhcp \
		-cf "$dhcpd_cfg_v4" -lf "$dhcpd_lease_v4" -pf "$dhcpd_pid_v4"
	#dhcpd -6 -q -user dhcp -group dhcp \
	#	-cf "$dhcpd_cfg_v6" -lf "$dhcpd_lease_v6" -pf "$dhcpd_pid_v6"
} #}}}

_fw_conf() { #{{{1 fw rules, forward and nat rules
	printf -- 'configuring fw ..\n'

	sysctl -q net.ipv4.ip_forward=1
	# sysctl -q net.ipv6.conf.all.forwarding=1
	# sysctl -q net.ipv6.conf.default.forwarding=1

	# using nft as firewall with customized rules
	# as the default policy is drop, so append is enough
	local chain="filter_iw"
	local handle_in=$(nft -a list chain ip filter input 2>/dev/null |grep "jump ch_init")
	handle_in="${handle_in##*# handle }"

	# not my rules
	[ -z "handle_in" ] && return 2

	#{{{2 for ipv4
	nft add chain ip filter $chain
	nft add rule ip filter input jump $chain

	nft add rule ip filter $chain meta iifname $vif_0 udp dport bootps accept

	# forward and nat
	nft add rule ip filter forward meta iifname $vif_0 accept
	# it seems not to be able to recognize iifname here
	nft add rule ip m_n postrouting ip saddr $vif_0_4_Network masquerade

	#{{{2 for ipv6
	nft add chain ip6 filter $chain
	nft add rule ip6 filter input jump $chain

	nft add rule ip6 filter $chain meta iifname $vif_0 udp dport dhcpv6-server accept

	# forward and nat
	nft add rule ip6 filter forward meta iifname $vif_0 accept
	nft add rule ip6 m_n postrouting ip6 saddr $vif_0_6_Network masquerade
	#2}}}
}

_vif_to_ap() { #{{{1

	# as nic has limitations on valid interface combinations, pay attention to
	# the sequence or may got: RTNETLINK answers: Device or resource busy
	vif_create && hostapd_cal && dhcpd_cal
}

_reset() { #{{{1
	printf -- 'reset fw ..\n'
	sysctl -q net.ipv4.ip_forward=0
	# sysctl -q net.ipv6.conf.all.forwarding=0
	# sysctl -q net.ipv6.conf.default.forwarding=0
	systemctl restart nftables-restore.service

	printf -- "killing hostapd && dhcpd ..\n"
	killall hostapd dhcpd >/dev/null 2>&1
	rm -r "$tmp_dir"

	printf -- "removing virtual if ..\n"
	iw dev "$vif_0" del >/dev/null 2>&1
} #}}}

shell_main() { #{{{

	(( $#==1 )) || { _help && return 0; }

	env_opts

	case "_$1" in
		_ap)		_vif_to_ap ;;
		_fw)		_fw_conf ;;
		_ap_fw)		_vif_to_ap && _fw_conf ;;
		_reset)		_reset ;;
		_scan)		wifi_opts scan "$if_wlan" ;;
		*)			_help && return 2 ;;
	esac

} #}}}

shell_main "$@"


# vi: set nowrap sidescroll=7 ts=4 foldmethod=marker :
