#!/bin/bash

help_info() {
	printf "opts: wg_if [.c1] [.c2] ..\n"
}

env_opts() {
	(($# > 0)) || return 1

	wg_if="$1" && shift
	wg_peers="$@"

	sec_file="${wg_if}/${wg_if}.sec"

	# to be customized
	WG_SERV="host.or.ip.of.server"
	WG_PORT=51820
	ADDR="10.10.0.-/24, fd00:1::-/64"

	# default client's MTU for compatability with tunnel over ipv6
	MTU=1392
}

vtext_obj() { # opts: -s|{[-r|-a] text_str}
	# text_str should avoid '%'
	[ "$1" == "-s" ] && printf -- "$vtext_lines" && return
	[ "$1" == "-r" ] && vtext_lines= && return
	[ "$1" == "-a" ] && shift
	vtext_lines+="$*\n"
}

gen_sec() { # opts: peer
	peer="$1"

	wg_key="$(wg genkey)"
	wg_pub="$(echo "$wg_key"| wg pubkey)"
	wg_psk="$(wg genpsk)"

	[ "${peer::1}" == "." ] || wg_psk="<none>"

	vtext_obj -r; [ -f "$sec_file" ] && vtext_obj -a ''
	vtext_obj -a "# $peer"
	vtext_obj -a "pri: $wg_key"
	vtext_obj -a "pub: $wg_pub"
	vtext_obj -a "psk: $wg_psk"
	vtext_obj -s >> "$sec_file"
}

gen_conf() { # opts: peer, run along with gen_sec
	peer="$1"

	conf_if="${wg_if}/${wg_if}.conf"
	conf_peer="${wg_if}/${wg_if}${peer}.conf"

	if [ "${peer::1}" == "." ]; then
		[ -n "$wg_if_pub" ] || \
			wg_if_pub="$(grep -A 2 "^# ${wg_if}$" $sec_file 2>/dev/null|grep "^pub: "| awk '{print $2}')"

		vtext_obj -r; [ -f "$conf_if" ] && vtext_obj -a ''
		vtext_obj -a "[Peer]	# $peer"
		vtext_obj -a "PublicKey = $wg_pub"
		vtext_obj -a "PresharedKey = $wg_psk"
		vtext_obj -a "AllowedIPs = $(echo "$ADDR"| sed "s#/24#/32#; s#/64#/128#; s/-/$ct_peer/g")"
		vtext_obj -s >> "$conf_if"

		vtext_obj -r; [ -f "$conf_peer" ] && vtext_obj -a ''
		vtext_obj -a "[Interface]"
		vtext_obj -a "Address = ${ADDR//-/$ct_peer}"
		vtext_obj -a "PrivateKey = $wg_key"
		vtext_obj -a "MTU = $MTU"
		vtext_obj -a ""
		vtext_obj -a "[Peer]"
		vtext_obj -a "PublicKey = $wg_if_pub"
		vtext_obj -a "PresharedKey = $wg_psk"
		vtext_obj -a "AllowedIPs = ${ADDR//-/0}"
		vtext_obj -a "Endpoint = $WG_SERV:$WG_PORT"
		vtext_obj -s >> "$conf_peer"
	else
		wg_if_pub="$wg_pub"

		vtext_obj -r; [ -f "$conf_if" ] && vtext_obj -a ''
		vtext_obj -a "[Interface]"
		vtext_obj -a "Address = ${ADDR//-/1}"
		vtext_obj -a "ListenPort = $WG_PORT"
		vtext_obj -a "PrivateKey = $wg_key"
		vtext_obj -s >> "$conf_if"
	fi
}

shell_main() {
	env_opts "$@" || { help_info; return; }

	[ -d "$wg_if" ] && { echo "* dir './$wg_if' exist!"; return 1; }

	umask 077
	mkdir "$wg_if"

	ct_peer=0
	for node in $wg_if $wg_peers; do
		printf -- "-> %s\n" "$node"

		((ct_peer+=1))

		gen_sec "$node"
		gen_conf "$node"
	done
}

shell_main "$@"
