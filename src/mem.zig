//! In-memory Fs backend. Used by unit tests and as a stand-in while a host
//! has no cloud session.

const std = @import("std");
const Fs = @import("Fs.zig");
const Allocator = std.mem.Allocator;

pub const Mem = struct {
    allocator: Allocator,
    nodes: std.StringHashMap(Node),
    next_id: u64 = 1,

    const Node = struct {
        id: []u8,
        name: []u8,
        parent_id: []u8,
        kind: Fs.Kind,
        bytes: []u8,
    };

    pub const root_id = "root";

    pub fn init(allocator: Allocator) Allocator.Error!Mem {
        var self: Mem = .{
            .allocator = allocator,
            .nodes = std.StringHashMap(Node).init(allocator),
        };
        const id = try allocator.dupe(u8, root_id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, "");
        errdefer allocator.free(name);
        const parent = try allocator.dupe(u8, "");
        errdefer allocator.free(parent);
        try self.nodes.put(id, .{
            .id = id,
            .name = name,
            .parent_id = parent,
            .kind = .dir,
            .bytes = &.{},
        });
        return self;
    }

    pub fn deinit(self: *Mem) void {
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            freeNode(self.allocator, entry.value_ptr.*);
        }
        self.nodes.deinit();
    }

    pub fn fs(self: *Mem) Fs.Fs {
        return .{
            .ptr = self,
            .listDirFn = listDir,
            .statFn = stat,
            .readFileFn = readFile,
            .writeFileFn = writeFile,
            .createFileFn = createFile,
            .mkdirFn = mkdir,
            .removeFn = remove,
        };
    }

    fn freeNode(allocator: Allocator, node: Node) void {
        allocator.free(node.id);
        allocator.free(node.name);
        allocator.free(node.parent_id);
        if (node.bytes.len != 0) allocator.free(node.bytes);
    }

    fn get(self: *Mem, id: []const u8) Fs.Error!*Node {
        return self.nodes.getPtr(id) orelse error.NotFound;
    }

    fn childByName(self: *Mem, parent_id: []const u8, name: []const u8) ?*Node {
        var it = self.nodes.valueIterator();
        while (it.next()) |node| {
            if (std.mem.eql(u8, node.parent_id, parent_id) and std.mem.eql(u8, node.name, name)) {
                return node;
            }
        }
        return null;
    }

    fn allocId(self: *Mem) Allocator.Error![]u8 {
        const id = try std.fmt.allocPrint(self.allocator, "m{d}", .{self.next_id});
        self.next_id += 1;
        return id;
    }

    fn insert(self: *Mem, kind: Fs.Kind, parent_id: []const u8, name: []const u8, bytes: []const u8) Fs.Error![]u8 {
        const parent = try self.get(parent_id);
        if (parent.kind != .dir) return error.NotADirectory;
        if (self.childByName(parent_id, name) != null) return error.Exists;

        const id = try self.allocId();
        errdefer self.allocator.free(id);
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const parent_copy = try self.allocator.dupe(u8, parent_id);
        errdefer self.allocator.free(parent_copy);
        const bytes_copy = try self.allocator.dupe(u8, bytes);
        errdefer if (bytes_copy.len != 0) self.allocator.free(bytes_copy);

        try self.nodes.put(id, .{
            .id = id,
            .name = name_copy,
            .parent_id = parent_copy,
            .kind = kind,
            .bytes = bytes_copy,
        });
        return try self.allocator.dupe(u8, id);
    }

    fn listDir(ptr: *anyopaque, allocator: Allocator, dir_id: []const u8) Fs.Error![]Fs.Entry {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        const dir = try self.get(dir_id);
        if (dir.kind != .dir) return error.NotADirectory;

        var list: std.ArrayList(Fs.Entry) = .empty;
        errdefer {
            for (list.items) |entry| {
                allocator.free(entry.id);
                allocator.free(entry.name);
            }
            list.deinit(allocator);
        }

        var it = self.nodes.valueIterator();
        while (it.next()) |node| {
            if (!std.mem.eql(u8, node.parent_id, dir_id)) continue;
            const id = try allocator.dupe(u8, node.id);
            errdefer allocator.free(id);
            const name = try allocator.dupe(u8, node.name);
            errdefer allocator.free(name);
            try list.append(allocator, .{ .id = id, .name = name, .kind = node.kind });
        }
        return try list.toOwnedSlice(allocator);
    }

    fn stat(ptr: *anyopaque, allocator: Allocator, id: []const u8) Fs.Error!Fs.Stat {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        const node = try self.get(id);
        return .{
            .id = try allocator.dupe(u8, node.id),
            .name = try allocator.dupe(u8, node.name),
            .kind = node.kind,
            .size = node.bytes.len,
        };
    }

    fn readFile(ptr: *anyopaque, allocator: Allocator, file_id: []const u8) Fs.Error![]u8 {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        const node = try self.get(file_id);
        if (node.kind != .file) return error.NotAFile;
        return try allocator.dupe(u8, node.bytes);
    }

    fn writeFile(ptr: *anyopaque, file_id: []const u8, bytes: []const u8) Fs.Error!void {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        const node = try self.get(file_id);
        if (node.kind != .file) return error.NotAFile;
        const copy = try self.allocator.dupe(u8, bytes);
        if (node.bytes.len != 0) self.allocator.free(node.bytes);
        node.bytes = copy;
    }

    fn createFile(ptr: *anyopaque, allocator: Allocator, parent_id: []const u8, name: []const u8, bytes: []const u8) Fs.Error![]u8 {
        _ = allocator;
        const self: *Mem = @ptrCast(@alignCast(ptr));
        return self.insert(.file, parent_id, name, bytes);
    }

    fn mkdir(ptr: *anyopaque, allocator: Allocator, parent_id: []const u8, name: []const u8) Fs.Error![]u8 {
        _ = allocator;
        const self: *Mem = @ptrCast(@alignCast(ptr));
        return self.insert(.dir, parent_id, name, &.{});
    }

    fn remove(ptr: *anyopaque, id: []const u8) Fs.Error!void {
        const self: *Mem = @ptrCast(@alignCast(ptr));
        if (std.mem.eql(u8, id, root_id)) return error.Unsupported;
        const node = try self.get(id);
        if (node.kind == .dir) {
            var it = self.nodes.valueIterator();
            while (it.next()) |child| {
                if (std.mem.eql(u8, child.parent_id, id)) return error.NotEmpty;
            }
        }
        const kv = self.nodes.fetchRemove(id) orelse return error.NotFound;
        freeNode(self.allocator, kv.value);
    }
};

