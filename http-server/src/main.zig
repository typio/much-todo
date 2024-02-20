const std = @import("std");

const cli = @import("zig-cli");

const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/time.h");
    @cInclude("sys/select.h");

    @cInclude("unistd.h");

    @cInclude("signal.h");

    @cInclude("sys/socket.h");
    @cInclude("arpa/inet.h");

    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/bio.h");
});

const file_server = @import("./file_server.zig");
const api = @import("./api.zig");

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

var app = &cli.App{ .command = cli.Command{ .name = "much-todo http server", .options = &.{ &cli_option_server_mode, &cli_option_port }, .target = cli.CommandTarget{
    .action = cli.CommandAction{ .exec = startServer },
} } };

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
var file_server_instance: file_server.FileServer = undefined;

var server_start_time: i64 = undefined;
var running: bool = true;

pub const HTTPMethod = enum {
    HEAD,
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
};

// NOTE: head includes /r/n/r/n seperator for convenience
pub const ResponseBuffers = struct {
    head: ?[]const u8,
    body: ?[]const u8,
};

pub const HTTPHead = struct { path: []const u8, method: HTTPMethod, content_length: u16 };

pub const HTTPRequest = struct { head: HTTPHead, body: []const u8, source_ip: []const u8 };

pub const USER_REQUEST_BUFFER_SIZE = 32 * 1024;
pub const API_RESPONSE_BUFFER_SIZE = 256 * 1024;
pub const FILE_SERVE_BUFFER_SIZE = 2000 * 1024;

const MAX_POLL_ATTEMPTS = 10;
const POLL_MS_TIMEOUT = 1000;

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

    //TODO: set this programatically
    // remote linux server
    if (c.SSL_CTX_use_certificate_file(ctx, "/etc/letsencrypt/live/muchtodo.app/fullchain.pem", c.SSL_FILETYPE_PEM) <= 0 or
        c.SSL_CTX_use_PrivateKey_file(ctx, "/etc/letsencrypt/live/muchtodo.app/privkey.pem", c.SSL_FILETYPE_PEM) <= 0)
    {
        std.debug.print("Failed to load certificate or key.\n", .{});
        return;
    }

    // local machine
    // if (c.SSL_CTX_use_certificate_file(ctx, "build/cert.pem", c.SSL_FILETYPE_PEM) <= 0 or
    //     c.SSL_CTX_use_PrivateKey_file(ctx, "build/key.pem", c.SSL_FILETYPE_PEM) <= 0)
    // {
    //     std.debug.print("Failed to load certificate or key.\n", .{});
    //     return;
    // }
}

fn logIp(client: *c.BIO) ![]const u8 {
    const filename = "http-server.log";
    const contents = try std.fs.cwd().readFileAlloc(allocator, filename, FILE_SERVE_BUFFER_SIZE);
    defer allocator.free(contents);
    var logLines = std.mem.splitScalar(u8, contents, '\n');
    const request_count: usize = std.fmt.parseInt(u32, logLines.first(), 10) catch 0;

    const file = try std.fs.cwd().createFile(filename, .{ .read = false, .truncate = true });
    defer file.close();

    try file.writeAll(try std.fmt.allocPrint(allocator, "{d}\n{d}", .{ request_count + 1, server_start_time }));

    if (server_config.mode == ServerModes.debug) return "127.0.0.1";

    var ip_string: ?[]const u8 = null;
    // const now = std.time.timestamp();

    const client_fd: c_int = @intCast(c.BIO_get_fd(client, null));
    var client_addr: c.struct_sockaddr = .{};

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
            const ca: *struct_sockaddr_in = @ptrCast(@alignCast(&client_addr));

            var in_addr: c.in_addr_t = ca.sin_addr;
            const in_addr_struct: *c.struct_in_addr = @ptrCast(@alignCast(&in_addr));
            const ip: [*c]const u8 = c.inet_ntoa(in_addr_struct.*);

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

    ip_string = ip_string orelse try std.fmt.allocPrint(allocator, "{s}", .{"no ip!"});

    std.debug.print("IP: {s} connected.\n", .{ip_string.?});

    return ip_string.?;
}

