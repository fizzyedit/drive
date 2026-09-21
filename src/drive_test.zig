//! Drive client against a scripted transport: what URL each op produces, how the path index
//! fills, and what the caller sees — with no network.

const std = @import("std");
const vfs = @import("core").vfs;
const Fs = vfs;
const http = vfs.http;
const drive = @import("drive.zig");
const Allocator = std.mem.Allocator;

/// Answers each request from the first `Route` whose `contains` matches the URL, and records
/// every request in order. Responses are queued until `pump`, like a real transport.
const Scripted = struct {
    allocator: Allocator,
    routes: []const Route,
    log: std.ArrayList(Logged) = .empty,
    completions: http.Completions(Pending),

    const Route = struct {
        contains: []const u8,
        status: u16 = 200,
        body: []const u8 = "{}",
        /// Only match this method, when set.
        method: ?http.Method = null,
    };
    const Logged = struct { method: http.Method, url: []u8, body: []u8 };
    const Pending = struct { allocator: Allocator, cb: http.DoneFn, ctx: ?*anyopaque, status: u16, body: []u8 };

    fn init(allocator: Allocator, routes: []const Route) Scripted {
        return .{ .allocator = allocator, .routes = routes, .completions = .init(allocator) };
    }

    fn deinit(self: *Scripted) void {
        for (self.log.items) |l| {
            self.allocator.free(l.url);
            self.allocator.free(l.body);
        }
        self.log.deinit(self.allocator);
        for (self.completions.items.items) |item| item.payload.allocator.free(item.payload.body);
        self.completions.deinit();
    }

    fn transport(self: *Scripted) http.Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: http.Transport.VTable = .{ .request = request, .cancel = cancel, .pump = pump };

    fn request(ptr: *anyopaque, allocator: Allocator, req: http.Request, cb: http.DoneFn, ctx: ?*anyopaque) Fs.Error!http.Job {
        const self: *Scripted = @ptrCast(@alignCast(ptr));
        try self.log.append(self.allocator, .{
            .method = req.method,
            .url = try self.allocator.dupe(u8, req.url),
            .body = try self.allocator.dupe(u8, req.body),
        });
        const route = for (self.routes) |r| {
            if (r.method != null and r.method.? != req.method) continue;
            if (std.mem.indexOf(u8, req.url, r.contains) != null) break r;
        } else Route{ .contains = "", .status = 404, .body = "{}" };
        const id = self.completions.nextId();
        try self.completions.push(id, .{ .allocator = allocator, .cb = cb, .ctx = ctx, .status = route.status, .body = try allocator.dupe(u8, route.body) });
        return .{ .id = id };
    }

    fn cancel(ptr: *anyopaque, job: http.Job) void {
        const self: *Scripted = @ptrCast(@alignCast(ptr));
        if (self.completions.remove(job.id)) |p| p.allocator.free(p.body);
    }

    fn pump(ptr: *anyopaque) void {
        const self: *Scripted = @ptrCast(@alignCast(ptr));
        var taken = self.completions.take();
        defer taken.deinit(self.allocator);
        for (taken.items) |item| item.payload.cb(item.payload.ctx, .{ .status = item.payload.status, .body = item.payload.body });
    }

    /// The nth request's URL, or "" — so a test can assert on order.
    fn url(self: *Scripted, n: usize) []const u8 {
        return if (n < self.log.items.len) self.log.items[n].url else "";
    }
};

const Sink = struct {
    allocator: Allocator,
    entries: ?[]Fs.Entry = null,
    bytes: ?[]u8 = null,
    stat: ?Fs.Stat = null,
    err: ?Fs.Error = null,
    calls: usize = 0,

    fn reset(self: *Sink) void {
        if (self.entries) |e| Fs.freeEntries(self.allocator, e);
        if (self.bytes) |b| self.allocator.free(b);
        self.* = .{ .allocator = self.allocator };
    }
    fn onList(ctx: ?*anyopaque, result: Fs.Error![]Fs.Entry) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.entries = result catch |err| {
            self.err = err;
            return;
        };
    }
    fn onStat(ctx: ?*anyopaque, result: Fs.Error!Fs.Stat) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.stat = result catch |err| {
            self.err = err;
            return;
        };
    }
    fn onRead(ctx: ?*anyopaque, result: Fs.Error![]u8) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.bytes = result catch |err| {
            self.err = err;
            return;
        };
    }
    fn onDone(ctx: ?*anyopaque, result: Fs.Error!void) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        result catch |err| {
            self.err = err;
        };
    }
};

