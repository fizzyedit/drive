//! The Google Drive plugin: sign in, and the drive is a folder in the explorer.
//!
//! Everything file-shaped is someone else's: `core.drive.Client` speaks Drive's REST,
//! `core.transport` moves bytes, and `Host.mount` puts the result in the tree beside the disk,
//! where the workbench, the text editor, search and the files service already work on it. What
//! is left for this plugin is exactly the part only it can own — the account: getting a token,
//! keeping it fresh, and naming the mount after whoever signed in.
//!
//! Two sign-ins, one shape. Native: Google's desktop flow — PKCE, the system browser, a
//! loopback listener for the code, a token exchange, and a refresh token kept in settings so
//! the next launch signs in silently. Web: Google Identity Services' token client (Google will
//! not exchange a code from a browser without a secret), which hands over an hour's access
//! token and is asked again, silently, before it runs out. Both end in the same place:
//! `mount("gdrive://<email>")`.
const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const core = @import("core");
const Settings = @import("src/Settings.zig");
const oauth = @import("src/oauth.zig");
const drive = @import("src/drive.zig");
/// The app's OAuth clients, baked in at build time (see `credentials.zon.example`).
const credentials = @import("credentials.zon");
const icons = @import("icons");
/// Google's Picker wants an API key beside the token. Older `credentials.zon` files predate
/// the field; without it the folder picker says so instead of opening.
const api_key: []const u8 = if (@hasField(@TypeOf(credentials), "api_key")) credentials.api_key else "";
/// The Cloud project number, which the Picker sends as `setAppId`. Under `drive.file` that call
/// is what hands this app the folder the user picked: without it the picker returns an id the
/// app is not allowed to open. Older `credentials.zon` files predate the field.
const project_number: []const u8 = if (@hasField(@TypeOf(credentials), "project_number")) credentials.project_number else "";
/// Google's own folder picker, run in the browser: served by the loopback listener on the
/// desktop, shipped beside the web app (`web/` is copied by fizzy's web build).
const picker_page = @embedFile("web/picker.html");

const vfs = core.vfs;
const is_wasm = builtin.target.cpu.arch == .wasm32;

pub const plugin_options = @import("fizzy_plugin_options");
pub const plugin_id = plugin_options.id;

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_id,
    .display_name = plugin_options.name,
};

const vtable: sdk.Plugin.VTable = .{
    .deinit = deinit,
    .initPlugin = initPlugin,
    .beginFrame = beginFrame,
    .needsContinuousRepaint = needsContinuousRepaint,
};

const Schema = sdk.settings.Schema(Settings);

/// Google's own error pages (an account that is not a listed tester, a dismissed consent
/// prompt) never redirect back to the loopback, so without a limit that state is forever.
const sign_in_timeout_ms: i64 = 5 * 60 * 1000;

/// How often the mount asks Drive what changed. Drive's own change feed is what a folder
/// watcher is for the disk; a few seconds is fine for edits made elsewhere to show up.
const poll_interval_ms: i64 = 5000;

const State = struct {
    settings: Settings = .{},
    native_transport: if (is_wasm) void else core.transport.Native = if (is_wasm) {} else undefined,
    transport: vfs.http.Transport = undefined,
    /// Set by `initPlugin`. Nothing that needs `dvui.io` may run before: in a dylib, `register`
    /// runs before the host injects it.
    ready: bool = false,

    phase: Phase = .signed_out,
    /// The desktop flow's listener while a browser tab is open. Native only.
    loopback: if (is_wasm) void else ?*oauth.Loopback = if (is_wasm) {} else null,
    /// The folder picker's listener while its browser tab is open. Native only.
    picker: if (is_wasm) void else ?*oauth.Loopback = if (is_wasm) {} else null,
    /// The nonce the picker's reply must echo (both targets). Owned.
    picker_state: []u8 = &.{},
    pkce: if (is_wasm) void else oauth.Pkce = if (is_wasm) {} else undefined,
    /// Web: the `state` the implicit flow must echo. Owned.
    web_state: []u8 = &.{},
    /// The one request this plugin has in flight (exchange, refresh, or the account probe).
    pending: ?vfs.http.Job = null,

    /// Boot-clock ms when the browser was opened; a sign-in nobody finishes is abandoned
    /// after `sign_in_timeout_ms` so the option comes back on its own.
    awaiting_since_ms: i64 = 0,
    access_token: []u8 = &.{},
    /// Boot-clock ms after which `access_token` is no longer trusted.
    expires_at_ms: i64 = 0,
    account: []u8 = &.{},
    /// `gdrive://<account>` while mounted. Owned.
    prefix: []u8 = &.{},
    client: ?*drive.Client = null,
    /// The `changes.list` poll: when it last ran, and whether one is in flight.
    last_poll_ms: i64 = 0,
    poll: ?vfs.Job = null,
    /// The account's profile picture, once fetched. Owned pixels (freed with the source).
    avatar: ?dvui.ImageSource = null,
    avatar_job: ?vfs.http.Job = null,

    const Phase = enum {
        signed_out,
        /// Native: the browser is open, the loopback is waiting for the code.
        awaiting_code,
        /// A token request is in flight (exchange or refresh).
        token,
        /// Token in hand; asking Drive who this is.
        account,
        mounted,
    };
};

