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
//! The index lives in `Tree.zig`: every directory knows its children and every id its path,
//! so nothing here walks the whole index. A listing reconciles the directory's children against
//! Drive's answer — what survives keeps its subtree, so a re-list never pulls paths out from
//! under other ops in flight beneath it.
//!
//! ## Freshness
//!
//! Once the change feed is running (`pollChanges` has a token) or a `prefetch` has walked a
//! tree, a listed directory answers `listDir` from the index: the feed is what keeps it true,
//! folding every outside edit into the index as it reports it (`onChangesPage`). Before that,
//! `listDir` refetches — the caller is a cache calling on a miss.
//!
//! ## Prefetch
//!
//! A crawl of a real drive is tens of thousands of folders, one `files.list` each, against a
//! per-minute quota. `prefetch(path)` walks the tree beneath `path` breadth-first instead, asking
//! for the children of `prefetch_batch` folders in one query (`'a' in parents or 'b' in
//! parents …`) with a few such queries in flight: requests fall by the batch size, and a crawler
//! arriving afterwards (a vault scan) finds every listing already answered. An op that needs a
//! directory the walk has queued waits for it — and moves it to the front — rather than listing
//! it a second time.
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

/// Every request says it understands shared drives. Without it Drive answers as if they did not
/// exist: a folder in one resolves by id (the metadata call is allowed) but listing its children
/// comes back *empty rather than failing*, which reads as an empty folder. `includeItemsFromAllDrives`
/// is only meaningful on a list, and Drive rejects it without `supportsAllDrives` beside it.
const all_drives = "&supportsAllDrives=true";
const all_drives_list = "&supportsAllDrives=true&includeItemsFromAllDrives=true";
const upload_api = "https://www.googleapis.com/upload/drive/v3/files";
const file_fields = "id,name,mimeType,size,modifiedTime";

pub const Tree = @import("Tree.zig");

/// Folders asked about in one prefetch query. Drive refuses a query past some complexity it
/// does not publish; fifty `in parents` clauses is well inside it, and a refusal halves the
/// batch (`batchDone`).
const prefetch_batch: usize = 50;
/// Prefetch queries in flight at once. Each is one request against the quota however many
/// folders it covers, so a few is plenty.
const prefetch_parallel: usize = 4;

/// One outside change the feed reported, as a path under the mount — what a folder watcher
/// would have said for the disk.
pub const Change = struct {
    pub const Kind = enum { created, modified, deleted, renamed };
    kind: Kind,
    is_dir: bool,
    /// Owned.
    path: []u8,
    /// The path it had before, for `.renamed`; empty otherwise. Owned.
    old_path: []u8 = &.{},
};

/// Drive charges a *query cost* per user per minute, and a recursive walk of a real drive
/// spends it in seconds — an indexer crawling a mounted vault is thousands of `files.list`
/// calls. Past the limit Drive answers 403 to everything, including the folder the user is
/// looking at, and a client that treats that as a permanent refusal turns a momentary
/// over-spend into a broken mount.
///
/// So: the refusal is read for what it is (Google says `rateLimitExceeded` /
/// `userRateLimitExceeded` / "Quota exceeded" in the body), every request in flight backs off
/// together, and each one retries a few times before giving up. Backing off *together* is the
/// point — sixteen crawlers each retrying on their own schedule is the same storm again.
const retry_limit: u8 = 5;
const retry_base_ms: i64 = 1_000;
const retry_ceiling_ms: i64 = 30_000;

