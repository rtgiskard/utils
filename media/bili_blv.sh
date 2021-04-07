#!/bin/bash

help_info() {
	printf "opts: [D_in] [D_out] [--go]\n"
}

env_opts() {

	## bili cache directory:
	#	/storage/emulated/0/Android/data/tv.danmaku.bili

	FFMPEG="ffmpeg -nostdin -loglevel warning"
	OFMT="mkv"
	IFMT="blv"

	D_in="${1%%/}"
	D_out="${2%%/}"

	[ "$3" == "--go" ] && ECHO='' || ECHO="echo ..."
	(( $# < 2 || $# > 3 )) && help_info && return 2

	if ! [ -d "$D_in" -a -d "$D_out" ]; then
		echo "no such directory!" && return 2
	fi
}

get_val() { # opts: $str $entry_file|stdin: return $val
	grep -E -o \"$1\"':(([^,}]*)||("[^"]*"))' "${2:--}" | \
		cut -d ':' -f 2 | sed 's/^[" ]*//; s/[" ]*$//; s/ \+/./g;'
}

gen_name() { # opts: [-t|-f] $entry_file
	local out_str= tgt_op='-f'
	[ "${1::1}" == '-' ] && tgt_op="$1" && shift

	local title="$(cat "$1"|get_val 'title')"
	local epseq="$(cat "$1"|get_val 'index')"
	local epname="$(cat "$1"|get_val 'index_title')"

	[ -z "$epseq" ] && epseq="$(cat "$1"|get_val 'page')"
	[ -z "$epname" ] && epname="$(cat "$1"|get_val 'part')"

	[ "$epseq" == "全片" ] && epseq=""

	[ "$tgt_op" == "-t" ] && printf -v out_str "%s" "$title"
	[ "$tgt_op" == "-f" ] && printf -v out_str "%s_%02i_%s" "$title" "$epseq" "$epname"

	echo "$out_str" | sed 's/[\\\/]/_/g; s/_\{2,\}/_/g; s/_*$//;'
}

gen_cclist() { # opts: $D_in_ep_subd
	for((i=0; ;i++)) {
		[ -f "$1"/${i}.$IFMT ] || break
		printf "file %s\n" "$1/${i}.$IFMT"
	}
}

cv_cc_single() { # opts: $D_in_ep_root
	local f_entry="$1/entry.json"
	local ep_name="$(gen_name -f "$f_entry")"
	local D_ep_sub="$1/$(get_val 'type_tag' "$f_entry")"

	# create out directory
	local DX_out="$D_out/$(gen_name -t "$f_entry")"
	[ -z "$ECHO" -a ! -d "${DX_out}" ] && mkdir -p "${DX_out}"

	# check to avoid override
	local Fv_out="${DX_out}/${ep_name}.${OFMT}"
	if [ ! -f "$Fv_out" ]; then
		echo "-> $ep_name (${1}) .."
	else
		echo "-> $ep_name exsit, skip!" && return 0
	fi

	if [ -f "$D_ep_sub/audio.m4s" -a -f "$D_ep_sub/video.m4s" ]; then
		# the new hierarchy? only audio.m4s and video.m4s
		$ECHO $FFMPEG -i "$D_ep_sub/audio.m4s" -i "$D_ep_sub/video.m4s" -c copy "$Fv_out"
	elif [ -d "$D_ep_sub" ]; then
		$ECHO $FFMPEG -f concat -safe 0 -i <(gen_cclist "$D_ep_sub") -c copy "$Fv_out"
	fi
}

cv_cc_all() {
	X_list="$(ls -1 "$D_in")"
	for x in $X_list; do
		X_ep_list="$(ls -1 "$D_in/$x")"
		for y in $X_ep_list; do
			cv_cc_single "$D_in/$x/$y"
		done
	done
}

shell_main() {
	env_opts "$@" || return 2
	cv_cc_all
}

shell_main "$@"