fn parseHead(head: []const u8) !HTTPHead {
    var head_lines = std.mem.splitScalar(u8, head, '\n');

    const first_line = head_lines.first();

    var start_line_parts = std.mem.splitScalar(u8, first_line, ' ');

    const method = std.meta.stringToEnum(HTTPMethod, start_line_parts.next() orelse return error.MalformedRequest) orelse return error.MalformedRequest;
    const path = start_line_parts.next() orelse return error.MalformedRequest;

    var content_length: u16 = 0;
    while (head_lines.next()) |line| {
        var header: []const u8 = "";
        var value: []const u8 = "";
        for (line, 0..) |line_c, i| {
            if (line_c == ':') {
                header = line[0..i];
                value = line[i + 2 .. line.len - 1];
                if (std.mem.eql(u8, header, "Content-Length")) {
                    content_length = try std.fmt.parseInt(u16, value, 10);
                }
                break;
            }
        }
    }

    return HTTPHead{ .method = method, .path = path, .content_length = content_length };
}

fn handleClientRequest(client: *c.BIO, ssl: ?*c.SSL, source_ip: []const u8) !void {
    var request_head: ?HTTPHead = null;
    var request_body: ?[]const u8 = null;

    var buffer: [USER_REQUEST_BUFFER_SIZE]u8 = [_]u8{0} ** USER_REQUEST_BUFFER_SIZE;
    var total_read: usize = 0;

    const fd = switch (server_config.mode) {
        ServerModes.release => c.SSL_get_fd(ssl.?),
        else => c.BIO_get_fd(client, null),
    };

    var attempts: usize = 0;

    var poll_fds: [1]std.os.pollfd = [_]std.os.pollfd{.{ .revents = 0, .fd = @intCast(fd), .events = std.os.POLL.IN }};

    while (true) {
        const n = try std.os.poll(&poll_fds, POLL_MS_TIMEOUT);
        if (n > 0 and (poll_fds[0].revents & std.os.POLL.IN) != 0) {
            const read_result = switch (server_config.mode) {
                ServerModes.release => c.SSL_read(ssl, &buffer, @intCast(buffer.len - total_read)),
                else => c.BIO_read(client, &buffer, @intCast(buffer.len - total_read)),
            };

            if (read_result > 0) {
                total_read += @intCast(read_result);

                const initial_read = buffer[0..@as(usize, @intCast(total_read))];

                var request_parts = std.mem.splitSequence(u8, initial_read, "\r\n\r\n");
                request_head = parseHead(request_parts.next() orelse return error.MalformedRequest) catch return error.MalformedRequest;

                request_body = request_parts.next() orelse "";

                // If the Content-Length header indicates more data, attempt to read more
                if (request_head.?.content_length > request_body.?.len) {
                    // Calculate remaining bytes to read
                    var remaining_bytes = request_head.?.content_length - @as(u16, @intCast(request_body.?.len));
                    var total_read_bytes = request_body.?.len;
                    while (remaining_bytes > 0) {
                        std.debug.print("Remaining {d} of {d}\n", .{ remaining_bytes, total_read_bytes });
                        var read_buffer: [USER_REQUEST_BUFFER_SIZE]u8 = [_]u8{0} ** USER_REQUEST_BUFFER_SIZE;
                        const body_bytes_read = switch (server_config.mode) {
                            ServerModes.release => c.SSL_read(ssl, &read_buffer, remaining_bytes),
                            else => c.BIO_read(client, &read_buffer, remaining_bytes),
                        };
                        if (body_bytes_read <= 0) {
                            std.debug.print("Failed to read remaining body bytes.\n", .{});
                            return;
                        }
                        // Append read bytes to request body
                        request_body.? = try std.mem.concat(allocator, u8, &[_][]const u8{ request_body.?, read_buffer[0..@as(usize, @intCast(body_bytes_read))] });
                        remaining_bytes -= @as(u16, @intCast(body_bytes_read));
                        total_read_bytes += @as(usize, @intCast(body_bytes_read));
                        if (total_read_bytes > USER_REQUEST_BUFFER_SIZE) {
                            std.debug.print("Request body exceeds buffer size.\n", .{});
                            return;
                        }
                    }
                } else {
                    break;
                }
            } else if (read_result == 0) {
                // std.debug.print("Connection closed by peer.\n", .{});
                return;
            } else {
                break;
            }
        } else if (n == 0) {
            attempts += 1;
            std.debug.print("Write timeout, attempt {d} of {d}.\n", .{ attempts, MAX_POLL_ATTEMPTS });
            if (attempts >= MAX_POLL_ATTEMPTS) {
                std.debug.print("Max read attempts reached, giving up.\n", .{});
                return;
            }
        } else {
            std.debug.print("Error during write poll.\n", .{});
            return;
        }
    }

    if (request_head != null and request_body != null) {
        const httpRequest = HTTPRequest{ .head = request_head.?, .body = request_body.?, .source_ip = source_ip };
        try parseRequest(httpRequest, client, ssl);
    }
}

