//! OAuth pieces with no UI and no host: PKCE, the URLs and bodies Google wants, the token
//! response, and (native only) the loopback listener that receives the authorization code.
//!
//! Google's rules that shape this: a desktop client uses the authorization-code flow with
//! PKCE and a `http://127.0.0.1:<port>` redirect, and its token exchange must carry the
//! client "secret" (not secret for a desktop app; Google's docs say so). The web build cannot
//! do that exchange from a browser without a secret at all, so it uses Google Identity
//! Services' token client instead — that half lives in `plugin.zig`'s JS import, not here.
const std = @import("std");
const builtin = @import("builtin");

pub const scope_file = "https://www.googleapis.com/auth/drive.file";
pub const scope_full = "https://www.googleapis.com/auth/drive";
pub const auth_endpoint = "https://accounts.google.com/o/oauth2/v2/auth";
pub const token_endpoint = "https://oauth2.googleapis.com/token";
pub const about_endpoint = "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress,displayName,photoLink)";

/// A PKCE verifier and its S256 challenge, plus a `state` nonce the redirect must echo.
pub const Pkce = struct {
    verifier: [64]u8,
    challenge: [43]u8,
    state: [32]u8,

    pub fn generate(io: std.Io) Pkce {
        var raw: [48]u8 = undefined;
        io.random(&raw);
        var p: Pkce = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&p.verifier, &raw);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&p.verifier, &digest, .{});
        _ = std.base64.url_safe_no_pad.Encoder.encode(&p.challenge, &digest);
        var nonce: [24]u8 = undefined;
        io.random(&nonce);
        _ = std.base64.url_safe_no_pad.Encoder.encode(&p.state, &nonce);
        return p;
    }
};

/// The browser URL that starts a desktop sign-in. Caller owns.
/// `pick` asks Google to show its own folder picker inside this consent flow — the documented
/// way for an installed app to use the Picker (`trigger_onepick`). The chosen ids come back on
/// the redirect as `picked_file_ids`, and under `drive.file` that grant *is* the access. It
/// replaces hosting Google's JavaScript picker widget ourselves, which an installed app cannot
/// do honestly: that widget is judged by the web origin it runs on, and a loopback listener has
/// no origin anyone can register.
pub fn authUrl(allocator: std.mem.Allocator, client_id: []const u8, scope: []const u8, port: u16, pkce: *const Pkce, pick: bool) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, auth_endpoint ++ "?response_type=code&access_type=offline&prompt=consent&code_challenge_method=S256");
    if (pick) try out.appendSlice(allocator, "&trigger_onepick=true&allow_folder_selection=true");
    try appendParam(allocator, &out, "client_id", client_id);
    var redirect_buf: [40]u8 = undefined;
    try appendParam(allocator, &out, "redirect_uri", redirectUri(&redirect_buf, port));
    try appendParam(allocator, &out, "scope", scope);
    try appendParam(allocator, &out, "code_challenge", &pkce.challenge);
    try appendParam(allocator, &out, "state", &pkce.state);
    return out.toOwnedSlice(allocator);
}

pub fn redirectUri(buf: *[40]u8, port: u16) []const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{port}) catch unreachable;
}

/// The browser URL for the web build's implicit flow: the access token comes back in the
/// fragment of `redirect_uri` (fizzy's `oauth-callback.html`), no exchange, no secret. Caller
/// owns. `silent` asks Google to answer without a prompt — for renewing an expired token.
pub fn implicitAuthUrl(allocator: std.mem.Allocator, client_id: []const u8, scope: []const u8, redirect_uri: []const u8, state: []const u8, silent: bool, pick: bool) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, auth_endpoint ++ "?response_type=token&include_granted_scopes=true");
    if (silent) try out.appendSlice(allocator, "&prompt=none");
    // Same picker the desktop uses (`authUrl`), and it answers an implicit grant too: the ids
    // come back on the redirect beside the token. `prompt=consent` is required with it.
    if (pick) try out.appendSlice(allocator, "&prompt=consent&trigger_onepick=true&allow_folder_selection=true");
    try appendParam(allocator, &out, "client_id", client_id);
    try appendParam(allocator, &out, "redirect_uri", redirect_uri);
    try appendParam(allocator, &out, "scope", scope);
    try appendParam(allocator, &out, "state", state);
    return out.toOwnedSlice(allocator);
}

