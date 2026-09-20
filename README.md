# zig-drive

A path-addressed, completion-based filesystem API over cloud storage, for
[Fizzy](https://github.com/fizzyedit/fizzy). Google Drive is the first backend; Dropbox or
OneDrive would be another `Fs` behind the same interface.

Zig **0.16.0**. MIT. Same package shape as [md4zig](https://github.com/fizzyedit/md4zig): a
module, not a plugin. No Fizzy or DVUI dependency. Links for wasm32-freestanding.

## Two decisions that shape the API

**Paths, not ids.** A consumer already speaks paths everywhere (fizzy's file table, documents,
explorer); an id-addressed API would force a second code path into each of them. Every op takes
a `/`-rooted path *within the mount* — the host strips its own prefix (`gdrive://<account>`)
before calling — and the Drive backend keeps the path→id map to itself, filling it lazily as
directories are listed. Duplicate sibling names (Drive allows them) resolve first-listed-wins.

**Async, not blocking.** wasm32-freestanding is single-threaded and cannot wait on `fetch`, so a
synchronous `readFile() -> []u8` is unimplementable on the one target this exists for. Every op
starts a `Job` and completes through a callback that runs only from `pump()`, on the calling
thread — once per frame, in fizzy. A backend that can answer immediately (`Mem`) still defers to
`pump`, so a consumer sees one timing everywhere.

## Use from a Zig project

```sh
zig fetch --save git+https://github.com/fizzyedit/zig-drive
```

```zig
const zig_drive = b.dependency("zig_drive", .{ .target = target, .optimize = optimize });
mod.addImport("zig_drive", zig_drive.module("zig_drive"));
```

```zig
const drive = @import("zig_drive");

var mem = try drive.Mem.init(allocator);
defer mem.deinit();
const fs = mem.fs();

fn onList(ctx: ?*anyopaque, result: drive.Error![]drive.Entry) void {
    const entries = result catch |err| return handle(err);
    defer drive.freeEntries(allocator, entries);
    // …
}

_ = try fs.listDir(allocator, "/", onList, null);
// each frame:
fs.pump();
```

Google Drive is the same `Fs`, with HTTP and the bearer token injected by the host:

```zig
var client = try drive.drive.Client.init(allocator, my_transport, access_token, "root");
defer client.deinit();
const fs = client.fs();
```

`root_id` is `"root"` for My Drive or the id of a picked folder — the mount's `/` is whatever
the host says it is; the API does not know the difference.

| `Fs` op | Drive v3 |
|---|---|
| `listDir` | `files.list` with `'<id>' in parents and trashed=false`, paginated |
| `stat` | answered from the index (lists ancestors on a cold path) |
| `readFile` | `files.get?alt=media` — a Google Doc/Sheet is `error.NotBinary` |
| `writeFile` | `PATCH upload/…/files/<id>?uploadType=media` |
| `createFile` / `mkdir` | `POST files` with `{name, parents[, mimeType]}` — metadata only, no multipart |
| `rename` | `PATCH files/<id>?addParents=&removeParents=` with `{name}` |
| `remove` | `PATCH files/<id>` with `{trashed: true}`; a non-empty directory is `error.NotEmpty` |

Errors split `Unauthorized` (refresh the token and retry) from `Forbidden` (the token is fine,
the op is not allowed).

`http.Transport` has the same completion shape: `request(allocator, req, cb, ctx)` returns a
job, `pump()` delivers. Native wraps `std.http` on a thread; wasm calls JS `fetch` and completes
from the callback export. `src/drive_test.zig` has a scripted transport to copy.

## Build

```sh
zig build test
zig build check-wasm   # wasm32-freestanding link, Fizzy's web target
```

## What the host still owns

- **HTTP** — `http.Transport`.
- **OAuth** — native: desktop client, PKCE, system browser + loopback, refresh token persisted
  by the host. Web: Google Identity Services token client (Google will not do a browser PKCE
  code exchange for a Web client without a secret) — 1-hour tokens, silent re-request. Both
  hand this library a bearer string; it sees `Authorization: Bearer …` and nothing else.
- **Scopes** — `drive.file` plus a folder picker ships without restricted-scope review; full
  `drive` is the same API with `root_id = "root"` and a harder Google review.
- **Freshness** — `changes.list` polling is the host's; on a change it calls `Client.forget(path)`.

The fizzy side of this (mount table, `FileTable` routing, the `drive` plugin) is planned in
fizzy's `docs/CLOUD_FS_PLAN.md`.
