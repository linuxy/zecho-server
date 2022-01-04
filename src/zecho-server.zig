const std = @import("std");
const flags = @import("flags.zig");
const builtin = @import("builtin");
const net = std.net;
const os = std.os;
const io = std.io;
const ArrayList = std.ArrayList;
const log = std.log.scoped(.zecho);

const c = @cImport({
    @cInclude("signal.h");
});

pub const log_level: std.log.Level = .info;

const is_windows = builtin.os.tag == .windows;
const is_darwin = builtin.os.tag.isDarwin();
const is_linux = builtin.os.tag == .linux;

var is_exiting = false;

pub const io_mode = .evented;

const usage =
    \\zecho server
    \\
    \\usage: zecho-server [ -a <address> ] [ -p <port> ]
    \\       zecho-server ( -h | --help )
    \\       zecho-server ( -v | --version )
    \\
;

const build_version =
    \\zecho-server (zig echo-server) 0.1.0
    \\Copyright (C) 2021 Ian Applegate
    \\
    \\This program comes with NO WARRANTY, to the extent permitted by law.
    \\You may redistribute copies of this program under the terms of
    \\the GNU General Public License.
    \\For more information about these matters, see the file named COPYING.
    \\
;

pub fn main() !void {
    _ = c.signal(c.SIGINT, handleInterrupt);
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    var gpa = general_purpose_allocator.allocator();

    var server = Zecho().init(gpa);
    defer server.deinit();
    try server.parseArgs();
    try server.start();
}

pub fn Zecho() type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        arg_address: [:0]const u8,
        arg_port: u16,
        arg_count: u16,
        arg_udp: bool,
        arg_uring: bool,

        parsed_address: std.net.Address,
        found_port: bool,
        found_address: bool,
        barrier: Barrier,
        socket: os.socket_t,
        socket_len: os.socklen_t,
        clients: ArrayList(*Client),
        tick: u64,
        mutex: std.Thread.Mutex,

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self {
                .allocator = allocator,
                .arg_address = undefined,
                .arg_port = undefined,
                .arg_count = 0,
                .arg_udp = false,
                .arg_uring = false,
                .parsed_address = undefined,
                .found_port = false,
                .found_address = false,
                .barrier = undefined,
                .socket = undefined,
                .socket_len = 0,
                .clients = ArrayList(*Client).init(allocator),
                .tick = 0,
                .mutex = std.Thread.Mutex{},
            };
        }

        pub fn start(self: *Self) !void {
            const kernel_backlog = 1;

            self.socket = try os.socket(self.parsed_address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC | os.SOCK.NONBLOCK, os.IPPROTO.TCP);
            self.socket_len = self.parsed_address.getOsSockLen();

            try os.setsockopt(self.socket, os.SOL.SOCKET, os.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
            try os.bind(self.socket, &self.parsed_address.any, self.socket_len);
            try os.listen(self.socket, kernel_backlog);

            self.barrier = Barrier{};
            self.barrier.start();

            // Cleanup has a race condition, so this will leak the thread handles until fixed
            //_ = std.Thread.spawn(.{}, cleanup, .{ self }) catch unreachable;

            while(!is_exiting) {
                std.os.nanosleep(0, 10);
                const peer = os.accept(self.socket, &self.parsed_address.any, &self.socket_len, os.SOCK.CLOEXEC | os.SOCK.NONBLOCK) catch continue;
                if(@TypeOf(peer) == i32) {
                    var client_ptr = self.allocator.create(Client) catch unreachable;
                    client_ptr.* = client_ptr.init();
                    client_ptr.* = client_ptr.add(peer);
                    self.mutex.lock();
                    try self.clients.append(client_ptr);
                    self.mutex.unlock();
                }
            }
            self.barrier.stop();
        }

        pub fn deinit(self: *Self) void {
            os.close(self.socket);
            self.clients.deinit();
        }

        inline fn remove(self: *Self, sock: *Client) void {
            for (self.clients.items) |client, i| {
                if (sock.fd == client.fd) {
                    _ = self.clients.swapRemove(i);
                }
            }
        }

        pub fn cleanup(self: *Self) void {
            while(self.barrier.isRunning()) {
                for (self.clients.items) |client| {
                    if(client.dead) {
                        self.mutex.lock();
                        remove(self, client);
                        self.mutex.unlock();
                    }
                }
                std.os.nanosleep(1, 0);
            }
        }

        pub fn parseArgs(self: *Self) anyerror!void {
            const argv: [][*:0]const u8 = os.argv;
            const result = flags.parse(argv[1..], &[_]flags.Flag{
                .{ .name = "--help", .kind = .boolean },
                .{ .name = "-h", .kind = .boolean },
                .{ .name = "--version", .kind = .boolean },
                .{ .name = "-v", .kind = .boolean },
                .{ .name = "-u", .kind = .boolean },
                .{ .name = "--udp", .kind = .boolean },
                .{ .name = "-p", .kind = .arg },
                .{ .name = "-a", .kind = .arg },
                .{ .name = "-c", .kind = .arg },                
            }) catch {
                try io.getStdErr().writeAll(usage);
                os.exit(1);
            };
            if (result.boolFlag("--help") or result.boolFlag("-h")) {
                try io.getStdOut().writeAll(usage);
                os.exit(0);
            }
            if (result.args.len != 0) {
                std.log.err("unknown option '{s}'", .{result.args[0]});
                try io.getStdErr().writeAll(usage);
                os.exit(1);
            }
            if (result.boolFlag("--version") or result.boolFlag("-v")) {
                try io.getStdOut().writeAll(build_version);
                os.exit(0);
            }
            if (result.argFlag("-a")) |address| {
                if(result.args.len == 0) {
                    log.info("Found ip address: {s}", .{address});
                    self.arg_address = std.mem.span(address);
                    self.found_address = true;
                } else {
                    try io.getStdErr().writeAll("Invalid argument for -a expected type [u8]\n");
                    os.exit(1);
                }
            }
            if (result.argFlag("-p")) |port| {
                const maybe_port = std.fmt.parseInt(u16,  std.mem.span(port), 10) catch null;
                if(maybe_port) |int_port| {
                    log.info("Found port address: {}", .{int_port});
                    self.arg_port = int_port;
                    self.found_port = true;
                } else {
                    try io.getStdErr().writeAll("Invalid argument for -p expected type [u16]\n");
                    os.exit(1);            
                }
            }
            if (result.argFlag("-c")) |count| {
                const maybe_count = std.fmt.parseInt(u16,  std.mem.span(count), 10) catch null;
                if (maybe_count) |int_count| {
                    log.info("Found int count: {}", .{int_count});
                    self.arg_count = int_count;
                } else {
                    try io.getStdErr().writeAll("Invalid argument for -c expected type [u16]\n");
                    os.exit(1);
                }
            }
            if(self.found_address and self.found_port) {
                const arg_con = net.Address.parseIp(self.arg_address, self.arg_port) catch {
                        try io.getStdErr().writeAll("Invalid address and/or port.\n");
                        os.exit(1);        
                };
                log.info("Found valid port & address.", .{});
                self.parsed_address = arg_con;
            } else {
                if (os.argv.len - 1 == 0) {
                    try io.getStdOut().writeAll(usage);
                    os.exit(0);
                } else {
                    try io.getStdErr().writeAll("Address and/or port not found.\n");
                    os.exit(1);            
                }
            }
        }
    };
}