pub fn register(host: *sdk.Host) !void {
    const gpa = host.allocator;
    const st = try gpa.create(State);
    errdefer gpa.destroy(st);
    st.* = .{};
    plugin.state = @ptrCast(st);

    try host.registerPlugin(&plugin);
    try Schema.register(host, &plugin, .{ .title = "Google Drive", .value = &st.settings });

    try host.registerCommand(.{
        .id = sdk.Plugin.commandId(plugin_id, "sign_in"),
        .owner = &plugin,
        .title = "Connect Google Drive…",
        .run = cmdSignIn,
        .isEnabled = cmdSignInEnabled,
        .icon = icons.tvg.lucide.@"log-in",
    });
    try host.registerCommand(.{
        .id = sdk.Plugin.commandId(plugin_id, "open"),
        .owner = &plugin,
        .title = "Open Drive",
        .run = cmdOpen,
        .isEnabled = cmdOpenEnabled,
        .icon = icons.tvg.lucide.@"hard-drive",
    });
    try host.registerCommand(.{
        .id = sdk.Plugin.commandId(plugin_id, "open_folder"),
        .owner = &plugin,
        .title = "Open Drive Folder",
        .run = cmdOpenFolder,
        .isEnabled = cmdMounted,
        .icon = icons.tvg.lucide.@"folder-open",
    });
    try host.registerCommand(.{
        .id = sdk.Plugin.commandId(plugin_id, "sign_out"),
        .owner = &plugin,
        .title = "Disconnect Google Drive",
        .run = cmdSignOut,
        .isEnabled = cmdSignOutEnabled,
        .icon = icons.tvg.lucide.@"log-out",
    });
    try host.registerOpenAction(.{
        .id = "drive.open_folder",
        .owner = &plugin,
        .title = "Open Drive Folder",
        .command = sdk.Plugin.commandId(plugin_id, "open_folder"),
        .sf_symbol = "folder.badge.gearshape",
    });
    try host.registerAccountProvider(.{
        .id = "drive.google",
        .name = "Google Drive",
        .owner = &plugin,
        .ctx = st,
        .vtable = &account_vtable,
    });
    try host.registerMenuSection(.{
        .id = "drive.menu.file_section",
        .parent_menu_id = "fizzy.menu.file",
        .owner = &plugin,
        .draw = drawFileMenuSection,
    });
    if (!is_wasm) {
        try host.registerNativeMenuItem(.{
            .id = "drive.native.open_folder",
            .owner = &plugin,
            .parent_menu_id = "fizzy.menu.file",
            .title = "Open Drive Folder",
            .command = sdk.Plugin.commandId(plugin_id, "open_folder"),
            .run = nativeOpenFolder,
        });
        try host.registerNativeMenuItem(.{
            .id = "drive.native.sign_in",
            .owner = &plugin,
            .parent_menu_id = "fizzy.menu.file",
            .title = "Connect Google Drive…",
            .command = sdk.Plugin.commandId(plugin_id, "sign_in"),
            .run = nativeSignIn,
        });
    }

}

/// After the host injected its dvui globals: the transport (which keeps `dvui.io`), and the
/// silent sign-in a saved refresh token allows.
fn initPlugin(ptr: *anyopaque) anyerror!void {
    const st = stateOf(ptr);
    if (st.ready) return;
    const gpa = sdk.allocator();
    if (!is_wasm) {
        st.native_transport = core.transport.Native.init(gpa, dvui.io, wakeHost);
        st.transport = st.native_transport.transport();
    } else {
        st.transport = core.transport.Web.transport(gpa);
    }
    st.ready = true;

    // A saved refresh token (the host's secret store) means the user signed in before: pick
    // up where they left off.
    if (!is_wasm and refreshToken(st).len != 0) startRefresh(st);
}

pub fn pluginPtr() *sdk.Plugin {
    return &plugin;
}

test {
    _ = @import("src/drive.zig");
    _ = @import("src/oauth.zig");
}

fn stateOf(ptr: *anyopaque) *State {
    return @ptrCast(@alignCast(ptr));
}

fn deinit(ptr: *anyopaque) void {
    const st = stateOf(ptr);
    const gpa = sdk.allocator();
    signOut(st, false);
    if (!is_wasm and st.ready) st.native_transport.deinit();
    Schema.deinit(&st.settings);
    gpa.destroy(st);
}

fn wakeHost() void {
    sdk.refresh();
}

const secret_refresh_token = "drive.refresh_token";

/// The saved refresh token, from the host's secret store.
fn refreshToken(_: *State) []const u8 {
    return sdk.host().getSecret(secret_refresh_token) orelse "";
}

fn storeRefreshToken(value: []const u8) void {
    sdk.host().setSecret(secret_refresh_token, value) catch |err| {
        dvui.log.warn("drive: could not store the refresh token: {t}", .{err});
    };
}

