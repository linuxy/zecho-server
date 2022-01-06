# zecho-server
A zig echo server.

builds against zig 0.9.0
```
$ zig build
$ ./zig-out/bin/zecho-server --help
zecho server

usage: zecho-server [ -a <address> ] [ -p <port> ]
       zecho-server ( -h | --help )
       zecho-server ( -v | --version )
```

Running zecho-server:
```
$ ./zig-out/bin/zecho-server -a 127.0.0.1 -p 9999
```
