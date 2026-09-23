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
        self.completions.drain({}, struct {
            fn f(_: void, p: Pending) void {
                p.cb(p.ctx, .{ .status = p.status, .body = p.body });
            }
        }.f);
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
    modified_ms: i64 = 0,
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
    fn onRead(ctx: ?*anyopaque, result: Fs.Error!Fs.Read) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        const r = result catch |err| {
            self.err = err;
            return;
        };
        self.bytes = r.bytes;
        self.modified_ms = r.modified_ms;
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
    \\{"files":[{"id":"a1","name":"a.txt","mimeType":"text/plain","size":"7","modifiedTime":"2024-01-01T00:00:00Z"},{"id":"d1","name":"Doc","mimeType":"application/vnd.google-apps.document"}]}
;
const little_drive = [_]Scripted.Route{
    .{ .contains = "changes/startPageToken", .body = "{\"startPageToken\":\"100\"}" },
    .{ .contains = "changes?", .body =
        \\{"newStartPageToken":"101","changes":[{"fileId":"a1","removed":false,"file":{"id":"a1","name":"a.txt","parents":["n1"]}},{"fileId":"zz","removed":false,"file":{"id":"zz","name":"new.md","mimeType":"text/markdown","parents":["root"]}}]}
    },
    .{ .contains = "pageToken=p2", .body = root_page2 },
    .{ .contains = "q=%27root%27%20in%20parents", .body = root_page1 },
    .{ .contains = "q=%27n1%27%20in%20parents", .body = notes_page },
    .{ .contains = "files/a1?alt=media", .body = "content" },
    // The live metadata says someone saved a.txt a day after the listing.
    .{ .contains = "files/a1?fields=modifiedTime", .method = .GET, .body = "{\"modifiedTime\":\"2024-01-02T00:00:00Z\"}" },
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
    .{ .contains = "files/a1?fields=", .method = .PATCH, .body =
        \\{"id":"a1","name":"b.txt","mimeType":"text/plain","size":"7"}
    },
};