/// Pump until the sink has heard back. Every op finishes in a bounded number of round trips;
/// a job that never completes fails the test instead of hanging it.
fn settle(fs: Fs.Fs, sink: *Sink) !void {
    var rounds: usize = 0;
    while (sink.calls == 0) : (rounds += 1) {
        if (rounds > 32) return error.JobNeverCompleted;
        fs.pump();
    }
}

// A little Drive: / { notes/ { a.txt, Doc (google doc) }, top.txt }
const root_page1 =
    \\{"nextPageToken":"p2","files":[{"id":"n1","name":"notes","mimeType":"application/vnd.google-apps.folder","modifiedTime":"2024-01-02T03:04:05.678Z"}]}
;
const root_page2 =
    \\{"files":[{"id":"t1","name":"top.txt","mimeType":"text/plain","size":"5"}]}
;
const notes_page =
    \\{"files":[{"id":"a1","name":"a.txt","mimeType":"text/plain","size":"7"},{"id":"d1","name":"Doc","mimeType":"application/vnd.google-apps.document"}]}
;
const little_drive = [_]Scripted.Route{
    .{ .contains = "pageToken=p2", .body = root_page2 },
    .{ .contains = "q=%27root%27%20in%20parents", .body = root_page1 },
    .{ .contains = "q=%27n1%27%20in%20parents", .body = notes_page },
    .{ .contains = "files/a1?alt=media", .body = "content" },
    .{ .contains = "files/d1?alt=media", .body = "never" },
    .{ .contains = "upload/drive/v3/files/a1?uploadType=media", .method = .PATCH, .body = 
        \\{"id":"a1","name":"a.txt","mimeType":"text/plain","size":"3","modifiedTime":"2024-06-01T00:00:00Z"}
    },
    .{ .contains = "files?fields=", .method = .POST, .body =
        \\{"id":"new1","name":"b.txt","mimeType":"text/plain","size":"0"}
    },
    .{ .contains = "addParents=", .method = .PATCH, .body = 
        \\{"id":"a1","name":"renamed.txt","mimeType":"text/plain","size":"7"}
    },
    .{ .contains = "?fields=id", .method = .PATCH, .body = "{\"id\":\"x\"}" },
};

const Harness = struct {
    scripted: Scripted,
    client: drive.Client,
    sink: Sink,

    fn init(allocator: Allocator, rs: []const Scripted.Route) !*Harness {
        const h = try allocator.create(Harness);
        h.scripted = Scripted.init(allocator, rs);
        h.client = try drive.Client.init(allocator, h.scripted.transport(), "token", "root");
        h.sink = .{ .allocator = allocator };
        return h;
    }
    fn deinit(h: *Harness) void {
        const allocator = h.sink.allocator;
        h.sink.reset();
        h.client.deinit();
        h.scripted.deinit();
        allocator.destroy(h);
    }
    fn fs(h: *Harness) Fs.Fs {
        return h.client.fs();
    }
};

test "listDir paginates and reports entries in Drive order" {
    const h = try Harness.init(std.testing.allocator, &little_drive);
    defer h.deinit();
    _ = try h.fs().listDir(std.testing.allocator, "/", Sink.onList, &h.sink);
    try settle(h.fs(), &h.sink);
    const entries = h.sink.entries orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("notes", entries[0].name);
    try std.testing.expectEqual(Fs.Kind.dir, entries[0].kind);
    try std.testing.expectEqual(@as(i64, 1_704_164_645_678), entries[0].modified_ms);
    try std.testing.expectEqualStrings("top.txt", entries[1].name);
    try std.testing.expectEqual(@as(u64, 5), entries[1].size);
    try std.testing.expectEqual(@as(usize, 2), h.scripted.log.items.len);
    try std.testing.expect(std.mem.indexOf(u8, h.scripted.url(1), "pageToken=p2") != null);
}

