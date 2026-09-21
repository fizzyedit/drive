//! Google Drive v3 behind `Fs`. HTTP and OAuth stay in the host via `http.Transport` and a
//! bearer token; this file knows Drive's REST shape and nothing else.
//!
//! ## Paths over an id-addressed store
//!
//! Drive addresses everything by id and allows two children of one folder to share a name.
//! `Fs` speaks paths. The bridge is a **lazy path index**: listing a directory records every
//! child under its path (`/Notes/todo.md` → `{id, kind, size, mtime}`), so anything beneath a
//! listed directory resolves with no request, and resolving a cold path lists its ancestors
//! one at a time. Duplicate names resolve first-listed-wins. Per-directory listing rather than
//! one whole-drive `files.list` because it behaves the same under every scope — with
//! `drive.file` and a picked folder, descendants are not guaranteed to be granted.
//!
//! `listDir` always refetches (the consumer is a cache calling on a miss); everything else
//! trusts the index. A host that learns of an outside change (`changes.list`, later) calls
//! `forget(path)`.
//!
//! ## Every op is a small state machine
//!
//! A `Job` walks: resolve what it needs → issue one request → update the index → complete.
//! Each transport completion re-enters `Job.step`, which does as much as it can synchronously
//! and returns when it has to wait. Completions to the caller are queued and delivered from
//! `pump`, after the transport's own pump — so in fizzy a request finished this frame is seen
//! this frame.

const std = @import("std");
const vfs = @import("core").vfs;
const Fs = vfs;
const http = vfs.http;
const Allocator = std.mem.Allocator;

pub const folder_mime = "application/vnd.google-apps.folder";
pub const google_apps_prefix = "application/vnd.google-apps.";
const api = "https://www.googleapis.com/drive/v3/files";
const upload_api = "https://www.googleapis.com/upload/drive/v3/files";
const file_fields = "id,name,mimeType,size,modifiedTime";

/// What Drive told us about one path.
const Node = struct {
    id: []u8,
    kind: Fs.Kind,
    size: u64 = 0,
    modified_ms: i64 = 0,
    /// A Google Doc / Sheet / Slide: exists, has no bytes.
    google_app: bool = false,
    /// Children have been listed at least once, so a name missing from the index is `NotFound`
    /// rather than "not looked yet".
    listed: bool = false,
};

