from fabric.api import *
import socket
import string

domain_name = ''

@runs_once
def host_monkeypatch(new_domain_name):
	global domain_name
	domain_name = new_domain_name

	if new_domain_name:
		# -- Redefinine GetAddrInfo ---------------------------------------------------
		socket.getaddrinfo_old = socket.getaddrinfo
		def getaddrinfo_monkeypatch(host, port, family=0, type=0, proto=0, flags=0):
			if string.find(host,'.') == -1 and host != 'localhost':
				host = host + '.' + domain_name
			return socket.getaddrinfo_old(host, port, family, type, proto, flags)
		socket.getaddrinfo = getaddrinfo_monkeypatch
		# -----------------------------------------------------------------------------
