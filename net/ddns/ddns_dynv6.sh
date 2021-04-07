#!/bin/bash
# dynv6 ddns update script
# api reference: https://dynv6.com/docs/apis

#{{{1 help && env
help_info() {
	cat - <<EOF
usage: [options] noop|update

options:
    -4|-6           update ipv4|ipv6 only, or both if not given
    -d              delete ip record, require api:dns

    --dn zone         * zone to update (required)
    --src if:*|ip:*   * ip source for update (required)
        if:dev            detect ip from interface 'dev'
		ip:ip4,ip6        use specified ip (for ip4|ip6==auto: checkip)

    --chk cc|ns     ip match check, cc:cache, ns:dig
    --api dns|http  api for update, dns: nsupdate, http: curl
    --tsig key      path to tsig key file, for api:dns
    --token token   http token, for api:http

    noop            check only, no update
    update          apply update
EOF
}

env_opts() {
	zone=
	src_str=

	addr_ip4=
	addr_ip6=
	addr_ip4_ck=
	addr_ip6_ck=

	ip_ver=0			# ip_ver: 0: ipv4+ipv6, 4: ipv4, 6: ipv6
	ddns_api='dns'		# api default to dns
	chk_mt='ns'			# chk default to ns
	sig_todo=
	sig_del=false

	ns_server="ns1.dynv6.com"
	tsig_key="./dynv6.tsig"

	http_bin="curl -fsS"
	#http_bin="wget -O-"
	http_api_uri="https://dynv6.com/api/update"
	http_token=

	checkip_v4="https://ipv4.checkip.dns.he.net"
	checkip_v6="https://ipv6.checkip.dns.he.net"

	cache_dir="/var/cache/ddns"
	cache_file="dynv6.cache"

	(( $# > 0 )) || return 1

	while (( $# > 0 )); do
		case "$1" in
			-4|-6) ip_ver=${1:1}; shift ;;
			-d) sig_del=true; shift ;;
			--dn) zone="$2"; shift 2 || break ;;
			--src) src_str="$2"; shift 2 || break ;;
			--chk) chk_mt="$2"; shift 2 || break ;;
			--api) ddns_api="$2"; shift 2 || break ;;
			--tsig) tsig_key="$2"; shift 2 || break ;;
			--token) http_token="$2"; shift 2 || break ;;
			noop|update) sig_todo="$1"; shift ;;
			*) return 1 ;;
		esac
	done

	(( $# == 0 )) || return 1

	[ "$chk_mt" == "ns" -o "$chk_mt" == "cc" ] || return 1
	[ "$ddns_api" == "dns" -o "$ddns_api" == "http" ] || return 1
	[ "${src_str::3}" == "if:" -o "${src_str::3}" == "ip:" ] || return 1
	[ "$sig_todo" == "noop" -o "$sig_todo" == "update" ] || return 1
}

env_opts_post() {
	(( ip_ver==0 || ip_ver==4 )) && sig_ipv4=true || sig_ipv4=false
	(( ip_ver==0 || ip_ver==6 )) && sig_ipv6=true || sig_ipv6=false

	[ -n "$zone" -a -z "${zone//[0-9a-zA-Z.-]/}" ] || { printf "err: zone '${zone}' invalid!\n"; return 1; }

	if [ "$sig_todo" == "update" -a "$ddns_api" == "dns" ]; then
		[ -f "$tsig_key" ] || { printf "err: tsig key not found!\n"; return 1; }
	fi

	if $sig_del; then
		[ "$ddns_api" == "http" ] && printf "use '--api dns' for dn delete!\n" && return 1
	else
		if [ "${src_str::2}" == "if" -a -z "$(ip link show dev "${src_str:3}" up 2>/dev/null)" ]; then
			printf "err: interface '${src_str:3}' not ready!\n"; return 1;
		fi
	fi

	return 0
}

#{{{1 addr
addr_parse() {
	local ip_or_dev="${src_str:3}"
	case "${src_str::3}" in
	'if:')
		$sig_ipv4 && addr_ip4="$(ip -4 addr show dev "$ip_or_dev" scope global | sed -n 's/.*inet \([0-9.]\+\).*/\1/p' | head -n 1)"
		$sig_ipv6 && addr_ip6="$(ip -6 addr show dev "$ip_or_dev" scope global | sed -n 's/.*inet6 \([0-9a-f:]\+\).*/\1/p' | head -n 1)" ;;
	'ip:')
		$sig_ipv4 && addr_ip4="$(echo "$ip_or_dev" | awk -F, '{print $1}')"
		$sig_ipv6 && addr_ip6="$(echo "$ip_or_dev" | awk -F, '{print $2}')"

		$sig_ipv4 && [ "$addr_ip4" == "auto" ] && addr_ip4="$(curl -s "$checkip_v4"|sed  -n 's/.* \([0-9.]\{7,\}\).*/\1/p')"
		$sig_ipv6 && [ "$addr_ip6" == "auto" ] && addr_ip6="$(curl -s "$checkip_v6"|sed  -n 's/.* \([0-9a-f:]\{7,\}\).*/\1/p')" ;;
	esac
}

