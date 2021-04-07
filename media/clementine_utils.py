#!/usr/bin/python
# -*- coding: utf8 -*-

import sys, os, argparse
import sqlite3

#SQL_LIST_DB = "SELECT name from sqlite_master"
#SQL_SHOW_COL = "PRAGMA table_info(TABLE_NAME)"

class Clementine_DB: #{{{1
	def __init__(self, db_path): #{{{2
		self.db_path = db_path

	def db_set_count(self, title, artist, count): #{{{2
		SQL_UPDATE = "UPDATE songs SET playcount=? WHERE title=? AND artist=?"
		self.db_con.cursor().execute(SQL_UPDATE, (count, title, artist))

	def db_update_info(self, title, artist, count): #{{{2
		if title != '' or artist != '':
				print('-> {} - {}: {}'.format(title, artist, count))
				self.db_set_count(title, artist, count)
		else:
			print('-> skip update for -: empty title && artist!')

	def db_merge(self, db_from): #{{{2

		db_con_from = sqlite3.connect(db_from)

		SQL_QUERY = "SELECT title,artist,SUM(playcount) FROM songs GROUP BY title"
		info_src = db_con_from.cursor().execute(SQL_QUERY);

		for title, artist, count in info_src:
			self.db_update_info(title, artist, count)

		db_con_from.close()

	def db_list(self, limit=20): #{{{2
		SQL_QUERY = "SELECT title,artist,playcount FROM songs LIMIT ?"
		info_list = self.db_con.cursor().execute(SQL_QUERY, (limit,));

		for row in info_list:
			print(row)

	def db_op_pre(self): #{{{2
		self.db_con = sqlite3.connect(self.db_path)

	def db_op_post(self, commit=False): #{{{2
		if commit == True:
			self.db_con.commit()

		self.db_con.close()
	#2}}}
#}}}

def arg_parse(argv): #{{{1
	parser = argparse.ArgumentParser(prog='clementine_utils',
			description="tool to manupulate clementine info db")

	parser.add_argument('--db', help='database to operate',
			nargs=1, default=['clementine.db'], dest='db')

	sub_parsers = parser.add_subparsers(dest='op', help='subcommand')

	sub_set = sub_parsers.add_parser('set', help='set info of the song')
	sub_set.add_argument('--title', nargs=1, help='info: title', required=True)
	sub_set.add_argument('--artist', nargs=1, help='info: artist', required=True)
	sub_set.add_argument('--count', nargs=1, help='info: playcount', required=True)

	sub_list = sub_parsers.add_parser('list', help='list some of the info')
	sub_list.add_argument('--limit', help='number to limit on query',
			nargs=1, default=[20], type=int)

	sub_import = sub_parsers.add_parser('import', help='import info from other db')
	sub_import.add_argument('--db_from', help='database from where to import info',
			nargs=1, default=['clementine.orig.db'], dest='db_from')

	if len(argv) == 1: argv.append('-h')
	return parser.parse_args(argv[1:])

def check_args(args): #{{{1
	if not os.path.isfile(args.db[0]):
		print("no such file:", args.db[0])
		return False

	if args.op == "import" and not os.path.isfile(args.db_from[0]):
		print("no such file:", args.db_from[0])
		return False

	return True

def user_main(argv): #{{{1
	args = arg_parse(argv)

	if check_args(args) == False:
		return False

	db = Clementine_DB(args.db[0])

	if args.op == "set":
		db.db_op_pre()
		db.db_update_info(args.title[0], args.artist[0], args.count[0])
		db.db_op_post(commit=True)
	elif args.op == "import":
		db.db_op_pre()
		db.db_merge(args.db_from[0])
		db.db_op_post(commit=True)
	elif args.op == "list":
		db.db_op_pre()
		db.db_list(args.limit[0])
		db.db_op_post()
#}}}

if __name__ == "__main__":
	user_main(sys.argv)


# vi: set ts=4 noexpandtab foldmethod=marker nowrap :