/// What the implicit flow put in the callback's fragment: `#access_token=…&expires_in=…`.
pub const ImplicitResult = struct {
    access_token: []const u8,
    expires_in: i64,
    state: []const u8,
    /// The picker's answer, when the request asked for one — comma-separated ids.
    picked_file_ids: ?[]const u8 = null,
};

/// Parse the callback page's `search ++ hash`. Null when it carries no token (an `error=`).
pub fn parseImplicit(result: []const u8) ?ImplicitResult {
    const hash = if (std.mem.indexOfScalar(u8, result, '#')) |i| result[i + 1 ..] else return null;
    const token = queryParam(hash, "access_token") orelse return null;
    const expires = queryParam(hash, "expires_in") orelse "3600";
    return .{
        .access_token = token,
        .expires_in = std.fmt.parseInt(i64, expires, 10) catch 3600,
        .state = queryParam(hash, "state") orelse "",
        // Present only when the request asked for the picker. Google puts it in the query
        // rather than the fragment, so look through the whole reply, not just the hash.
        .picked_file_ids = queryParam(result, "picked_file_ids"),
    };
}

/// The form body that trades an authorization code for tokens. Caller owns.
pub fn exchangeBody(allocator: std.mem.Allocator, client_id: []const u8, client_secret: []const u8, code: []const u8, port: u16, pkce: *const Pkce) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "grant_type=authorization_code");
    try appendParam(allocator, &out, "client_id", client_id);
    if (client_secret.len != 0) try appendParam(allocator, &out, "client_secret", client_secret);
    try appendParam(allocator, &out, "code", code);
    try appendParam(allocator, &out, "code_verifier", &pkce.verifier);
    var redirect_buf: [40]u8 = undefined;
    try appendParam(allocator, &out, "redirect_uri", redirectUri(&redirect_buf, port));
    return out.toOwnedSlice(allocator);
}

/// The form body that refreshes an access token. Caller owns.
pub fn refreshBody(allocator: std.mem.Allocator, client_id: []const u8, client_secret: []const u8, refresh_token: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "grant_type=refresh_token");
    try appendParam(allocator, &out, "client_id", client_id);
    if (client_secret.len != 0) try appendParam(allocator, &out, "client_secret", client_secret);
    try appendParam(allocator, &out, "refresh_token", refresh_token);
    return out.toOwnedSlice(allocator);
}

pub const TokenResponse = struct {
    access_token: []const u8 = "",
    refresh_token: ?[]const u8 = null,
    expires_in: i64 = 3600,
    @"error": ?[]const u8 = null,
    error_description: ?[]const u8 = null,
};

pub fn parseToken(allocator: std.mem.Allocator, body: []const u8) !std.json.Parsed(TokenResponse) {
    return std.json.parseFromSlice(TokenResponse, allocator, body, .{ .ignore_unknown_fields = true });
}

pub const About = struct {
    user: struct {
        emailAddress: []const u8 = "",
        displayName: []const u8 = "",
        photoLink: ?[]const u8 = null,
    } = .{},
};

pub fn parseAbout(allocator: std.mem.Allocator, body: []const u8) !std.json.Parsed(About) {
    return std.json.parseFromSlice(About, allocator, body, .{ .ignore_unknown_fields = true });
}

fn appendParam(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), name: []const u8, value: []const u8) !void {
    try out.append(allocator, '&');
    try out.appendSlice(allocator, name);
    try out.append(allocator, '=');
    try appendEncoded(allocator, out, value);
}

/// `application/x-www-form-urlencoded` / query-string escaping.
pub fn appendEncoded(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(allocator, c),
            else => {
                const hex = "0123456789ABCDEF";
                try out.appendSlice(allocator, &.{ '%', hex[c >> 4], hex[c & 0x0f] });
            },
        }
    }
}

