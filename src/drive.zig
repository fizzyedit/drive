//! Google Drive v3 client behind `Fs`. HTTP and OAuth stay in the host via
//! `http.Transport` + a bearer token.

const std = @import("std");
const Fs = @import("Fs.zig");
const http = @import("http.zig");
const Allocator = std.mem.Allocator;

pub const folder_mime = "application/vnd.google-apps.folder";
pub const google_apps_prefix = "application/vnd.google-apps.";

pub const Client = struct {
    allocator: Allocator,
    transport: http.Transport,
    access_token: []const u8,

    pub const root_id = "root";

    pub fn fs(self: *Client) Fs.Fs {
        return .{
            .ptr = self,
            .listDirFn = listDir,
            .statFn = stat,
            .readFileFn = readFile,
            .writeFileFn = unsupportedWrite,
            .createFileFn = unsupportedCreate,
            .mkdirFn = unsupportedMkdir,
            .removeFn = unsupportedRemove,
        };
    }

    fn authHeader(self: *Client) Fs.Error![]u8 {
        return std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.access_token});
    }

    fn call(self: *Client, method: http.Method, url: []const u8) Fs.Error!http.Response {
        const auth = try self.authHeader();
        defer self.allocator.free(auth);
        const headers = [_]http.Header{
            .{ .name = "Authorization", .value = auth },
        };
        const resp = try self.transport.request(.{
            .allocator = self.allocator,
            .method = method,
            .url = url,
            .headers = &headers,
        });
        errdefer resp.deinit(self.allocator);
        return switch (resp.status) {
            200...299 => resp,
            401, 403 => blk: {
                resp.deinit(self.allocator);
                break :blk error.Unauthorized;
            },
            404 => blk: {
                resp.deinit(self.allocator);
                break :blk error.NotFound;
            },
            else => blk: {
                resp.deinit(self.allocator);
                break :blk error.Http;
            },
        };
    }

    fn listDir(ptr: *anyopaque, allocator: Allocator, dir_id: []const u8) Fs.Error![]Fs.Entry {
        const self: *Client = @ptrCast(@alignCast(ptr));
        var list: std.ArrayList(Fs.Entry) = .empty;
        errdefer {
            for (list.items) |entry| {
                allocator.free(entry.id);
                allocator.free(entry.name);
            }
            list.deinit(allocator);
        }

        var page_token: ?[]u8 = null;
        defer if (page_token) |token| allocator.free(token);

        while (true) {
            const url = try buildListUrl(allocator, dir_id, page_token);
            defer allocator.free(url);
            const resp = try self.call(.GET, url);
            defer resp.deinit(self.allocator);

            const parsed = std.json.parseFromSlice(ListResponse, allocator, resp.body, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidJson,
            };
            defer parsed.deinit();

            for (parsed.value.files) |file| {
                const id = try allocator.dupe(u8, file.id);
                errdefer allocator.free(id);
                const name = try allocator.dupe(u8, file.name);
                errdefer allocator.free(name);
                try list.append(allocator, .{
                    .id = id,
                    .name = name,
                    .kind = kindFromMime(file.mimeType),
                });
            }

            if (page_token) |token| allocator.free(token);
            page_token = null;
            if (parsed.value.nextPageToken) |next| {
                if (next.len == 0) break;
                page_token = try allocator.dupe(u8, next);
            } else break;
        }

        return try list.toOwnedSlice(allocator);
    }

    fn stat(ptr: *anyopaque, allocator: Allocator, id: []const u8) Fs.Error!Fs.Stat {
        const self: *Client = @ptrCast(@alignCast(ptr));
        const meta = try self.getMeta(id);
        defer meta.deinit();
        return .{
            .id = try allocator.dupe(u8, meta.value.id),
            .name = try allocator.dupe(u8, meta.value.name),
            .kind = kindFromMime(meta.value.mimeType),
            .size = parseSize(meta.value.size),
        };
    }

    fn readFile(ptr: *anyopaque, allocator: Allocator, file_id: []const u8) Fs.Error![]u8 {
        const self: *Client = @ptrCast(@alignCast(ptr));
        const meta = try self.getMeta(file_id);
        defer meta.deinit();
        const kind = kindFromMime(meta.value.mimeType);
        if (kind == .dir) return error.NotAFile;
        if (isGoogleApps(meta.value.mimeType)) return error.NotBinary;

        const url = try std.fmt.allocPrint(allocator, "https://www.googleapis.com/drive/v3/files/{s}?alt=media", .{file_id});
        defer allocator.free(url);
        const resp = try self.call(.GET, url);
        defer resp.deinit(self.allocator);
        return try allocator.dupe(u8, resp.body);
    }

    fn getMeta(self: *Client, id: []const u8) Fs.Error!std.json.Parsed(FileMeta) {
        const url = try std.fmt.allocPrint(self.allocator, "https://www.googleapis.com/drive/v3/files/{s}?fields=id,name,mimeType,size", .{id});
        defer self.allocator.free(url);
        const resp = try self.call(.GET, url);
        defer resp.deinit(self.allocator);
        return std.json.parseFromSlice(FileMeta, self.allocator, resp.body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidJson,
        };
    }

    fn unsupportedWrite(_: *anyopaque, _: []const u8, _: []const u8) Fs.Error!void {
        return error.Unsupported;
    }

    fn unsupportedCreate(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8, _: []const u8) Fs.Error![]u8 {
        return error.Unsupported;
    }

    fn unsupportedMkdir(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8) Fs.Error![]u8 {
        return error.Unsupported;
    }

    fn unsupportedRemove(_: *anyopaque, _: []const u8) Fs.Error!void {
        return error.Unsupported;
    }
};

