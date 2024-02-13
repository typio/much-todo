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

var app = &cli.App{ .command = cli.Command{ .name = "much-todo http server", .options = &.{ &cli_option_server_mode, &cli_option_port }, .target = cli.CommandTarget{
    .action = cli.CommandAction{ .exec = startServer },
} } };

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

const HTTPHead = struct { path: []const u8, method: HTTPMethod, content_length: u16 };

const HTTPRequest = struct { head: HTTPHead, body: []const u8, source_ip: []const u8 };

const USER_REQUEST_BUFFER_SIZE = 32 * 1024;
const API_RESPONSE_BUFFER_SIZE = 256 * 1024;
const FILE_SERVE_BUFFER_SIZE = 2000 * 1024;

const RouteFileDescriptor = struct { server_path: []const u8, mime_type: []const u8 };
var routeToFileMap: std.StringHashMap(RouteFileDescriptor) = undefined;

const MimeType = struct { mime: []const u8, extensions: []const []const u8 };
const mimeTypes = [_]MimeType{
    MimeType{ .mime = "text/html", .extensions = &[_][]const u8{ ".html", ".htm" } },
    MimeType{ .mime = "text/css", .extensions = &[_][]const u8{".css"} },
    MimeType{ .mime = "application/javascript", .extensions = &[_][]const u8{".js"} },
    MimeType{ .mime = "application/json", .extensions = &[_][]const u8{".json"} },
    MimeType{ .mime = "image/jpeg", .extensions = &[_][]const u8{ ".jpeg", ".jpg" } },
    MimeType{ .mime = "image/png", .extensions = &[_][]const u8{".png"} },
    MimeType{ .mime = "image/webp", .extensions = &[_][]const u8{".webp"} },
    MimeType{ .mime = "image/svg+xml", .extensions = &[_][]const u8{".svg"} },
    MimeType{ .mime = "image/gif", .extensions = &[_][]const u8{".gif"} },
    MimeType{ .mime = "text/plain", .extensions = &[_][]const u8{".txt"} },
    MimeType{ .mime = "application/pdf", .extensions = &[_][]const u8{".pdf"} },
    MimeType{ .mime = "application/xml", .extensions = &[_][]const u8{".xml"} },
    MimeType{ .mime = "font/woff", .extensions = &[_][]const u8{".woff"} },
    MimeType{ .mime = "font/woff2", .extensions = &[_][]const u8{".woff2"} },
    MimeType{ .mime = "font/ttf", .extensions = &[_][]const u8{".ttf"} },
    MimeType{ .mime = "font/otf", .extensions = &[_][]const u8{".otf"} },
    MimeType{ .mime = "video/mp4", .extensions = &[_][]const u8{".mp4"} },
    MimeType{ .mime = "video/webm", .extensions = &[_][]const u8{".webm"} },
    MimeType{ .mime = "video/ogg", .extensions = &[_][]const u8{".ogg"} },
    MimeType{ .mime = "audio/mpeg", .extensions = &[_][]const u8{".mpeg"} },
    MimeType{ .mime = "audio/ogg", .extensions = &[_][]const u8{".ogg"} },
    MimeType{ .mime = "audio/wav", .extensions = &[_][]const u8{".wav"} },
};

pub fn handleExitSignal(signum: c_int) callconv(.C) void {
    switch (signum) {
        c.SIGINT => std.debug.print("\nReceived SIGINT. Terminating...\n", .{}),
        c.SIGTERM => std.debug.print("\nReceived SIGTERM. Terminating...\n", .{}),
        else => {},
    }
    running = false;
}

fn getMimeTypeOfExtension(extension: []const u8) !?[]const u8 {
    var lowercase_extension = try std.mem.Allocator.dupe(allocator, u8, extension);
    lowercase_extension = std.ascii.lowerString(lowercase_extension, extension);

    for (mimeTypes) |mimeType| {
        for (mimeType.extensions) |ext| {
            if (std.mem.eql(u8, ext, lowercase_extension[0..])) {
                return mimeType.mime;
            }
        }
    }
    return undefined;
}