/// Percent-decoding for a query value. Caller owns.
pub fn decode(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const c = value[i];
        if (c == '%' and i + 3 <= value.len) {
            if (std.fmt.parseInt(u8, value[i + 1 .. i + 3], 16)) |b| {
                try out.append(allocator, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(allocator, if (c == '+') ' ' else c);
    }
    return out.toOwnedSlice(allocator);
}

/// The value of `name` in a `?a=b&c=d` query, still encoded. Null when absent.
pub fn queryParam(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

// ---- the loopback listener (native) -----------------------------------------------------------

/// One `http://127.0.0.1:<port>` listener that accepts exactly one request — Google's redirect
/// with the code — answers it with a page that says the tab can be closed, and stops. Runs
/// on its own thread; the plugin polls `take` once a frame.
pub const Loopback = if (builtin.target.cpu.arch == .wasm32) struct {} else struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    thread: ?std.Thread = null,
    expected_state: [32]u8,
    /// What a GET with no `state` is answered with: a page for the browser to run (the
    /// folder picker), or nothing (404 — a favicon probe during sign-in).
    page: ?[]const u8,
    /// What the redirect carrying `state` is answered with.
    done_page: []const u8,
    lock: std.atomic.Mutex = .unlocked,
    /// Set by the thread: the redirect's whole query string. Owned; taken by `take`.
    query: ?[]u8 = null,
    failed: bool = false,
    done: std.atomic.Value(bool) = .init(false),
    /// Set by `stop` before it connects to wake the thread, so the thread knows that
    /// connection is not the browser.
    stopping: std.atomic.Value(bool) = .init(false),

    const Self = @This();

    pub const Options = struct {
        /// Served at `/` (any request without `state`). Static: whatever the page needs to
        /// know travels in the URL fragment fizzy opens, which never reaches this listener.
        page: ?[]const u8 = null,
        done_page: []const u8 = page_ok,
    };

    pub fn start(gpa: std.mem.Allocator, io: std.Io, expected_state: [32]u8, opts: Options) !*Self {
        const self = try gpa.create(Self);
        errdefer gpa.destroy(self);
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .server = try addr.listen(io, .{ .reuse_address = true }),
            .expected_state = expected_state,
            .page = opts.page,
            .done_page = opts.done_page,
        };
        errdefer self.server.deinit(io);
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    pub fn port(self: *const Self) u16 {
        return self.server.socket.address.getPort();
    }

    fn serve(self: *Self) void {
        defer self.done.store(true, .release);
        // Loop until a request that carries our `state` arrives: a browser opens speculative
        // idle connections (and favicon requests) that would otherwise consume the one accept
        // and leave the real redirect with nobody listening.
        while (true) {
            const stream = self.server.accept(self.io) catch {
                self.setResult(null, true);
                return;
            };
            defer stream.close(self.io);
            if (self.stopping.load(.acquire)) return;
            var in_buf: [8192]u8 = undefined;
            var out_buf: [1024]u8 = undefined;
            var reader = stream.reader(self.io, &in_buf);
            var writer = stream.writer(self.io, &out_buf);
            var server = std.http.Server.init(&reader.interface, &writer.interface);
            var req = server.receiveHead() catch continue; // an idle connection that closed
            const target = req.head.target;
            const query = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[q + 1 ..] else "";
            const state = queryParam(query, "state") orelse {
                if (self.page) |page| {
                    req.respond(page, .{ .keep_alive = false, .extra_headers = &html }) catch {};
                } else {
                    req.respond("", .{ .status = .not_found, .keep_alive = false }) catch {};
                }
                continue;
            };
            if (!std.mem.eql(u8, state, &self.expected_state)) {
                req.respond(page_err, .{ .keep_alive = false, .extra_headers = &html }) catch {};
                self.setResult(null, true);
                return;
            }
            const owned = self.gpa.dupe(u8, query) catch {
                req.respond(page_err, .{ .keep_alive = false, .extra_headers = &html }) catch {};
                self.setResult(null, true);
                return;
            };
            self.setResult(owned, false);
            req.respond(self.done_page, .{ .keep_alive = false, .extra_headers = &html }) catch {};
            return;
        }
    }

    const html = [_]std.http.Header{.{ .name = "content-type", .value = "text/html; charset=utf-8" }};

    fn setResult(self: *Self, query: ?[]u8, failed: bool) void {
        while (!self.lock.tryLock()) std.Thread.yield() catch {};
        defer self.lock.unlock();
        self.query = query;
        self.failed = failed;
    }

    pub const Outcome = union(enum) { waiting, query: []u8, failed };

    /// Once: the redirect's query (owned by the caller from then on; `queryParam` + `decode`
    /// read it), failure, or still waiting.
    pub fn take(self: *Self) Outcome {
        while (!self.lock.tryLock()) std.Thread.yield() catch {};
        defer self.lock.unlock();
        if (self.query) |q| {
            self.query = null;
            return .{ .query = q };
        }
        if (self.failed) return .failed;
        return .waiting;
    }

    /// Stops the listener. If the browser never came back the thread is still blocked in
    /// `accept`; closing the socket under it is not an option (`Io.Threaded` treats the EBADF
    /// that produces as a bug and aborts), so it is woken with a connection of our own, which
    /// it recognises by `stopping` and ignores. Then join, then the one close.
    pub fn stop(self: *Self) void {
        self.stopping.store(true, .release);
        if (!self.done.load(.acquire)) {
            if (self.server.socket.address.connect(self.io, .{ .mode = .stream })) |poke| poke.close(self.io) else |_| {}
        }
        if (self.thread) |t| t.join();
        self.server.deinit(self.io);
        if (self.query) |q| self.gpa.free(q);
        self.gpa.destroy(self);
    }

    pub const page_ok =
        \\<!doctype html><meta charset="utf-8"><title>fizzy</title>
        \\<body style="font-family:system-ui;background:#1d2029;color:#e6e6e6;display:grid;place-items:center;height:100vh;margin:0">
        \\<div style="text-align:center"><h1>Signed in to Google Drive</h1><p>You can close this tab and return to fizzy.</p></div>
    ;
    pub const page_err =
        \\<!doctype html><meta charset="utf-8"><title>fizzy</title>
        \\<body style="font-family:system-ui;background:#1d2029;color:#e6e6e6;display:grid;place-items:center;height:100vh;margin:0">
        \\<div style="text-align:center"><h1>Sign-in did not complete</h1><p>Return to fizzy and try again.</p></div>
    ;
};

test "pkce challenge is the base64url sha256 of the verifier" {
    const p = Pkce.generate(std.testing.io);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&p.verifier, &digest, .{});
    var expect: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&expect, &digest);
    try std.testing.expectEqualStrings(&expect, &p.challenge);
}