addr_ck_rec() {
	case "$chk_mt" in
	'ns')
		$sig_ipv4 && addr_ip4_ck="$(dig +noall +answer @$ns_server ${zone}. A | awk '{print $5}')"
		$sig_ipv6 && addr_ip6_ck="$(dig +noall +answer @$ns_server ${zone}. AAAA | awk '{print $5}')" ;;
	'cc')
		local last_rec="$(cache_read "$zone" | tail -1 | tr -d [:space:])"

		$sig_ipv4 && addr_ip4_ck="$(echo "$last_rec" | awk -F, '{print $3}')"
		$sig_ipv6 && addr_ip6_ck="$(echo "$last_rec" | awk -F, '{print $4}')" ;;
	esac
}

addr_check_match() {
	local chk_ct=0

	if $sig_ipv4; then
		$sig_del && addr_ip4_ck='*'

		if [ "$addr_ip4" != "$addr_ip4_ck" ]; then
			printf "addr ip4: %s -> %s\n" "$addr_ip4_ck" "$addr_ip4"
			((chk_ct+=1))
		fi
	fi

	if $sig_ipv6; then
		$sig_del && addr_ip6_ck='*'

		if [ "$addr_ip6" != "$addr_ip6_ck" ]; then
			printf "addr ip6: %s -> %s\n" "$addr_ip6_ck" "$addr_ip6"
			((chk_ct+=1))
		fi
	fi

	((chk_ct==0)) && printf "addr: up to date\n"

	return $chk_ct
}

#{{{1 update
ddns_update() {
	case "$ddns_api" in
		dns) update_api_dns ;;
		http) update_api_http ;;
	esac
}

update_api_dns() {
	nsupdate -L 2 -k "$tsig_key" <(
		echo "server $ns_server"
		echo "zone $zone"

		$sig_ipv4 && echo "update delete $zone A"
		$sig_ipv6 && echo "update delete $zone AAAA"

		if ! $sig_del; then
			$sig_ipv4 && [ -n "$addr_ip4" ] && echo "update add $zone 60 A $addr_ip4"
			$sig_ipv6 && [ -n "$addr_ip6" ] && echo "update add $zone 60 AAAA $addr_ip6"
		fi

		echo "send"
	)
}

update_api_http() {
	$sig_ipv4 && $http_bin "$http_api_uri?hostname=${zone}&token=${http_token}&ipv4=${addr_ip4}"
	$sig_ipv6 && $http_bin "$http_api_uri?hostname=${zone}&token=${http_token}&ipv6=${addr_ip6}"
}

#{{{1 cache
# cache format: mtime, dn, ip4, ip6, ip_ver, status
cache_write() { # opts: dn, ip4, ip6, ip_ver, status
	[ -d "$cache_dir" ] || mkdir -p "$cache_dir"

	printf "%s, %s, %s, %s, %s, %s\n" "$(date +%y%m%d%H%M%S)" "$@" | tee -a "$cache_dir/$cache_file"
}

cache_read() { # opts: dn
	[ -f "$cache_dir/$cache_file" ] || return
	grep -E ",\s+${1}.+" "$cache_dir/$cache_file"
} #}}}

shell_main() {
	env_opts "$@" || { help_info && return 1; }
	env_opts_post || return 1

	if ! $sig_del; then
		addr_parse
		addr_ck_rec
	fi

	addr_check_match

	if [ $? -gt 0 -a "$sig_todo" == "update" ]; then
		ddns_update
		cache_write "$zone" "$addr_ip4" "$addr_ip6" "$ip_ver" "$?"
		echo 'done'
	fi
}

shell_main "$@"

# vi: set ts=4 foldmethod=marker :