/// `drive.file` — the files and folders the user hands over, and nothing else.
///
/// The whole drive (`scope_full`) is a *restricted* scope: publishing with it means Google's
/// verification and an annual third-party security assessment, and until that is done a build
/// can only be used by accounts added by hand as testers. `drive.file` is non-sensitive, so an
/// app asking only for it publishes without review — and the picker, which now exists on the
/// desktop as well as the web, is how the user says which folder they mean. That was the
/// argument for full scope when this was written; it no longer holds.
///
/// Whole-drive access is still available to anyone who wants it and can be a tester on their own
/// Cloud project: `full_drive_scope` in the plugin's settings.
fn scopeOf(st: *State) []const u8 {
    return if (st.settings.full_drive_scope.get()) oauth.scope_full else oauth.scope_file;
}

fn nowMs() i64 {
    return @intCast(@divTrunc(std.Io.Clock.boot.now(dvui.io).nanoseconds, std.time.ns_per_ms));
}

// ---- commands and menu ----------------------------------------------------------------------

fn cmdSignIn(ptr: *anyopaque) anyerror!void {
    signIn(stateOf(ptr));
}
fn cmdSignInEnabled(ptr: *anyopaque) bool {
    // Also while a browser tab is open: choosing Connect again abandons that attempt and
    // starts over, which is what someone whose first try ended on a Google error page wants.
    const phase = stateOf(ptr).phase;
    return phase == .signed_out or phase == .awaiting_code;
}
fn cmdSignOut(ptr: *anyopaque) anyerror!void {
    signOut(stateOf(ptr), true);
}
fn cmdSignOutEnabled(ptr: *anyopaque) bool {
    return stateOf(ptr).phase != .signed_out;
}
fn cmdOpen(ptr: *anyopaque) anyerror!void {
    openAsRoot(stateOf(ptr));
}
fn cmdOpenEnabled(ptr: *anyopaque) bool {
    const st = stateOf(ptr);
    return st.phase == .mounted and !rootIsDrive(st);
}
fn cmdOpenFolder(ptr: *anyopaque) anyerror!void {
    openPicker(stateOf(ptr));
}
fn cmdMounted(ptr: *anyopaque) bool {
    return stateOf(ptr).phase == .mounted;
}

/// Whether the open folder is this drive.
fn rootIsDrive(st: *State) bool {
    const f = sdk.host().folder() orelse return false;
    return st.prefix.len != 0 and std.mem.startsWith(u8, f, st.prefix) and (f.len == st.prefix.len or f[st.prefix.len] == '/');
}

/// Make the whole drive the open root — after the user closed it, opened something else, or
/// had a folder of it open (the mount is re-rooted at My Drive).
fn openAsRoot(st: *State) void {
    if (st.phase != .mounted) return;
    if (!std.mem.eql(u8, st.settings.root_folder_id.get(), "root")) return remount(st, "root", "");
    sdk.host().setProjectFolder(st.prefix) catch |err| dvui.log.warn("drive: could not open {s}: {t}", .{ st.prefix, err });
}

fn nativeOpenFolder(_: ?*anyopaque) anyerror!void {
    openPicker(stateOf(plugin.state));
}
fn nativeSignIn(_: ?*anyopaque) anyerror!void {
    signIn(stateOf(plugin.state));
}

fn drawFileMenuSection(_: ?*anyopaque) anyerror!void {
    const st = stateOf(plugin.state);
    const host = sdk.host();
    if (st.phase == .signed_out) {
        if (host.drawMenuItem("Connect Google Drive…", sdk.Plugin.commandId(plugin_id, "sign_in"))) signIn(st);
    } else if (st.phase == .awaiting_code) {
        if (host.drawMenuItem("Connect Google Drive… (retry)", sdk.Plugin.commandId(plugin_id, "sign_in"))) signIn(st);
        if (host.drawMenuItem("Cancel Google sign-in", sdk.Plugin.commandId(plugin_id, "sign_out"))) signOut(st, false);
    } else {
        const label = std.fmt.allocPrint(host.arena(), "Disconnect Google Drive ({s})", .{
            if (st.account.len != 0) st.account else "signing in…",
        }) catch "Disconnect Google Drive";
        if (host.drawMenuItem(label, sdk.Plugin.commandId(plugin_id, "sign_out"))) signOut(st, true);
    }
}

// ---- the per-frame tick ---------------------------------------------------------------------

fn beginFrame(ptr: *anyopaque) void {
    const st = stateOf(ptr);
    if (!st.ready) return;
    // Own requests land here; once mounted the table pumps the same transport too, which is
    // harmless — a completion is delivered once.
    st.transport.pump();
    if (is_wasm) core.transport.WebOAuth.pump();

    if (!is_wasm) pollPicker(st);
    if (!is_wasm and st.phase == .awaiting_code) {
        pollLoopback(st);
        if (st.phase == .awaiting_code and nowMs() - st.awaiting_since_ms > sign_in_timeout_ms) {
            signOut(st, false);
            complain("Google sign-in timed out; choose Connect Google Drive to try again.");
        }
    }

    // The watcher: what changed on Drive since last time, folded into the table's listings.
    if (st.phase == .mounted and st.poll == null and nowMs() - st.last_poll_ms > poll_interval_ms) {
        if (st.client) |client| {
            st.last_poll_ms = nowMs();
            st.poll = client.pollChanges(sdk.allocator(), onChanges, st) catch null;
        }
    }

    // Refresh ahead of expiry while mounted, so a listing never has to fail first — and at
    // once when one did anyway with a 401 (the token was revoked, or the clock was wrong),
    // rather than leaving the tree dead until the timer says so.
    var stale = st.expires_at_ms != 0 and nowMs() > st.expires_at_ms - 120_000;
    if (st.client) |client| {
        if (client.takeUnauthorized()) stale = true;
    }
    if (st.phase == .mounted and st.pending == null and stale) {
        if (is_wasm) requestWebToken(st, true) else startRefresh(st);
    }
}