pub const Client = struct {
    allocator: Allocator,
    transport: http.Transport,
    /// Refreshed by the host: the client reads it at request time, never copies it.
    access_token: []const u8,
    /// The Drive folder id the mount's `/` stands for. `"root"` is My Drive; a picked folder's
    /// id makes that folder the root. Not owned.
    root_id: []const u8 = "root",

    index: std.StringHashMapUnmanaged(Node) = .empty,
    /// `changes.list` page token: where the next poll continues from. Owned; null until the
    /// first poll fetched a start token.
    changes_token: ?[]u8 = null,
    jobs: std.AutoArrayHashMapUnmanaged(u64, *Job) = .empty,
    ready: http.Completions(*Job),
    /// The job whose callback `pump` is inside, so a cancel of it from that callback is a
    /// no-op rather than a use-after-free.
    delivering: ?*Job = null,
    initialised: bool = false,

    pub fn init(allocator: Allocator, transport: http.Transport, access_token: []const u8, root_id: []const u8) Allocator.Error!Client {
        var self: Client = .{
            .allocator = allocator,
            .transport = transport,
            .access_token = access_token,
            .root_id = root_id,
            .ready = .init(allocator),
        };
        errdefer self.deinit();
        try self.index.put(allocator, try allocator.dupe(u8, "/"), .{ .id = try allocator.dupe(u8, root_id), .kind = .dir });
        self.initialised = true;
        return self;
    }

    pub fn deinit(self: *Client) void {
        if (self.changes_token) |t| self.allocator.free(t);
        for (self.jobs.values()) |job| job.destroy();
        self.jobs.deinit(self.allocator);
        self.ready.deinit();
        var it = self.index.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.id);
        }
        self.index.deinit(self.allocator);
    }

    pub fn fs(self: *Client) Fs.Fs {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Paths whose contents changed on Drive since the last poll (files the index knew about
    /// have been forgotten already; directories are un-listed). Owned by the callback.
    pub const ChangesFn = *const fn (ctx: ?*anyopaque, result: Fs.Error![][]u8) void;

    pub fn freeChanges(allocator: Allocator, paths: [][]u8) void {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }

    /// Ask Drive what changed since the last call. The first call only fetches a start token
    /// and answers with nothing — changes are relative to a moment, and that is the moment.
    /// Each path reported is one the index knew: a file's own path when it was modified or
    /// removed, or its parent when something appeared under a listed directory. The host
    /// invalidates those listings; nothing here draws.
    pub fn pollChanges(self: *Client, allocator: Allocator, cb: ChangesFn, ctx: ?*anyopaque) Fs.Error!Fs.Job {
        return self.start("/", null, .{ .changes = .{ .allocator = allocator, .cb = cb, .ctx = ctx } });
    }

    /// Drop what the index knows at and beneath `path`, so the next op re-asks Drive. The
    /// root is never dropped, only un-listed.
    pub fn forget(self: *Client, path: []const u8) void {
        if (Fs.path.isRoot(path)) {
            self.forgetChildren("/");
            return;
        }
        self.drop(path);
        if (self.index.getPtr(Fs.path.dirname(path))) |parent| parent.listed = false;
    }

    /// Remove `path` and everything beneath it from the index, trusting the parent's listing
    /// otherwise — what a successful `remove` knows, where `forget` does not.
    fn drop(self: *Client, path: []const u8) void {
        self.forgetChildren(path);
        if (self.index.fetchRemove(path)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.id);
        }
    }

    fn forgetChildren(self: *Client, dir: []const u8) void {
        var doomed: std.ArrayList([]const u8) = .empty;
        defer doomed.deinit(self.allocator);
        var it = self.index.keyIterator();
        while (it.next()) |key| {
            if (isBeneath(key.*, dir)) doomed.append(self.allocator, key.*) catch return;
        }
        for (doomed.items) |key| {
            const kv = self.index.fetchRemove(key).?;
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.id);
        }
        if (self.index.getPtr(dir)) |node| node.listed = false;
    }

    /// The path the index holds for a Drive id, or null when it has never listed it.
    pub fn pathOfId(self: *Client, id: []const u8) ?[]const u8 {
        var it = self.index.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.id, id)) return kv.key_ptr.*;
        }
        return null;
    }

    fn setChangesToken(self: *Client, token: []const u8) Allocator.Error!void {
        const copy = try self.allocator.dupe(u8, token);
        if (self.changes_token) |t| self.allocator.free(t);
        self.changes_token = copy;
    }

    fn isBeneath(path: []const u8, dir: []const u8) bool {
        if (Fs.path.isRoot(dir)) return !Fs.path.isRoot(path);
        return path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
    }

    const vtable: Fs.Fs.VTable = .{
        .listDir = startListDir,
        .stat = startStat,
        .readFile = startReadFile,
        .writeFile = startWriteFile,
        .createFile = startCreateFile,
        .mkdir = startMkdir,
        .rename = startRename,
        .remove = startRemove,
        .cancel = cancel,
        .pump = pump,
    };

    fn startListDir(ptr: *anyopaque, allocator: Allocator, path: []const u8, cb: Fs.ListDirFn, ctx: ?*anyopaque) Fs.Error!Fs.Job {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.start(path, null, .{ .list = .{ .allocator = allocator, .cb = cb, .ctx = ctx } });
    }
    fn startStat(ptr: *anyopaque, path: []const u8, cb: Fs.StatFn, ctx: ?*anyopaque) Fs.Error!Fs.Job {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.start(path, null, .{ .stat = .{ .cb = cb, .ctx = ctx } });
    }
    fn startReadFile(ptr: *anyopaque, allocator: Allocator, path: []const u8, cb: Fs.ReadFn, ctx: ?*anyopaque) Fs.Error!Fs.Job {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.start(path, null, .{ .read = .{ .allocator = allocator, .cb = cb, .ctx = ctx } });
    }
    fn startWriteFile(ptr: *anyopaque, path: []const u8, bytes: []const u8, opts: Fs.WriteOptions, cb: Fs.DoneFn, ctx: ?*anyopaque) Fs.Error!Fs.Job {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.start(path, null, .{ .write = .{ .bytes = bytes, .opts = opts, .cb = cb, .ctx = ctx } });
    }
    fn startCreateFile(ptr: *anyopaque, path: []const u8, cb: Fs.DoneFn, ctx: ?*anyopaque) Fs.Error!Fs.Job {
        const self: *Client = @ptrCast(@alignCast(ptr));
        if (Fs.path.isRoot(path)) return error.Exists;
        return self.start(path, null, .{ .create = .{ .kind = .file, .cb = cb, .ctx = ctx } });
    }
    fn startMkdir(ptr: *anyopaque, path: []const u8, cb: Fs.DoneFn, ctx: ?*anyopaque) Fs.Error!Fs.Job {
        const self: *Client = @ptrCast(@alignCast(ptr));
        if (Fs.path.isRoot(path)) return error.Exists;
        return self.start(path, null, .{ .create = .{ .kind = .dir, .cb = cb, .ctx = ctx } });
    }
    fn startRename(ptr: *anyopaque, path: []const u8, new_path: []const u8, cb: Fs.DoneFn, ctx: ?*anyopaque) Fs.Error!Fs.Job {
        const self: *Client = @ptrCast(@alignCast(ptr));
        if (Fs.path.isRoot(path) or Fs.path.isRoot(new_path)) return error.Unsupported;
        return self.start(path, new_path, .{ .rename = .{ .cb = cb, .ctx = ctx } });
    }
    fn startRemove(ptr: *anyopaque, path: []const u8, cb: Fs.DoneFn, ctx: ?*anyopaque) Fs.Error!Fs.Job {
        const self: *Client = @ptrCast(@alignCast(ptr));
        if (Fs.path.isRoot(path)) return error.Unsupported;
        return self.start(path, null, .{ .remove = .{ .cb = cb, .ctx = ctx } });
    }

    fn start(self: *Client, path: []const u8, path2: ?[]const u8, op: Job.Op) Fs.Error!Fs.Job {
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{ .client = self, .id = self.ready.nextId(), .op = op, .path = &.{}, .path2 = &.{} };
        job.path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(job.path);
        job.path2 = try self.allocator.dupe(u8, path2 orelse "");
        errdefer self.allocator.free(job.path2);
        try self.jobs.put(self.allocator, job.id, job);
        errdefer _ = self.jobs.swapRemove(job.id);
        job.step();
        return .{ .id = job.id };
    }

    fn cancel(ptr: *anyopaque, handle: Fs.Job) void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        const job = self.jobs.get(handle.id) orelse return;
        // Its own callback is running right now: `pump` destroys it once that returns.
        if (self.delivering == job) return;
        _ = self.jobs.swapRemove(handle.id);
        if (job.phase == .done) {
            // Queued for delivery. `remove` hands it back (or, if a callback earlier in the
            // same batch is what cancelled it, marks it skipped) — either way `pump` will not
            // touch it again, so it is ours to destroy.
            _ = self.ready.remove(handle.id);
        }
        job.destroy();
    }

    fn pump(ptr: *anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        self.transport.pump();
        self.ready.drain(self, deliverOne);
    }

    fn deliverOne(self: *Client, job: *Job) void {
        _ = self.jobs.swapRemove(job.id);
        self.delivering = job;
        job.deliver();
        self.delivering = null;
        job.destroy();
    }

    // -- HTTP ------------------------------------------------------------------------------

    /// Issue one request on behalf of `job`. `url` is owned by the job from here; `body` must
    /// outlive the request, and when the job allocated it, `body_owned` hands it over too.
    fn send(self: *Client, job: *Job, method: http.Method, url: []u8, content_type: ?[]const u8, body: []const u8, body_owned: ?[]u8) Fs.Error!void {
        job.freeRequest();
        job.url = url;
        job.body = body;
        job.body_owned = body_owned;
        job.auth = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.access_token});
        job.header_count = 1;
        job.headers[0] = .{ .name = "Authorization", .value = job.auth };
        if (content_type) |ct| {
            job.headers[1] = .{ .name = "Content-Type", .value = ct };
            job.header_count = 2;
        }
        job.pending = try self.transport.request(self.allocator, .{
            .method = method,
            .url = job.url,
            .headers = job.headers[0..job.header_count],
            .body = job.body,
        }, Job.onResponse, job);
    }
};