fn parseRequest(request: HTTPRequest, client: *c.BIO, ssl: ?*c.SSL) !void {
    var response_buffers = ResponseBuffers{ .head = null, .body = null };
    defer if (response_buffers.head) |head| allocator.free(head);
    defer if (response_buffers.body) |body| allocator.free(body);

    if ((request.head.method == .GET or request.head.method == .HEAD) and file_server_instance.routeToFileMap.contains(request.head.path)) {
        response_buffers = (try file_server_instance.serveFile(request.head.path)).?;
    }

    if (std.mem.startsWith(u8, request.head.path, "/api/")) {
        if (try api.handleRequest(&allocator, request)) |res| {
            response_buffers = res;
        }
    }

    if (response_buffers.body == null or response_buffers.head == null) {
        std.log.info("404 not found: {s}", .{request.head.path});

        const filename = "build/frontend/_404.html";
        const file = try std.fs.cwd().openFile(filename, .{ .mode = .read_only });

        defer file.close();

        response_buffers.body = try file.reader().readAllAlloc(
            allocator,
            FILE_SERVE_BUFFER_SIZE,
        );

        response_buffers.head = try std.fmt.allocPrint(allocator, "HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nConnection: close\r\nServer: much-todo\r\n\r\n", .{response_buffers.body.?.len});
    }

    if (request.head.method == .HEAD) {
        const buffer = try allocator.alloc(u8, response_buffers.head.?.len);
        std.mem.copyForwards(u8, buffer, response_buffers.head.?);
        try serveBytes(client, ssl, buffer);
    } else {
        var buffer = try allocator.alloc(u8, response_buffers.head.?.len + response_buffers.body.?.len);
        std.mem.copyForwards(u8, buffer, response_buffers.head.?);
        std.mem.copyForwards(u8, buffer[response_buffers.head.?.len..], response_buffers.body.?);
        try serveBytes(client, ssl, buffer);
    }
}

fn serveBytes(client: *c.BIO, ssl: ?*c.SSL, bytes: []const u8) !void {
    var total_bytes_written: usize = 0;

    var attempts: usize = 0;

    const fd = switch (server_config.mode) {
        ServerModes.release => c.SSL_get_fd(ssl.?),
        else => c.BIO_get_fd(client, null),
    };

    var poll_fds: [1]std.os.pollfd = [_]std.os.pollfd{.{ .revents = 0, .fd = @intCast(fd), .events = std.os.POLL.OUT }};

    while (total_bytes_written < bytes.len) {
        const n = try std.os.poll(&poll_fds, POLL_MS_TIMEOUT);
        if (n > 0 and (poll_fds[0].revents & std.os.POLL.OUT) != 0) {
            const remaining_bytes = bytes.len - total_bytes_written;
            const chunk = bytes[total_bytes_written..];
            const bytes_written = switch (server_config.mode) {
                ServerModes.release => c.SSL_write(ssl, chunk.ptr, @intCast(remaining_bytes)),
                else => c.BIO_write(client, chunk.ptr, @intCast(remaining_bytes)),
            };

            if (bytes_written > 0) {
                attempts = 0;
                total_bytes_written += @intCast(bytes_written);
            } else if (bytes_written == 0) {
                std.debug.print("Connection closed by peer during write.\n", .{});
                return;
            } else {
                const write_error = if (server_config.mode == .release) c.SSL_get_error(ssl.?, bytes_written) else -1;
                if (write_error == c.SSL_ERROR_WANT_WRITE or write_error == c.SSL_ERROR_WANT_READ) {
                    continue;
                } else {
                    std.debug.print("Write error: {d}\n", .{write_error});
                    return;
                }
            }
        } else if (n == 0) {
            // Timeout handling
            attempts += 1;
            std.debug.print("Write timeout, attempt {d} of {d}.\n", .{ attempts, MAX_POLL_ATTEMPTS });
            if (attempts >= MAX_POLL_ATTEMPTS) {
                std.debug.print("Max write attempts reached, giving up.\n", .{});
                return; // Exceeded max attempts, give up
            }
        } else {
            std.debug.print("Error during read poll.\n", .{});
            return;
        }
    }
}

