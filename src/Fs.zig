//! Filesystem-like API over id-addressed entries (Drive file ids, memory
//! node ids, later Dropbox ids). Not OS paths.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    NotFound,
    NotADirectory,
    NotAFile,
    NotEmpty,
    Exists,
    Unsupported,
    NotBinary,
    Unauthorized,
    Http,
    InvalidJson,
    OutOfMemory,
};

pub const Kind = enum { file, dir };

pub const Entry = struct {
    id: []const u8,
    name: []const u8,
    kind: Kind,
};

pub const Stat = struct {
    id: []const u8,
    name: []const u8,
    kind: Kind,
    size: u64,
};

pub fn freeEntries(allocator: Allocator, entries: []Entry) void {
    for (entries) |entry| {
        allocator.free(entry.id);
        allocator.free(entry.name);
    }
    allocator.free(entries);
}

pub fn freeStat(allocator: Allocator, stat: Stat) void {
    allocator.free(stat.id);
    allocator.free(stat.name);
}

/// Host-owned backend. Function pointers keep this wasm-safe (no std.http,
/// no OS filesystem).
pub const Fs = struct {
    ptr: *anyopaque,
    listDirFn: *const fn (ptr: *anyopaque, allocator: Allocator, dir_id: []const u8) Error![]Entry,
    statFn: *const fn (ptr: *anyopaque, allocator: Allocator, id: []const u8) Error!Stat,
    readFileFn: *const fn (ptr: *anyopaque, allocator: Allocator, file_id: []const u8) Error![]u8,
    writeFileFn: *const fn (ptr: *anyopaque, file_id: []const u8, bytes: []const u8) Error!void,
    createFileFn: *const fn (ptr: *anyopaque, allocator: Allocator, parent_id: []const u8, name: []const u8, bytes: []const u8) Error![]u8,
    mkdirFn: *const fn (ptr: *anyopaque, allocator: Allocator, parent_id: []const u8, name: []const u8) Error![]u8,
    removeFn: *const fn (ptr: *anyopaque, id: []const u8) Error!void,

    pub fn listDir(self: Fs, allocator: Allocator, dir_id: []const u8) Error![]Entry {
        return self.listDirFn(self.ptr, allocator, dir_id);
    }

    pub fn stat(self: Fs, allocator: Allocator, id: []const u8) Error!Stat {
        return self.statFn(self.ptr, allocator, id);
    }

    pub fn readFile(self: Fs, allocator: Allocator, file_id: []const u8) Error![]u8 {
        return self.readFileFn(self.ptr, allocator, file_id);
    }

    pub fn writeFile(self: Fs, file_id: []const u8, bytes: []const u8) Error!void {
        return self.writeFileFn(self.ptr, file_id, bytes);
    }

    /// Returns a newly allocated id the caller owns.
    pub fn createFile(self: Fs, allocator: Allocator, parent_id: []const u8, name: []const u8, bytes: []const u8) Error![]u8 {
        return self.createFileFn(self.ptr, allocator, parent_id, name, bytes);
    }

    /// Returns a newly allocated id the caller owns.
    pub fn mkdir(self: Fs, allocator: Allocator, parent_id: []const u8, name: []const u8) Error![]u8 {
        return self.mkdirFn(self.ptr, allocator, parent_id, name);
    }

    pub fn remove(self: Fs, id: []const u8) Error!void {
        return self.removeFn(self.ptr, id);
    }
};