const Harness = struct {
    scripted: Scripted,
    client: drive.Client,
    sink: Sink,

    fn init(allocator: Allocator, rs: []const Scripted.Route) !*Harness {
        const h = try allocator.create(Harness);
        h.scripted = Scripted.init(allocator, rs);
        h.client = try drive.Client.init(allocator, std.testing.io, h.scripted.transport(), "token", "root");
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
    _ = try h.fs().writeFile("/notes/a.txt", "abc", .{}, Sink.onDone, &h.sink);
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

test "a conditional write checks Drive's live modifiedTime and refuses a stale one" {
    const a = std.testing.allocator;
    const h = try Harness.init(a, &little_drive);
    defer h.deinit();
    _ = try h.fs().readFile(a, "/notes/a.txt", Sink.onRead, &h.sink);
    try settle(h.fs(), &h.sink);
    const seen = h.sink.modified_ms;
    try std.testing.expect(seen != 0);
    h.sink.reset();
    _ = try h.fs().writeFile("/notes/a.txt", "mine", .{ .if_unmodified_ms = seen }, Sink.onDone, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(Fs.Error.Conflict, h.sink.err.?);
    // No upload happened.
    for (h.scripted.log.items) |l| try std.testing.expect(l.method != .PATCH);
    // With the live time it goes through.
    h.sink.reset();
    _ = try h.fs().writeFile("/notes/a.txt", "mine", .{ .if_unmodified_ms = 1_704_153_600_000 }, Sink.onDone, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expect(h.sink.err == null);
    try std.testing.expectEqual(http.Method.PATCH, h.scripted.log.items[h.scripted.log.items.len - 1].method);
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

test "an ancestor forgotten while a listing is in flight fails that listing, not the process" {
    const h = try Harness.init(std.testing.allocator, &little_drive);
    defer h.deinit();
    // Page 1 of the root arrives; before page 2, something re-lists the root (a mutation's
    // invalidateAll) which drops what the first listing indexed.
    _ = try h.fs().listDir(std.testing.allocator, "/", Sink.onList, &h.sink);
    h.fs().pump(); // page 1 answered, page 2 in flight
    h.client.forget("/");
    try settle(h.fs(), &h.sink);
    try std.testing.expect(h.sink.err != null or h.sink.entries != null);
}

test "a rename within one folder does not move parents" {
    const h = try Harness.init(std.testing.allocator, &little_drive);
    defer h.deinit();
    _ = try h.fs().rename("/notes/a.txt", "/notes/b.txt", Sink.onDone, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expect(h.sink.err == null);
    const last = h.scripted.log.items[h.scripted.log.items.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, last.url, "addParents") == null);
    try std.testing.expect(std.mem.indexOf(u8, last.body, "\"name\":\"b.txt\"") != null);
}

test "changes: the first poll takes a start token, the next folds changes into the index and reports them" {
    const a = std.testing.allocator;
    const h = try Harness.init(a, &little_drive);
    defer h.deinit();
    // Index root and /notes first, so the changes have something to hit.
    _ = try h.fs().stat("/notes/a.txt", Sink.onStat, &h.sink);
    try settle(h.fs(), &h.sink);

    const Got = struct {
        changes: ?[]drive.Change = null,
        calls: usize = 0,
        fn cb(ctx: ?*anyopaque, result: Fs.Error![]drive.Change) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            self.changes = result catch null;
        }
    };
    var got: Got = .{};
    _ = try h.client.pollChanges(a, Got.cb, &got);
    var spins: usize = 0;
    while (got.calls == 0 and spins < 32) : (spins += 1) h.fs().pump();
    try std.testing.expectEqual(@as(usize, 0), got.changes.?.len);
    drive.Client.freeChanges(a, got.changes.?);
    try std.testing.expectEqualStrings("100", h.client.changes_token.?);

    got = .{};
    _ = try h.client.pollChanges(a, Got.cb, &got);
    spins = 0;
    while (got.calls == 0 and spins < 32) : (spins += 1) h.fs().pump();
    const changes = got.changes orelse return error.NoChanges;
    defer drive.Client.freeChanges(a, changes);
    // a.txt's metadata moved → modified in place; new.md appeared under the listed root → created.
    try std.testing.expectEqual(@as(usize, 2), changes.len);
    try std.testing.expectEqual(drive.Change.Kind.modified, changes[0].kind);
    try std.testing.expectEqualStrings("/notes/a.txt", changes[0].path);
    try std.testing.expectEqual(drive.Change.Kind.created, changes[1].kind);
    try std.testing.expectEqualStrings("/new.md", changes[1].path);
    try std.testing.expect(!changes[1].is_dir);
    try std.testing.expectEqualStrings("101", h.client.changes_token.?);
    // Both are in the index now, where a listing answered from it will find them.
    try std.testing.expectEqualStrings("/notes/a.txt", h.client.pathOfId("a1").?);
    try std.testing.expectEqualStrings("/new.md", h.client.pathOfId("zz").?);
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

test "re-listing an ancestor while a deeper listing is in flight does not fail it" {
    // What a vault scan meets: it lists `/notes` while the file tree re-lists `/`.
    const h = try Harness.init(std.testing.allocator, &little_drive);
    defer h.deinit();
    _ = try h.fs().listDir(std.testing.allocator, "/", Sink.onList, &h.sink);
    try settle(h.fs(), &h.sink);
    h.sink.reset();

    var deep: Sink = .{ .allocator = std.testing.allocator };
    defer deep.reset();
    _ = try h.fs().listDir(std.testing.allocator, "/notes", Sink.onList, &deep);
    _ = try h.fs().listDir(std.testing.allocator, "/", Sink.onList, &h.sink);
    try settle(h.fs(), &deep);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(@as(?Fs.Error, null), deep.err);
    try std.testing.expectEqual(@as(usize, 2), deep.entries.?.len);
    try std.testing.expectEqual(@as(usize, 2), h.sink.entries.?.len);

    // And what the deeper listing learned survived the root's re-list: no request for this.
    const before = h.scripted.log.items.len;
    h.sink.reset();
    _ = try h.fs().stat("/notes/a.txt", Sink.onStat, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(@as(u64, 7), h.sink.stat.?.size);
    try std.testing.expectEqual(before, h.scripted.log.items.len);
}

test "a re-list drops children that are gone and keeps a surviving folder's subtree" {
    const h = try Harness.init(std.testing.allocator, &little_drive);
    defer h.deinit();
    _ = try h.fs().stat("/notes/a.txt", Sink.onStat, &h.sink);
    try settle(h.fs(), &h.sink);

    // `top.txt` is gone and `notes` is a different folder under the same name … then the
    // same folder again, with `top.txt` back.
    const replaced = [_]Scripted.Route{
        .{ .contains = "q=%27root%27%20in%20parents", .body =
            \\{"files":[{"id":"n2","name":"notes","mimeType":"application/vnd.google-apps.folder"}]}
        },
    };
    const same = [_]Scripted.Route{
        .{ .contains = "q=%27root%27%20in%20parents", .body =
            \\{"files":[{"id":"n1","name":"notes","mimeType":"application/vnd.google-apps.folder","modifiedTime":"2024-03-01T00:00:00Z"},{"id":"t1","name":"top.txt","mimeType":"text/plain","size":"9"}]}
        },
    };

    // Same folder: its subtree stays, its metadata refreshes.
    h.scripted.routes = &same;
    h.sink.reset();
    _ = try h.fs().listDir(std.testing.allocator, "/", Sink.onList, &h.sink);
    try settle(h.fs(), &h.sink);
    const after_same = h.scripted.log.items.len;
    h.sink.reset();
    _ = try h.fs().stat("/notes/a.txt", Sink.onStat, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(@as(u64, 7), h.sink.stat.?.size);
    try std.testing.expectEqual(after_same, h.scripted.log.items.len);
    h.sink.reset();
    _ = try h.fs().stat("/top.txt", Sink.onStat, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(@as(u64, 9), h.sink.stat.?.size);

    // A different folder under the name, and `top.txt` gone.
    h.scripted.routes = &replaced;
    h.sink.reset();
    _ = try h.fs().listDir(std.testing.allocator, "/", Sink.onList, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(@as(usize, 1), h.sink.entries.?.len);
    h.sink.reset();
    _ = try h.fs().stat("/top.txt", Sink.onStat, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(Fs.Error.NotFound, h.sink.err.?);
    // The old folder's children went with it: this has to ask Drive about `n2`.
    h.sink.reset();
    _ = try h.fs().stat("/notes/a.txt", Sink.onStat, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(Fs.Error.NotFound, h.sink.err.?);
    try std.testing.expect(std.mem.indexOf(u8, h.scripted.url(h.scripted.log.items.len - 1), "n2") != null);
}

/// Google's body for a spent per-minute quota, trimmed to what the classifier reads.
const quota_body =
    \\{"error":{"code":403,"message":"Quota exceeded for quota metric 'Total Query Cost' and limit 'Units per minute per user'","errors":[{"message":"Quota exceeded","domain":"usageLimits","reason":"rateLimitExceeded"}]}}
;

test "a spent quota is retried, not reported as a refusal" {
    // The failure this exists for: a recursive crawl of a real drive spends Drive's per-minute
    // query cost in seconds, and every 403 that followed used to surface as Forbidden — the
    // mount looked permission-broken for the rest of the session over something that fixes
    // itself in a moment.
    const a = std.testing.allocator;
    const h = try Harness.init(a, &.{
        .{ .contains = "files?q=", .status = 403, .body = quota_body },
    });
    defer h.deinit();

    _ = try h.fs().listDir(a, "/", Sink.onList, &h.sink);
    // Several pumps: the retry is on a clock, so nothing comes back in the first few.
    var rounds: usize = 0;
    while (h.sink.calls == 0 and rounds < 8) : (rounds += 1) h.fs().pump();
    try std.testing.expectEqual(@as(usize, 0), h.sink.calls);
    try std.testing.expect(h.client.quiet_until_ms > 0);
}

test "a refusal that is not a quota is still a refusal" {
    const a = std.testing.allocator;
    const h = try Harness.init(a, &.{
        .{ .contains = "files?q=", .status = 403, .body = 
            \\{"error":{"code":403,"message":"Insufficient permission","errors":[{"reason":"insufficientPermissions"}]}}
        },
    });
    defer h.deinit();

    _ = try h.fs().listDir(a, "/", Sink.onList, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(@as(?Fs.Error, error.Forbidden), h.sink.err);
}

test "a folder that came back as a file forgets what was beneath it" {
    // The crash this exists for: the same id listed again, no longer a folder. `child` was
    // freed and *then* handed to `forgetChildren`, which read it — a segfault inside
    // `startsWith`, reached by re-listing a drive (what "Set Root Here" does).
    const a = std.testing.allocator;
    const h = try Harness.init(a, &little_drive);
    defer h.deinit();

    _ = try h.fs().listDir(a, "/", Sink.onList, &h.sink);
    try settle(h.fs(), &h.sink);
    h.sink.reset();
    _ = try h.fs().listDir(a, "/notes", Sink.onList, &h.sink);
    try settle(h.fs(), &h.sink);
    h.sink.reset();

    // Same id `n1`, same name, now a plain file.
    const notes_is_a_file = [_]Scripted.Route{
        .{ .contains = "pageToken=p2", .body = root_page2 },
        .{ .contains = "q=%27root%27%20in%20parents", .body = 
            \\{"nextPageToken":"p2","files":[{"id":"n1","name":"notes","mimeType":"text/plain","size":"3"}]}
        },
    };
    h.scripted.routes = &notes_is_a_file;

    _ = try h.fs().listDir(a, "/", Sink.onList, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(@as(?Fs.Error, null), h.sink.err);

    // What was beneath it is gone with it: the old child is not answered from the index any
    // more. (It does not go back to Drive either — a path beneath a *file* cannot exist, so
    // resolving it fails without a round trip, which is the better answer.)
    h.sink.reset();
    _ = try h.fs().stat("/notes/a.txt", Sink.onStat, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expect(h.sink.err != null);
    try std.testing.expect(h.sink.stat == null);
}

// A drive for the walk: / { notes/ { a.md, sub/ { deep.md } }, more/ { b.md }, top.md }
// Asked about as `'root'`, answered under My Drive's real id — as Drive does: the alias is
// accepted in a query and never reported back.
const walk_drive = [_]Scripted.Route{
    .{ .contains = "q=%28%27root%27%20in%20parents%29", .body =
        \\{"files":[{"id":"n1","name":"notes","mimeType":"application/vnd.google-apps.folder","parents":["0Aroot"]},{"id":"m1","name":"more","mimeType":"application/vnd.google-apps.folder","parents":["0Aroot"]},{"id":"t1","name":"top.md","mimeType":"text/markdown","size":"3","parents":["0Aroot"]}]}
    },
    // Both of root's folders in one query, answered in one page.
    .{ .contains = "q=%28%27n1%27%20in%20parents%20or%20%27m1%27%20in%20parents%29", .body =
        \\{"files":[{"id":"a1","name":"a.md","mimeType":"text/markdown","size":"5","parents":["n1"]},{"id":"s1","name":"sub","mimeType":"application/vnd.google-apps.folder","parents":["n1"]},{"id":"b1","name":"b.md","mimeType":"text/markdown","size":"6","parents":["m1"]}]}
    },
    .{ .contains = "q=%28%27s1%27%20in%20parents%29", .body =
        \\{"files":[{"id":"d1","name":"deep.md","mimeType":"text/markdown","size":"7","parents":["s1"]}]}
    },
};

fn settleWalk(h: *Harness) !void {
    var rounds: usize = 0;
    while (h.client.prefetching()) : (rounds += 1) {
        if (rounds > 64) return error.WalkNeverFinished;
        h.fs().pump();
    }
}

fn countRequestsContaining(h: *Harness, needle: []const u8) usize {
    var n: usize = 0;
    for (h.scripted.log.items) |l| {
        if (std.mem.indexOf(u8, l.url, needle) != null) n += 1;
    }
    return n;
}

test "prefetch walks the tree in batched queries, then listings answer from the index" {
    const h = try Harness.init(std.testing.allocator, &walk_drive);
    defer h.deinit();
    try h.client.prefetch("/");
    try settleWalk(h);
    // One query per level, not one per folder: root, then notes+more together, then sub.
    try std.testing.expectEqual(@as(usize, 3), h.scripted.log.items.len);
    try std.testing.expectEqualStrings("/notes/sub/deep.md", h.client.pathOfId("d1").?);
    try std.testing.expectEqualStrings("/more/b.md", h.client.pathOfId("b1").?);
    // My Drive is known by its real id from the first batch on, so the change feed can route
    // a change at the top of the drive.
    try std.testing.expectEqualStrings("/", h.client.pathOfId("0Aroot").?);

    // The root answers with its children, not the empty listing the alias used to leave it.
    _ = try h.fs().listDir(std.testing.allocator, "/", Sink.onList, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(@as(usize, 3), h.sink.entries.?.len);
    h.sink.reset();

    // A crawler arriving now asks nothing of Drive.
    _ = try h.fs().listDir(std.testing.allocator, "/notes", Sink.onList, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(@as(usize, 2), h.sink.entries.?.len);
    try std.testing.expectEqual(@as(usize, 3), h.scripted.log.items.len);
}

test "a listing of a folder the walk has queued waits for it instead of asking twice" {
    const h = try Harness.init(std.testing.allocator, &walk_drive);
    defer h.deinit();
    try h.client.prefetch("/");
    // Asked before the walk has even reached /notes/sub.
    _ = try h.fs().listDir(std.testing.allocator, "/notes/sub", Sink.onList, &h.sink);
    try settle(h.fs(), &h.sink);
    try settleWalk(h);
    try std.testing.expectEqual(@as(?Fs.Error, null), h.sink.err);
    try std.testing.expectEqual(@as(usize, 1), h.sink.entries.?.len);
    try std.testing.expectEqualStrings("deep.md", h.sink.entries.?[0].name);
    // Every request was a walk query; nothing listed a folder on its own.
    try std.testing.expectEqual(h.scripted.log.items.len, countRequestsContaining(h, "q=%28"));
}

test "a refused batch is asked again in halves" {
    const routes = [_]Scripted.Route{
        walk_drive[0],
        // The two-folder query is "too complex"; each folder alone is fine.
        .{ .contains = "q=%28%27n1%27%20in%20parents%20or", .status = 400, .body = "{\"error\":{\"message\":\"The query is too complex.\"}}" },
        .{ .contains = "q=%28%27n1%27%20in%20parents%29", .body =
            \\{"files":[{"id":"a1","name":"a.md","mimeType":"text/markdown","parents":["n1"]}]}
        },
        .{ .contains = "q=%28%27m1%27%20in%20parents%29", .body =
            \\{"files":[{"id":"b1","name":"b.md","mimeType":"text/markdown","parents":["m1"]}]}
        },
    };
    const h = try Harness.init(std.testing.allocator, &routes);
    defer h.deinit();
    try h.client.prefetch("/");
    try settleWalk(h);
    try std.testing.expectEqualStrings("/notes/a.md", h.client.pathOfId("a1").?);
    try std.testing.expectEqualStrings("/more/b.md", h.client.pathOfId("b1").?);
    try std.testing.expect(h.client.tree.get("/more").?.listed);
}

test "once the change feed has a token, a listed folder answers from the index" {
    const a = std.testing.allocator;
    const h = try Harness.init(a, &little_drive);
    defer h.deinit();
    _ = try h.fs().listDir(a, "/", Sink.onList, &h.sink);
    try settle(h.fs(), &h.sink);
    const Got = struct {
        calls: usize = 0,
        fn cb(ctx: ?*anyopaque, result: Fs.Error![]drive.Change) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            if (result) |c| drive.Client.freeChanges(std.testing.allocator, c) else |_| {}
        }
    };
    var got: Got = .{};
    _ = try h.client.pollChanges(a, Got.cb, &got);
    var spins: usize = 0;
    while (got.calls == 0 and spins < 32) : (spins += 1) h.fs().pump();

    const before = h.scripted.log.items.len;
    h.sink.reset();
    _ = try h.fs().listDir(a, "/", Sink.onList, &h.sink);
    try settle(h.fs(), &h.sink);
    try std.testing.expectEqual(@as(usize, 2), h.sink.entries.?.len);
    try std.testing.expectEqual(before, h.scripted.log.items.len);
}