fn bindAndListen() !*c.BIO {
    std.debug.print("Port: {s}\n", .{server_config.port});

    const bio = c.BIO_new_accept(@ptrCast(server_config.port)) orelse {
        std.debug.print("Failed to create BIO socket.\n", .{});
        return error.FailedToCreateSocket;
    };

    if (c.BIO_set_nbio(bio, 1) <= 0) {
        c.BIO_free_all(bio);
        std.debug.print("Failed to set BIO to non-blocking mode.\n", .{});
        return error.FailedToSetNonBlocking;
    }

    if (c.BIO_do_accept(bio) <= 0) {
        c.BIO_free_all(bio);
        std.debug.print("Failed to setup BIO for listening.\n", .{});
        return error.FailedToSetupListening;
    }

    return bio;
}

fn handleClientConnection(client: *c.BIO, ctx: *c.SSL_CTX) !void {
    var ssl: ?*c.SSL = null;

    var source_ip: []const u8 = undefined;
    if (server_config.mode == .release) {
        source_ip = logIp(client) catch "failed IP";
    } else {
        source_ip = "127.0.0.1";
    }

    if (server_config.mode == ServerModes.release) {
        ssl = c.SSL_new(ctx);
        c.SSL_set_bio(ssl, client, client);

        while (true) {
            const ret = c.SSL_accept(ssl);
            const ssl_err = c.SSL_get_error(ssl, ret);

            if (ret > 0) {
                // std.debug.print("Passed SSL handshake.\n", .{});
                break;
            } else if (ssl_err == c.SSL_ERROR_WANT_READ or ssl_err == c.SSL_ERROR_WANT_WRITE) {
                // std.debug.print("Waiting on SSL handshake.\n", .{});
                _ = c.usleep(1000);
                continue;
            } else {
                const err = c.ERR_get_error();
                var errbuf: [256]u8 = [_]u8{0} ** 256;
                c.ERR_error_string_n(err, &errbuf, errbuf.len);
                // std.debug.print("Failed SSL handshake: {s}\n", .{errbuf[0..]});
                return;
            }
        }
    }

    try handleClientRequest(client, ssl, source_ip);

    if (ssl) |ssl_obj| {
        if (c.SSL_shutdown(ssl_obj) == 0) {
            _ = c.SSL_shutdown(ssl_obj);
        }
        c.SSL_free(ssl_obj);
    }
}

fn startServer() !void {
    const c_o = &server_config;

    server_start_time = std.time.timestamp();

    if (c_o.mode == ServerModes.release) {
        server_config.mode = ServerModes.release;
        server_config.port = "443";
        std.log.info("In release mode! mode: {any}, port: {s}\n", .{ server_config.mode, server_config.port });
    } else {
        server_config.mode = ServerModes.debug;
        server_config.port = c_o.port;
    }

    file_server_instance = try file_server.FileServer.init(&allocator, "build/frontend");

    const ctx = try initializeServer();
    defer c.SSL_CTX_free(ctx);
    try loadCertificates(ctx);

    const socket = try bindAndListen();
    defer _ = c.BIO_free(socket);

    const fd = c.BIO_get_fd(socket, null);

    if (fd < 0) {
        std.debug.print("Failed to get valid file descriptor from BIO socket. {d}\n", .{fd});
        return;
    }

    var poll_fds: [1]std.os.pollfd = [_]std.os.pollfd{.{ .revents = 0, .fd = @intCast(fd), .events = std.os.POLL.IN }};

    while (running) {
        if (try std.os.poll(&poll_fds, POLL_MS_TIMEOUT) > 0) {
            if (c.BIO_do_accept(socket) > 0) {
                if (c.BIO_pop(socket)) |client| {
                    handleClientConnection(client, ctx) catch |err| {
                        std.debug.print("Error handling client connection: {}\n", .{err});
                    };
                } else {
                    std.debug.print("Failed to accept client.\n", .{});
                }
            }
        }
    }
    std.debug.print("\nShutting down...\n", .{});
}

