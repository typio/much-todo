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

const ServerCliOptions = struct {
    server_mode: cli.Option = .{
        .long_name = "mode",
        .short_alias = 'm',
        .help = "server mode (debug or release)",
        .value = cli.OptionValue{ .string = "debug" },
    },
    port: cli.Option = .{
        .long_name = "port",
        .short_alias = 'p',
        .help = "port to bind to",
        .value = cli.OptionValue{ .string = "8080" },
    },
};

var server_cli_options = ServerCliOptions{};

var app = &cli.App{
    .name = "much-todo http server",
    .options = &.{ &server_cli_options.server_mode, &server_cli_options.port },
    .action = startServer,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

var running: bool = true;

// Signal handler for SIGINT (Ctrl+C)
pub fn sigintHandler(signum: c_int) void {
    _ = signum;
    running = false;
    std.debug.print("\nReceived SIGINT. Terminating...\n", .{});
    std.process.exit(0);
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
    const file = std.fs.cwd().openFile(filename, .{ .mode = std.fs.File.OpenMode.write_only }) catch try std.fs.cwd().createFile(filename, .{});
    defer file.close();
    var stat = try file.stat();
    try file.seekTo(stat.size);

    var writer = file.writer();
    try writer.print("{s} at {d}\n", .{ ip_string, now });
}

fn handleClientConnection(client: *c.BIO, ctx: *c.SSL_CTX) !void {
    var ssl: ?*c.SSL = null;

    logIp(client) catch std.log.err("Failed to log IP\n", .{});

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

    const filename = "client_ips.log";
    const file = try std.fs.cwd().openFile(filename, .{ .mode = std.fs.File.OpenMode.read_only });
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

    const responseBody = try std.fmt.allocPrint(allocator,
        \\<html>
        \\  <link rel="icon" href="data:image/x-icon;,">
        \\  <body style="text-align:center;">
        \\      <h1 style="color:dodgerblue">Hello, world!</h1>
        \\      <h3 style="color:firebrick">This website has had {d} requests and {d} unique visitors.</h3>
        \\  </body>
        \\</html>
    , .{ view_count, unique_ip_count });

    const responseHeaders = try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nConnection: close\r\nServer: much-todo\r\n\r\n", .{responseBody.len});

    var response_buffer = try allocator.alloc(u8, responseHeaders.len + responseBody.len);
    defer allocator.free(response_buffer);
    std.mem.copy(u8, response_buffer, responseHeaders);
    std.mem.copy(u8, response_buffer[responseHeaders.len..], responseBody);

    const response = @as(*anyopaque, response_buffer.ptr);
    const response_len: c_int = @intCast(response_buffer.len);

    const bytes_written = switch (server_config.mode) {
        ServerModes.release => c.SSL_write(ssl, response, response_len),
        else => c.BIO_write(client, response, response_len),
    };

    std.log.info("Wrote {d} bytes\n", .{bytes_written});

    if (bytes_written <= 0) {
        std.log.err("Failed to write.\n", .{});
    }

    var buffer: [512]u8 = undefined;
    const bytes_read = switch (server_config.mode) {
        ServerModes.release => c.SSL_read(ssl, &buffer, buffer.len),
        else => c.BIO_read(client, &buffer, buffer.len),
    };

    if (bytes_read > 0) {
        const thing = buffer[0..@as(usize, @intCast(bytes_read))];
        var request = std.mem.tokenizeScalar(u8, thing, ' ');
        try parseRequest(&request);
    } else if (bytes_read == 0) {
        std.debug.print("Connection closed by client.\n", .{});
    }

    if (ssl != null) c.SSL_free(ssl);
}

fn parseRequest(request: *std.mem.TokenIterator(u8, std.mem.DelimiterType.scalar)) !void {
    var count: usize = 0;
    while (request.next()) |token| {
        std.log.info("{s}", .{token});
        count += 1;
        if (count == 2) {
            break;
        }
    }
}

fn startServer(_: []const []const u8) !void {
    const m = server_cli_options.server_mode.value.string.?;
    if (std.mem.eql(u8, m, "release")) {
        server_config.mode = ServerModes.release;
        server_config.port = "443";
        std.log.info("In release mode! mode: {any}, port: {s}\n", .{ server_config.mode, server_config.port });
    } else {
        server_config.mode = ServerModes.debug;
        server_config.port = server_cli_options.port.value.string.?;
    }

    const ctx = try initializeServer();
    defer c.SSL_CTX_free(ctx);

    try loadCertificates(ctx);

    const socket = try bindAndListen();

    while (true) {
        if (c.BIO_do_accept(socket) <= 0) {
            std.debug.print("Failed to accept.\n", .{});
            std.time.sleep(std.time.ns_per_ms * 100);
            continue;
        }

        const client = c.BIO_pop(socket) orelse return error.FailedToAccept;
        try handleClientConnection(client, ctx);
    }

    c.BIO_free(socket);

    return socket;
}

pub fn main() !void {
    const handlerPtr = @as(c.__sighandler_t, @ptrCast(&sigintHandler));
    _ = c.signal(2, handlerPtr);

    return cli.run(app, allocator);
}
