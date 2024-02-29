from socket import socket, AF_INET, SOCK_STREAM
from time import sleep

# python testing script
with socket(AF_INET, SOCK_STREAM) as _sock:
	_sock.connect(("localhost", 7556))

	# ping command
	# _sock.send("*1\r\n$4\r\nPING\r\n".encode("utf-8"))

	# _sock.send("*3\r\n$3\r\nSET\r\n$9\r\nmycounter\r\n:42\r\n".encode("utf-8"))
	_sock.send("*2\r\n$3\r\nGET\r\n$9\r\nmycounter\r\n".encode("utf-8"))
	sleep(0.1)
	print(_sock.recv(1024))
