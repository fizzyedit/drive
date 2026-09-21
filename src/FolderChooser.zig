//! "Open Google Drive folder…": a dialog that walks the drive's folders — through the host's
//! file table, so it lists exactly what the explorer would — and opens the chosen one as the
//! root. Works the same natively and on the web, and needs no Google Picker (which is web-only
//! and wants an API key of its own).
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");

/// The folder being browsed, within the mount (`/`-rooted). Owned; empty means closed.
var current: []u8 = &.{};
var prefix: []u8 = &.{};

pub fn open(mount_prefix: []const u8) void {
    const gpa = sdk.allocator();
    close();
    prefix = gpa.dupe(u8, mount_prefix) catch return;
    current = gpa.dupe(u8, "/") catch return;
    var mutex = core.dialogs.dialog(@src(), .{
        .displayFn = display,
        .callafterFn = callAfter,
        .title = "Open Google Drive folder",
        .ok_label = "",
        .cancel_label = "",
        .hide_footer = true,
        .default = .cancel,
        .max_size = .{ .w = 520, .h = 480 },
    });
    mutex.mutex.unlock(dvui.io);
}

fn close() void {
    const gpa = sdk.allocator();
    if (current.len != 0) gpa.free(current);
    if (prefix.len != 0) gpa.free(prefix);
    current = &.{};
    prefix = &.{};
}

fn callAfter(_: dvui.Id, _: dvui.enums.DialogResponse) anyerror!void {
    close();
}

fn fullPath(arena: std.mem.Allocator, rel: []const u8) ![]u8 {
    if (rel.len <= 1) return arena.dupe(u8, prefix);
    return std.mem.concat(arena, u8, &.{ prefix, rel });
}

fn display(_: dvui.Id) anyerror!bool {
    const gpa = sdk.allocator();
    const arena = dvui.currentWindow().arena();
    const files = sdk.host().files orelse return false;
    if (prefix.len == 0) return false;

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(8) });
    defer outer.deinit();

    // Where we are, as breadcrumbs: the mount, then each segment; any of them navigates up.
    {
        var crumbs = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer crumbs.deinit();
        const mount_name = prefix[(std.mem.indexOf(u8, prefix, "://") orelse 0) + 3 ..];
        if (dvui.button(@src(), mount_name, .{ .draw_focus = false }, .{ .font = dvui.Font.theme(.mono), .padding = dvui.Rect.all(2) })) {
            navigate("/");
        }
        var it = core.vfs.path.segments(current);
        var upto: usize = 0;
        var i: usize = 0;
        while (it.next()) |seg| : (i += 1) {
            upto += 1 + seg.len; // the "/" and the segment
            dvui.labelNoFmt(@src(), "/", .{}, .{ .id_extra = i, .gravity_y = 0.5, .padding = dvui.Rect.all(0) });
            if (dvui.button(@src(), seg, .{ .draw_focus = false }, .{ .id_extra = i, .font = dvui.Font.theme(.mono), .padding = dvui.Rect.all(2) })) {
                const target = gpa.dupe(u8, current[0..upto]) catch break;
                defer gpa.free(target);
                navigate(target);
            }
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 6 } });

    // The subfolders. The table answers from its cache, or asks the drive and answers null
    // until the listing lands on a later frame.
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .min_size_content = .{ .w = 480, .h = 300 } });
        defer scroll.deinit();
        const full = try fullPath(arena, current);
        if (files.listDir(full)) |listing| {
            if (listing.dir_count == 0) {
                dvui.labelNoFmt(@src(), "No folders here.", .{}, .{ .color_text = .{ .color = dvui.themeGet().color(.control, .text) } });
            }
            for (listing.entries[0..listing.dir_count], 0..) |e, i| {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal });
                defer row.deinit();
                core.icon.icon(@src(), "folder", dvui.entypo.folder, .{ .fill_color = .{ .color = dvui.themeGet().color(.control, .text) } }, .{ .gravity_y = 0.5, .min_size_content = .{ .h = 14 } });
                if (dvui.button(@src(), e.name, .{ .draw_focus = false }, .{ .expand = .horizontal, .background = false, .padding = dvui.Rect.all(3) })) {
                    const target = core.vfs.path.join(gpa, current, e.name) catch break;
                    defer gpa.free(target);
                    navigate(target);
                }
            }
        } else {
            dvui.labelNoFmt(@src(), "Loading…", .{}, .{ .color_text = .{ .color = dvui.themeGet().color(.control, .text) } });
            dvui.refresh(null, @src(), null);
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 1, .h = 8 } });

    var buttons = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer buttons.deinit();
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    if (dvui.button(@src(), "Cancel", .{}, .{})) {
        return true;
    }
    const label = std.fmt.allocPrint(arena, "Open {s}", .{if (current.len <= 1) "My Drive" else core.vfs.path.basename(current)}) catch "Open";
    if (dvui.button(@src(), label, .{}, .{ .style = .highlight })) {
        const full = try fullPath(arena, current);
        sdk.host().setProjectFolder(full) catch |err| dvui.log.warn("drive: could not open {s}: {t}", .{ full, err });
        return true;
    }
    return false;
}

fn navigate(rel: []const u8) void {
    const gpa = sdk.allocator();
    const copy = gpa.dupe(u8, rel) catch return;
    if (current.len != 0) gpa.free(current);
    current = copy;
}
