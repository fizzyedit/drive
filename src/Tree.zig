//! The path index: what Drive has told us about each path under the mount, with every
//! directory's children and every id's path kept alongside, so that nothing here scans the
//! whole index.
//!
//! It used to be one flat `path → Node` map, and every question a directory is asked — "what
//! is beneath you", "which of your children are gone", "where is id X" — was a walk over every
//! path the mount had ever seen. One listing of a folder cost the size of the drive, so a
//! crawl of the drive cost its square: on a real drive, minutes of frame time spent comparing
//! strings. Now each of those is proportional to the directory, or constant.
//!
//! Nodes are heap-allocated, so a `*Node` survives the map growing or other paths being
//! removed; only removing that node's own path (or an ancestor's) invalidates it.

const std = @import("std");
const vfs = @import("core").vfs;
const Fs = vfs;
const Allocator = std.mem.Allocator;

const Tree = @This();

pub const Node = struct {
    /// Owned.
    id: []u8,
    kind: Fs.Kind,
    size: u64 = 0,
    modified_ms: i64 = 0,
    /// A Google Doc / Sheet / Slide: exists, has no bytes.
    google_app: bool = false,
    /// Children have been listed and nothing since has said the listing is stale, so a name
    /// missing from `children` is `NotFound` rather than "not looked yet" — and a listing can be
    /// answered from here.
    listed: bool = false,
    /// The full paths of this directory's children — the very slices `nodes` is keyed by, so
    /// not owned here.
    children: std.StringArrayHashMapUnmanaged(void) = .empty,
};

/// What a listing says about one child, before it is a node.
pub const Listed = struct {
    name: []const u8,
    id: []const u8,
    kind: Fs.Kind,
    size: u64 = 0,
    modified_ms: i64 = 0,
    google_app: bool = false,
};

gpa: Allocator,
/// Path → node. Keys and nodes owned.
nodes: std.StringHashMapUnmanaged(*Node) = .empty,
/// Drive id → the path the index holds it at (a `nodes` key, not owned). An item Drive shows
/// under two parents is kept at whichever path was seen last.
by_id: std.StringHashMapUnmanaged([]const u8) = .empty,

pub fn init(gpa: Allocator, root_id: []const u8) Allocator.Error!Tree {
    var self: Tree = .{ .gpa = gpa };
    errdefer self.deinit();
    _ = try self.put("/", .{ .name = "", .id = root_id, .kind = .dir });
    return self;
}

pub fn deinit(self: *Tree) void {
    var it = self.nodes.iterator();
    while (it.next()) |kv| {
        self.freeNode(kv.value_ptr.*);
        self.gpa.free(kv.key_ptr.*);
    }
    self.nodes.deinit(self.gpa);
    self.by_id.deinit(self.gpa);
}

fn freeNode(self: *Tree, node: *Node) void {
    node.children.deinit(self.gpa);
    self.gpa.free(node.id);
    self.gpa.destroy(node);
}

pub fn get(self: *const Tree, path: []const u8) ?*Node {
    return self.nodes.get(path);
}

pub fn contains(self: *const Tree, path: []const u8) bool {
    return self.nodes.contains(path);
}

pub fn count(self: *const Tree) usize {
    return self.nodes.count();
}

/// The path the index holds for a Drive id, or null when no listing has shown it. Valid until
/// that path is removed or renamed.
pub fn pathOfId(self: *const Tree, id: []const u8) ?[]const u8 {
    return self.by_id.get(id);
}

