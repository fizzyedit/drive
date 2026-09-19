//! zig-drive — filesystem-like API over cloud storage.
//!
//! The host injects HTTP (`http.Transport`) and an OAuth access token.
//! This module never opens sockets, talks to JS, or stores credentials.

const FsFile = @import("Fs.zig");

pub const Error = FsFile.Error;
pub const Kind = FsFile.Kind;
pub const Entry = FsFile.Entry;
pub const Stat = FsFile.Stat;
pub const Fs = FsFile.Fs;
pub const freeEntries = FsFile.freeEntries;
pub const freeStat = FsFile.freeStat;

pub const http = @import("http.zig");
pub const Mem = @import("mem.zig").Mem;
pub const drive = @import("drive.zig");

test {
    _ = @import("mem.zig");
    _ = @import("drive.zig");
    _ = @import("http.zig");
    _ = @import("Fs.zig");
}