/// One in-flight op. Owned by the client from `start` until delivered or cancelled.
const Job = struct {
    client: *Client,
    id: u64,
    op: Op,
    /// The op's path (owned) and, for rename, the destination (owned; empty otherwise).
    path: []u8,
    path2: []u8,

    phase: Phase = .resolve,
    /// Which path `resolve` is walking, and how far it got.
    resolving: []const u8 = "",
    /// Directory whose children are being listed, and the next page to ask for.
    listing: []const u8 = "",
    page_token: ?[]u8 = null,
    /// The listed names, in Drive order, so `listDir` returns what this listing saw and not
    /// whatever the index accumulated.
    seen: std.ArrayList([]const u8) = .empty,
    /// A changes poll's paths, accumulated across its pages. Owned (client allocator).
    changed: std.ArrayList([]u8) = .empty,
    /// A conditional write's `modifiedTime` check has come back and matched.
    write_checked: bool = false,

    pending: ?http.Job = null,
    url: []u8 = &.{},
    body: []const u8 = &.{},
    body_owned: ?[]u8 = null,
    auth: []u8 = &.{},
    headers: [2]http.Header = undefined,
    header_count: usize = 0,

    result: Result = .{ .pending = {} },

    const Phase = enum {
        /// Walking `resolving` segment by segment, listing ancestors as needed.
        resolve,
        /// A page of `listing`'s children is in flight.
        list_page,
        /// The op's own request is in flight.
        request,
        done,
    };

    const Op = union(enum) {
        list: struct { allocator: Allocator, cb: Fs.ListDirFn, ctx: ?*anyopaque },
        stat: struct { cb: Fs.StatFn, ctx: ?*anyopaque },
        read: struct { allocator: Allocator, cb: Fs.ReadFn, ctx: ?*anyopaque },
        write: struct { bytes: []const u8, opts: Fs.WriteOptions, cb: Fs.DoneFn, ctx: ?*anyopaque },
        create: struct { kind: Fs.Kind, cb: Fs.DoneFn, ctx: ?*anyopaque },
        rename: struct { cb: Fs.DoneFn, ctx: ?*anyopaque },
        remove: struct { cb: Fs.DoneFn, ctx: ?*anyopaque },
        changes: struct { allocator: Allocator, cb: Client.ChangesFn, ctx: ?*anyopaque },
    };

    /// Set exactly once by `finish`; consumed by `deliver`.
    const Result = union(enum) {
        pending,
        err: Fs.Error,
        entries: []Fs.Entry,
        stat: Fs.Stat,
        read: Fs.Read,
        changed: [][]u8,
        ok,
    };

    fn destroy(job: *Job) void {
        const a = job.client.allocator;
        if (job.pending) |p| job.client.transport.cancel(p);
        job.freeRequest();
        if (job.page_token) |t| a.free(t);
        for (job.seen.items) |name| a.free(name);
        job.seen.deinit(a);
        switch (job.result) {
            .entries => |entries| Fs.freeEntries(job.op.list.allocator, entries),
            .read => |r| job.op.read.allocator.free(r.bytes),
            .changed => |paths| Client.freeChanges(job.op.changes.allocator, paths),
            else => {},
        }
        for (job.changed.items) |p| a.free(p);
        job.changed.deinit(a);
        a.free(job.path);
        a.free(job.path2);
        a.destroy(job);
    }

    fn freeRequest(job: *Job) void {
        const a = job.client.allocator;
        if (job.url.len != 0) a.free(job.url);
        if (job.auth.len != 0) a.free(job.auth);
        if (job.body_owned) |b| a.free(b);
        job.url = &.{};
        job.auth = &.{};
        job.body = &.{};
        job.body_owned = null;
        job.pending = null;
    }

    fn finish(job: *Job, err: Fs.Error) void {
        job.complete(.{ .err = err });
    }

    fn complete(job: *Job, result: Result) void {
        job.phase = .done;
        job.result = result;
        job.client.ready.push(job.id, job) catch {
            // The one failure that cannot be reported: the queue itself is out of memory. The
            // job stays in `jobs` and is freed with the client.
        };
    }

    fn deliver(job: *Job) void {
        const result = job.result;
        job.result = .pending;
        switch (job.op) {
            .list => |o| o.cb(o.ctx, switch (result) {
                .entries => |e| e,
                .err => |e| e,
                else => unreachable,
            }),
            .stat => |o| o.cb(o.ctx, switch (result) {
                .stat => |s| s,
                .err => |e| e,
                else => unreachable,
            }),
            .read => |o| o.cb(o.ctx, switch (result) {
                .read => |r| r,
                .err => |e| e,
                else => unreachable,
            }),
            .changes => |o| o.cb(o.ctx, switch (result) {
                .changed => |c| c,
                .err => |e| e,
                else => unreachable,
            }),
            inline .write, .create, .rename, .remove => |o| o.cb(o.ctx, switch (result) {
                .ok => {},
                .err => |e| e,
                else => unreachable,
            }),
        }
    }

    // -- the state machine ---------------------------------------------------------------

    /// Do everything possible without waiting; return once a request is in flight or the
    /// job is complete. Every failure inside the machine funnels through here to `finish`.
    fn step(job: *Job) void {
        job.stepInner() catch |err| job.finish(err);
    }

    fn stepInner(job: *Job) Fs.Error!void {
        const client = job.client;
        switch (job.phase) {
            .resolve => {
                if (job.resolving.len == 0) job.resolving = job.firstResolve();
                // Walk as far as the index already knows.
                var dir: []const u8 = "/";
                var it = Fs.path.segments(job.resolving);
                while (it.next()) |seg| {
                    const child_path_end = @intFromPtr(seg.ptr) + seg.len - @intFromPtr(job.resolving.ptr);
                    const child_path = job.resolving[0..child_path_end];
                    if (client.index.contains(child_path)) {
                        dir = child_path;
                        continue;
                    }
                    const parent = client.index.getPtr(dir) orelse return error.NotFound;
                    if (parent.kind != .dir) return error.NotADirectory;
                    if (parent.listed) return error.NotFound;
                    return job.beginListing(dir);
                }
                try job.resolved();
            },
            .list_page, .request, .done => {},
        }
    }

    /// What this op has to resolve before it can act. `listDir` resolves the directory itself
    /// and then lists it; creates resolve the parent and need it listed (to answer `Exists`).
    fn firstResolve(job: *Job) []const u8 {
        return switch (job.op) {
            .create => Fs.path.dirname(job.path),
            else => job.path,
        };
    }

    fn requestChanges(job: *Job) Fs.Error!void {
        const client = job.client;
        const a = client.allocator;
        job.phase = .request;
        const token = client.changes_token orelse {
            const url = try a.dupe(u8, "https://www.googleapis.com/drive/v3/changes/startPageToken");
            return client.send(job, .GET, url, null, &.{}, null);
        };
        var url: std.ArrayList(u8) = .empty;
        errdefer url.deinit(a);
        try url.appendSlice(a, "https://www.googleapis.com/drive/v3/changes?pageSize=1000&fields=newStartPageToken,nextPageToken,changes(fileId,removed,file(id,name,mimeType,size,modifiedTime,parents))&pageToken=");
        try appendQueryValue(a, &url, token);
        try client.send(job, .GET, try url.toOwnedSlice(a), null, &.{}, null);
    }

    /// `resolving` is fully in the index. Decide what comes next.
    fn resolved(job: *Job) Fs.Error!void {
        const client = job.client;
        const a = client.allocator;
        const node = client.index.getPtr(job.resolving) orelse return error.NotFound;
        switch (job.op) {
            .changes => try job.requestChanges(),
            .list => {
                if (node.kind != .dir) return error.NotADirectory;
                // Always refetch — the caller is a cache and this is its miss path.
                client.forgetChildren(job.path);
                try job.beginListing(job.path);
            },
            .stat => job.complete(.{ .stat = .{ .kind = node.kind, .size = node.size, .modified_ms = node.modified_ms } }),
            .read => {
                if (node.kind != .file) return error.NotAFile;
                if (node.google_app) return error.NotBinary;
                const url = try std.fmt.allocPrint(a, "{s}/{s}?alt=media", .{ api, node.id });
                job.phase = .request;
                try client.send(job, .GET, url, null, &.{}, null);
            },
            .write => |o| {
                if (node.kind != .file) return error.NotAFile;
                if (node.google_app) return error.NotBinary;
                if (o.opts.if_unmodified_ms != null and !job.write_checked) {
                    // The index's modified time may be seconds stale; ask Drive for the live
                    // one before uploading over someone else's edit.
                    const url = try std.fmt.allocPrint(a, "{s}/{s}?fields=modifiedTime", .{ api, node.id });
                    job.phase = .request;
                    return client.send(job, .GET, url, null, &.{}, null);
                }
                const url = try std.fmt.allocPrint(a, "{s}/{s}?uploadType=media&fields={s}", .{ upload_api, node.id, file_fields });
                job.phase = .request;
                try client.send(job, .PATCH, url, "application/octet-stream", o.bytes, null);
            },
            .create => |o| {
                // `resolving` is the parent; its listing is complete only once `listed`.
                if (node.kind != .dir) return error.NotADirectory;
                if (!node.listed) return job.beginListing(job.resolving);
                if (client.index.contains(job.path)) return error.Exists;
                const meta = try std.json.Stringify.valueAlloc(a, .{
                    .name = Fs.path.basename(job.path),
                    .parents = [_][]const u8{node.id},
                    .mimeType = if (o.kind == .dir) @as(?[]const u8, folder_mime) else null,
                }, .{ .emit_null_optional_fields = false });
                errdefer a.free(meta);
                const url = try std.fmt.allocPrint(a, "{s}?fields={s}", .{ api, file_fields });
                job.phase = .request;
                try client.send(job, .POST, url, "application/json", meta, meta);
            },
            .rename => {
                if (std.mem.eql(u8, job.resolving, job.path)) {
                    // Source found; now the destination's parent, which must be listed so a
                    // clash is caught before Drive silently creates a duplicate.
                    job.resolving = Fs.path.dirname(job.path2);
                    return job.stepInner();
                }
                if (node.kind != .dir) return error.NotADirectory;
                if (!node.listed) return job.beginListing(job.resolving);
                if (client.index.contains(job.path2)) return error.Exists;
                const src = client.index.getPtr(job.path) orelse return error.NotFound;
                const old_parent = client.index.getPtr(Fs.path.dirname(job.path)) orelse return error.NotFound;
                const meta = try std.json.Stringify.valueAlloc(a, .{ .name = Fs.path.basename(job.path2) }, .{});
                errdefer a.free(meta);
                // A plain rename keeps its parent; Google rejects add == remove.
                const url = if (std.mem.eql(u8, node.id, old_parent.id))
                    try std.fmt.allocPrint(a, "{s}/{s}?fields={s}", .{ api, src.id, file_fields })
                else
                    try std.fmt.allocPrint(a, "{s}/{s}?addParents={s}&removeParents={s}&fields={s}", .{ api, src.id, node.id, old_parent.id, file_fields });
                job.phase = .request;
                try client.send(job, .PATCH, url, "application/json", meta, meta);
            },
            .remove => {
                if (node.kind == .dir) {
                    if (!node.listed) return job.beginListing(job.path);
                    var it = client.index.keyIterator();
                    while (it.next()) |key| {
                        if (Client.isBeneath(key.*, job.path)) return error.NotEmpty;
                    }
                }
                const meta = try std.json.Stringify.valueAlloc(a, .{ .trashed = true }, .{});
                errdefer a.free(meta);
                const url = try std.fmt.allocPrint(a, "{s}/{s}?fields=id", .{ api, node.id });
                job.phase = .request;
                try client.send(job, .PATCH, url, "application/json", meta, meta);
            },
        }
    }

    fn beginListing(job: *Job, dir: []const u8) Fs.Error!void {
        job.listing = dir;
        job.phase = .list_page;
        try job.requestPage();
    }

    fn requestPage(job: *Job) Fs.Error!void {
        const client = job.client;
        // Another op may have forgotten this directory while a page was in flight.
        const dir_node = client.index.get(job.listing) orelse return error.NotFound;
        const url = try buildListUrl(client.allocator, dir_node.id, job.page_token);
        try client.send(job, .GET, url, null, &.{}, null);
    }

    fn onResponse(ctx: ?*anyopaque, result: Fs.Error!http.Response) void {
        const job: *Job = @ptrCast(@alignCast(ctx.?));
        job.pending = null;
        job.onResponseInner(result) catch |err| job.finish(err);
    }

    fn onResponseInner(job: *Job, result: Fs.Error!http.Response) Fs.Error!void {
        const resp = try result;
        defer resp.deinit(job.client.allocator);
        switch (resp.status) {
            200...299 => {},
            else => {
                // Drive's error bodies say why (scope, disabled API, a wrong id); a bare
                // error code would not.
                std.log.warn("drive: {s} → HTTP {d}: {s}", .{ job.url, resp.status, resp.body[0..@min(resp.body.len, 400)] });
                return switch (resp.status) {
                    401 => error.Unauthorized,
                    403 => error.Forbidden,
                    404 => error.NotFound,
                    else => error.Http,
                };
            },
        }
        switch (job.phase) {
            .list_page => try job.onListPage(resp.body),
            .request => try job.onRequestDone(resp.body),
            .resolve, .done => unreachable,
        }
    }

    fn onListPage(job: *Job, body: []const u8) Fs.Error!void {
        const client = job.client;
        const a = client.allocator;
        const parsed = std.json.parseFromSlice(ListResponse, a, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJson,
        };
        defer parsed.deinit();

        const for_caller = job.op == .list and std.mem.eql(u8, job.listing, job.path);
        for (parsed.value.files) |file| {
            const child = try Fs.path.join(a, job.listing, file.name);
            // First-listed wins: Drive allows siblings with one name; a path cannot.
            if (client.index.contains(child)) {
                a.free(child);
                continue;
            }
            errdefer a.free(child);
            const id = try a.dupe(u8, file.id);
            errdefer a.free(id);
            try client.index.put(a, child, nodeFromFile(file, id));
            if (for_caller) {
                const name = try a.dupe(u8, file.name);
                errdefer a.free(name);
                try job.seen.append(a, name);
            }
        }

        if (job.page_token) |t| a.free(t);
        job.page_token = null;
        if (parsed.value.nextPageToken) |next| {
            if (next.len != 0) {
                job.page_token = try a.dupe(u8, next);
                return job.requestPage();
            }
        }

        (client.index.getPtr(job.listing) orelse return error.NotFound).listed = true;
        if (for_caller) return job.completeListing();
        // An ancestor listing on the way to something else: keep resolving.
        job.phase = .resolve;
        try job.stepInner();
    }

    fn completeListing(job: *Job) Fs.Error!void {
        const client = job.client;
        const o = job.op.list;
        var entries: std.ArrayList(Fs.Entry) = .empty;
        errdefer {
            for (entries.items) |e| o.allocator.free(e.name);
            entries.deinit(o.allocator);
        }
        for (job.seen.items) |name| {
            const child = try Fs.path.join(client.allocator, job.path, name);
            defer client.allocator.free(child);
            const node = client.index.get(child) orelse continue;
            const copy = try o.allocator.dupe(u8, name);
            errdefer o.allocator.free(copy);
            try entries.append(o.allocator, .{ .name = copy, .kind = node.kind, .size = node.size, .modified_ms = node.modified_ms });
        }
        job.complete(.{ .entries = try entries.toOwnedSlice(o.allocator) });
    }

    fn onRequestDone(job: *Job, body: []const u8) Fs.Error!void {
        const client = job.client;
        const a = client.allocator;
        switch (job.op) {
            .read => |o| {
                const mtime = if (client.index.get(job.path)) |n| n.modified_ms else 0;
                job.complete(.{ .read = .{ .bytes = try o.allocator.dupe(u8, body), .modified_ms = mtime } });
            },
            .write => |o| {
                if (o.opts.if_unmodified_ms != null and !job.write_checked) {
                    // The metadata check. Match → upload; else nothing is written.
                    const file = try parseFile(a, body);
                    defer file.deinit();
                    const live = parseRfc3339Ms(file.value.modifiedTime);
                    if (live != o.opts.if_unmodified_ms.?) {
                        if (client.index.getPtr(job.path)) |node| node.modified_ms = live;
                        return error.Conflict;
                    }
                    job.write_checked = true;
                    job.phase = .resolve;
                    job.resolving = "";
                    return job.stepInner();
                }
                if (parseFile(a, body)) |file| {
                    defer file.deinit();
                    if (client.index.getPtr(job.path)) |node| {
                        node.size = parseSize(file.value.size);
                        node.modified_ms = parseRfc3339Ms(file.value.modifiedTime);
                    }
                } else |_| {}
                job.complete(.ok);
            },
            .create => {
                const file = try parseFile(a, body);
                defer file.deinit();
                const id = try a.dupe(u8, file.value.id);
                errdefer a.free(id);
                const key = try a.dupe(u8, job.path);
                errdefer a.free(key);
                try client.index.put(a, key, nodeFromFile(file.value, id));
                job.complete(.ok);
            },
            .rename => {
                try job.moveIndex(job.path, job.path2);
                job.complete(.ok);
            },
            .remove => {
                client.drop(job.path);
                job.complete(.ok);
            },
            .changes => try job.onChangesPage(body),
            .list, .stat => unreachable,
        }
    }

    fn onChangesPage(job: *Job, body: []const u8) Fs.Error!void {
        const client = job.client;
        const a = client.allocator;
        const parsed = std.json.parseFromSlice(ChangesResponse, a, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJson,
        };
        defer parsed.deinit();
        const v = parsed.value;

        // The first poll: only a start token comes back.
        if (v.startPageToken) |t| {
            try client.setChangesToken(t);
            return job.completeChanges();
        }

        for (v.changes) |ch| {
            const id = ch.fileId orelse continue;
            if (client.pathOfId(id)) |known| {
                // Something the index holds: its own listing (a directory) or its parent's
                // (a file) is stale, and so is anything cached beneath it.
                try job.noteChanged(known);
                const parent = Fs.path.dirname(known);
                try job.noteChanged(parent);
                client.forget(known);
                continue;
            }
            // New to us: if it landed in a directory we have listed, that listing is stale.
            const file = ch.file orelse continue;
            for (file.parents) |pid| {
                if (client.pathOfId(pid)) |parent| {
                    try job.noteChanged(parent);
                    if (client.index.getPtr(parent)) |pn| pn.listed = false;
                }
            }
        }

        if (v.nextPageToken) |next| {
            try client.setChangesToken(next);
            return job.requestChanges();
        }
        if (v.newStartPageToken) |t| try client.setChangesToken(t);
        job.completeChanges();
    }

    fn noteChanged(job: *Job, path: []const u8) Fs.Error!void {
        for (job.changed.items) |p| {
            if (std.mem.eql(u8, p, path)) return;
        }
        const copy = try job.client.allocator.dupe(u8, path);
        errdefer job.client.allocator.free(copy);
        try job.changed.append(job.client.allocator, copy);
    }

    fn completeChanges(job: *Job) void {
        const o = job.op.changes;
        const out = o.allocator.alloc([]u8, job.changed.items.len) catch return job.finish(error.OutOfMemory);
        var n: usize = 0;
        errdefer Client.freeChanges(o.allocator, out[0..n]);
        for (job.changed.items) |p| {
            out[n] = o.allocator.dupe(u8, p) catch return job.finish(error.OutOfMemory);
            n += 1;
        }
        job.complete(.{ .changed = out });
    }

    /// Re-key everything at or beneath `from` under `to`.
    fn moveIndex(job: *Job, from: []const u8, to: []const u8) Allocator.Error!void {
        const client = job.client;
        const a = client.allocator;
        var moving: std.ArrayList([]const u8) = .empty;
        defer moving.deinit(a);
        var it = client.index.keyIterator();
        while (it.next()) |key| {
            if (std.mem.eql(u8, key.*, from) or Client.isBeneath(key.*, from)) try moving.append(a, key.*);
        }
        for (moving.items) |old_key| {
            const new_key = try std.mem.concat(a, u8, &.{ to, old_key[from.len..] });
            errdefer a.free(new_key);
            try client.index.put(a, new_key, client.index.get(old_key).?);
            const kv = client.index.fetchRemove(old_key).?;
            a.free(kv.key);
        }
    }
};