fn needsContinuousRepaint(ptr: *anyopaque) bool {
    const st = stateOf(ptr);
    // Polling the loopback is the one thing nothing else wakes us for.
    return !is_wasm and st.phase == .awaiting_code;
}

// ---- sign in ----------------------------------------------------------------------------------

fn signIn(st: *State) void {
    if (!st.ready) return complain("Google Drive is still starting; try again in a moment.");
    // A retry while the previous browser tab is still open: drop that attempt first.
    if (st.phase == .awaiting_code) signOut(st, false);
    if (st.phase != .signed_out) return;
    if (is_wasm) {
        if (credentials.web_client_id.len == 0) return complain("This build of the Drive plugin has no web OAuth client configured.");
        st.phase = .token;
        requestWebToken(st, false);
        return;
    }
    if (credentials.client_id.len == 0) return complain("This build of the Drive plugin has no OAuth client configured.");
    startDesktopFlow(st) catch |err| {
        dvui.log.err("drive: could not start sign-in: {t}", .{err});
        complain("Could not start Google sign-in; see the log.");
    };
}

fn startDesktopFlow(st: *State) !void {
    if (is_wasm) return error.Unsupported;
    const gpa = sdk.allocator();
    st.pkce = oauth.Pkce.generate(dvui.io);
    const loopback = try oauth.Loopback.start(gpa, dvui.io, st.pkce.state, .{});
    errdefer loopback.stop();
    const url = try oauth.authUrl(gpa, credentials.client_id, scopeOf(st), loopback.port(), &st.pkce);
    defer gpa.free(url);
    if (!dvui.openURL(.{ .url = url })) return error.CouldNotOpenBrowser;
    st.loopback = loopback;
    st.phase = .awaiting_code;
    st.awaiting_since_ms = nowMs();
    dvui.toast(@src(), .{ .message = "Finish signing in to Google in your browser." });
}

fn pollLoopback(st: *State) void {
    if (is_wasm) return;
    const loopback = st.loopback orelse return;
    switch (loopback.take()) {
        .waiting => return,
        .failed => {
            loopback.stop();
            st.loopback = null;
            st.phase = .signed_out;
            complain("Google sign-in did not complete.");
        },
        .query => |query| {
            const gpa = sdk.allocator();
            defer gpa.free(query);
            const port = loopback.port();
            loopback.stop();
            st.loopback = null;
            const raw = oauth.queryParam(query, "code") orelse {
                st.phase = .signed_out;
                return complain("Google sign-in did not complete.");
            };
            const code = oauth.decode(gpa, raw) catch return fail(st, "out of memory");
            defer gpa.free(code);
            startExchange(st, code, port);
        },
    }
}

// ---- the folder picker ----------------------------------------------------------------------
//
// Google's Picker is a browser widget, so it runs in one: the web build opens it in the same
// popup sign-in uses, the desktop serves `web/picker.html` from a loopback listener and opens
// that in the system browser. Either way the page comes back with a folder id and name, and
// the mount is re-rooted there.

fn openPicker(st: *State) void {
    if (st.phase != .mounted) return;
    if (api_key.len == 0) return complain("Google's folder picker needs an API key: add .api_key to credentials.zon (README › Publisher setup, step 5) and rebuild the plugin.");
    const gpa = sdk.allocator();
    if (st.picker_state.len == 0) {
        var nonce: [24]u8 = undefined;
        dvui.io.random(&nonce);
        const buf = gpa.alloc(u8, 32) catch return;
        _ = std.base64.url_safe_no_pad.Encoder.encode(buf, &nonce);
        st.picker_state = buf;
    }
    if (is_wasm) {
        // The picker page travels with the plugin (it is embedded), opened as a same-origin
        // blob page with its needs in the fragment — nothing to serve beside the app.
        const hash = pickerUrl(gpa, "", st, "web") catch return;
        defer gpa.free(hash);
        core.transport.WebOAuth.beginPage(gpa, picker_page, hash[1..], onWebPicker, st) catch return complain("A Google window is already open.");
        return;
    }
    if (st.picker) |old| {
        old.stop();
        st.picker = null;
    }
    var state: [32]u8 = undefined;
    @memcpy(&state, st.picker_state[0..32]);
    const lb = oauth.Loopback.start(gpa, dvui.io, state, .{ .page = picker_page, .done_page = picker_done_page }) catch return complain("Could not start the folder picker.");
    var page_buf: [40]u8 = undefined;
    const page = std.fmt.bufPrint(&page_buf, "http://127.0.0.1:{d}/", .{lb.port()}) catch unreachable;
    const url = pickerUrl(gpa, page, st, "loopback") catch {
        lb.stop();
        return;
    };
    defer gpa.free(url);
    if (!dvui.openURL(.{ .url = url })) {
        lb.stop();
        return complain("Could not open your browser for the folder picker.");
    }
    st.picker = lb;
    dvui.toast(@src(), .{ .message = "Choose a folder in your browser." });
}

