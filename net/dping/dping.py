#!/usr/bin/python3
# -*- coding: utf-8 -*-

import sys, os
import re, argparse
import yaml, json
import subprocess as subp
import multiprocessing as mp


class env:
	SIG_STR = { 'O':'oo', 'X':'xx', 'A':'ox' }
	CMD_PING = "ping -q -c 20 -W 2"
	BAD_WT_DELAY = 10000


class Ip_Info:
	def __init__(self, ip=None, rtt=0, lost=100): #{{{1
		self.ip = ip		# ip addr
		self.rtt = rtt		# average rtt
		self.lost = lost	# package lost in percent

	def __eq__(self, other):	#{{{1
		return self.ip == other.ip

	def __repr__(self):		#{{{1
		return "{0:s} {1:.2f}:{2:.1f}:{3:.2f}".format( self.ip, self.rtt,
				self.lost, self.wt_delay() )

	def show(self, pfx=''): #{{{1
		print("{0}{1:<20} (rtt ms, lost, wt: {2:>7.2f}, {3:>5.1f}%, {4:>8.2f})".format(
				pfx, self.ip, self.rtt, self.lost, self.wt_delay() ))

	def dump(self): #{{{1
		return { 'ip':self.ip, 'rtt':self.rtt, 'lost':self.lost }

	def load(self, data): #{{{1
		self.ip = data['ip']
		self.rtt = data['rtt']
		self.lost = data['lost']
		return self

	def wt_delay(self):		# {{{1
		# lost packet will have a penalty in wt_delay
		if (self.rtt == 0) :
			return env.BAD_WT_DELAY
		else:
			# wt_delay should be <= (1+10)*2000
			return (1 + self.lost/10) * self.rtt

	def ping(self, verb=2):	#{{{1
		"""ping and parse the result

		ex. ping -q -c 20 -W 2 8.8.8.8:
			PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.

			--- 8.8.8.8 ping statistics ---
			8 packets transmitted, 8 received, 0% packet loss, time 16ms
			rtt min/avg/max/mdev = 29.539/52.534/109.118/23.357 ms
		"""
		ping_cmd_full = f"{env.CMD_PING} {self.ip} 2>/dev/null"
		out_obj = subp.run(ping_cmd_full, shell=True, stdout=subp.PIPE)
		out_str = out_obj.stdout.decode('utf8')

		if len(out_str) == 0:
			self.rtt, self.lost = (0, 100)
		else:
			pt_lost = re.compile('[^ ]*% packet loss')
			pt_rtt  = re.compile('= [^ ]* ms')

			self.lost = float(re.split('%', pt_lost.search(out_str).group())[0])
			if self.lost < 100 :
				self.rtt = float(re.split('/', pt_rtt.search(out_str).group())[1])
			else:
				self.rtt = 0

		if verb > 0:
			msg = " -> {:<40}".format( ping_cmd_full + ' ..')
		if verb > 1:
			msg += "{0:>8.2f}, {1:>6.1f}, {2:>8.2f}".format(self.rtt, self.lost, self.wt_delay())
		if verb > 0:
			print(msg, flush=True)

		return self
	#1}}}