test "a cold path resolves by listing ancestors once, then answers from the index" {
    const h = try Harness.init(std.testing.allocator, &little_drive);
    defer h.deinit();
    _ = try h.fs().stat("/notes/a.txt", Sink.onStat, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(@as(u64, 7), h.sink.stat.?.size);
    // root (2 pages) + notes = 3 requests …
    try std.testing.expectEqual(@as(usize, 3), h.scripted.log.items.len);
    // … and a sibling is now free.
    h.sink.reset();
    _ = try h.fs().stat("/notes/Doc", Sink.onStat, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(Fs.Kind.file, h.sink.stat.?.kind);
    try std.testing.expectEqual(@as(usize, 3), h.scripted.log.items.len);
    // A name that is not there, under a listed directory, is NotFound with no request.
    h.sink.reset();
    _ = try h.fs().stat("/notes/nope", Sink.onStat, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(Fs.Error.NotFound, h.sink.err.?);
    try std.testing.expectEqual(@as(usize, 3), h.scripted.log.items.len);
}

test "readFile fetches media; a Google Doc is NotBinary before any download" {
    const h = try Harness.init(std.testing.allocator, &little_drive);
    defer h.deinit();
    _ = try h.fs().readFile(std.testing.allocator, "/notes/a.txt", Sink.onRead, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqualStrings("content", h.sink.bytes.?);
    const n = h.scripted.log.items.len;
    h.sink.reset();
    _ = try h.fs().readFile(std.testing.allocator, "/notes/Doc", Sink.onRead, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(Fs.Error.NotBinary, h.sink.err.?);
    try std.testing.expectEqual(n, h.scripted.log.items.len);
}

test "writeFile uploads media and refreshes size/mtime" {
    const h = try Harness.init(std.testing.allocator, &little_drive);
    defer h.deinit();
    _ = try h.fs().writeFile("/notes/a.txt", "abc", Sink.onDone, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expect(h.sink.err == null);
    const last = h.scripted.log.items[h.scripted.log.items.len - 1];
    try std.testing.expectEqual(http.Method.PATCH, last.method);
    try std.testing.expectEqualStrings("abc", last.body);
    h.sink.reset();
    _ = try h.fs().stat("/notes/a.txt", Sink.onStat, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(@as(u64, 3), h.sink.stat.?.size);
}

test "createFile posts metadata with the parent id; a second create is Exists" {
    const h = try Harness.init(std.testing.allocator, &little_drive);
    defer h.deinit();
    _ = try h.fs().createFile("/notes/b.txt", Sink.onDone, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expect(h.sink.err == null);
    const last = h.scripted.log.items[h.scripted.log.items.len - 1];
    try std.testing.expectEqual(http.Method.POST, last.method);
    try std.testing.expect(std.mem.indexOf(u8, last.body, "\"parents\":[\"n1\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, last.body, "mimeType") == null);
    h.sink.reset();
    _ = try h.fs().createFile("/notes/b.txt", Sink.onDone, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(Fs.Error.Exists, h.sink.err.?);
    // An existing (listed) name is refused before Drive is asked.
    h.sink.reset();
    _ = try h.fs().createFile("/notes/a.txt", Sink.onDone, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(Fs.Error.Exists, h.sink.err.?);
}

test "mkdir posts the folder mime type" {
    const h = try Harness.init(std.testing.allocator, &little_drive);
    defer h.deinit();
    _ = try h.fs().mkdir("/sub", Sink.onDone, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expect(h.sink.err == null);
    const last = h.scripted.log.items[h.scripted.log.items.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, last.body, drive.folder_mime) != null);
    try std.testing.expect(std.mem.indexOf(u8, last.body, "\"parents\":[\"root\"]") != null);
}

test "rename moves parents and re-keys the index" {
    const h = try Harness.init(std.testing.allocator, &little_drive);
    defer h.deinit();
    _ = try h.fs().rename("/notes/a.txt", "/renamed.txt", Sink.onDone, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expect(h.sink.err == null);
    const last = h.scripted.log.items[h.scripted.log.items.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, last.url, "files/a1?addParents=root&removeParents=n1") != null);
    try std.testing.expect(std.mem.indexOf(u8, last.body, "\"name\":\"renamed.txt\"") != null);
    h.sink.reset();
    _ = try h.fs().stat("/renamed.txt", Sink.onStat, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(@as(u64, 7), h.sink.stat.?.size);
    h.sink.reset();
    _ = try h.fs().stat("/notes/a.txt", Sink.onStat, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(Fs.Error.NotFound, h.sink.err.?);
}

test "remove trashes; a non-empty directory is refused after listing it" {
    const h = try Harness.init(std.testing.allocator, &little_drive);
    defer h.deinit();
    _ = try h.fs().remove("/notes", Sink.onDone, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(Fs.Error.NotEmpty, h.sink.err.?);
    h.sink.reset();
    _ = try h.fs().remove("/top.txt", Sink.onDone, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expect(h.sink.err == null);
    const last = h.scripted.log.items[h.scripted.log.items.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, last.url, "files/t1?fields=id") != null);
    try std.testing.expectEqualStrings("{\"trashed\":true}", last.body);
    h.sink.reset();
    _ = try h.fs().stat("/top.txt", Sink.onStat, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(Fs.Error.NotFound, h.sink.err.?);
}

test "duplicate sibling names: first listed wins" {
    const dup = [_]Scripted.Route{
        .{ .contains = "in%20parents", .body =
            \\{"files":[{"id":"x1","name":"same.txt","mimeType":"text/plain","size":"1"},{"id":"x2","name":"same.txt","mimeType":"text/plain","size":"2"}]}
        },
        .{ .contains = "files/x1?alt=media", .body = "first" },
    };
    const h = try Harness.init(std.testing.allocator, &dup);
    defer h.deinit();
    _ = try h.fs().listDir(std.testing.allocator, "/", Sink.onList, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(@as(usize, 1), h.sink.entries.?.len);
    h.sink.reset();
    _ = try h.fs().readFile(std.testing.allocator, "/same.txt", Sink.onRead, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqualStrings("first", h.sink.bytes.?);
}

test "401 is Unauthorized, 403 is Forbidden" {
    const denied = [_]Scripted.Route{.{ .contains = "in%20parents", .status = 401, .body = "" }};
    const h = try Harness.init(std.testing.allocator, &denied);
    defer h.deinit();
    _ = try h.fs().listDir(std.testing.allocator, "/", Sink.onList, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(Fs.Error.Unauthorized, h.sink.err.?);

    const forbidden = [_]Scripted.Route{.{ .contains = "in%20parents", .status = 403, .body = "" }};
    const h2 = try Harness.init(std.testing.allocator, &forbidden);
    defer h2.deinit();
    _ = try h2.fs().listDir(std.testing.allocator, "/", Sink.onList, &h2.sink);
    try settle(h2.fs(), &h2.sink);
    try std.testing.expectEqual(Fs.Error.Forbidden, h2.sink.err.?);
}

test "cancel mid-flight: no callback, no leak" {
    const h = try Harness.init(std.testing.allocator, &little_drive);
    defer h.deinit();
    const job = try h.fs().readFile(std.testing.allocator, "/notes/a.txt", Sink.onRead, &h.sink);
    h.fs().pump(); // root page 1 answered, page 2 in flight
    h.fs().cancel(job);
    var i: usize = 0;
    while (i < 8) : (i += 1) h.fs().pump();
    try std.testing.expectEqual(@as(usize, 0), h.sink.calls);
}
