const std = @import("std");

const main = @import("./main.zig");

pub fn handleRequest(allocator: *const std.mem.Allocator, request: main.HTTPRequest) !?main.ResponseBuffers {
    if (request.head.method == .GET) {
        if (std.mem.eql(u8, request.head.path, "/api/notes")) {
            return try getNotes(allocator.*, request.source_ip);
        } else if (std.mem.eql(u8, request.head.path, "/api/httpServer")) {
            return try getHttpServerStats(allocator.*);
        }
    } else if (request.head.method == .POST) {
        if (std.mem.eql(u8, request.head.path, "/api/notes")) {
            return try postNote(allocator.*, request.source_ip, request.body);
        }
    } else if (request.head.method == .PUT) {
        if (std.mem.eql(u8, request.head.path, "/api/notes/vote")) {
            return try voteOnNote(allocator.*, request.source_ip, request.body);
        }
    } else if (request.head.method == .PATCH) {
        if (std.mem.eql(u8, request.head.path, "/api/notes/edit/body")) {
            return try editNoteBody(allocator.*, request.source_ip, request.body);
        }
    } else if (request.head.method == .DELETE) {
        return try deleteNote(allocator.*, request.source_ip, request.body);
    }

    std.log.info("Unsupported request method: {?}, on path: {s}", .{ request.head.method, request.head.path });
    return null;
}

fn requestApp(allocator: std.mem.Allocator, method: []const u8, endpoint: []const u8, body: anytype) !main.ResponseBuffers {
    var string = std.ArrayList(u8).init(allocator);
    defer string.deinit();
    try std.json.stringify(body, .{}, string.writer());

    const appRequest = try std.fmt.allocPrint(allocator, "{s} {s} HTTP/1.1\r\nOrigin: http://localhost:7050\r\nHost: localhost:7050\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ method, endpoint, string.items.len, string.items });
    defer allocator.free(appRequest);

    const stream = try std.net.tcpConnectToHost(allocator, "localhost", 7050);
    defer stream.close();

    try stream.writeAll(appRequest);

    var appResponseBuffer: [main.API_RESPONSE_BUFFER_SIZE]u8 = undefined;
    const bytes_read = try stream.read(appResponseBuffer[0..]);

    var it = std.mem.split(u8, appResponseBuffer[0..bytes_read], "\r\n\r\n");
    const app_response_head = it.next() orelse "";
    const app_response_body = it.next() orelse "";

    const response_body = try std.fmt.allocPrint(allocator, "{s}", .{app_response_body});
    const response_head = try std.fmt.allocPrint(allocator, "{s}\r\n\r\n", .{app_response_head});

    return main.ResponseBuffers{ .body = response_body, .head = response_head };
}

fn getNotes(allocator: std.mem.Allocator, source_ip: []const u8) !main.ResponseBuffers {
    return requestApp(allocator, "GET", "/notes", .{ .sourceIp = source_ip });
}

fn getHttpServerStats(allocator: std.mem.Allocator) !main.ResponseBuffers {
    const filename = "http-server.log";
    const contents = try std.fs.cwd().readFileAlloc(allocator, filename, main.FILE_SERVE_BUFFER_SIZE);
    defer allocator.free(contents);
    var logLines = std.mem.splitScalar(u8, contents, '\n');
    const request_count: []const u8 = logLines.first();
    const server_start_timestamp: []const u8 = logLines.next() orelse "";

    var string = std.ArrayList(u8).init(allocator);
    defer string.deinit();
    try std.json.stringify(.{ .request_count = request_count, .server_start_timestamp = server_start_timestamp }, .{}, string.writer());

    const body = try std.fmt.allocPrint(allocator, "{s}", .{string.items});
    const head = try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nServer: much-todo\r\n\r\n", .{body.len});

    return main.ResponseBuffers{ .body = body, .head = head };
}

fn postNote(allocator: std.mem.Allocator, source_ip: []const u8, request_body: []const u8) !main.ResponseBuffers {
    const request_body_json = try std.json.parseFromSlice(struct { title: []const u8, body: []const u8 }, allocator, request_body, .{});
    defer request_body_json.deinit();

    return requestApp(allocator, "POST", "/notes", .{ .body = request_body_json.value.body, .sourceIp = source_ip });
}

fn voteOnNote(allocator: std.mem.Allocator, source_ip: []const u8, request_body: []const u8) !main.ResponseBuffers {
    const request_body_json = try std.json.parseFromSlice(struct { like: bool, noteId: []const u8 }, allocator, request_body, .{});
    defer request_body_json.deinit();

    return requestApp(allocator, "PUT", "/notes/vote", .{ .like = request_body_json.value.like, .noteId = request_body_json.value.noteId, .sourceIp = source_ip });
}

fn editNoteBody(allocator: std.mem.Allocator, source_ip: []const u8, request_body: []const u8) !main.ResponseBuffers {
    const request_body_json = try std.json.parseFromSlice(struct { body: []const u8, noteId: []const u8 }, allocator, request_body, .{});
    defer request_body_json.deinit();

    return requestApp(allocator, "PATCH", "/notes/edit/body", .{ .body = request_body_json.value.body, .noteId = request_body_json.value.noteId, .sourceIp = source_ip });
}

fn deleteNote(allocator: std.mem.Allocator, source_ip: []const u8, request_body: []const u8) !main.ResponseBuffers {
    const request_body_json = try std.json.parseFromSlice(struct { noteId: []const u8 }, allocator, request_body, .{});
    defer request_body_json.deinit();

    return requestApp(allocator, "DELETE", "/notes", .{ .noteId = request_body_json.value.noteId, .sourceIp = source_ip });
}
