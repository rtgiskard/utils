#!/bin/bash

help_info() { #{{{1
	printf -- "%s\n  %s\n  %s\n  %s\n" "usage: [sync|relay] [--go] | [clean=n]" \
		"sync: sync from local dist cache to dist repo" \
		"relay: re-layout the dist repo" \
		"clean=n: clean dist repo with op for stage n in [1-4]"
}

env_opts() { #{{{1

	sig_op="0"; todo="";

	while (( $# != 0 )); do
		case "_$1" in
			_sync|_relay)
				[ -n "$todo" ] && todo="" && break
				todo="$1" && shift ;;
			_clean=[1-4])
				todo="clean"; sig_op="${1:6}"
				shift ;;
			_--go)
				[ "$todo" != "clean" ] && sig_op="1"
				shift ;;
			_*) todo="" && break ;;
		esac
	done

	[ "$todo" == "" ] && help_info && return 2

	if [ "$todo" == "clean" -a "$sig_op" == 0 ]; then
		printf "'clean' require 'n > 0' to go!\n"
		return 2
	fi

	if [ $(id -u) != 0 -a "$sig_op" -gt 0 ]; then
		printf "require root privilege!\n"
		return 2
	fi

	dist_repo="/srv/repos/mirrors/gentoo/distfiles"
	dist_cache="/srv/repos/sys/distfiles"
	dist_sys="$(portageq envvar DISTDIR)"

} #}}}

gen_dist_sparse() { #{{{1 opts: $dist_dir $file_orig

	truncate -r "$2" "$1/$(basename "$2")"

	#> sparse with dd:
	#	local fsize="$(stat -c%s "$2")"
	#	dd if=/dev/zero of="$1/$(basename "$2")" bs=1 count=0 seek="$fsize" status=none
}

mv_dist_to_rm() { #{{{1 opts: $dist_dir $file_orig $dir_rm

	local fn="$(basename "$2")"
	if [ ! -f "$1/$fn" -a -f "$2" ]; then
		# skip "layout.conf"
		[ "$fn" == "layout.conf" ] || mv "$2" "$3"
	fi
}

switch_dist_layout() { #{{{1 opts: $src_dist $dest_dist

	local src_dist="$1" dest_dist="$2"
	[ -z "$dest_dist" ] && dest_dist="."
	local fn subd
	pushd "$src_dist" > /dev/null

	ls -1 ./ | while read fn; do
		[[ -f $fn &&
			$fn != "layout.conf" &&
			$fn != *.__download__ &&
			$fn != *.portage_lockfile &&
			$fn != *_checksum_failure_* ]] || continue

		subd="$dest_dist/$(printf '%s' "$fn" | b2sum | cut -c1-2)"

		[ ! -f "$subd/$fn" -o "$fn" -nt "$subd/$fn" ] || continue

		if [ "$sig_op" == 0 ]; then
			echo "-> mv '$fn' .."
		else
			[ -d "$subd" ] || mkdir -v "$subd"
			chown nobody:nobody "$fn" && mv -v "$fn" "$subd/$fn"
		fi
	done

	popd > /dev/null
}

clean_dist() { #{{{1

	local dist_fcache="$dist_repo/.dist.fcache"
	local dist_dir_rm="$dist_repo/.dist.rm"

	# export func for xargs
	export -f gen_dist_sparse mv_dist_to_rm

	case "$sig_op" in
	1) #{{{2
		# use tmpfs for operation
		mount -t tmpfs -o size=1G tmpfs "$dist_sys"

		# generate dist_repo cache file ($dist_fcache is also scaned)
		find "$dist_repo" -type f -fprint0 "$dist_fcache"

		# create sparse dist_sys
		xargs -a "$dist_fcache" -0 -n 1 -P 20 -I {} \
			bash -c 'gen_dist_sparse "$@"' _ "$dist_sys" {} ;;
	2) #{{{2
		if [ ! -f "$dist_fcache" ]; then
			echo "run with 'clean=1' first!"
			return 2
		fi

		# apply eclean-dist (may remove layout.conf)
		eclean-dist --deep --fetch-restricted -s 1G

		[ ! -d "$dist_dir_rm" ] && mkdir "$dist_dir_rm"

		# move from "$dist_repo" to "$dist_dir_rm"
		xargs -a "$dist_fcache" -0 -n 1 -P 20 -I {} \
			bash -c 'mv_dist_to_rm "$@"' _ "$dist_sys" {} "$dist_dir_rm" ;;
	3) #{{{2
		if [ ! -d "$dist_dir_rm" ]; then
			echo "run with 'clean=2' first!"
			return 2
		fi

		# remove "$dist_dir_rm", "$dist_fcache" got moved to "$dist_dir_rm" already
		rm -r "$dist_dir_rm"

		umount "$dist_sys" ;;
	4) #{{{2
		# clean up (casual style)
		find "$dist_repo" -type f \( \
			-name "*_checksum_failure_*" -o \
			-name "*.__download__" -o \
			-name "*.portage_lockfile" \) \
			-exec rm -v {} \;
		rm -rfv "$dist_sys"/* ;;
		#2}}}
	esac
} #}}}

shell_main() {
	env_opts "$@" || return 2

	case "_$todo" in
		_sync) switch_dist_layout "$dist_cache" "$dist_repo" ;;
		_relay) switch_dist_layout "$dist_repo" ;;
		_clean) clean_dist ;;
	esac
}

shell_main "$@"


# vi: set nowrap sidescroll=7 ts=4 foldmethod=marker :
