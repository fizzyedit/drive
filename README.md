# zig-drive

Filesystem-like API over cloud storage for [Fizzy](https://github.com/fizzyedit/fizzy). Google Drive is the first backend; Dropbox can be another `Fs` later. The explorer talks to ids (Drive file ids), not OS paths.

Zig **0.16.0**. MIT. Same package shape as [md4zig](https://github.com/fizzyedit/md4zig): a module, not a plugin. No Fizzy or DVUI dependency.

## Use from a Zig project

```sh
zig fetch --save git+https://github.com/fizzyedit/zig-drive
```

```zig
const zig_drive = b.dependency("zig_drive", .{
    .target = target,
    .optimize = optimize,
});
mod.addImport("zig_drive", zig_drive.module("zig_drive"));
```

```zig
const drive = @import("zig_drive");

var mem_fs = try drive.Mem.init(allocator);
defer mem_fs.deinit();
const fs = mem_fs.fs();

const entries = try fs.listDir(allocator, drive.Mem.root_id);
defer drive.freeEntries(allocator, entries);
```

Drive is the same `Fs`, with HTTP and the bearer token injected by the host:

```zig
var client: drive.drive.Client = .{
    .allocator = allocator,
    .transport = my_transport, // http.Transport — you implement requestFn
    .access_token = access_token,
};
const fs = client.fs();
const listing = try fs.listDir(allocator, "root"); // or a picked folder id
```

`listDir` / `readFile` / `stat` hit Drive v3 (`files.list`, `files.get`, `files.get?alt=media`). `writeFile` / `createFile` / `mkdir` / `remove` return `error.Unsupported` until a later slice. Google Docs / Sheets MIME types return `error.NotBinary`.

## Build

```sh
zig build test
zig build check-wasm   # wasm32-freestanding link, Fizzy's web target
```

## How Google Drive access actually works

The library speaks REST. The **host** (Fizzy native vs web) must supply HTTP and login.

### GCP (once)

1. Google Cloud project, enable **Google Drive API**.
2. OAuth consent screen.
3. Two OAuth clients:
   - **Web** — JS origin `https://fizzyed.it` and localhost for `zig build` web.
   - **Desktop** — native loopback.

### Scopes

Start with `drive.file` plus Google Picker (or an equivalent folder chooser) so the explorer root is a folder the user granted. That ships without restricted-scope verification.

Full `https://www.googleapis.com/auth/drive` is the same zig-drive API with a different root id and a harder Google review. Do not bake “My Drive vs picked folder” into `Fs`.

### OAuth

PKCE. Native: system browser + loopback. Web: popup / redirect on fizzyed.it.

Tokens stay in the **host**. Refresh is host-side. zig-drive only sees `Authorization: Bearer …`.

### Transport

`http.Transport.requestFn` must support GET/POST/PATCH and arbitrary headers. Native can wrap `std.http`. Wasm cannot use `std.http`; call JS `fetch`.

## Fizzy follow-up (not this package)

A working zig-drive is not enough to draw the explorer. Today:

1. `FileTable.listDir` is hardcoded to `Io.Dir`. Give it an `Fs` (local adapter + Drive).
2. Point `sdk.services.files.Api` at the same `Fs` for open/save (that service is already replaceable).
3. `fizzy_web_fetch` is GET-only and cannot set auth headers. Extend it for method + headers and implement `Transport` in `web_io.zig`.
4. Replace `WebFolderUnavailable` (“The file explorer is not available in the browser”) with Connect Google Drive.
5. Persist tokens in existing ZON settings (`settings.zon`), not a new plugin.

Native gets the same `Fs`: local disk and Drive side by side (open a Drive folder as the project root).
