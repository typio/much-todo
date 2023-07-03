const std = @import("std");

const c = @cImport({
    @cInclude("signal.h");

    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/bio.h");
});

// var gpa = std.heap.GeneralPurposeAllocator(.{}){};
// const allocator = gpa.allocator();

var running: bool = true;

// Signal handler for SIGINT (Ctrl+C)
pub fn sigintHandler(signum: c_int) void {
    _ = signum;
    running = false;
    std.debug.print("\nReceived SIGINT. Terminating...\n", .{});
    std.process.exit(0);
}

fn initializeServer() !*c.SSL_CTX {
    // Init OpenSSL
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
    if (c.SSL_CTX_use_certificate_file(ctx, "/etc/letsencrypt/live/muchtodo.app/fullchain.pem", c.SSL_FILETYPE_PEM) <= 0 or
        c.SSL_CTX_use_PrivateKey_file(ctx, "/etc/letsencrypt/live/muchtodo.app/privkey.pem", c.SSL_FILETYPE_PEM) <= 0)
    {
        std.debug.print("Failed to load certificate or key.\n", .{});
        return;
    }
}

fn bindAndListen(port: [*c]const u8) !*c.BIO {
    std.debug.print("Port: {s}\n", .{port});

    const socket = c.BIO_new_accept(port);
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

fn handleClientConnection(client: *c.BIO, ctx: *c.SSL_CTX) void {
    const ssl = c.SSL_new(ctx);
    c.SSL_set_bio(ssl, client, client);

    if (c.SSL_accept(ssl) <= 0) {
        const err = c.ERR_get_error();
        var errbuf: [128]u8 = undefined;
        c.ERR_error_string_n(err, &errbuf, errbuf.len);
        std.debug.print("Failed SSL handshake: {s}\n", .{errbuf[0..]});
    } else {
        // Construct the HTTP response
        const responseHeaders = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n";
        const responseBody = "<html><body><h1 style=\"color:dodgerblue; text-align:center;\">Hello, world!</h1></body></html>";

        // Send the response
        const response = responseHeaders ++ responseBody;
        const bytes_written = c.SSL_write(ssl, response, response.len);

        if (bytes_written <= 0) {
            // Handle error
        }

        // Read a message from the client
        var buffer: [256]u8 = undefined;
        const bytes_read = c.SSL_read(ssl, &buffer, buffer.len);
        if (bytes_read > 0) {
            std.debug.print("Received message: {s}\n", .{buffer[0..@as(usize, @intCast(bytes_read))]});
        } else if (bytes_read == 0) {
            std.debug.print("Connection closed by client.\n", .{});
        } else {
            // Handle error
        }
    }
    c.SSL_free(ssl);
}

pub fn main() !void {
    // Register the SIGINT signal handler
    const handlerPtr = @as(c.__sighandler_t, @ptrCast(&sigintHandler));
    _ = c.signal(2, handlerPtr); // Use numeric value for SIGINT

    const ctx = try initializeServer();
    defer c.SSL_CTX_free(ctx);

    try loadCertificates(ctx);

    const socket = try bindAndListen("443");

    // Accept connections
    while (true) {
        if (c.BIO_do_accept(socket) <= 0) {
            std.debug.print("Failed to accept.\n", .{});
            continue;
        }

        const client = c.BIO_pop(socket) orelse return error.FailedToAccept;
        handleClientConnection(client, ctx);
    }

    // Close the socket and free resources
    c.BIO_free(socket);

    return socket;
}