/// `<page>#token=…&key=…&state=…&mode=…` — the fragment, which no server is sent.
fn pickerUrl(gpa: std.mem.Allocator, page: []const u8, st: *State, mode: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, page);
    try out.appendSlice(gpa, "#token=");
    try oauth.appendEncoded(gpa, &out, st.access_token);
    try out.appendSlice(gpa, "&key=");
    try oauth.appendEncoded(gpa, &out, api_key);
    try out.appendSlice(gpa, "&state=");
    try out.appendSlice(gpa, st.picker_state);
    try out.appendSlice(gpa, "&mode=");
    try out.appendSlice(gpa, mode);
    try out.appendSlice(gpa, "&app=");
    try oauth.appendEncoded(gpa, &out, project_number);
    return out.toOwnedSlice(gpa);
}

fn pollPicker(st: *State) void {
    if (is_wasm) return;
    const lb = st.picker orelse return;
    switch (lb.take()) {
        .waiting => return,
        .failed => {
            lb.stop();
            st.picker = null;
            complain("The folder picker did not complete.");
        },
        .query => |query| {
            defer sdk.allocator().free(query);
            lb.stop();
            st.picker = null;
            onPicked(st, query);
        },
    }
}

fn onWebPicker(ctx: ?*anyopaque, result: ?[]u8) void {
    if (!is_wasm) return;
    const st: *State = @ptrCast(@alignCast(ctx.?));
    const text = result orelse return;
    defer sdk.allocator().free(text);
    const query = if (std.mem.startsWith(u8, text, "?")) text[1..] else text;
    if (!std.mem.eql(u8, oauth.queryParam(query, "state") orelse "", st.picker_state)) return complain("The folder picker's reply did not match the request.");
    onPicked(st, query);
}

/// The picker's reply: `id` + `name` re-root the mount there; `cancel` is nothing.
fn onPicked(st: *State, query: []const u8) void {
    const gpa = sdk.allocator();
    const id = oauth.queryParam(query, "id") orelse return;
    const raw_name = oauth.queryParam(query, "name") orelse "";
    const name = oauth.decode(gpa, raw_name) catch return;
    defer gpa.free(name);
    const id_dec = oauth.decode(gpa, id) catch return;
    defer gpa.free(id_dec);
    remount(st, id_dec, name);
}

const picker_done_page =
    \\<!doctype html><meta charset="utf-8"><title>fizzy</title>
    \\<body style="font-family:system-ui;background:#1d2029;color:#e6e6e6;display:grid;place-items:center;height:100vh;margin:0">
    \\<div style="text-align:center"><h1>Folder chosen</h1><p>You can close this tab and return to fizzy.</p></div>
;

/// Tear the mount down and bring it up again rooted at `folder_id` (`"root"` for My Drive),
/// which becomes the open folder. The account and token stay; only the mount changes — and
/// with it the prefix, so a folder's files are `gdrive://<account>/<folder>/…`.
fn remount(st: *State, folder_id: []const u8, folder_name: []const u8) void {
    if (st.phase != .mounted) return;
    const gpa = sdk.allocator();
    const email = gpa.dupe(u8, st.account) catch return;
    defer gpa.free(email);
    setSetting(st, "root_folder_id", folder_id);
    setSetting(st, "root_folder_name", folder_name);
    if (st.poll) |job| {
        if (st.client) |client| client.fs().cancel(job);
        st.poll = null;
    }
    if (st.client) |client| {
        sdk.host().unmount(st.prefix);
        client.deinit();
        gpa.destroy(client);
        st.client = null;
    }
    if (st.prefix.len != 0) gpa.free(st.prefix);
    st.prefix = &.{};
    st.phase = .account;
    mountDrive(st, email, true) catch |err| {
        dvui.log.err("drive: mount failed: {t}", .{err});
        fail(st, "could not mount the drive");
    };
}

fn startExchange(st: *State, code: []const u8, port: u16) void {
    if (is_wasm) return;
    const gpa = sdk.allocator();
    const body = oauth.exchangeBody(gpa, credentials.client_id, credentials.client_secret, code, port, &st.pkce) catch return fail(st, "out of memory");
    st.phase = .token;
    postForm(st, oauth.token_endpoint, body, onToken);
}

fn startRefresh(st: *State) void {
    if (is_wasm) return;
    const gpa = sdk.allocator();
    const body = oauth.refreshBody(gpa, credentials.client_id, credentials.client_secret, refreshToken(st)) catch return fail(st, "out of memory");
    if (st.phase == .signed_out) st.phase = .token;
    postForm(st, oauth.token_endpoint, body, onToken);
}