class Dn_Info:
	def __init__(self, dn=None, ips=None): #{{{1
		self.dn = dn

		""" todo: the ips may need to be a fixed pointer """
		self.ips = list()			# all ips

		if type(ips) is list:
			self.ips = ips

	def __eq__(self, other):	#{{{1
		return self.dn == other.dn

	def __repr__(self): #{{{1
		return 'dn:' + self.dn + repr(self.ips)

	def dump(self): #{{{1
		return { 'dn':self.dn, 'ips':[ ip.dump() for ip in self.ips ] }

	def load(self, data): #{{{1
		self.dn = data['dn']
		self.ips = [ Ip_Info.load(Ip_Info(), ip) for ip in data['ips'] ]
		return self

	def dn_ping_sp(self):	#{{{1
		for ip_info in self.ips :
			ip_info.ping()

	def dn_ping_mp(self, threads):	#{{{1
		with mp.Pool(threads) as p:
			# attention for data parallelism
			self.ips = p.map(Ip_Info.ping, self.ips)

	def dn_ping(self, threads=0): #{{{1
		print("dn: {} ..".format(self.dn))

		if threads == 0:
			threads = os.cpu_count() * 8

		if threads == 1 :
			self.dn_ping_sp()
		elif threads > 1 :
			self.dn_ping_mp(threads)

	def sort_dn(self):	#{{{1
		if len(self.ips) > 0:
			self.ips.sort(key=Ip_Info.wt_delay)

	def wt_delay(self):	#{{{1
		# assume sorted, return the first one
		if len(self.ips) > 0:
			return self.ips[0].wt_delay()
		else:
			return env.BAD_WT_DELAY

	def show(self, sig='A'): #{{{1

		if sig == 'A':
			ips_tgt = self.ips
		elif sig == 'O':
			ips_tgt = [ ip for ip in self.ips if ip.rtt != 0 ]
		elif sig == 'X':
			ips_tgt = [ ip for ip in self.ips if ip.rtt == 0 ]

		print('dn: {:<52} ({}: {:>7})'.format(self.dn, env.SIG_STR[sig],
			"{}/{}".format(len(ips_tgt), len(self.ips)) ))

		for ip in ips_tgt:
			ip.show(pfx=' '*4)

		return len(ips_tgt)
	#1}}}

class Dns_Info:
	def __init__(self): #{{{1
		self.dns = list()

	def dump(self): #{{{1
		return { 'dns': [ dn.dump() for dn in self.dns ] }

	def load(self, data): #{{{1
		self.dns = [ Dn_Info.load(Dn_Info(), dn) for dn in data['dns'] ]
		return self

	def dumpf(self, dfile):	#{{{1
		with open(dfile, 'wb') as fd:
			fd.write(yaml.dump(self.dump(), encoding='utf-8'))

	def loadf(self, dfile):	#{{{1
		with open(dfile, 'rb') as fd:
			self.load(yaml.safe_load(fd.read()))

	def load_dns(self, fdns=None): #{{{1
		with open(fdns, 'r') as fd:
			tmp=json.load(fd)

			for k,v in tmp.items():
				for dn,ips in v.items():

					dn_info = Dn_Info(dn)				# create dn_info with empty ips
					for ip in ips:						# assign dn_info with ips
						dn_info.ips.append(Ip_Info(ip))

					self.dns.append(dn_info)

	def gen_info(self, threads=0):	#{{{1
		for dn in self.dns:
			dn.dn_ping(threads)

	def sort_dns(self):	#{{{1
		for dn in self.dns:
			dn.sort_dn()

		if len(self.dns) > 0:
			self.dns.sort(key=Dn_Info.wt_delay)

	def show(self, sig='A'):	#{{{1
		for dn in self.dns:
			if dn.show(sig) > 0:
				print('')
	# 1}}}


def arg_parse(argv):		#{{{1
	parser = argparse.ArgumentParser(prog='dp_ovpn.py',
			description="dns test tool for torguard vpn")
	parser.add_argument('op', help='operation to do',
			nargs='?', choices=["list", "show", "ping"])
	parser.add_argument('--dns', help='file to load dns',
			nargs='?', default='dns.json', dest='f_dns')
	parser.add_argument('--out', help='file to save dns info',
			nargs='?', default='dns_info.yaml', dest='f_info')
	parser.add_argument('--opt', help='extra option for ping test',
			nargs='?', default='', dest='ping_opt')

	if len(argv) == 1: argv.append('-h')
	return parser.parse_args(argv[1:])


def user_main(argv):	#{{{1

	args = arg_parse(argv)
	dns_info = Dns_Info()

	env.CMD_PING += ' ' + args.ping_opt

	if args.op == "list":
		dns_info.load_dns(args.f_dns)
		dns_info.sort_dns()
	elif args.op == "show":
		dns_info.loadf(args.f_info)
		dns_info.sort_dns()
	elif args.op == "ping":
		dns_info.load_dns(args.f_dns)
		dns_info.gen_info()
		dns_info.sort_dns()
		dns_info.dumpf(args.f_info)

	print('\n==> PASSED:')
	dns_info.show('O')
	print('\n==> BLOCKED:')
	dns_info.show('X')
#}}}

if __name__ == "__main__":
	user_main(sys.argv)


# vi: set ts=4 noexpandtab foldmethod=marker nowrap :