pub const Client = struct {
    allocator: Allocator,
    transport: http.Transport,
    /// For the retry clock. The host's `dvui.io`, passed in at init.
    io: std.Io,
    /// Boot-clock ms before which no request is sent: set when Drive says the quota is spent.
    quiet_until_ms: i64 = 0,
    /// Refreshed by the host: the client reads it at request time, never copies it.
    access_token: []const u8,
    /// The Drive folder id the mount's `/` stands for. `"root"` is My Drive; a picked folder's
    /// id makes that folder the root. Not owned.
    root_id: []const u8 = "root",

    tree: Tree,
    /// Whether a listed directory may answer `listDir` from the index — true once something
    /// keeps the index honest (the change feed, or a prefetch that just read the tree).
    cache_listings: bool = false,
    walk: Prefetch = .{},
    /// `changes.list` page token: where the next poll continues from. Owned; null until the
    /// first poll fetched a start token.
    changes_token: ?[]u8 = null,
    /// Set when Drive answered 401 to any request: the token is dead before its clock said so.
    /// The owner reads and clears it (`takeUnauthorized`) to refresh at once.
    unauthorized: bool = false,
    jobs: std.AutoArrayHashMapUnmanaged(u64, *Job) = .empty,
    ready: http.Completions(*Job),
    /// The job whose callback `pump` is inside, so a cancel of it from that callback is a
    /// no-op rather than a use-after-free.
    delivering: ?*Job = null,
    initialised: bool = false,

    /// Whether a 401 arrived since the last call; cleared by the call.
    pub fn takeUnauthorized(self: *Client) bool {
        defer self.unauthorized = false;
        return self.unauthorized;
    }

    pub fn init(allocator: Allocator, io: std.Io, transport: http.Transport, access_token: []const u8, root_id: []const u8) Allocator.Error!Client {
        var tree = try Tree.init(allocator, root_id);
        errdefer tree.deinit();
        const self: Client = .{
            .allocator = allocator,
            .io = io,
            .transport = transport,
            .access_token = access_token,
            .root_id = root_id,
            .tree = tree,
            .ready = .init(allocator),
            .initialised = true,
        };
        return self;
    }

    pub fn deinit(self: *Client) void {
        if (self.changes_token) |t| self.allocator.free(t);
        for (self.jobs.values()) |job| job.destroy();
        self.jobs.deinit(self.allocator);
        self.ready.deinit();
        self.walk.deinit(self.allocator);
        self.tree.deinit();
    }

    pub fn fs(self: *Client) Fs.Fs {
        // `remote`: every listing here is an API call against a per-minute quota, which is what
        // a crawler needs to know before deciding how many to have in flight.
        return .{ .ptr = self, .vtable = &vtable, .remote = true };
    }

    /// What changed on Drive since the last poll, already folded into the index. Owned by the
    /// callback (`freeChanges`).
    pub const ChangesFn = *const fn (ctx: ?*anyopaque, result: Fs.Error![]Change) void;

    pub fn freeChanges(allocator: Allocator, changes: []Change) void {
        for (changes) |c| {
            allocator.free(c.path);
            allocator.free(c.old_path);
        }
        allocator.free(changes);
    }

    /// Ask Drive what changed since the last call. The first call only fetches a start token
    /// and answers with nothing — changes are relative to a moment, and that is the moment.
    /// Each change is applied to the index before it is reported (a rename moves the subtree, a
    /// deletion drops it, a new file under a listed folder is added), so a listing answered from
    /// the index afterwards is already right; the report is for everything *else* that caches —
    /// the host's file table, a vault's index. Only paths under a folder the index has seen are
    /// reported: nothing can be holding anything else.
    pub fn pollChanges(self: *Client, allocator: Allocator, cb: ChangesFn, ctx: ?*anyopaque) Fs.Error!Fs.Job {
        return self.start("/", null, .{ .changes = .{ .allocator = allocator, .cb = cb, .ctx = ctx } });
    }

    /// Drop what the index knows at and beneath `path`, so the next op re-asks Drive. The
    /// root is never dropped, only un-listed.
    pub fn forget(self: *Client, path: []const u8) void {
        if (Fs.path.isRoot(path)) {
            self.tree.clearChildren("/");
            return;
        }
        self.tree.remove(path);
        if (self.tree.get(Fs.path.dirname(path))) |parent| parent.listed = false;
    }

    /// The path the index holds for a Drive id, or null when it has never listed it.
    pub fn pathOfId(self: *Client, id: []const u8) ?[]const u8 {
        return self.tree.pathOfId(id);
    }

    /// The path (a copy, owned) of the first of `parents` the index holds as a directory.
    fn knownParent(self: *Client, parents: []const []const u8) Allocator.Error!?[]u8 {
        for (parents) |pid| {
            const p = self.tree.pathOfId(pid) orelse continue;
            const node = self.tree.get(p) orelse continue;
            if (node.kind == .dir) return try self.allocator.dupe(u8, p);
        }
        return null;
    }

    // -- prefetch ----------------------------------------------------------------------------

    /// Walk the tree beneath `path` in batched queries (see the file header). `path` must be a
    /// directory the index already holds — the mount root always is; for anything else, `stat`
    /// it first. Idempotent: a directory already walked, or being walked, is not asked twice.
    pub fn prefetch(self: *Client, path: []const u8) Fs.Error!void {
        const node = self.tree.get(path) orelse return error.NotFound;
        if (node.kind != .dir) return error.NotADirectory;
        self.cache_listings = true;
        try self.walk.queueDir(self.allocator, path, node.id);
        self.walkIssue();
    }

    /// Whether a prefetch still has work queued or in flight.
    pub fn prefetching(self: *const Client) bool {
        return self.walk.in_flight != 0 or self.walk.head < self.walk.queue.items.len;
    }

    /// Start batch queries while there is room.
    fn walkIssue(self: *Client) void {
        const a = self.allocator;
        while (self.walk.in_flight < prefetch_parallel) {
            var dirs: std.ArrayList(BatchDir) = .empty;
            self.walkTake(&dirs) catch {
                for (dirs.items) |d| d.free(a);
                dirs.deinit(a);
                return;
            };
            if (dirs.items.len == 0) {
                dirs.deinit(a);
                if (!self.prefetching()) {
                    self.walk.reset(a);
                    self.walk.need_wake = true;
                }
                break;
            }
            const owned = dirs.toOwnedSlice(a) catch {
                for (dirs.items) |d| d.free(a);
                dirs.deinit(a);
                return;
            };
            self.walk.in_flight += 1;
            _ = self.start("/", null, .{ .batch = .{ .dirs = owned } }) catch |err| {
                // `start` frees nothing of the op on failure; the directories fall back to
                // being listed one at a time when something asks.
                std.log.warn("drive: prefetch batch could not start: {t}", .{err});
                self.walk.in_flight -= 1;
                for (owned) |d| {
                    self.walk.markDone(d.path);
                    d.free(a);
                }
                a.free(owned);
                return;
            };
        }
        // Directories the walk settled without asking (listed another way, or gone): whatever
        // was parked on them can go.
        if (self.walk.need_wake) self.wakeWaiting();
    }

    /// The next batch: directories something is waiting on first, then breadth-first. One
    /// already listed another way is not asked again — its subfolders are queued from the index.
    fn walkTake(self: *Client, out: *std.ArrayList(BatchDir)) Allocator.Error!void {
        const a = self.allocator;
        const batch = self.walk.batch;
        while (out.items.len < batch) {
            const path = if (self.walk.urgent.pop()) |u| u else if (self.walk.head < self.walk.queue.items.len) blk: {
                self.walk.head += 1;
                break :blk self.walk.queue.items[self.walk.head - 1];
            } else break;
            const d = self.walk.dirs.getPtr(path) orelse continue;
            if (d.state != .queued) continue;
            const node = self.tree.get(path) orelse {
                d.state = .done;
                self.walk.need_wake = true;
                continue;
            };
            if (node.kind != .dir or !std.mem.eql(u8, node.id, d.id)) {
                d.state = .done;
                self.walk.need_wake = true;
                continue;
            }
            if (node.listed) {
                d.state = .done;
                self.walk.need_wake = true;
                try self.walkQueueChildren(path);
                continue;
            }
            d.state = .listing;
            const path_copy = try a.dupe(u8, path);
            errdefer a.free(path_copy);
            const id_copy = try a.dupe(u8, d.id);
            errdefer a.free(id_copy);
            try out.append(a, .{ .path = path_copy, .id = id_copy });
        }
    }

    fn walkQueueChildren(self: *Client, dir: []const u8) Allocator.Error!void {
        const node = self.tree.get(dir) orelse return;
        for (node.children.keys()) |child| {
            const c = self.tree.get(child) orelse continue;
            if (c.kind == .dir) try self.walk.queueDir(self.allocator, child, c.id);
        }
    }

    /// A batch has answered (or failed). Apply what it listed, queue what it found, and wake
    /// whatever was waiting on those directories.
    fn batchDone(self: *Client, job: *Job, result: Fs.Error!void) void {
        const a = self.allocator;
        self.walk.in_flight -= 1;
        const dirs = job.op.batch.dirs;
        if (result) |_| {
            for (dirs) |*d| {
                self.walk.markDone(d.path);
                const node = self.tree.get(d.path) orelse continue;
                if (node.kind != .dir or !std.mem.eql(u8, node.id, d.id)) continue;
                self.tree.setListing(d.path, d.items.items, null) catch continue;
                self.walkQueueChildren(d.path) catch {};
            }
        } else |err| {
            if (dirs.len > 1 and err == error.Http) {
                // Most likely "the query is too complex": ask about fewer at once, and put these
                // back to be asked again.
                self.walk.batch = @max(1, dirs.len / 2);
                for (dirs) |d| {
                    if (self.walk.dirs.getPtr(d.path)) |w| {
                        w.state = .queued;
                        self.walk.urgent.append(a, self.walk.dirs.getKey(d.path).?) catch {
                            w.state = .done;
                        };
                    }
                }
            } else {
                std.log.warn("drive: prefetch of {d} folder(s) failed ({t}); they will be listed when asked for", .{ dirs.len, err });
                for (dirs) |d| self.walk.markDone(d.path);
            }
        }
        self.wakeWaiting();
        self.walkIssue();
    }

    /// Ops parked on a directory the walk had queued: re-run the ones whose directory is done.
    /// Collected first: a job re-run can park again, which starts a batch, which adds to `jobs`.
    fn wakeWaiting(self: *Client) void {
        self.walk.need_wake = false;
        var ready_now: std.ArrayList(*Job) = .empty;
        defer ready_now.deinit(self.allocator);
        for (self.jobs.values()) |job| {
            if (job.phase != .await_prefetch) continue;
            if (self.walk.pending(job.waiting)) continue;
            ready_now.append(self.allocator, job) catch break;
        }
        for (ready_now.items) |job| {
            job.phase = .resolve;
            job.step();
        }
    }

    /// When the walk has `dir` queued or in flight, park `job` on it (bumping it to the front)
    /// and say so; otherwise the job lists it itself.
    fn waitForWalk(self: *Client, job: *Job, dir: []const u8) bool {
        const d = self.walk.dirs.getPtr(dir) orelse return false;
        switch (d.state) {
            .done => return false,
            .queued => self.walk.urgent.append(self.allocator, self.walk.dirs.getKey(dir).?) catch return false,
            .listing => {},
        }
        job.phase = .await_prefetch;
        job.waiting = dir;
        self.walkIssue();
        return true;
    }

    fn setChangesToken(self: *Client, token: []const u8) Allocator.Error!void {
        const copy = try self.allocator.dupe(u8, token);
        if (self.changes_token) |t| self.allocator.free(t);
        self.changes_token = copy;
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
        self.retryWaiting();
        self.ready.drain(self, deliverOne);
    }

    fn nowMs(self: *Client) i64 {
        return @intCast(@divTrunc(std.Io.Clock.boot.now(self.io).nanoseconds, std.time.ns_per_ms));
    }

    /// Re-issue the requests whose backoff has run out. Walked rather than queued: a job's whole
    /// request is still on it (url, body, phase), so a retry is the same send again.
    fn retryWaiting(self: *Client) void {
        const now = self.nowMs();
        if (now < self.quiet_until_ms) return;
        for (self.jobs.values()) |job| {
            if (job.retry_at_ms == 0 or now < job.retry_at_ms) continue;
            job.retry_at_ms = 0;
            job.resend() catch |err| job.finish(err);
        }
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
        job.retry_method = method;
        job.retry_content_type = content_type;

        // Quiet period: hold this one rather than spending a quota that is already spent. It
        // goes out with everything else when the wait is over (`retryWaiting`).
        const now = self.nowMs();
        if (now < self.quiet_until_ms) {
            job.retry_at_ms = self.quiet_until_ms;
            return;
        }
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

/// A prefetch's bookkeeping: every directory it has queued, and in what order.
const Prefetch = struct {
    /// Path (owned) → id (owned) and how far it got. Kept until the walk is over, so the
    /// slices in `queue` and `urgent` stay valid.
    dirs: std.StringHashMapUnmanaged(Dir) = .empty,
    /// Breadth-first order; slices of `dirs` keys. `head` is the next to take.
    queue: std.ArrayListUnmanaged([]const u8) = .empty,
    head: usize = 0,
    /// Asked for by a waiting op; taken first. Slices of `dirs` keys.
    urgent: std.ArrayListUnmanaged([]const u8) = .empty,
    in_flight: usize = 0,
    batch: usize = prefetch_batch,
    /// A directory was settled outside `batchDone`; parked ops need a look.
    need_wake: bool = false,

    const Dir = struct {
        id: []u8,
        state: enum { queued, listing, done } = .queued,
    };

    fn queueDir(self: *Prefetch, a: Allocator, path: []const u8, id: []const u8) Allocator.Error!void {
        if (self.dirs.contains(path)) return;
        const key = try a.dupe(u8, path);
        errdefer a.free(key);
        const id_copy = try a.dupe(u8, id);
        errdefer a.free(id_copy);
        try self.queue.ensureUnusedCapacity(a, 1);
        try self.dirs.put(a, key, .{ .id = id_copy });
        self.queue.appendAssumeCapacity(key);
    }

    fn markDone(self: *Prefetch, path: []const u8) void {
        if (self.dirs.getPtr(path)) |d| d.state = .done;
    }

    /// Queued or in flight — something waiting on it should keep waiting.
    fn pending(self: *const Prefetch, path: []const u8) bool {
        const d = self.dirs.get(path) orelse return false;
        return d.state != .done;
    }

    /// The walk is over: let its bookkeeping go (the index keeps everything it learned).
    fn reset(self: *Prefetch, a: Allocator) void {
        self.deinit(a);
        self.* = .{};
    }

    fn deinit(self: *Prefetch, a: Allocator) void {
        var it = self.dirs.iterator();
        while (it.next()) |kv| {
            a.free(kv.key_ptr.*);
            a.free(kv.value_ptr.id);
        }
        self.dirs.deinit(a);
        self.queue.deinit(a);
        self.urgent.deinit(a);
    }
};

/// One directory in a prefetch query, and what came back for it. Strings owned (client
/// allocator); `items` borrow from the job's arena.
const BatchDir = struct {
    path: []u8,
    id: []u8,
    items: std.ArrayListUnmanaged(Tree.Listed) = .empty,

    fn free(d: BatchDir, a: Allocator) void {
        a.free(d.path);
        a.free(d.id);
    }
};

/// One in-flight op. Owned by the client from `start` until delivered or cancelled.
/// Whether this refusal is "you are going too fast" rather than "no". Google returns 429 for
/// some of them and 403 for others, with the reason in the body — the status alone cannot tell
/// a spent quota from a missing permission, and treating the two the same is how a mount breaks
/// for the rest of the session.
fn isRateLimited(status: u16, body: []const u8) bool {
    if (status == 429) return true;
    if (status != 403) return false;
    return std.mem.indexOf(u8, body, "rateLimitExceeded") != null or
        std.mem.indexOf(u8, body, "userRateLimitExceeded") != null or
        std.mem.indexOf(u8, body, "Quota exceeded") != null or
        std.mem.indexOf(u8, body, "quotaExceeded") != null;
}

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
    /// A listing's children across its pages, in Drive order; strings in `arena`.
    listed: std.ArrayListUnmanaged(Tree.Listed) = .empty,
    /// Page data that must outlive one page's JSON: listed names and ids.
    arena: ?std.heap.ArenaAllocator = null,
    /// The directory an `await_prefetch` job is parked on (a slice of `path` or `resolving`).
    waiting: []const u8 = "",
    /// A changes poll's changes, accumulated across its pages. Owned (client allocator).
    changed: std.ArrayList(Change) = .empty,
    /// A conditional write's `modifiedTime` check has come back and matched.
    write_checked: bool = false,

    pending: ?http.Job = null,
    /// A rate-limited request waiting to be sent again: the boot-clock ms to send it at, and how
    /// many times it has already been refused. Zero means nothing is waiting.
    retry_at_ms: i64 = 0,
    attempts: u8 = 0,
    /// What `resend` repeats. The url and body are still on the job; this is the rest.
    retry_method: http.Method = .GET,
    retry_content_type: ?[]const u8 = null,
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
        /// Parked until a prefetch has listed `waiting`.
        await_prefetch,
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
        /// A prefetch query: the children of every folder in `dirs` (owned), paged. No caller;
        /// it reports to `Client.batchDone`.
        batch: struct { dirs: []BatchDir },
    };

    /// Set exactly once by `finish`; consumed by `deliver`.
    const Result = union(enum) {
        pending,
        err: Fs.Error,
        entries: []Fs.Entry,
        stat: Fs.Stat,
        read: Fs.Read,
        changed: []Change,
        ok,
    };

    fn destroy(job: *Job) void {
        const a = job.client.allocator;
        if (job.pending) |p| job.client.transport.cancel(p);
        job.freeRequest();
        if (job.page_token) |t| a.free(t);
        job.listed.deinit(a);
        if (job.arena) |*ar| ar.deinit();
        switch (job.result) {
            .entries => |entries| Fs.freeEntries(job.op.list.allocator, entries),
            .read => |r| job.op.read.allocator.free(r.bytes),
            .changed => |changes| Client.freeChanges(job.op.changes.allocator, changes),
            else => {},
        }
        if (job.op == .batch) {
            for (job.op.batch.dirs) |d| d.free(a);
            a.free(job.op.batch.dirs);
        }
        for (job.changed.items) |c| {
            a.free(c.path);
            a.free(c.old_path);
        }
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

    /// Wait, then say it again. Gives up after `retry_limit` tries: a quota that has not come
    /// back in half a minute of doubling is not about to, and an op that never answers is worse
    /// than one that fails.
    fn backOff(job: *Job) Fs.Error!void {
        const client = job.client;
        job.attempts += 1;
        if (job.attempts >= retry_limit) {
            std.log.warn("drive: gave up after {d} rate-limited tries: {s}", .{ job.attempts, job.url });
            return error.Http;
        }
        // 1s, 2s, 4s, … capped. No jitter: every job shares one `quiet_until_ms`, so they are
        // already spread by whatever order `retryWaiting` walks them in rather than by luck.
        const shift: u6 = @intCast(@min(job.attempts - 1, 5));
        const wait = @min(retry_base_ms << shift, retry_ceiling_ms);
        const until = client.nowMs() + wait;
        if (until > client.quiet_until_ms) client.quiet_until_ms = until;
        job.retry_at_ms = client.quiet_until_ms;
        if (job.attempts == 1) {
            std.log.warn("drive: over Drive's per-minute quota; holding requests for {d}ms", .{wait});
        }
    }

    /// Send this job's current request again, after a backoff. Everything it needs is still on
    /// the job — `freeRequest` is what would have cleared it, and a waiting job has not been
    /// through it.
    fn resend(job: *Job) Fs.Error!void {
        const self = job.client;
        job.auth = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.access_token});
        job.header_count = 1;
        job.headers[0] = .{ .name = "Authorization", .value = job.auth };
        if (job.retry_content_type) |ct| {
            job.headers[1] = .{ .name = "Content-Type", .value = ct };
            job.header_count = 2;
        }
        job.pending = try self.transport.request(self.allocator, .{
            .method = job.retry_method,
            .url = job.url,
            .headers = job.headers[0..job.header_count],
            .body = job.body,
        }, Job.onResponse, job);
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
            .batch => job.client.batchDone(job, switch (result) {
                .ok => {},
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
                    if (client.tree.contains(child_path)) {
                        dir = child_path;
                        continue;
                    }
                    const parent = client.tree.get(dir) orelse return error.NotFound;
                    if (parent.kind != .dir) return error.NotADirectory;
                    if (parent.listed) return error.NotFound;
                    if (client.waitForWalk(job, dir)) return;
                    return job.beginListing(dir);
                }
                try job.resolved();
            },
            .list_page, .request, .done, .await_prefetch => {},
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
            const url = try a.dupe(u8, "https://www.googleapis.com/drive/v3/changes/startPageToken?supportsAllDrives=true");
            return client.send(job, .GET, url, null, &.{}, null);
        };
        var url: std.ArrayList(u8) = .empty;
        errdefer url.deinit(a);
        try url.appendSlice(a, "https://www.googleapis.com/drive/v3/changes?pageSize=1000" ++ all_drives_list ++ "&fields=newStartPageToken,nextPageToken,changes(fileId,removed,file(id,name,mimeType,size,modifiedTime,parents,trashed))&pageToken=");
        try appendQueryValue(a, &url, token);
        try client.send(job, .GET, try url.toOwnedSlice(a), null, &.{}, null);
    }

    /// `resolving` is fully in the index. Decide what comes next.
    fn resolved(job: *Job) Fs.Error!void {
        const client = job.client;
        const a = client.allocator;
        const node = client.tree.get(job.resolving) orelse return error.NotFound;
        switch (job.op) {
            .changes => try job.requestChanges(),
            .batch => {
                job.phase = .list_page;
                try job.requestBatchPage();
            },
            .list => {
                if (node.kind != .dir) return error.NotADirectory;
                // Answered from the index while something keeps it honest (see "Freshness");
                // otherwise refetched — the caller is a cache and this is its miss path. What the
                // index holds beneath it stays until the listing says which children are gone
                // (`Tree.setListing`), so a re-list never pulls paths out from under other ops.
                if (node.listed and client.cache_listings) return job.completeFromIndex();
                if (client.waitForWalk(job, job.path)) return;
                try job.beginListing(job.path);
            },
            .stat => job.complete(.{ .stat = .{ .kind = node.kind, .size = node.size, .modified_ms = node.modified_ms } }),
            .read => {
                if (node.kind != .file) return error.NotAFile;
                if (node.google_app) return error.NotBinary;
                const url = try std.fmt.allocPrint(a, "{s}/{s}?alt=media" ++ all_drives, .{ api, node.id });
                job.phase = .request;
                try client.send(job, .GET, url, null, &.{}, null);
            },
            .write => |o| {
                if (node.kind != .file) return error.NotAFile;
                if (node.google_app) return error.NotBinary;
                if (o.opts.if_unmodified_ms != null and !job.write_checked) {
                    // The index's modified time may be seconds stale; ask Drive for the live
                    // one before uploading over someone else's edit.
                    const url = try std.fmt.allocPrint(a, "{s}/{s}?fields=modifiedTime" ++ all_drives, .{ api, node.id });
                    job.phase = .request;
                    return client.send(job, .GET, url, null, &.{}, null);
                }
                const url = try std.fmt.allocPrint(a, "{s}/{s}?uploadType=media&fields={s}" ++ all_drives, .{ upload_api, node.id, file_fields });
                job.phase = .request;
                try client.send(job, .PATCH, url, "application/octet-stream", o.bytes, null);
            },
            .create => |o| {
                // `resolving` is the parent; its listing is complete only once `listed`.
                if (node.kind != .dir) return error.NotADirectory;
                if (!node.listed) return job.beginListing(job.resolving);
                if (client.tree.contains(job.path)) return error.Exists;
                const meta = try std.json.Stringify.valueAlloc(a, .{
                    .name = Fs.path.basename(job.path),
                    .parents = [_][]const u8{node.id},
                    .mimeType = if (o.kind == .dir) @as(?[]const u8, folder_mime) else null,
                }, .{ .emit_null_optional_fields = false });
                errdefer a.free(meta);
                const url = try std.fmt.allocPrint(a, "{s}?fields={s}" ++ all_drives, .{ api, file_fields });
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
                if (client.tree.contains(job.path2)) return error.Exists;
                const src = client.tree.get(job.path) orelse return error.NotFound;
                const old_parent = client.tree.get(Fs.path.dirname(job.path)) orelse return error.NotFound;
                const meta = try std.json.Stringify.valueAlloc(a, .{ .name = Fs.path.basename(job.path2) }, .{});
                errdefer a.free(meta);
                // A plain rename keeps its parent; Google rejects add == remove.
                const url = if (std.mem.eql(u8, node.id, old_parent.id))
                    try std.fmt.allocPrint(a, "{s}/{s}?fields={s}" ++ all_drives, .{ api, src.id, file_fields })
                else
                    try std.fmt.allocPrint(a, "{s}/{s}?addParents={s}&removeParents={s}&fields={s}" ++ all_drives, .{ api, src.id, node.id, old_parent.id, file_fields });
                job.phase = .request;
                try client.send(job, .PATCH, url, "application/json", meta, meta);
            },
            .remove => {
                if (node.kind == .dir) {
                    if (!node.listed) return job.beginListing(job.path);
                    if (node.children.count() != 0) return error.NotEmpty;
                }
                const meta = try std.json.Stringify.valueAlloc(a, .{ .trashed = true }, .{});
                errdefer a.free(meta);
                const url = try std.fmt.allocPrint(a, "{s}/{s}?fields=id" ++ all_drives, .{ api, node.id });
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
        const dir_node = client.tree.get(job.listing) orelse return error.NotFound;
        const url = try buildListUrl(client.allocator, dir_node.id, job.page_token);
        try client.send(job, .GET, url, null, &.{}, null);
    }

    fn requestBatchPage(job: *Job) Fs.Error!void {
        const client = job.client;
        const url = try buildBatchUrl(client.allocator, job.op.batch.dirs, job.page_token);
        try client.send(job, .GET, url, null, &.{}, null);
    }

    fn pageArena(job: *Job) Allocator {
        if (job.arena == null) job.arena = std.heap.ArenaAllocator.init(job.client.allocator);
        return job.arena.?.allocator();
    }

    /// The listing's answer, from the index.
    fn completeFromIndex(job: *Job) Fs.Error!void {
        const client = job.client;
        const o = job.op.list;
        const node = client.tree.get(job.path) orelse return error.NotFound;
        var entries: std.ArrayList(Fs.Entry) = .empty;
        errdefer {
            for (entries.items) |e| o.allocator.free(e.name);
            entries.deinit(o.allocator);
        }
        try entries.ensureTotalCapacity(o.allocator, node.children.count());
        for (node.children.keys()) |child| {
            const c = client.tree.get(child) orelse continue;
            const name = try o.allocator.dupe(u8, Fs.path.basename(child));
            entries.appendAssumeCapacity(.{ .name = name, .kind = c.kind, .size = c.size, .modified_ms = c.modified_ms });
        }
        job.complete(.{ .entries = try entries.toOwnedSlice(o.allocator) });
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
                // Spent quota, not a refusal: Drive says so in the body, and the same request a
                // moment later succeeds. Everything in flight goes quiet together — one crawler
                // retrying while fifteen others keep firing is the storm that spent it.
                if (isRateLimited(resp.status, resp.body)) return job.backOff();

                // Drive's error bodies say why (scope, disabled API, a wrong id); a bare
                // error code would not.
                std.log.warn("drive: {s} → HTTP {d}: {s}", .{ job.url, resp.status, resp.body[0..@min(resp.body.len, 400)] });
                if (resp.status == 401) job.client.unauthorized = true;
                return switch (resp.status) {
                    401 => error.Unauthorized,
                    403 => error.Forbidden,
                    404 => error.NotFound,
                    else => error.Http,
                };
            },
        }
        switch (job.phase) {
            .list_page => if (job.op == .batch) try job.onBatchPage(resp.body) else try job.onListPage(resp.body),
            .request => try job.onRequestDone(resp.body),
            .resolve, .done, .await_prefetch => unreachable,
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

        // Accumulated, not applied page by page: which children are *gone* is only known once
        // the last page is in.
        const arena = job.pageArena();
        try job.listed.ensureUnusedCapacity(a, parsed.value.files.len);
        for (parsed.value.files) |file| job.listed.appendAssumeCapacity(try listedFromFile(arena, file));

        if (job.page_token) |t| a.free(t);
        job.page_token = null;
        if (parsed.value.nextPageToken) |next| {
            if (next.len != 0) {
                job.page_token = try a.dupe(u8, next);
                return job.requestPage();
            }
        }

        const for_caller = job.op == .list and std.mem.eql(u8, job.listing, job.path);
        if (!for_caller) {
            // An ancestor listed on the way to something else: record it, keep resolving.
            try client.tree.setListing(job.listing, job.listed.items, null);
            job.listed.clearRetainingCapacity();
            job.phase = .resolve;
            return job.stepInner();
        }

        var took: std.ArrayList(usize) = .empty;
        defer took.deinit(a);
        try client.tree.setListing(job.listing, job.listed.items, &took);
        const o = job.op.list;
        var entries: std.ArrayList(Fs.Entry) = .empty;
        errdefer {
            for (entries.items) |e| o.allocator.free(e.name);
            entries.deinit(o.allocator);
        }
        try entries.ensureTotalCapacity(o.allocator, took.items.len);
        for (took.items) |i| {
            const l = job.listed.items[i];
            entries.appendAssumeCapacity(.{ .name = try o.allocator.dupe(u8, l.name), .kind = l.kind, .size = l.size, .modified_ms = l.modified_ms });
        }
        job.complete(.{ .entries = try entries.toOwnedSlice(o.allocator) });
    }

    /// One page of a prefetch query: route each child to the folder(s) it is in.
    fn onBatchPage(job: *Job, body: []const u8) Fs.Error!void {
        const client = job.client;
        const a = client.allocator;
        const parsed = std.json.parseFromSlice(ListResponse, a, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJson,
        };
        defer parsed.deinit();
        const arena = job.pageArena();
        const dirs = job.op.batch.dirs;
        for (parsed.value.files) |file| {
            var copy: ?Tree.Listed = null;
            for (file.parents) |pid| {
                for (dirs) |*d| {
                    if (!std.mem.eql(u8, d.id, pid)) continue;
                    if (copy == null) copy = try listedFromFile(arena, file);
                    try d.items.append(arena, copy.?);
                }
            }
        }
        if (job.page_token) |t| a.free(t);
        job.page_token = null;
        if (parsed.value.nextPageToken) |next| {
            if (next.len != 0) {
                job.page_token = try a.dupe(u8, next);
                return job.requestBatchPage();
            }
        }
        job.complete(.ok);
    }

    fn onRequestDone(job: *Job, body: []const u8) Fs.Error!void {
        const client = job.client;
        const a = client.allocator;
        switch (job.op) {
            .read => |o| {
                const mtime = if (client.tree.get(job.path)) |n| n.modified_ms else 0;
                job.complete(.{ .read = .{ .bytes = try o.allocator.dupe(u8, body), .modified_ms = mtime } });
            },
            .write => |o| {
                if (o.opts.if_unmodified_ms != null and !job.write_checked) {
                    // The metadata check. Match → upload; else nothing is written.
                    const file = try parseFile(a, body);
                    defer file.deinit();
                    const live = parseRfc3339Ms(file.value.modifiedTime);
                    if (live != o.opts.if_unmodified_ms.?) {
                        if (client.tree.get(job.path)) |node| node.modified_ms = live;
                        return error.Conflict;
                    }
                    job.write_checked = true;
                    job.phase = .resolve;
                    job.resolving = "";
                    return job.stepInner();
                }
                if (parseFile(a, body)) |file| {
                    defer file.deinit();
                    if (client.tree.get(job.path)) |node| {
                        node.size = parseSize(file.value.size);
                        node.modified_ms = parseRfc3339Ms(file.value.modifiedTime);
                    }
                } else |_| {}
                job.complete(.ok);
            },
            .create => {
                const file = try parseFile(a, body);
                defer file.deinit();
                if (!client.tree.contains(job.path)) _ = try client.tree.put(job.path, try listedFromFile(null, file.value));
                job.complete(.ok);
            },
            .rename => {
                try client.tree.rename(job.path, job.path2);
                job.complete(.ok);
            },
            .remove => {
                client.tree.remove(job.path);
                job.complete(.ok);
            },
            .changes => try job.onChangesPage(body),
            .list, .stat, .batch => unreachable,
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

        // The first poll: only a start token comes back. From here the feed keeps the index
        // honest, so listed directories can answer from it (see "Freshness").
        if (v.startPageToken) |t| {
            try client.setChangesToken(t);
            client.cache_listings = true;
            return job.completeChanges();
        }

        for (v.changes) |ch| try job.applyChange(ch);

        if (v.nextPageToken) |next| {
            try client.setChangesToken(next);
            return job.requestChanges();
        }
        if (v.newStartPageToken) |t| try client.setChangesToken(t);
        job.completeChanges();
    }

    /// Fold one reported change into the index, and note it for the caller. The index is what
    /// `listDir` answers from once the feed is running, so this is what keeps it true.
    fn applyChange(job: *Job, ch: ChangeJson) Fs.Error!void {
        const client = job.client;
        const a = client.allocator;
        const tree = &client.tree;
        const id = ch.fileId orelse return;
        const gone = ch.removed or (if (ch.file) |f| f.trashed else false);

        if (tree.pathOfId(id)) |known_in_tree| {
            // Copied: every branch below can remove or re-key the path it names.
            const known = try a.dupe(u8, known_in_tree);
            defer a.free(known);
            const node = tree.get(known) orelse return;
            const is_dir = node.kind == .dir;
            if (gone) {
                tree.remove(known);
                return job.noteChange(.deleted, is_dir, known, "");
            }
            const file = ch.file orelse {
                if (!is_dir) try job.noteChange(.modified, false, known, "");
                return;
            };
            // Where it is now: under the first parent the index knows. None means it moved
            // somewhere this mount does not reach, which from here is a deletion.
            const parent = (try client.knownParent(file.parents)) orelse {
                tree.remove(known);
                return job.noteChange(.deleted, is_dir, known, "");
            };
            defer a.free(parent);
            const now = try Fs.path.join(a, parent, file.name);
            defer a.free(now);
            const fresh = try listedFromChanged(file);
            if (std.mem.eql(u8, now, known)) {
                // Same place: its contents (a file) or nothing we track (a folder's own metadata).
                if (is_dir) return;
                if (node.size == fresh.size and node.modified_ms == fresh.modified_ms) return;
                node.size = fresh.size;
                node.modified_ms = fresh.modified_ms;
                return job.noteChange(.modified, false, known, "");
            }
            if (tree.contains(now)) {
                // Moved onto a name the index already holds: neither listing can be trusted.
                tree.remove(known);
                try job.noteChange(.deleted, is_dir, known, "");
                if (tree.get(parent)) |p| p.listed = false;
                return job.noteChange(.created, is_dir, now, "");
            }
            try tree.rename(known, now);
            if (tree.get(now)) |moved| {
                moved.size = fresh.size;
                moved.modified_ms = fresh.modified_ms;
            }
            return job.noteChange(.renamed, is_dir, now, known);
        }

        // New to the index: added under each listed parent the index knows, so the listing
        // stays complete; reported either way, since a cache elsewhere may hold that folder.
        if (gone) return;
        const file = ch.file orelse return;
        const fresh = try listedFromChanged(file);
        for (file.parents) |pid| {
            const parent_in_tree = tree.pathOfId(pid) orelse continue;
            const parent = try a.dupe(u8, parent_in_tree);
            defer a.free(parent);
            const pnode = tree.get(parent) orelse continue;
            if (pnode.kind != .dir) continue;
            const path = try Fs.path.join(a, parent, file.name);
            defer a.free(path);
            if (pnode.listed and !tree.contains(path)) _ = try tree.put(path, fresh);
            try job.noteChange(.created, fresh.kind == .dir, path, "");
        }
    }

    fn noteChange(job: *Job, kind: Change.Kind, is_dir: bool, path: []const u8, old_path: []const u8) Fs.Error!void {
        const a = job.client.allocator;
        const p = try a.dupe(u8, path);
        errdefer a.free(p);
        const o = try a.dupe(u8, old_path);
        errdefer a.free(o);
        try job.changed.append(a, .{ .kind = kind, .is_dir = is_dir, .path = p, .old_path = o });
    }

    fn completeChanges(job: *Job) void {
        const o = job.op.changes;
        const out = o.allocator.alloc(Change, job.changed.items.len) catch return job.finish(error.OutOfMemory);
        var n: usize = 0;
        for (job.changed.items) |c| {
            const p = o.allocator.dupe(u8, c.path) catch break;
            const op = o.allocator.dupe(u8, c.old_path) catch {
                o.allocator.free(p);
                break;
            };
            out[n] = .{ .kind = c.kind, .is_dir = c.is_dir, .path = p, .old_path = op };
            n += 1;
        }
        if (n != out.len) {
            Client.freeChanges(o.allocator, out[0..n]);
            return job.finish(error.OutOfMemory);
        }
        job.complete(.{ .changed = out });
    }
};

// -- Drive JSON -------------------------------------------------------------------------------

const File = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    mimeType: []const u8 = "",
    size: ?[]const u8 = null,
    modifiedTime: ?[]const u8 = null,
    /// Only asked for by a prefetch query, which has to route each child to its folder.
    parents: []const []const u8 = &.{},
};