/// Record `path` (which must not be in the index yet) and link it under its parent, when the
/// parent is known. `what.name` is ignored; the path says where it goes.
pub fn put(self: *Tree, path: []const u8, what: Listed) Allocator.Error!*Node {
    std.debug.assert(!self.nodes.contains(path));
    const key = try self.gpa.dupe(u8, path);
    errdefer self.gpa.free(key);
    const node = try self.gpa.create(Node);
    errdefer self.gpa.destroy(node);
    node.* = .{
        .id = try self.gpa.dupe(u8, what.id),
        .kind = what.kind,
        .size = what.size,
        .modified_ms = what.modified_ms,
        .google_app = what.google_app,
    };
    errdefer self.gpa.free(node.id);
    try self.nodes.put(self.gpa, key, node);
    errdefer _ = self.nodes.remove(key);
    if (!Fs.path.isRoot(path)) {
        if (self.nodes.get(Fs.path.dirname(path))) |parent| try parent.children.put(self.gpa, key, {});
    }
    try self.by_id.put(self.gpa, node.id, key);
    return node;
}

/// Remove `path` and everything beneath it.
pub fn remove(self: *Tree, path: []const u8) void {
    const kv = self.nodes.fetchRemove(path) orelse return;
    if (!Fs.path.isRoot(kv.key)) {
        if (self.nodes.get(Fs.path.dirname(kv.key))) |parent| _ = parent.children.swapRemove(kv.key);
    }
    self.destroy(kv.key, kv.value);
}

/// Forget everything beneath `dir` and mark it unlisted, so the next op re-asks Drive.
pub fn clearChildren(self: *Tree, dir: []const u8) void {
    const node = self.nodes.get(dir) orelse return;
    self.removeChildren(node);
    node.listed = false;
}

fn removeChildren(self: *Tree, node: *Node) void {
    // Each child is taken out of `nodes` here and handed down, rather than removed by path:
    // a child looking its parent up by path would not find one already on its way out.
    for (node.children.keys()) |child| {
        if (self.nodes.fetchRemove(child)) |kv| self.destroy(kv.key, kv.value);
    }
    node.children.clearRetainingCapacity();
}

/// Free a node already out of `nodes`, and its subtree.
fn destroy(self: *Tree, key: []const u8, node: *Node) void {
    self.removeChildren(node);
    self.unlinkId(node.id, key);
    self.freeNode(node);
    self.gpa.free(key);
}

fn unlinkId(self: *Tree, id: []const u8, path: []const u8) void {
    if (self.by_id.get(id)) |at| {
        if (at.ptr == path.ptr) _ = self.by_id.remove(id);
    }
}

/// Re-key `from` and everything beneath it under `to`, keeping what is known about each (a
/// folder moved stays listed). Whatever the index held at `to` is replaced — the move is the
/// newer fact. `to`'s parent should exist.
pub fn rename(self: *Tree, from: []const u8, to: []const u8) Allocator.Error!void {
    if (std.mem.eql(u8, from, to)) return;
    if (!self.nodes.contains(from)) return;
    // Moving something beneath itself is not a move this index can represent.
    if (to.len > from.len and std.mem.startsWith(u8, to, from) and to[from.len] == '/') return;
    // Nor onto one of its own ancestors, which replacing `to` would take `from` down with.
    if (from.len > to.len and std.mem.startsWith(u8, from, to) and (Fs.path.isRoot(to) or from[to.len] == '/')) return;
    self.remove(to);
    const gpa = self.gpa;

    // The subtree, parents before children, as (old key, node).
    const Entry = struct { key: []const u8, node: *Node };
    var moving: std.ArrayList(Entry) = .empty;
    defer moving.deinit(gpa);
    {
        const root = self.nodes.get(from) orelse return;
        try moving.append(gpa, .{ .key = self.nodes.getKey(from).?, .node = root });
        var i: usize = 0;
        while (i < moving.items.len) : (i += 1) {
            for (moving.items[i].node.children.keys()) |child| {
                try moving.append(gpa, .{ .key = child, .node = self.nodes.get(child).? });
            }
        }
    }
    // Every new key up front, so nothing below can fail halfway through the move.
    const new_keys = try gpa.alloc([]u8, moving.items.len);
    defer gpa.free(new_keys);
    var made: usize = 0;
    errdefer for (new_keys[0..made]) |k| gpa.free(k);
    for (moving.items, 0..) |e, i| {
        new_keys[i] = try std.mem.concat(gpa, u8, &.{ to, e.key[from.len..] });
        made += 1;
    }
    try self.nodes.ensureUnusedCapacity(gpa, @intCast(moving.items.len));
    try self.by_id.ensureUnusedCapacity(gpa, @intCast(moving.items.len));
    const new_parent = self.nodes.get(Fs.path.dirname(to));
    if (new_parent) |p| try p.children.ensureUnusedCapacity(gpa, 1);
    for (moving.items) |e| try e.node.children.ensureTotalCapacity(gpa, e.node.children.count());

    // Detach.
    if (self.nodes.get(Fs.path.dirname(from))) |old_parent| _ = old_parent.children.swapRemove(moving.items[0].key);
    for (moving.items) |e| {
        _ = self.nodes.remove(e.key);
        self.unlinkId(e.node.id, e.key);
        e.node.children.clearRetainingCapacity();
    }
    // Reattach under the new keys, parents first so each child finds its parent.
    for (moving.items, 0..) |e, i| {
        const key = new_keys[i];
        self.nodes.putAssumeCapacity(key, e.node);
        self.by_id.putAssumeCapacity(e.node.id, key);
        if (i == 0) {
            if (new_parent) |p| p.children.putAssumeCapacity(key, {});
        } else {
            self.nodes.get(Fs.path.dirname(key)).?.children.putAssumeCapacity(key, {});
        }
        gpa.free(e.key);
    }
}

