//! Injected HTTP transport. The library never opens sockets or calls JS;
//! the host (native `std.http`, wasm `fetch`, or a test double) supplies this.

const std = @import("std");
const Fs = @import("Fs.zig");
const Allocator = std.mem.Allocator;

pub const Method = enum {
    GET,
    POST,
    PATCH,
    PUT,
    DELETE,

    pub fn asSlice(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PATCH => "PATCH",
            .PUT => "PUT",
            .DELETE => "DELETE",
        };
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    allocator: Allocator,
    method: Method,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = &.{},
};

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: Response, allocator: Allocator) void {
        allocator.free(self.body);
    }
};

pub const Transport = struct {
    ptr: *anyopaque,
    requestFn: *const fn (ptr: *anyopaque, req: Request) Fs.Error!Response,

    pub fn request(self: Transport, req: Request) Fs.Error!Response {
        return self.requestFn(self.ptr, req);
    }
};