/// A form POST whose body the transport copies; freed here once it has.
fn postForm(st: *State, url: []const u8, body: []u8, cb: vfs.http.DoneFn) void {
    const gpa = sdk.allocator();
    defer gpa.free(body);
    st.pending = st.transport.request(gpa, .{
        .method = .POST,
        .url = url,
        .headers = &.{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }},
        .body = body,
    }, cb, st) catch |err| {
        dvui.log.err("drive: request failed to start: {t}", .{err});
        return fail(st, "could not reach Google");
    };
}

fn onToken(ctx: ?*anyopaque, result: vfs.Error!vfs.http.Response) void {
    const st: *State = @ptrCast(@alignCast(ctx.?));
    st.pending = null;
    const gpa = sdk.allocator();
    const resp = result catch |err| {
        dvui.log.err("drive: token request failed: {t}", .{err});
        return fail(st, "could not reach Google");
    };
    defer resp.deinit(gpa);
    const parsed = oauth.parseToken(gpa, resp.body) catch return fail(st, "unexpected reply from Google");
    defer parsed.deinit();
    if (resp.status != 200 or parsed.value.access_token.len == 0) {
        dvui.log.err("drive: token request: HTTP {d} {s}: {s}", .{ resp.status, parsed.value.@"error" orelse "", parsed.value.error_description orelse "" });
        if (resp.status == 400 or resp.status == 401) {
            // A refresh token Google no longer honours is not worth keeping, and a mount it
            // can no longer refresh is not worth keeping up.
            storeRefreshToken("");
            signOut(st, false);
            return complain("Google Drive: the saved sign-in is no longer valid; connect again.");
        }
        return fail(st, "Google refused the sign-in");
    }
    setToken(st, parsed.value.access_token, parsed.value.expires_in);
    if (parsed.value.refresh_token) |rt| storeRefreshToken(rt);
    afterToken(st);
}

fn setToken(st: *State, token: []const u8, expires_in: i64) void {
    const gpa = sdk.allocator();
    const copy = gpa.dupe(u8, token) catch return;
    if (st.access_token.len != 0) gpa.free(st.access_token);
    st.access_token = copy;
    st.expires_at_ms = nowMs() + expires_in * 1000;
    if (st.client) |c| c.access_token = st.access_token;
}

/// Token in hand. Mounted already (a refresh) → nothing more; otherwise find out whose drive.
fn afterToken(st: *State) void {
    if (st.phase == .mounted) return;
    st.phase = .account;
    const gpa = sdk.allocator();
    var auth_buf: [2100]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{st.access_token}) catch return fail(st, "token too long");
    st.pending = st.transport.request(gpa, .{
        .method = .GET,
        .url = oauth.about_endpoint,
        .headers = &.{.{ .name = "Authorization", .value = auth }},
    }, onAbout, st) catch return fail(st, "could not reach Google");
}

fn onAbout(ctx: ?*anyopaque, result: vfs.Error!vfs.http.Response) void {
    const st: *State = @ptrCast(@alignCast(ctx.?));
    st.pending = null;
    const gpa = sdk.allocator();
    const resp = result catch return fail(st, "could not reach Google Drive");
    defer resp.deinit(gpa);
    if (resp.status != 200) {
        dvui.log.err("drive: about: HTTP {d}: {s}", .{ resp.status, resp.body });
        return fail(st, "Google Drive refused the token");
    }
    const parsed = oauth.parseAbout(gpa, resp.body) catch return fail(st, "unexpected reply from Google Drive");
    defer parsed.deinit();
    const email = parsed.value.user.emailAddress;
    if (email.len == 0) return fail(st, "Google did not say whose drive this is");
    mountDrive(st, email, false) catch |err| {
        dvui.log.err("drive: mount failed: {t}", .{err});
        return fail(st, "could not mount the drive");
    };
    if (parsed.value.user.photoLink) |link| fetchAvatar(st, link);
}

/// The profile picture is decoration: fetched after the mount is up, dropped on any failure
/// (the web build's `fetch` cannot read it cross-origin, for one), and the disc shows a
/// glyph until it lands.
fn fetchAvatar(st: *State, link: []const u8) void {
    if (st.avatar_job != null) return;
    const gpa = sdk.allocator();
    // A larger rendition than Google's default 64 px, sharp on a 2× rail.
    const url = std.fmt.allocPrint(gpa, "{s}{s}", .{ link, if (std.mem.indexOf(u8, link, "=s") != null) "" else "=s128" }) catch return;
    defer gpa.free(url);
    st.avatar_job = st.transport.request(gpa, .{ .method = .GET, .url = url }, onAvatar, st) catch null;
}

fn onAvatar(ctx: ?*anyopaque, result: vfs.Error!vfs.http.Response) void {
    const st: *State = @ptrCast(@alignCast(ctx.?));
    st.avatar_job = null;
    const gpa = sdk.allocator();
    const resp = result catch return;
    defer resp.deinit(gpa);
    if (resp.status != 200) return;
    dropAvatar(st);
    st.avatar = core.image.fromImageFileBytesAlloc(gpa, "drive-avatar", resp.body, .ptr) catch null;
    sdk.refresh();
}