// // Support multiple connections at a time, this had issues like double frees so I restarted from scratch, should be easy to get working
// const Connection = struct { client_fd: ?i32, ssl: ?*c.SSL };
// fn acceptNewConnection(listeningSocket: *c.BIO, ctx: *c.SSL_CTX) Connection {
//     // Try to accept a new connection
//     if (c.BIO_do_accept(listeningSocket) <= 0) {
//         std.debug.print("Failed to accept new connection.\n", .{});
//         return Connection{ .client_fd = null, .ssl = null };
//     }

//     const clientBIO = c.BIO_pop(listeningSocket);
//     if (clientBIO == null) {
//         std.debug.print("Failed to retrieve client BIO.\n", .{});
//         return Connection{ .client_fd = null, .ssl = null };
//     }

//     var ssl: ?*c.SSL = null;

//     if (server_config.mode == ServerModes.release) {
//         ssl = c.SSL_new(ctx);
//         if (ssl == null) {
//             std.debug.print("Failed to create SSL object.\n", .{});
//             return Connection{ .client_fd = null, .ssl = null };
//         }

//         c.SSL_set_bio(ssl, clientBIO, clientBIO);

//         while (true) {
//             const ret = c.SSL_accept(ssl);
//             if (ret > 0) {
//                 // SSL handshake was successful
//                 std.debug.print("GOT SSL!!!\n", .{});
//                 break; // Exit the loop
//             } else {
//                 const ssl_err = c.SSL_get_error(ssl, ret);
//                 if (ssl_err == c.SSL_ERROR_WANT_READ or ssl_err == c.SSL_ERROR_WANT_WRITE) {
//                     std.debug.print("WAITING!", .{});
//                     _ = c.usleep(100000); // Sleep for 0.1 seconds to reduce CPU usage
//                     continue; // Retry the operation
//                 } else {
//                     switch (ssl_err) {
//                         c.SSL_ERROR_NONE => {
//                             std.debug.print("SSL_ERROR_NONE", .{});
//                         },
//                         c.SSL_ERROR_ZERO_RETURN => {
//                             std.debug.print("SSL_ERROR_ZERO_RETURN", .{});
//                         },
//                         c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => {
//                             std.debug.print("SSL_ERROR_WANT_READ/WRITE", .{});
//                         },
//                         c.SSL_ERROR_WANT_CONNECT, c.SSL_ERROR_WANT_ACCEPT => {
//                             std.debug.print("SSL_ERROR_WANT_CONNECT/ACCEPT", .{});
//                         },
//                         c.SSL_ERROR_SSL => {
//                             std.debug.print("SSL_ERROR_SSL", .{});
//                         },
//                         else => {
//                             std.debug.print("SSL_ERROR other", .{});
//                         },
//                     }
//                     const err = c.ERR_get_error();
//                     var errbuf: [256]u8 = undefined;
//                     c.ERR_error_string_n(err, &errbuf, errbuf.len);
//                     std.debug.print("Failed SSL handshake: {s}\n", .{errbuf[0..]});
//                     return Connection{ .client_fd = null, .ssl = null };
//                 }
//             }
//         }
//     }

//     const client_fd: i32 = @intCast(c.BIO_get_fd(clientBIO, null));
//     if (client_fd < 0) {
//         std.debug.print("Failed to get file descriptor from BIO.\n", .{});
//         return Connection{ .client_fd = null, .ssl = null };
//     }

