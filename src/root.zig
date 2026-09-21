//! zig-drive — a path-addressed, completion-based filesystem API over cloud storage.
//!
//! The host injects HTTP (`http.Transport`) and an OAuth access token. This module never
//! opens sockets, talks to JS, or stores credentials. See `Fs.zig` for the contract.

const FsFile = @import("Fs.zig");

pub const Error = FsFile.Error;
pub const Kind = FsFile.Kind;
pub const Entry = FsFile.Entry;
pub const Stat = FsFile.Stat;
pub const Job = FsFile.Job;
pub const Fs = FsFile.Fs;
pub const ListDirFn = FsFile.ListDirFn;
pub const StatFn = FsFile.StatFn;
pub const ReadFn = FsFile.ReadFn;
pub const DoneFn = FsFile.DoneFn;
pub const freeEntries = FsFile.freeEntries;
pub const path = struct {
    pub const dirname = FsFile.dirname;
    pub const basename = FsFile.basename;
    pub const join = FsFile.join;
    pub const isRoot = FsFile.isRoot;
    pub const segments = FsFile.segments;
};

pub const http = @import("http.zig");
pub const Mem = @import("mem.zig").Mem;
pub const drive = @import("drive.zig");
pub const zip = @import("zip.zig");

test {
    _ = @import("Fs.zig");
    _ = @import("http.zig");
    _ = @import("mem.zig");
    _ = @import("drive.zig");
    _ = @import("zip.zig");
}