/// Make `dir`'s children exactly `entries` — one complete listing of it — and mark it listed.
///
/// A child that is still the same item (same id) keeps what is known beneath it, so a re-list
/// never pulls paths out from under ops in flight deeper down; a name now held by a different
/// item loses the old one's subtree; a child the listing did not return is gone. Duplicate
/// names resolve first-listed-wins: Drive allows two siblings one name, a path cannot.
///
/// `seen` is filled with the index of each entry that took a path (so a caller can answer in
/// Drive's order without the duplicates). Null if the caller does not need it.
pub fn setListing(self: *Tree, dir: []const u8, entries: []const Listed, seen: ?*std.ArrayList(usize)) Allocator.Error!void {
    const gpa = self.gpa;
    const dir_node = self.nodes.get(dir) orelse return;
    if (dir_node.kind != .dir) return;

    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(gpa);
    try names.ensureTotalCapacity(gpa, @intCast(entries.len));

    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(gpa);

    for (entries, 0..) |e, i| {
        if (e.name.len == 0 or names.contains(e.name)) continue;
        names.putAssumeCapacity(e.name, {});
        path_buf.clearRetainingCapacity();
        try path_buf.appendSlice(gpa, dir);
        if (!Fs.path.isRoot(dir)) try path_buf.append(gpa, '/');
        try path_buf.appendSlice(gpa, e.name);
        const child = path_buf.items;

        if (self.nodes.get(child)) |node| {
            if (std.mem.eql(u8, node.id, e.id)) {
                node.size = e.size;
                node.modified_ms = e.modified_ms;
                node.google_app = e.google_app;
                if (node.kind != e.kind) {
                    // A folder that came back as a file (or the reverse): nothing beneath it
                    // is its any more.
                    self.removeChildren(node);
                    node.listed = false;
                    node.kind = e.kind;
                }
                if (seen) |s| try s.append(gpa, i);
                continue;
            }
            self.remove(child);
        }
        _ = try self.put(child, e);
        if (seen) |s| try s.append(gpa, i);
    }

    // What was here and was not listed.
    var i: usize = dir_node.children.count();
    while (i > 0) {
        i -= 1;
        const child = dir_node.children.keys()[i];
        if (!names.contains(Fs.path.basename(child))) self.remove(child);
    }
    dir_node.listed = true;
}

// -- tests -------------------------------------------------------------------------------------

const testing = std.testing;

fn listed(name: []const u8, id: []const u8, kind: Fs.Kind) Listed {
    return .{ .name = name, .id = id, .kind = kind };
}

