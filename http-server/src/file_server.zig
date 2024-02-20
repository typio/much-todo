const std = @import("std");

const main = @import("./main.zig");

const RouteFileDescriptor = struct { server_path: []const u8, mime_type: []const u8 };

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

pub const FileServer = struct {
    allocator: std.mem.Allocator,
    routeToFileMap: std.StringHashMap(RouteFileDescriptor),

    pub fn init(allocator: *const std.mem.Allocator, base_path: []const u8) !FileServer {
        var self = FileServer{
            .allocator = allocator.*,
            .routeToFileMap = std.StringHashMap(RouteFileDescriptor).init(allocator.*),
        };

        try self.scanAndRegisterFiles(base_path);

        return self;
    }

    fn scanAndRegisterFiles(self: *FileServer, base_path: []const u8) !void {
        const frontend_dir = try std.fs.cwd().openDir(base_path, std.fs.Dir.OpenDirOptions{ .iterate = true });
        var frontend_walker = try frontend_dir.walk(self.allocator);
        defer frontend_walker.deinit();
        while (try frontend_walker.next()) |entry| {
            if (entry.kind == std.fs.File.Kind.file and entry.path[0] != '_') {
                const file_path = try std.mem.Allocator.dupe(self.allocator, u8, entry.path);
                const route = if (std.mem.eql(u8, file_path, "index.html")) try std.fmt.allocPrint(self.allocator, "/", .{}) else try std.fmt.allocPrint(self.allocator, "/{s}", .{file_path});

                const mime_type = try getMimeTypeOfExtension(self.allocator, std.fs.path.extension(entry.basename));

                try self.routeToFileMap.put(route, .{ .server_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, file_path }), .mime_type = mime_type });
            }
        }
    }

    pub fn serveFile(self: *FileServer, path: []const u8) !?main.ResponseBuffers {
        if (self.routeToFileMap.contains(path)) {
            const file_descriptor = self.routeToFileMap.get(path).?;
            const filename = file_descriptor.server_path;
            const mime_type = file_descriptor.mime_type;

            const file = try std.fs.cwd().openFile(filename, .{ .mode = .read_only });
            defer file.close();

            const body = try file.reader().readAllAlloc(self.allocator, main.FILE_SERVE_BUFFER_SIZE);
            const head = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nServer: your-server-name\r\n\r\n", .{ mime_type, body.len });

            return main.ResponseBuffers{ .body = body, .head = head };
        } else {
            return null;
        }
    }
};

fn getMimeTypeOfExtension(allocator: std.mem.Allocator, extension: []const u8) ![]const u8 {
    var lowercase_extension = try std.mem.Allocator.dupe(allocator, u8, extension);
    lowercase_extension = std.ascii.lowerString(lowercase_extension, extension);

    for (mimeTypes) |mimeType| {
        for (mimeType.extensions) |ext| {
            if (std.mem.eql(u8, ext, lowercase_extension[0..])) {
                return mimeType.mime;
            }
        }
    }
    return "application/octet-stream";
}