const ListResponse = struct {
    nextPageToken: ?[]const u8 = null,
    files: []const FileMeta = &.{},
};

const FileMeta = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    mimeType: []const u8 = "",
    size: ?[]const u8 = null,
};

fn kindFromMime(mime: []const u8) Fs.Kind {
    if (std.mem.eql(u8, mime, folder_mime)) return .dir;
    return .file;
}

fn isGoogleApps(mime: []const u8) bool {
    return std.mem.startsWith(u8, mime, google_apps_prefix) and
        !std.mem.eql(u8, mime, folder_mime);
}

fn parseSize(size: ?[]const u8) u64 {
    const text = size orelse return 0;
    return std.fmt.parseInt(u64, text, 10) catch 0;
}

fn buildListUrl(allocator: Allocator, dir_id: []const u8, page_token: ?[]const u8) Fs.Error![]u8 {
    var q: std.ArrayList(u8) = .empty;
    defer q.deinit(allocator);
    try q.appendSlice(allocator, "https://www.googleapis.com/drive/v3/files?q=");
    try appendQueryValue(allocator, &q, "'");
    try appendQueryValue(allocator, &q, dir_id);
    try appendQueryValue(allocator, &q, "' in parents and trashed=false");
    try q.appendSlice(allocator, "&fields=nextPageToken,files(id,name,mimeType)&pageSize=100");
    if (page_token) |token| {
        try q.appendSlice(allocator, "&pageToken=");
        try appendQueryValue(allocator, &q, token);
    }
    return try q.toOwnedSlice(allocator);
}

fn appendQueryValue(allocator: Allocator, list: *std.ArrayList(u8), value: []const u8) Allocator.Error!void {
    for (value) |c| {
        if (isUnreserved(c)) {
            try list.append(allocator, c);
        } else {
            const hex = "0123456789ABCDEF";
            try list.appendSlice(allocator, &.{ '%', hex[c >> 4], hex[c & 0x0f] });
        }
    }
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}