test "put links children; remove takes the subtree and the ids with it" {
    var t = try Tree.init(testing.allocator, "root");
    defer t.deinit();
    _ = try t.put("/a", listed("a", "A", .dir));
    _ = try t.put("/a/b", listed("b", "B", .dir));
    _ = try t.put("/a/b/c.md", listed("c.md", "C", .file));
    try testing.expectEqual(@as(usize, 1), t.get("/a").?.children.count());
    try testing.expectEqualStrings("/a/b/c.md", t.pathOfId("C").?);

    t.remove("/a");
    try testing.expectEqual(@as(usize, 1), t.count());
    try testing.expect(t.pathOfId("B") == null);
    try testing.expect(t.pathOfId("C") == null);
    try testing.expectEqual(@as(usize, 0), t.get("/").?.children.count());
}

test "setListing keeps a surviving folder's subtree, replaces a changed id, drops the missing" {
    var t = try Tree.init(testing.allocator, "root");
    defer t.deinit();
    try t.setListing("/", &.{ listed("keep", "K", .dir), listed("swap", "S1", .dir), listed("gone.md", "G", .file) }, null);
    try t.setListing("/keep", &.{listed("deep.md", "D", .file)}, null);
    try t.setListing("/swap", &.{listed("old.md", "O", .file)}, null);

    try t.setListing("/", &.{ listed("keep", "K", .dir), listed("swap", "S2", .dir) }, null);
    try testing.expect(t.contains("/keep/deep.md"));
    try testing.expect(t.get("/keep").?.listed);
    try testing.expect(!t.contains("/swap/old.md"));
    try testing.expect(!t.get("/swap").?.listed);
    try testing.expect(!t.contains("/gone.md"));
    try testing.expect(t.pathOfId("O") == null);
    try testing.expectEqualStrings("/swap", t.pathOfId("S2").?);
}

test "setListing: first-listed wins among duplicate names, and says which entries took a path" {
    var t = try Tree.init(testing.allocator, "root");
    defer t.deinit();
    var seen: std.ArrayList(usize) = .empty;
    defer seen.deinit(testing.allocator);
    try t.setListing("/", &.{ listed("x", "X1", .file), listed("y", "Y", .file), listed("x", "X2", .file) }, &seen);
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, seen.items);
    try testing.expectEqualStrings("X1", t.get("/x").?.id);
}

test "setListing: a folder that came back as a file loses what was beneath it" {
    var t = try Tree.init(testing.allocator, "root");
    defer t.deinit();
    try t.setListing("/", &.{listed("n", "N", .dir)}, null);
    try t.setListing("/n", &.{listed("a.md", "A", .file)}, null);
    try t.setListing("/", &.{listed("n", "N", .file)}, null);
    try testing.expectEqual(Fs.Kind.file, t.get("/n").?.kind);
    try testing.expect(!t.contains("/n/a.md"));
}

test "rename moves the subtree, its listed state and its ids" {
    var t = try Tree.init(testing.allocator, "root");
    defer t.deinit();
    try t.setListing("/", &.{ listed("a", "A", .dir), listed("z", "Z", .dir) }, null);
    try t.setListing("/a", &.{listed("b", "B", .dir)}, null);
    try t.setListing("/a/b", &.{listed("c.md", "C", .file)}, null);

    try t.rename("/a", "/z/moved");
    try testing.expect(!t.contains("/a"));
    try testing.expect(!t.contains("/a/b/c.md"));
    try testing.expect(t.get("/z/moved/b").?.listed);
    try testing.expectEqualStrings("/z/moved/b/c.md", t.pathOfId("C").?);
    try testing.expectEqual(@as(usize, 1), t.get("/z").?.children.count());
    try testing.expectEqual(@as(usize, 1), t.get("/").?.children.count());
    try testing.expectEqual(@as(usize, 1), t.get("/z/moved/b").?.children.count());
}
