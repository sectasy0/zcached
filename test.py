import socket

key = "key"
value = "myvalue"

new_key = "new_key123"

command = f"*2\r\n$3\r\nGET\r\n${len(key)}\r\n{key}\r\n"
command = f"*3\r\n$3\r\nSET\r\n${len(key)}\r\n{key}\r\n/3\r\n$5\r\nfirst\r\n$6\r\nsecond\r\n$5\r\nthird\r\n"
# command = f"*2\r\n$6\r\nDELETE\r\n${len(new_key)}\r\n{new_key}\r\n"
# command = f"*3\r\n$3\r\nSET\r\n${len(key)}\r\n{key}\r\n${len(value)}\r\n{value}\r\n"
# command = f"*3\r\n$6\r\nRENAME\r\n${len(key)}\r\n{key}\r\n${len(new_key)}\r\n{new_key}\r\n"
# command = f"*1\r\n$4\r\nKEYS\r\n"

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(('localhost', 7556))

# Send the command to the Redis server
s.sendall(command.encode('utf-8'))

print(s.recv(1000))

# Close the socket
s.close()