const ListResponse = struct {
    nextPageToken: ?[]const u8 = null,
    files: []const File = &.{},
};

const ChangedFile = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    mimeType: []const u8 = "",
    size: ?[]const u8 = null,
    modifiedTime: ?[]const u8 = null,
    parents: []const []const u8 = &.{},
    trashed: bool = false,
};

const ChangeJson = struct {
    fileId: ?[]const u8 = null,
    removed: bool = false,
    file: ?ChangedFile = null,
};

/// `changes.list`, or `changes/startPageToken` (only `startPageToken` set).
const ChangesResponse = struct {
    startPageToken: ?[]const u8 = null,
    newStartPageToken: ?[]const u8 = null,
    nextPageToken: ?[]const u8 = null,
    changes: []const ChangeJson = &.{},
};

fn parseFile(allocator: Allocator, body: []const u8) Fs.Error!std.json.Parsed(File) {
    return std.json.parseFromSlice(File, allocator, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
}

/// What a listing says about `file`, with its strings copied into `arena` — or borrowed from
/// the JSON when `arena` is null, for a caller that hands it straight to `Tree.put` (which
/// copies what it keeps).
fn listedFromFile(arena: ?Allocator, file: File) Allocator.Error!Tree.Listed {
    const is_folder = std.mem.eql(u8, file.mimeType, folder_mime);
    return .{
        .name = if (arena) |ar| try ar.dupe(u8, file.name) else file.name,
        .id = if (arena) |ar| try ar.dupe(u8, file.id) else file.id,
        .kind = if (is_folder) .dir else .file,
        .size = parseSize(file.size),
        .modified_ms = parseRfc3339Ms(file.modifiedTime),
        .google_app = !is_folder and std.mem.startsWith(u8, file.mimeType, google_apps_prefix),
    };
}

fn listedFromChanged(file: ChangedFile) Allocator.Error!Tree.Listed {
    return listedFromFile(null, .{
        .id = file.id,
        .name = file.name,
        .mimeType = file.mimeType,
        .size = file.size,
        .modifiedTime = file.modifiedTime,
    });
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
    try q.appendSlice(allocator, "&fields=nextPageToken,files(" ++ file_fields ++ ")&pageSize=1000" ++ all_drives_list);
    if (page_token) |token| {
        try q.appendSlice(allocator, "&pageToken=");
        try appendQueryValue(allocator, &q, token);
    }
    return try q.toOwnedSlice(allocator);
}

/// The children of every folder in `dirs` at once: `('a' in parents or 'b' in parents …) and
/// trashed=false`, asking for `parents` so each child can be routed back to its folder.
fn buildBatchUrl(allocator: Allocator, dirs: []const BatchDir, page_token: ?[]const u8) Allocator.Error![]u8 {
    var q: std.ArrayList(u8) = .empty;
    errdefer q.deinit(allocator);
    try q.appendSlice(allocator, api ++ "?q=");
    try appendQueryValue(allocator, &q, "(");
    for (dirs, 0..) |d, i| {
        if (i != 0) try appendQueryValue(allocator, &q, " or ");
        try appendQueryValue(allocator, &q, "'");
        try appendQueryValue(allocator, &q, d.id);
        try appendQueryValue(allocator, &q, "' in parents");
    }
    try appendQueryValue(allocator, &q, ") and trashed=false");
    try q.appendSlice(allocator, "&fields=nextPageToken,files(" ++ file_fields ++ ",parents)&pageSize=1000" ++ all_drives_list);
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