test "query params decode" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("abc", queryParam("state=x&code=abc&scope=y", "code").?);
    try std.testing.expect(queryParam("state=x", "code") == null);
    const d = try decode(a, "4%2F0Ab-c+d%2");
    defer a.free(d);
    try std.testing.expectEqualStrings("4/0Ab-c d%2", d);
}

test "the implicit result is read from the fragment" {
    const r = parseImplicit("?x=1#state=abc&access_token=ya29.tok&token_type=Bearer&expires_in=3599").?;
    try std.testing.expectEqualStrings("ya29.tok", r.access_token);
    try std.testing.expectEqual(@as(i64, 3599), r.expires_in);
    try std.testing.expectEqualStrings("abc", r.state);
    try std.testing.expect(parseImplicit("?error=access_denied#state=abc") == null);
}

test "bodies are form-encoded" {
    const a = std.testing.allocator;
    const b = try refreshBody(a, "id x", "", "tok/1");
    defer a.free(b);
    try std.testing.expectEqualStrings("grant_type=refresh_token&client_id=id%20x&refresh_token=tok%2F1", b);
}

test "the loopback listener takes the code from Google's redirect and answers the browser" {
    if (builtin.target.cpu.arch == .wasm32) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const pkce = Pkce.generate(io);
    const lb = try Loopback.start(a, io, pkce.state, .{});
    defer lb.stop();
    try std.testing.expectEqual(Loopback.Outcome.waiting, lb.take());

    // The browser, redirected by Google.
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/?state={s}&code=4%2F0Ab-xyz&scope=drive.file", .{ lb.port(), &pkce.state });
    defer a.free(url);
    var page: std.Io.Writer.Allocating = .init(a);
    defer page.deinit();
    const res = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &page.writer });
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expect(std.mem.indexOf(u8, page.written(), "Signed in") != null);

    var spins: usize = 0;
    const query = while (spins < 5000) : (spins += 1) {
        switch (lb.take()) {
            .query => |q| break q,
            .failed => return error.LoopbackFailed,
            .waiting => std.Io.sleep(io, .fromMicroseconds(1000), .awake) catch {},
        }
    } else return error.NoCode;
    defer a.free(query);
    const code = try decode(a, queryParam(query, "code").?);
    defer a.free(code);
    try std.testing.expectEqualStrings("4/0Ab-xyz", code);
}