fn initializeStaticRoutes() !void {
    routeToFileMap = std.StringHashMap(RouteFileDescriptor).init(allocator);

    const frontend_dir = try std.fs.cwd().openDir("build/frontend", std.fs.Dir.OpenDirOptions{ .iterate = true });
    var frontend_walker = try frontend_dir.walk(allocator);
    defer frontend_walker.deinit();
    while (try frontend_walker.next()) |walker_entry| {
        if (walker_entry.kind == std.fs.File.Kind.file and walker_entry.path[0] != '_') {
            const file_path = try std.mem.Allocator.dupe(allocator, u8, walker_entry.path);
            var route = file_path;
            if (std.mem.eql(u8, file_path, "index.html")) {
                route = try std.fmt.allocPrint(allocator, "/", .{});
            } else {
                route = try std.fmt.allocPrint(allocator, "/{s}", .{file_path});
            }

            const mime_type = try getMimeTypeOfExtension(std.fs.path.extension(walker_entry.basename));

            try routeToFileMap.put(route, RouteFileDescriptor{ .server_path = try std.fmt.allocPrint(allocator, "build/frontend/{s}", .{file_path}), .mime_type = mime_type orelse "text/html" });
        }
    }
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

fn logIp(client: *c.BIO) ![]const u8 {
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

    std.debug.print("IP: {s} connected.\n", .{ip_string});

    const filename = "client_ips.log";
    const file = try std.fs.cwd().createFile(filename, .{ .read = false, .truncate = false });
    defer file.close();
    const stat = try file.stat();
    try file.seekTo(stat.size);

    var writer = file.writer();
    try writer.print("{s} at {d}\n", .{ ip_string, now });

    return ip_string;
}

fn handleClientConnection(client: *c.BIO, ctx: *c.SSL_CTX) !void {
    var ssl: ?*c.SSL = null;

    var source_ip: []const u8 = undefined;
    if (server_config.mode == .release) {
        source_ip = try logIp(client);
    } else {
        source_ip = "127.0.0.1";
    }

    if (server_config.mode == ServerModes.release) {
        ssl = c.SSL_new(ctx);
        c.SSL_set_bio(ssl, client, client);

        if (c.SSL_accept(ssl) <= 0) {
            const err = c.ERR_get_error();
            var errbuf: [256]u8 = undefined;
            c.ERR_error_string_n(err, &errbuf, errbuf.len);
            std.debug.print("Failed SSL handshake: {s}\n", .{errbuf[0..]});
            return;
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

fn parseHead(head: []const u8) !HTTPHead {
    var head_lines = std.mem.splitScalar(u8, head, '\n');

    const first_line = head_lines.first();

    var start_line_parts = std.mem.splitScalar(u8, first_line, ' ');

    const method = std.meta.stringToEnum(HTTPMethod, start_line_parts.next() orelse "").?;
    const path = start_line_parts.next() orelse "";

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
    var buffer: [USER_REQUEST_BUFFER_SIZE]u8 = undefined;
    const bytes_read = switch (server_config.mode) {
        ServerModes.release => c.SSL_read(ssl, &buffer, buffer.len),
        else => c.BIO_read(client, &buffer, buffer.len),
    };

    if (bytes_read <= 0) {
        std.debug.print("Connection closed by client or error occurred.\n", .{});
        return;
    }

    const first_read = buffer[0..@as(usize, @intCast(bytes_read))];

    var request_parts = std.mem.splitSequence(u8, first_read, "\r\n\r\n");

    const request_head = try parseHead(request_parts.next() orelse "");
    var request_body = request_parts.next() orelse "";

    var body_reads: u8 = 0;
    while (request_head.content_length > 0 and request_head.content_length > request_body.len) {
        var read_buffer: [USER_REQUEST_BUFFER_SIZE]u8 = undefined;

        const bodyBytesRead = switch (server_config.mode) {
            ServerModes.release => c.SSL_read(ssl, &read_buffer, read_buffer.len),
            else => c.BIO_read(client, &read_buffer, read_buffer.len),
        };
        const next_body_read = read_buffer[0..@as(usize, @intCast(bodyBytesRead))];

        request_body = try std.mem.concat(allocator, u8, &[_][]const u8{ request_body, next_body_read });
        body_reads += 1;

        if (body_reads > 10) {
            std.log.warn("Read body 10 times! Sending request as is.", .{});
            break;
        }
    }

    const httpRequest = HTTPRequest{ .head = request_head, .body = request_body, .source_ip = source_ip };

    try parseRequest(&httpRequest, client, ssl);
}

fn parseRequest(request: *const HTTPRequest, client: *c.BIO, ssl: ?*c.SSL) !void {
    var response_buffers = ResponseBuffers{ .header = null, .body = null };
    defer if (response_buffers.header) |header| allocator.free(header);
    defer if (response_buffers.body) |body| allocator.free(body);

    if (request.head.method == .GET or request.head.method == .HEAD) {
        if (routeToFileMap.contains(request.head.path)) {
            const file_descriptor = routeToFileMap.get(request.head.path) orelse return;
            const filename = file_descriptor.server_path;
            const mime_type = file_descriptor.mime_type;

            const file = try std.fs.cwd().openFile(filename, .{ .mode = .read_only });
            defer file.close();
            response_buffers.body = try file.reader().readAllAlloc(
                allocator,
                FILE_SERVE_BUFFER_SIZE,
            );

            response_buffers.header = try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nServer: much-todo\r\n\r\n", .{ mime_type, response_buffers.body.?.len });
        } else if (std.mem.eql(u8, request.head.path, "/api/notes")) {
            const stream = try std.net.tcpConnectToHost(allocator, "localhost", 7050);
            defer stream.close();

            var appRequestJSON = std.ArrayList(u8).init(allocator);
            defer appRequestJSON.deinit();
            var write_stream = std.json.writeStream(appRequestJSON.writer(), .{ .whitespace = .indent_2 });
            defer write_stream.deinit();
            try write_stream.beginObject();
            try write_stream.objectField("source_ip");
            try write_stream.write(request.source_ip);
            try write_stream.endObject();

            const appRequest = try std.fmt.allocPrint(allocator, "GET / HTTP/1.1\r\nHost: localhost:7050\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ appRequestJSON.items.len, appRequestJSON.items });
            _ = try stream.writeAll(appRequest);

            var appResponseBuffer: [API_RESPONSE_BUFFER_SIZE]u8 = undefined;
            // while (true) {
            const bytes_read = try stream.read(appResponseBuffer[0..]);
            // if (bytes_read == 0) break;

            var it = std.mem.split(u8, appResponseBuffer[0..bytes_read], "\r\n\r\n");
            _ = it.next();
            const appResponseBody = it.next() orelse "";

            response_buffers.body = try std.fmt.allocPrint(allocator, "{s}", .{appResponseBody});
            response_buffers.header = try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nServer: much-todo\r\n\r\n", .{response_buffers.body.?.len});
            // }
        } else if (std.mem.eql(u8, request.head.path, "/api/viewCount")) {
            const contents = try std.fs.cwd().readFileAlloc(allocator, "client_ips.log", 100 * FILE_SERVE_BUFFER_SIZE);
            defer allocator.free(contents);
            var ip_strings = std.mem.tokenizeScalar(u8, contents, '\n');
            var unique_ip_count: usize = 0;
            var view_count: usize = 0;
            var unique_ip_set = std.BufSet.init(allocator);

            while (ip_strings.next()) |ip_string| {
                if (ip_string.len == 0) continue;
                view_count += 1;

                var ip_log_parts = std.mem.tokenizeScalar(u8, ip_string, ' ');
                const ip = ip_log_parts.next().?;

                if (!unique_ip_set.contains(ip)) {
                    unique_ip_count += 1;
                    try unique_ip_set.insert(ip);
                }
            }
            response_buffers.body = try std.fmt.allocPrint(allocator, "{{\"view_count\": {d}, \"unique_ip_count\": {d}}}", .{ view_count, unique_ip_count });
            response_buffers.header = try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nServer: much-todo\r\n\r\n", .{response_buffers.body.?.len});
        } else {
            std.log.info("404 not found: {s}", .{request.head.path});

            const filename = "build/frontend/_404.html";
            const file = try std.fs.cwd().openFile(filename, .{ .mode = .read_only });

            defer file.close();

            response_buffers.body = try file.reader().readAllAlloc(
                allocator,
                FILE_SERVE_BUFFER_SIZE,
            );

            response_buffers.header = try std.fmt.allocPrint(allocator, "HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nConnection: close\r\nServer: much-todo\r\n\r\n", .{response_buffers.body.?.len});
        }
    } else if (request.head.method == .POST) {
        if (std.mem.eql(u8, request.head.path, "/api/notes")) {
            const stream = try std.net.tcpConnectToHost(allocator, "localhost", 7050);
            defer stream.close();

            const requestBodyJSON = try std.json.parseFromSlice(struct { title: []const u8, body: []const u8 }, allocator, request.body, .{});
            defer requestBodyJSON.deinit();

            var appRequestJSON = std.ArrayList(u8).init(allocator);
            defer appRequestJSON.deinit();
            var write_stream = std.json.writeStream(appRequestJSON.writer(), .{ .whitespace = .indent_2 });
            defer write_stream.deinit();
            try write_stream.beginObject();
            try write_stream.objectField("body");
            try write_stream.write(requestBodyJSON.value.body);
            try write_stream.objectField("source_ip");
            try write_stream.write(request.source_ip);
            try write_stream.endObject();

            const appRequest = try std.fmt.allocPrint(allocator, "POST / HTTP/1.1\r\nOrigin: http://localhost:7050\r\nHost: localhost:7050\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ appRequestJSON.items.len, appRequestJSON.items });

            _ = try stream.writeAll(appRequest);

            var appResponseBuffer: [API_RESPONSE_BUFFER_SIZE]u8 = undefined;
            // while (true) {
            const bytes_read = try stream.read(appResponseBuffer[0..]);
            // if (bytes_read == 0) break;

            var it = std.mem.split(u8, appResponseBuffer[0..bytes_read], "\r\n\r\n");
            _ = it.next() orelse "";

            const appResponseBody = it.next() orelse "";
            response_buffers.body = try std.fmt.allocPrint(allocator, "{s}", .{appResponseBody});
            response_buffers.header = try std.fmt.allocPrint(allocator, "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nServer: much-todo\r\n\r\n", .{response_buffers.body.?.len});
            // }
        } else if (std.mem.eql(u8, request.head.path, "/api/notes/vote")) {
            const stream = try std.net.tcpConnectToHost(allocator, "localhost", 7050);
            defer stream.close();

            const requestBodyJSON = try std.json.parseFromSlice(struct { like: bool, noteId: []const u8 }, allocator, request.body, .{});
            defer requestBodyJSON.deinit();

            var appRequestJSON = std.ArrayList(u8).init(allocator);
            defer appRequestJSON.deinit();
            var write_stream = std.json.writeStream(appRequestJSON.writer(), .{ .whitespace = .indent_2 });
            defer write_stream.deinit();
            try write_stream.beginObject();
            try write_stream.objectField("like");
            try write_stream.write(requestBodyJSON.value.like);
            try write_stream.objectField("noteId");
            try write_stream.write(requestBodyJSON.value.noteId);
            try write_stream.objectField("source_ip");
            try write_stream.write(request.source_ip);
            try write_stream.endObject();

            const appRequest = try std.fmt.allocPrint(allocator, "POST /vote HTTP/1.1\r\nOrigin: http://localhost:7050\r\nHost: localhost:7050\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ appRequestJSON.items.len, appRequestJSON.items });

            _ = try stream.writeAll(appRequest);

            var appResponseBuffer: [API_RESPONSE_BUFFER_SIZE]u8 = undefined;
            // while (true) {
            const bytes_read = try stream.read(appResponseBuffer[0..]);
            // if (bytes_read == 0) break;

            var it = std.mem.split(u8, appResponseBuffer[0..bytes_read], "\r\n\r\n");
            _ = it.next() orelse "";

            const appResponseBody = it.next() orelse "";
            response_buffers.body = try std.fmt.allocPrint(allocator, "{s}", .{appResponseBody});
            response_buffers.header = try std.fmt.allocPrint(allocator, "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nServer: much-todo\r\n\r\n", .{response_buffers.body.?.len});
        }
    } else if (request.head.method == .DELETE) {
        const stream = try std.net.tcpConnectToHost(allocator, "localhost", 7050);
        defer stream.close();

        const requestBodyJSON = try std.json.parseFromSlice(struct { noteId: []const u8 }, allocator, request.body, .{});
        defer requestBodyJSON.deinit();

        var appRequestJSON = std.ArrayList(u8).init(allocator);
        defer appRequestJSON.deinit();
        var write_stream = std.json.writeStream(appRequestJSON.writer(), .{ .whitespace = .indent_2 });
        defer write_stream.deinit();
        try write_stream.beginObject();
        try write_stream.objectField("noteId");
        try write_stream.write(requestBodyJSON.value.noteId);
        try write_stream.objectField("source_ip");
        try write_stream.write(request.source_ip);
        try write_stream.endObject();

        const appRequest = try std.fmt.allocPrint(allocator, "DELETE / HTTP/1.1\r\nOrigin: http://localhost:7050\r\nHost: localhost:7050\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ appRequestJSON.items.len, appRequestJSON.items });

        _ = try stream.writeAll(appRequest);

        var appResponseBuffer: [API_RESPONSE_BUFFER_SIZE]u8 = undefined;
        const bytes_read = try stream.read(appResponseBuffer[0..]);

        var it = std.mem.split(u8, appResponseBuffer[0..bytes_read], "\r\n\r\n");
        _ = it.next() orelse "";
        const appResponseBody = it.next() orelse "";

        response_buffers.body = try std.fmt.allocPrint(allocator, "{s}", .{appResponseBody});
        response_buffers.header = try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nServer: much-todo\r\n\r\n", .{response_buffers.body.?.len});
        // }
    } else {
        std.log.info("Unsupported request method: {?}, on path: {s}", .{ request.head.method, request.head.path });
    }

    if (response_buffers.body == null or response_buffers.header == null) {
        response_buffers.body = "{{\"code\": 404, \"message\": \"Not Found\"}}";
        response_buffers.header = try std.fmt.allocPrint(allocator, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: {any}\r\nConnection: close\r\nServer: much-todo\r\n\r\n", .{response_buffers.body.?.len});
    }

    // Serve the reponse
    if (request.head.method == .HEAD) {
        const buffer = try allocator.alloc(u8, response_buffers.header.?.len);
        std.mem.copyForwards(u8, buffer, response_buffers.header.?);
        try serveBytes(client, ssl, buffer);
    } else {
        var buffer = try allocator.alloc(u8, response_buffers.header.?.len + response_buffers.body.?.len);
        std.mem.copyForwards(u8, buffer, response_buffers.header.?);
        std.mem.copyForwards(u8, buffer[response_buffers.header.?.len..], response_buffers.body.?);
        try serveBytes(client, ssl, buffer);
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

fn startServer() !void {
    const c_o = &server_config;

    if (c_o.mode == ServerModes.release) {
        server_config.mode = ServerModes.release;
        server_config.port = "443";
        std.log.info("In release mode! mode: {any}, port: {s}\n", .{ server_config.mode, server_config.port });
    } else {
        server_config.mode = ServerModes.debug;
        server_config.port = c_o.port;
    }

    try initializeStaticRoutes();

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

    defer routeToFileMap.deinit();

    return cli.run(app, allocator);
}