const Canned = struct {
    allocator: Allocator,
    list_pages: []const []const u8,
    list_calls: usize = 0,
    meta_body: []const u8,
    media_body: []const u8,
    last_url: []u8 = &.{},

    fn deinit(self: *Canned) void {
        if (self.last_url.len != 0) self.allocator.free(self.last_url);
    }

    fn request(ptr: *anyopaque, req: http.Request) Fs.Error!http.Response {
        const self: *Canned = @ptrCast(@alignCast(ptr));
        if (self.last_url.len != 0) self.allocator.free(self.last_url);
        self.last_url = try self.allocator.dupe(u8, req.url);
        if (std.mem.indexOf(u8, req.url, "alt=media") != null) {
            return .{ .status = 200, .body = try self.allocator.dupe(u8, self.media_body) };
        }
        if (std.mem.indexOf(u8, req.url, "fields=id,name,mimeType,size") != null) {
            return .{ .status = 200, .body = try self.allocator.dupe(u8, self.meta_body) };
        }
        const page = self.list_pages[@min(self.list_calls, self.list_pages.len - 1)];
        self.list_calls += 1;
        return .{ .status = 200, .body = try self.allocator.dupe(u8, page) };
    }

    fn transport(self: *Canned) http.Transport {
        return .{ .ptr = self, .requestFn = request };
    }
};

test "drive listDir parses canned JSON and paginates" {
    const allocator = std.testing.allocator;
    const page1 =
        \\{"nextPageToken":"p2","files":[{"id":"1","name":"a.txt","mimeType":"text/plain"}]}
    ;
    const page2 =
        \\{"files":[{"id":"2","name":"notes","mimeType":"application/vnd.google-apps.folder"}]}
    ;
    var canned: Canned = .{
        .allocator = allocator,
        .list_pages = &.{ page1, page2 },
        .meta_body = "{}",
        .media_body = "",
    };
    defer canned.deinit();
    var client: Client = .{
        .allocator = allocator,
        .transport = canned.transport(),
        .access_token = "token",
    };
    const listing = try client.fs().listDir(allocator, "root");
    defer Fs.freeEntries(allocator, listing);
    try std.testing.expectEqual(@as(usize, 2), listing.len);
    try std.testing.expectEqualStrings("a.txt", listing[0].name);
    try std.testing.expectEqual(Fs.Kind.file, listing[0].kind);
    try std.testing.expectEqualStrings("notes", listing[1].name);
    try std.testing.expectEqual(Fs.Kind.dir, listing[1].kind);
    try std.testing.expectEqual(@as(usize, 2), canned.list_calls);
    try std.testing.expect(std.mem.indexOf(u8, canned.last_url, "pageToken=p2") != null);
}

test "drive readFile uses metadata then media" {
    const allocator = std.testing.allocator;
    var canned: Canned = .{
        .allocator = allocator,
        .list_pages = &.{"{}"},
        .meta_body =
            \\{"id":"file1","name":"hello.txt","mimeType":"text/plain","size":"5"}
        ,
        .media_body = "hello",
    };
    defer canned.deinit();
    var client: Client = .{
        .allocator = allocator,
        .transport = canned.transport(),
        .access_token = "token",
    };
    const fs = client.fs();
    const st = try fs.stat(allocator, "file1");
    defer Fs.freeStat(allocator, st);
    try std.testing.expectEqualStrings("hello.txt", st.name);
    try std.testing.expectEqual(@as(u64, 5), st.size);

    const body = try fs.readFile(allocator, "file1");
    defer allocator.free(body);
    try std.testing.expectEqualStrings("hello", body);
}

test "drive rejects Google Docs" {
    const allocator = std.testing.allocator;
    var canned: Canned = .{
        .allocator = allocator,
        .list_pages = &.{"{}"},
        .meta_body =
            \\{"id":"doc1","name":"Doc","mimeType":"application/vnd.google-apps.document"}
        ,
        .media_body = "should-not-read",
    };
    defer canned.deinit();
    var client: Client = .{
        .allocator = allocator,
        .transport = canned.transport(),
        .access_token = "token",
    };
    try std.testing.expectError(error.NotBinary, client.fs().readFile(allocator, "doc1"));
}