fn dropAvatar(st: *State) void {
    if (st.avatar) |src| {
        if (src == .pixelsPMA) sdk.allocator().free(src.pixelsPMA.rgba);
    }
    st.avatar = null;
}

// ---- the account, as the host's rail disc shows it ----------------------------------------

const account_vtable: sdk.accounts.Provider.VTable = .{
    .accounts = providerAccounts,
    .signIn = providerSignIn,
    .menu = providerMenu,
};

fn providerAccounts(ctx: ?*anyopaque, arena: std.mem.Allocator) []const sdk.accounts.Account {
    const st: *State = @ptrCast(@alignCast(ctx.?));
    if (st.phase != .mounted) return &.{};
    const one = arena.alloc(sdk.accounts.Account, 1) catch return &.{};
    one[0] = .{ .id = st.account, .label = st.account, .avatar = st.avatar };
    return one;
}

fn providerSignIn(ctx: ?*anyopaque) void {
    const st: *State = @ptrCast(@alignCast(ctx.?));
    if (st.phase == .signed_out) signIn(st);
}

/// The account's submenu rows, drawn by the host (`Host.drawMenuItem`): a dylib's own dvui has
/// no open menu to put an item in. True when one was chosen.
fn providerMenu(ctx: ?*anyopaque, _: []const u8) bool {
    const st: *State = @ptrCast(@alignCast(ctx.?));
    const host = sdk.host();
    if (host.drawMenuItem("Open Drive Folder", sdk.Plugin.commandId(plugin_id, "open_folder"))) {
        openPicker(st);
        return true;
    }
    if (!rootIsDrive(st)) {
        if (host.drawMenuItem("Open Drive", sdk.Plugin.commandId(plugin_id, "open"))) {
            openAsRoot(st);
            return true;
        }
    }
    if (host.drawMenuItem("Sign out", sdk.Plugin.commandId(plugin_id, "sign_out"))) {
        signOut(st, true);
        return true;
    }
    return false;
}

fn mountDrive(st: *State, email: []const u8, open_it: bool) !void {
    const gpa = sdk.allocator();
    const account = try gpa.dupe(u8, email);
    errdefer gpa.free(account);
    // My Drive is `gdrive://<account>`; a picked folder is named after itself, so its paths
    // read like paths.
    const root_id = st.settings.root_folder_id.get();
    const root_name = st.settings.root_folder_name.get();
    const prefix = if (std.mem.eql(u8, root_id, "root") or root_name.len == 0)
        try std.fmt.allocPrint(gpa, "gdrive://{s}", .{email})
    else
        try std.fmt.allocPrint(gpa, "gdrive://{s}/{s}", .{ email, root_name });
    errdefer gpa.free(prefix);
    const client = try gpa.create(drive.Client);
    errdefer gpa.destroy(client);
    client.* = try drive.Client.init(gpa, st.transport, st.access_token, root_id);
    errdefer client.deinit();
    try sdk.host().mount(prefix, client.fs());

    if (st.account.len != 0) gpa.free(st.account);
    st.account = account;
    st.prefix = prefix;
    st.client = client;
    st.phase = .mounted;
    setSetting(st, "account", email);
    // Signing in only mounts (the explorer shows nothing until a drive folder is opened;
    // a recent gdrive path can now resolve). Opening a folder — the picker, Open Whole
    // Drive — makes it the root, replacing whatever was; it closes like any other root.
    if (open_it) sdk.host().setProjectFolder(prefix) catch |err| dvui.log.warn("drive: could not open {s} as the folder: {t}", .{ prefix, err });
    if (!open_it and std.mem.eql(u8, root_id, "root")) {
        const msg = std.fmt.allocPrint(sdk.host().arena(), "Google Drive connected as {s}.", .{email}) catch "Google Drive connected.";
        dvui.toast(@src(), .{ .message = msg });
    }
    sdk.refresh();
}

fn onChanges(ctx: ?*anyopaque, result: vfs.Error![][]u8) void {
    const st: *State = @ptrCast(@alignCast(ctx.?));
    st.poll = null;
    const gpa = sdk.allocator();
    const paths = result catch |err| {
        // Silent at frame rate would be a request storm; once a minute is a log line.
        dvui.log.warn("drive: changes poll failed: {t}", .{err});
        st.last_poll_ms = nowMs() + 60_000;
        return;
    };
    defer drive.Client.freeChanges(gpa, paths);
    const files = sdk.host().files orelse return;
    for (paths) |rel| {
        const full = std.mem.concat(gpa, u8, &.{ st.prefix, if (vfs.path.isRoot(rel)) "" else rel }) catch continue;
        defer gpa.free(full);
        // The listing of the path itself (a directory that changed) and its parent's (a file
        // that changed or went away).
        files.invalidateListing(full);
        if (std.fs.path.dirname(full)) |parent| files.invalidateListing(parent);
        files.invalidateIndex();
    }
    if (paths.len != 0) sdk.refresh();
}