//     return Connection{ .client_fd = @intCast(client_fd), .ssl = ssl };
// }

// fn handleClientConnection(client_fd: i32, ssl: ?*c.SSL) !void {
//     const clientBIO = c.BIO_new_socket(client_fd, c.BIO_NOCLOSE) orelse return;
//    // defer _ = c.BIO_free(clientBIO);

//     const source_ip = logIp(clientBIO) catch return;

//     try handleClientRequest(clientBIO, ssl, source_ip);
// }

// fn startServer() !void {
//     const c_o = &server_config;

//     if (c_o.mode == ServerModes.release) {
//         server_config.mode = ServerModes.release;
//         server_config.port = "443";
//         std.log.info("In release mode! mode: {any}, port: {s}\n", .{ server_config.mode, server_config.port });
//     } else {
//         server_config.mode = ServerModes.debug;
//         server_config.port = c_o.port;
//     }

//     file_server_instance = try file_server.FileServer.init(&allocator, "build/frontend");

//     const ctx = try initializeServer();
//     defer c.SSL_CTX_free(ctx);
//     try loadCertificates(ctx);

//     const socket = try bindAndListen();
//     defer _ = c.BIO_free(socket);

//     const fd = c.BIO_get_fd(socket, null);

//     if (fd < 0) {
//         std.debug.print("Failed to get valid file descriptor from BIO socket. {d}\n", .{fd});
//         return;
//     }

//     var poll_fds: [256]std.os.pollfd = undefined;
//     var num_fds: usize = 1;
//     poll_fds[0] = std.os.pollfd{ .fd = @intCast(fd), .events = std.os.POLL.IN, .revents = 0 };

//     var ssls: [256]?*c.SSL = [_]?*c.SSL{null} ** 256;

//     while (running) {
//         const n = try std.os.poll(poll_fds[0..num_fds], POLL_MS_TIMEOUT);
//         if (n == 0) {
//             // Timeout occurred
//             continue;
//         } else if (n < 0) {
//             std.debug.print("poll() error: {}\n", .{std.os.errno()});
//             break;
//         }

//         if (poll_fds[0].revents & std.os.POLL.IN > 0) {
//             const res = acceptNewConnection(socket, ctx);
//             const client_fd = res.client_fd;
//             if (client_fd != null) {
//                 ssls[num_fds] = res.ssl;
//                 poll_fds[num_fds] = std.os.pollfd{ .fd = client_fd.?, .events = std.os.POLL.IN, .revents = 0 };

//                 num_fds += 1;
//             }
//         }

//         for (poll_fds[1..num_fds], 1..) |*pfd, i| {
//             if (pfd.revents & std.os.POLL.IN > 0) {
//                 try handleClientConnection(pfd.fd, ssls[i]);
//             }

//             if (pfd.revents & (std.os.POLL.ERR | std.os.POLL.HUP | std.os.POLL.NVAL) > 0) {
//                 if (ssls[i]) |ssl_obj| {
//                     if (c.SSL_shutdown(ssl_obj) == 0) {
//                         _ = c.SSL_shutdown(ssl_obj); // Complete the bidirectional shutdown if necessary
//                     }
//                     c.SSL_free(ssl_obj); // This also closes the socket
//                     ssls[i] = null;
//                 }

//                 var found: bool = false;
//                 for (poll_fds[0..num_fds], 0..) |*curr_pfd, index| {
//                     if (found) {
//                         poll_fds[index - 1] = poll_fds[index];
//                     } else if (curr_pfd.fd == pfd.fd) {
//                         found = true;
//                     }
//                 }
//                 if (found) {
//                     num_fds -= 1;
//                 }
//             }
//         }
//     }
//     std.debug.print("\nShutting down...\n", .{});
// }

pub fn main() !void {
    const sigintHandlerPtr = @as(fn (c_int) callconv(.C) void, handleExitSignal);
    const sigtermHandlerPtr = @as(fn (c_int) callconv(.C) void, handleExitSignal);

    _ = c.signal(c.SIGINT, sigintHandlerPtr);
    _ = c.signal(c.SIGTERM, sigtermHandlerPtr);

    return cli.run(app, allocator);
}