// -- Drive JSON -------------------------------------------------------------------------------

const File = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    mimeType: []const u8 = "",
    size: ?[]const u8 = null,
    modifiedTime: ?[]const u8 = null,
};

const ListResponse = struct {
    nextPageToken: ?[]const u8 = null,
    files: []const File = &.{},
};

const ChangedFile = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    mimeType: []const u8 = "",
    parents: []const []const u8 = &.{},
};

const Change = struct {
    fileId: ?[]const u8 = null,
    removed: bool = false,
    file: ?ChangedFile = null,
};

/// `changes.list`, or `changes/startPageToken` (only `startPageToken` set).
const ChangesResponse = struct {
    startPageToken: ?[]const u8 = null,
    newStartPageToken: ?[]const u8 = null,
    nextPageToken: ?[]const u8 = null,
    changes: []const Change = &.{},
};

fn parseFile(allocator: Allocator, body: []const u8) Fs.Error!std.json.Parsed(File) {
    return std.json.parseFromSlice(File, allocator, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
}

fn nodeFromFile(file: File, id: []u8) Node {
    const is_folder = std.mem.eql(u8, file.mimeType, folder_mime);
    return .{
        .id = id,
        .kind = if (is_folder) .dir else .file,
        .size = parseSize(file.size),
        .modified_ms = parseRfc3339Ms(file.modifiedTime),
        .google_app = !is_folder and std.mem.startsWith(u8, file.mimeType, google_apps_prefix),
    };
}

fn parseSize(size: ?[]const u8) u64 {
    const s = size orelse return 0;
    return std.fmt.parseInt(u64, s, 10) catch 0;
}

/// `2024-01-02T03:04:05.678Z` → ms since the epoch. Drive always emits UTC with a `Z`; anything
/// else parses as 0 rather than guessing an offset.
fn parseRfc3339Ms(text: ?[]const u8) i64 {
    const s = text orelse return 0;
    if (s.len < 20 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return 0;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return 0;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return 0;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return 0;
    const hour = std.fmt.parseInt(i64, s[11..13], 10) catch return 0;
    const minute = std.fmt.parseInt(i64, s[14..16], 10) catch return 0;
    const second = std.fmt.parseInt(i64, s[17..19], 10) catch return 0;
    var ms: i64 = 0;
    var i: usize = 19;
    if (i < s.len and s[i] == '.') {
        i += 1;
        var scale: i64 = 100;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            ms += @as(i64, s[i] - '0') * scale;
            scale = @divTrunc(scale, 10);
        }
    }
    if (i >= s.len or s[i] != 'Z') return 0;
    const days = daysFromCivil(year, month, day);
    return ((days * 24 + hour) * 60 + minute) * 60_000 + second * 1000 + ms;
}

/// Howard Hinnant's days-from-civil: days since 1970-01-01 for a proleptic Gregorian date.
fn daysFromCivil(y_in: i64, m: u8, d: u8) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn buildListUrl(allocator: Allocator, dir_id: []const u8, page_token: ?[]const u8) Allocator.Error![]u8 {
    var q: std.ArrayList(u8) = .empty;
    errdefer q.deinit(allocator);
    try q.appendSlice(allocator, api ++ "?q=");
    try appendQueryValue(allocator, &q, "'");
    try appendQueryValue(allocator, &q, dir_id);
    try appendQueryValue(allocator, &q, "' in parents and trashed=false");
    try q.appendSlice(allocator, "&fields=nextPageToken,files(" ++ file_fields ++ ")&pageSize=1000");
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

test "rfc3339 to ms" {
    try std.testing.expectEqual(@as(i64, 0), parseRfc3339Ms("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 1_704_164_645_678), parseRfc3339Ms("2024-01-02T03:04:05.678Z"));
    try std.testing.expectEqual(@as(i64, 0), parseRfc3339Ms("garbage"));
}

test {
    _ = @import("drive_test.zig");
}