/// Back to signed out. `forget` also drops the saved refresh token, which is what the user
/// means by "disconnect"; a failure mid-flow keeps it so the next launch can try again.
fn signOut(st: *State, forget: bool) void {
    const gpa = sdk.allocator();
    if (st.pending) |job| {
        st.transport.cancel(job);
        st.pending = null;
    }
    if (st.poll) |job| {
        if (st.client) |client| client.fs().cancel(job);
        st.poll = null;
    }
    if (!is_wasm) {
        if (st.loopback) |l| {
            l.stop();
            st.loopback = null;
        }
        if (st.picker) |l| {
            l.stop();
            st.picker = null;
        }
    }
    if (st.picker_state.len != 0) gpa.free(st.picker_state);
    st.picker_state = &.{};
    if (st.client) |client| {
        sdk.host().unmount(st.prefix);
        client.deinit();
        gpa.destroy(client);
        st.client = null;
    }
    if (st.prefix.len != 0) gpa.free(st.prefix);
    st.prefix = &.{};
    if (st.access_token.len != 0) gpa.free(st.access_token);
    st.access_token = &.{};
    st.expires_at_ms = 0;
    if (st.account.len != 0) gpa.free(st.account);
    st.account = &.{};
    if (st.web_state.len != 0) gpa.free(st.web_state);
    st.web_state = &.{};
    if (st.avatar_job) |job| {
        st.transport.cancel(job);
        st.avatar_job = null;
    }
    dropAvatar(st);
    if (is_wasm) core.transport.WebOAuth.cancel();
    st.phase = .signed_out;
    if (forget) {
        storeRefreshToken("");
        setSetting(st, "account", "");
        setSetting(st, "root_folder_id", "root");
        setSetting(st, "root_folder_name", "");
    }
    sdk.refresh();
}

fn fail(st: *State, what: []const u8) void {
    const msg = std.fmt.allocPrint(sdk.host().arena(), "Google Drive: {s}.", .{what}) catch "Google Drive: sign-in failed.";
    complain(msg);
    // A refresh that fails while mounted (the network, a 5xx) leaves the mount up with its old
    // token and is retried in a minute — not next frame, which was one token POST per frame.
    // Anything earlier in the flow starts over.
    if (st.phase == .mounted) {
        st.expires_at_ms = nowMs() + 120_000 + 60_000;
        return;
    }
    signOut(st, false);
}

fn complain(msg: []const u8) void {
    dvui.log.warn("drive: {s}", .{msg});
    dvui.toast(@src(), .{ .message = msg });
}

/// Write a string setting the schema's way — its own allocator, the default never freed — and
/// persist the plugin's settings.
fn setSetting(st: *State, comptime field: []const u8, value: []const u8) void {
    const gpa = sdk.allocator();
    const cell = &@field(st.settings, field);
    const copy = gpa.dupe(u8, value) catch return;
    // Owned unless it is exactly the declared default (see `sdk.settings` on ownership).
    const default_value = (Settings{});
    if (cell.v.ptr != @field(default_value, field).v.ptr) gpa.free(cell.v);
    cell.v = copy;
    Schema.store(sdk.host(), plugin_id, st.settings);
    sdk.host().markSettingsDirty();
}

// ---- web: the implicit flow through fizzy's generic OAuth popup --------------------------
//
// Google will not exchange a code from a browser without a client secret, so the web build
// uses the implicit grant: the popup lands on fizzy's `oauth-callback.html` with the access
// token in the fragment. Nothing Google-specific lives in fizzy for this; the popup helper is
// the same one any provider's plugin would use.

fn requestWebToken(st: *State, silent: bool) void {
    if (!is_wasm) return;
    const gpa = sdk.allocator();
    const redirect = core.transport.WebOAuth.callbackUrl(gpa) catch return fail(st, "no callback page");
    defer gpa.free(redirect);
    if (st.web_state.len == 0) {
        var nonce: [24]u8 = undefined;
        dvui.io.random(&nonce);
        const state_buf = gpa.alloc(u8, 32) catch return fail(st, "out of memory");
        _ = std.base64.url_safe_no_pad.Encoder.encode(state_buf, &nonce);
        st.web_state = state_buf;
    }
    const url = oauth.implicitAuthUrl(gpa, credentials.web_client_id, scopeOf(st), redirect, st.web_state, silent) catch return fail(st, "out of memory");
    defer gpa.free(url);
    core.transport.WebOAuth.begin(gpa, url, onWebOAuth, st) catch return fail(st, "a sign-in is already open");
}

fn onWebOAuth(ctx: ?*anyopaque, result: ?[]u8) void {
    if (!is_wasm) return;
    const st: *State = @ptrCast(@alignCast(ctx.?));
    const gpa = sdk.allocator();
    const text = result orelse return fail(st, "Google sign-in did not complete");
    defer gpa.free(text);
    const parsed = oauth.parseImplicit(text) orelse return fail(st, "Google refused the sign-in");
    if (!std.mem.eql(u8, parsed.state, st.web_state)) return fail(st, "sign-in reply did not match the request");
    setToken(st, parsed.access_token, parsed.expires_in);
    afterToken(st);
}
