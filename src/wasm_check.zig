//! Root module for `zig build check-wasm`. Compiles and links the public API for
//! wasm32-freestanding (Fizzy's web target) so a libc or std.http dependency fails here instead
//! of in a consumer. Not shipped. Function pointers are taken so the bodies are analysed, not
//! just the types.

const drive = @import("root.zig");

export fn zig_drive_wasm_check() usize {
    return @sizeOf(drive.Fs) + @sizeOf(drive.http.Transport) + @sizeOf(drive.Mem) + @sizeOf(drive.drive.Client) +
        @intFromPtr(&drive.zip.pack) + @intFromPtr(&drive.zip.unpackInto) + @intFromPtr(&drive.Mem.init);
}