test "a listener with a page serves it to a bare GET and still takes the redirect" {
    if (builtin.target.cpu.arch == .wasm32) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const pkce = Pkce.generate(io);
    const lb = try Loopback.start(a, io, pkce.state, .{ .page = "<p>pick</p>", .done_page = "<p>picked</p>" });
    defer lb.stop();
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    const root = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/", .{lb.port()});
    defer a.free(root);
    var body: std.Io.Writer.Allocating = .init(a);
    defer body.deinit();
    const res = try client.fetch(.{ .location = .{ .url = root }, .response_writer = &body.writer });
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("<p>pick</p>", body.written());
    try std.testing.expectEqual(Loopback.Outcome.waiting, lb.take());

    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/?state={s}&id=f1&name=My%20Folder", .{ lb.port(), &pkce.state });
    defer a.free(url);
    var done: std.Io.Writer.Allocating = .init(a);
    defer done.deinit();
    _ = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &done.writer });
    try std.testing.expectEqualStrings("<p>picked</p>", done.written());
    var spins: usize = 0;
    while (spins < 5000) : (spins += 1) {
        switch (lb.take()) {
            .query => |q| {
                defer a.free(q);
                try std.testing.expectEqualStrings("f1", queryParam(q, "id").?);
                const name = try decode(a, queryParam(q, "name").?);
                defer a.free(name);
                try std.testing.expectEqualStrings("My Folder", name);
                return;
            },
            .failed => return error.LoopbackFailed,
            .waiting => std.Io.sleep(io, .fromMicroseconds(1000), .awake) catch {},
        }
    }
    return error.NoQuery;
}

test "stopping a listener nobody ever connected to is clean" {
    if (builtin.target.cpu.arch == .wasm32) return error.SkipZigTest;
    const io = std.testing.io;
    const pkce = Pkce.generate(io);
    const lb = try Loopback.start(std.testing.allocator, io, pkce.state, .{});
    lb.stop();
}

test "an idle connection before the redirect does not consume the listener" {
    if (builtin.target.cpu.arch == .wasm32) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const pkce = Pkce.generate(io);
    const lb = try Loopback.start(a, io, pkce.state, .{});
    defer lb.stop();
    // A speculative connection that says nothing and goes away, then a favicon request.
    const idle = try lb.server.socket.address.connect(io, .{ .mode = .stream });
    idle.close(io);
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    const fav = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/favicon.ico", .{lb.port()});
    defer a.free(fav);
    var sink: std.Io.Writer.Allocating = .init(a);
    defer sink.deinit();
    const r = try client.fetch(.{ .location = .{ .url = fav }, .response_writer = &sink.writer });
    try std.testing.expectEqual(std.http.Status.not_found, r.status);
    try std.testing.expectEqual(Loopback.Outcome.waiting, lb.take());
    // The real redirect still lands.
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/?state={s}&code=abc", .{ lb.port(), &pkce.state });
    defer a.free(url);
    var page: std.Io.Writer.Allocating = .init(a);
    defer page.deinit();
    _ = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &page.writer });
    var spins: usize = 0;
    while (spins < 5000) : (spins += 1) {
        switch (lb.take()) {
            .query => |q| {
                defer a.free(q);
                try std.testing.expectEqualStrings("abc", queryParam(q, "code").?);
                return;
            },
            .failed => return error.LoopbackFailed,
            .waiting => std.Io.sleep(io, .fromMicroseconds(1000), .awake) catch {},
        }
    }
    return error.NoCode;
}

test "a redirect with the wrong state is refused" {
    if (builtin.target.cpu.arch == .wasm32) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const pkce = Pkce.generate(io);
    const lb = try Loopback.start(a, io, pkce.state, .{});
    defer lb.stop();
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/?state=forged&code=abc", .{lb.port()});
    defer a.free(url);
    var page: std.Io.Writer.Allocating = .init(a);
    defer page.deinit();
    _ = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &page.writer });
    try std.testing.expect(std.mem.indexOf(u8, page.written(), "did not complete") != null);
    var spins: usize = 0;
    while (spins < 5000) : (spins += 1) {
        switch (lb.take()) {
            .failed => return,
            .query => return error.AcceptedForgedState,
            .waiting => std.Io.sleep(io, .fromMicroseconds(1000), .awake) catch {},
        }
    }
    return error.NeverFailed;
}
