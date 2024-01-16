const std = @import("std");

const cli = @import("zig-cli");

const c = @cImport({
    @cInclude("signal.h");

    @cInclude("sys/socket.h");
    @cInclude("arpa/inet.h");

    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/bio.h");
});

const ServerModes = enum { debug, release };
const ServerConfig = struct {
    mode: ServerModes,
    port: []const u8,
};

var server_config = ServerConfig{ .mode = ServerModes.debug, .port = "8080" };

var cli_option_server_mode = cli.Option{
    .long_name = "mode",
    .short_alias = 'm',
    .help = "server mode (debug or release)",
    .required = false,
    .value_ref = cli.mkRef(&server_config.mode),
};

var cli_option_port = cli.Option{
    .long_name = "port",
    .short_alias = 'p',
    .help = "port to bind to",
    .required = false,
    .value_ref = cli.mkRef(&server_config.port),
};

var app = &cli.App{
    .name = "much-todo http server",
    .options = &.{ &cli_option_server_mode, &cli_option_port },
    .action = startServer,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

var running: bool = true;

const HTTPMethod = enum {
    HEAD,
    GET,
    PUT,
    POST,
    DELETE,
};

const HTTPRequest = struct { path: []const u8, method: HTTPMethod, header: []const u8, body: []const u8 };

pub fn handleExitSignal(signum: c_int) callconv(.C) void {
    switch (signum) {
        c.SIGINT => std.debug.print("\nReceived SIGINT. Terminating...\n", .{}),
        c.SIGTERM => std.debug.print("\nReceived SIGTERM. Terminating...\n", .{}),
        else => {},
    }
    running = false;
}

fn initializeServer() !*c.SSL_CTX {
    if (1 != c.OPENSSL_init_ssl(c.OPENSSL_INIT_LOAD_SSL_STRINGS | c.OPENSSL_INIT_LOAD_CRYPTO_STRINGS, null)) {
        std.log.err("OPENSSL_init_ssl failed\n", .{});
        return error.FailedToInitializeSSL;
    }

    const method = c.TLS_server_method();
    const ctx = c.SSL_CTX_new(method);

    if (ctx) |context| {
        return context;
    } else {
        std.debug.print("Failed to create SSL context.\n", .{});
        return error.FailedToInitializeSSL;
    }
}

fn loadCertificates(ctx: *c.SSL_CTX) !void {
    if (server_config.mode != ServerModes.release) return;

    if (c.SSL_CTX_use_certificate_file(ctx, "/etc/letsencrypt/live/muchtodo.app/fullchain.pem", c.SSL_FILETYPE_PEM) <= 0 or
        c.SSL_CTX_use_PrivateKey_file(ctx, "/etc/letsencrypt/live/muchtodo.app/privkey.pem", c.SSL_FILETYPE_PEM) <= 0)
    {
        std.debug.print("Failed to load certificate or key.\n", .{});
        return;
    }
}

fn bindAndListen() !*c.BIO {
    std.debug.print("Port: {s}\n", .{server_config.port});

    const socket = c.BIO_new_accept(@ptrCast(server_config.port));
    _ = c.BIO_set_accept_bios(socket, null);
    if (c.BIO_do_accept(socket) <= 0) {
        std.debug.print("Failed to bind.\n", .{});
        return error.FailedToBind;
    }
    if (socket) |unwraped_socket| {
        return unwraped_socket;
    } else {
        std.debug.print("Failed to bind.\n", .{});
        return error.FailedToBind;
    }
}

fn logIp(client: *c.BIO) !void {
    var ip_string: []const u8 = undefined;
    const now = std.time.timestamp();

    const client_fd: c_int = @intCast(c.BIO_get_fd(client, null));
    var client_addr: c.struct_sockaddr = undefined;

    // can't use struct_sockaddr_storage bc of getpeername type checking
    var client_addr_len: std.os.socklen_t = @sizeOf(c.struct_sockaddr);
    if (c.getpeername(client_fd, &client_addr, &client_addr_len) < 0) {
        std.log.err("didn't get IP\n", .{});
    }

    const family = client_addr.sa_family;

    const struct_sockaddr_in = packed struct { // corresponds to c.struct_sockaddr_in
        sin_family: i16, // c.sa_family_t, is a short
        sin_port: u16, // u short
        sin_addr: u32, // struct {
        //     s_addr: u long,
        // },
        sin_zero: u64, // 8 bytes of padding
    };

    switch (family) {
        c.AF_INET => {
            var ca: *struct_sockaddr_in = @ptrCast(@alignCast(&client_addr));

            var in_addr: c.in_addr_t = ca.sin_addr;
            var in_addr_struct: *c.struct_in_addr = @ptrCast(@alignCast(&in_addr));
            var ip: [*c]const u8 = c.inet_ntoa(in_addr_struct.*);

            ip_string = try std.fmt.allocPrint(allocator, "{s}", .{ip});
        },
        c.AF_INET6 => {
            // We don't support this rn
            return error.UnsupportedAddressFamily;
        },
        else => {
            std.log.err("Unknown address family: {d}\n", .{family});
            return error.UnsupportedAddressFamily;
        },
    }

    std.debug.print("IP: {s} connected.\n", .{ip_string});

    const filename = "client_ips.log";
    const file = try std.fs.cwd().createFile(filename, .{ .read = false, .truncate = false });
    defer file.close();
    var stat = try file.stat();
    try file.seekTo(stat.size);

    var writer = file.writer();
    try writer.print("{s} at {d}\n", .{ ip_string, now });
}

fn handleClientConnection(client: *c.BIO, ctx: *c.SSL_CTX) !void {
    var ssl: ?*c.SSL = null;

    if (server_config.mode == .release) {
        logIp(client) catch std.log.err("Failed to log IP\n", .{});
    }

    if (server_config.mode == ServerModes.release) {
        ssl = c.SSL_new(ctx);
        c.SSL_set_bio(ssl, client, client);

        if (c.SSL_accept(ssl) <= 0) {
            const err = c.ERR_get_error();
            var errbuf: [128]u8 = undefined;
            c.ERR_error_string_n(err, &errbuf, errbuf.len);
            std.debug.print("Failed SSL handshake: {s}\n", .{errbuf[0..]});
            return;
        }
    }

    var buffer: [8_000]u8 = undefined;
    const bytes_read = switch (server_config.mode) {
        ServerModes.release => c.SSL_read(ssl, &buffer, buffer.len),
        else => c.BIO_read(client, &buffer, buffer.len),
    };

    if (bytes_read > 0) {
        const thing = buffer[0..@as(usize, @intCast(bytes_read))];

        // TODO: Find an idiomatic way to do this (difficulty is that delimiters are different)
        const firstSpace = std.mem.indexOf(u8, thing, " ") orelse 0;
        const secondSpace = firstSpace + 1 + (std.mem.indexOf(u8, thing[firstSpace + 1 ..], " ") orelse firstSpace);
        const bodyStart = secondSpace + 4 + (std.mem.indexOf(u8, thing[secondSpace + 1 ..], "\r\n\r\n") orelse secondSpace);

        // TODO: Actually parse headers (replace string with HashMap or struct)
        const request_method = std.meta.stringToEnum(HTTPMethod, thing[0..firstSpace]) orelse return;
        const httpRequest = HTTPRequest{ .method = request_method, .path = thing[(firstSpace + 1)..secondSpace], .header = thing[(secondSpace + 1)..bodyStart], .body = thing[(bodyStart + 1)..] };

        try parseRequest(&httpRequest, client, ssl);
    } else if (bytes_read == 0) {
        std.debug.print("Connection closed by client.\n", .{});
    }

    if (ssl) |ssl_obj| {
        if (c.SSL_shutdown(ssl_obj) == 0) {
            _ = c.SSL_shutdown(ssl_obj);
        }
        c.SSL_free(ssl_obj);
    }
}

fn parseRequest(request: *const HTTPRequest, client: *c.BIO, ssl: ?*c.SSL) !void {
    var response_buffers = ResponseBuffers{ .header = null, .body = null };
    defer if (response_buffers.header) |header| allocator.free(header);
    defer if (response_buffers.body) |body| allocator.free(body);

    if (request.method == .GET or request.method == .HEAD) {
        if (std.mem.eql(u8, request.path, "/")) {
            const filename = "build/frontend/index.html";
            const file = try std.fs.cwd().openFile(filename, .{ .mode = .read_only });

            defer file.close();

            response_buffers.body = try file.reader().readAllAlloc(
                allocator,
                16 * 1024,
            );

            response_buffers.header = try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nConnection: close\r\nServer: much-todo\r\n\r\n", .{response_buffers.body.?.len});
        } else if (std.mem.eql(u8, request.path, "/favicon.ico")) {
            const filename = "build/frontend/favicon.ico";
            const file = try std.fs.cwd().openFile(filename, .{ .mode = .read_only });

            defer file.close();

            response_buffers.body = try file.reader().readAllAlloc(
                allocator,
                16 * 1024,
            );

            response_buffers.header = try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\nServer: much-todo\r\n\r\n", .{response_buffers.body.?.len});
        } else if (std.mem.eql(u8, request.path, "/api/messages")) {
            const stream = try std.net.tcpConnectToHost(allocator, "localhost", 7050);
            defer stream.close();

            const appRequest = "GET / HTTP/1.1\r\nHost: localhost:7050\r\nConnection: close\r\n\r\n";
            _ = try stream.writeAll(appRequest);

            var appResponseBuffer: [16_000]u8 = undefined;
            // while (true) {
            const bytes_read = try stream.read(appResponseBuffer[0..]);
            // if (bytes_read == 0) break;

            var it = std.mem.split(u8, appResponseBuffer[0..bytes_read], "\r\n\r\n");
            _ = it.next();
            const appResponseBody = it.next() orelse "";

            response_buffers.body = try std.fmt.allocPrint(allocator, "{s}", .{appResponseBody});
            response_buffers.header = try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nServer: much-todo\r\n\r\n", .{response_buffers.body.?.len});
            // }
        } else if (std.mem.eql(u8, request.path, "/api/viewCount")) {
            const filename = "client_ips.log";
            const file = try std.fs.cwd().createFile(filename, .{ .read = true, .truncate = false });
            defer file.close();

            const contents = try file.reader().readAllAlloc(
                allocator,
                1024 * 1024 * 10,
            );

            var ip_strings = std.mem.tokenizeScalar(u8, contents, '\n');
            var unique_ip_count: usize = 0;
            var view_count: usize = 0;
            var unique_ip_set = std.BufSet.init(allocator);

            while (ip_strings.next()) |ip_string| {
                if (ip_string.len == 0) continue;
                view_count += 1;

                var ip_log_parts = std.mem.tokenizeScalar(u8, ip_string, ' ');
                var ip = ip_log_parts.next().?;

                if (!unique_ip_set.contains(ip)) {
                    unique_ip_count += 1;
                    try unique_ip_set.insert(ip);
                }
            }
            response_buffers.body = try std.fmt.allocPrint(allocator, "{{\"view_count\": {d}, \"unique_ip_count\": {d}}}", .{ view_count, unique_ip_count });
            response_buffers.header = try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nServer: much-todo\r\n\r\n", .{response_buffers.body.?.len});
        } else {
            std.log.info("404 not found: {s}", .{request.path});
        }
    } else if (request.method == .POST) {
        const stream = try std.net.tcpConnectToHost(allocator, "localhost", 7050);
        defer stream.close();

        const appRequest = try std.fmt.allocPrint(allocator, "POST / HTTP/1.1\r\nOrigin: http://localhost:7050\r\nHost: localhost:7050\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ request.body.len, request.body });

        _ = try stream.writeAll(appRequest);

        var appResponseBuffer: [16_000]u8 = undefined;
        // while (true) {
        const bytes_read = try stream.read(appResponseBuffer[0..]);
        // if (bytes_read == 0) break;

        var it = std.mem.split(u8, appResponseBuffer[0..bytes_read], "\r\n\r\n");
        _ = it.next() orelse "";
        const appResponseBody = it.next() orelse "";

        response_buffers.body = try std.fmt.allocPrint(allocator, "{s}", .{appResponseBody});
        response_buffers.header = try std.fmt.allocPrint(allocator, "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nServer: much-todo\r\n\r\n", .{response_buffers.body.?.len});
        // }
    } else if (request.method == .DELETE) {
        const stream = try std.net.tcpConnectToHost(allocator, "localhost", 7050);
        defer stream.close();

        const appRequest = try std.fmt.allocPrint(allocator, "DELETE / HTTP/1.1\r\nOrigin: http://localhost:7050\r\nHost: localhost:7050\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ request.body.len, request.body });

        _ = try stream.writeAll(appRequest);

        var appResponseBuffer: [16_000]u8 = undefined;
        const bytes_read = try stream.read(appResponseBuffer[0..]);

        var it = std.mem.split(u8, appResponseBuffer[0..bytes_read], "\r\n\r\n");
        _ = it.next() orelse "";
        const appResponseBody = it.next() orelse "";

        response_buffers.body = try std.fmt.allocPrint(allocator, "{s}", .{appResponseBody});
        response_buffers.header = try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nServer: much-todo\r\n\r\n", .{response_buffers.body.?.len});
        // }
    } else {
        std.log.info("Unsupported request method: {?}, on path: {s}", .{ request.method, request.path });
    }

    // Serve the reponse
    if (response_buffers.body != null and response_buffers.header != null) {
        if (request.method == .HEAD) {
            var buffer = try allocator.alloc(u8, response_buffers.header.?.len);
            std.mem.copy(u8, buffer, response_buffers.header.?);
            try serveBytes(client, ssl, buffer);
        } else {
            var buffer = try allocator.alloc(u8, response_buffers.header.?.len + response_buffers.body.?.len);
            std.mem.copy(u8, buffer, response_buffers.header.?);
            std.mem.copy(u8, buffer[response_buffers.header.?.len..], response_buffers.body.?);
            try serveBytes(client, ssl, buffer);
        }
    }
}

const ResponseBuffers = struct {
    header: ?[]const u8,
    body: ?[]const u8,
};

fn serveBytes(client: *c.BIO, ssl: ?*c.SSL, bytes: []const u8) !void {
    const bytes_written = switch (server_config.mode) {
        ServerModes.release => c.SSL_write(ssl, @as(*const anyopaque, bytes.ptr), @intCast(bytes.len)),
        else => c.BIO_write(client, @as(*const anyopaque, bytes.ptr), @intCast(bytes.len)),
    };

    if (bytes_written <= 0) {
        std.log.err("Failed to write.", .{});
    }
}

fn startServer(_: []const []const u8) !void {
    const c_o = &server_config;

    if (c_o.mode == ServerModes.release) {
        server_config.mode = ServerModes.release;
        server_config.port = "443";
        std.log.info("In release mode! mode: {any}, port: {s}\n", .{ server_config.mode, server_config.port });
    } else {
        server_config.mode = ServerModes.debug;
        server_config.port = c_o.port;
    }

    const ctx = try initializeServer();
    defer c.SSL_CTX_free(ctx);

    try loadCertificates(ctx);

    const socket = try bindAndListen();
    defer _ = c.BIO_free(socket);

    while (running) {
        if (c.BIO_do_accept(socket) <= 0) {
            std.debug.print("Failed to accept.", .{});
            continue;
        }

        const client = c.BIO_pop(socket);
        if (client == null) {
            std.debug.print("Failed to pop client socket.\n", .{});
        } else {
            handleClientConnection(client.?, ctx) catch |err| {
                std.debug.print("Error handling client connection: {}\n", .{err});
            };
        }
    }

    std.debug.print("\nShutting down...\n", .{});
}

pub fn main() !void {
    const sigintHandlerPtr = @as(fn (c_int) callconv(.C) void, handleExitSignal);
    const sigtermHandlerPtr = @as(fn (c_int) callconv(.C) void, handleExitSignal);

    _ = c.signal(c.SIGINT, sigintHandlerPtr);
    _ = c.signal(c.SIGTERM, sigtermHandlerPtr);

    return cli.run(app, allocator);
}