test "memory fs list read write mkdir" {
    const allocator = std.testing.allocator;
    var store = try Mem.init(allocator);
    defer store.deinit();
    const fs = store.fs();

    const dir_id = try fs.mkdir(allocator, Mem.root_id, "docs");
    defer allocator.free(dir_id);
    const file_id = try fs.createFile(allocator, dir_id, "hello.txt", "hi");
    defer allocator.free(file_id);

    try fs.writeFile(file_id, "hello world");
    const body = try fs.readFile(allocator, file_id);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("hello world", body);

    const listing = try fs.listDir(allocator, dir_id);
    defer Fs.freeEntries(allocator, listing);
    try std.testing.expectEqual(@as(usize, 1), listing.len);
    try std.testing.expectEqualStrings("hello.txt", listing[0].name);
    try std.testing.expectEqual(Fs.Kind.file, listing[0].kind);

    const st = try fs.stat(allocator, file_id);
    defer Fs.freeStat(allocator, st);
    try std.testing.expectEqual(@as(u64, 11), st.size);

    try std.testing.expectError(error.NotEmpty, fs.remove(dir_id));
    try fs.remove(file_id);
    try fs.remove(dir_id);
    const empty = try fs.listDir(allocator, Mem.root_id);
    defer Fs.freeEntries(allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