fn handleInterrupt(signal: c_int) callconv(.C) void {
    is_exiting = true;
    log.info("Requesting exit.", .{});
    _ = signal;
}

const Client = struct {
    const Self = @This();

    fd: i32,
    thread: std.Thread,
    ts: i64,
    timeout: i64,
    dead: bool,

    pub fn init(self: *Self) Self {
        _ = self;
        return Self {
            .fd = undefined,
            .thread = undefined,
            .ts = undefined,
            .timeout = undefined,
            .dead = undefined,
        };
    }

    pub fn add(self: *Self, fd: i32) Self {
        return Self {
            .fd = fd,
            .thread = std.Thread.spawn(.{}, run, .{ self }) catch unreachable,
            .ts = std.time.milliTimestamp(),
            .timeout = 5000,
            .dead = false,
        };
    }

    fn run(self: *Self) void {
        var recv_buf: [256]u8 = undefined;

        while(!is_exiting) {
            if((std.time.milliTimestamp() - self.ts) > self.timeout) {
                self.dead = true;
                os.close(self.fd);
                break;
            }
            
            const bytes_read = read_(self.fd, &recv_buf) catch continue;

            if(bytes_read > 0) {
                const bytes_written = os.linux.write(self.fd, &recv_buf, recv_buf.len);
                _ = bytes_written;
                recv_buf = undefined;
                self.ts = std.time.milliTimestamp();
            }
            _ = self;
        }
    }

    pub fn read_(fd: os.fd_t, buf: []u8) !usize {
        const max_count = switch (builtin.os.tag) {
            .linux => 0x7ffff000,
            .macos, .ios, .watchos, .tvos => std.math.maxInt(i32),
            else => std.math.maxInt(isize),
        };
        const adjusted_len = std.math.min(max_count, buf.len);
        
        while (true) {
            const rc = os.system.read(fd, buf.ptr, adjusted_len);
            switch (os.errno(rc)) {
                .SUCCESS => return @intCast(usize, rc),
                .INTR => continue,
                .INVAL => unreachable,
                .FAULT => unreachable,
                .AGAIN => return error.WouldBlock,
                .BADF => return error.NotOpenForReading, // Can be a race condition.
                .IO => return error.InputOutput,
                .ISDIR => return error.IsDir,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                .NOTCONN => return error.SocketNotConnected,
                .CONNRESET => return error.ConnectionResetByPeer,
                .TIMEDOUT => return error.ConnectionTimedOut,
                else => |err| return os.unexpectedErrno(err),
            }
        }
        return os.index;
    }
};

const Barrier = struct {
    state: std.atomic.Atomic(u32) = std.atomic.Atomic(u32).init(0),

    fn wait(self: *const Barrier) void {
        while (self.state.load(.Acquire) == 0) {
            std.Thread.Futex.wait(&self.state, 0, null) catch unreachable;
        }
    }

    fn isRunning(self: *const Barrier) bool {
        return self.state.load(.Acquire) == 1;
    }

    fn wake(self: *Barrier, value: u32) void {
        self.state.store(value, .Release);
        std.Thread.Futex.wake(&self.state, std.math.maxInt(u32));
    }

    fn start(self: *Barrier) void {
        self.wake(1);
    }

    fn stop(self: *Barrier) void {
        self.wake(2);
    }
};