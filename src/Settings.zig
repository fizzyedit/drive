//! The Drive plugin's settings. The OAuth client ids are the app's, not the user's — they are
//! public identifiers, and the defaults here are what a stock fizzy signs in with; a fork or a
//! self-hosted web build pastes its own. The refresh token and account are written by Sign In
//! and read back at the next launch; clearing the token is the same as signing out.
const sdk = @import("fizzy_sdk");
const settings = sdk.settings;

client_id: settings.Value([]const u8, .{
    .name = "OAuth client ID (desktop)",
    .description = "The Google Cloud OAuth client of type \"Desktop app\" that native fizzy signs in with.",
}) = .init(""),

/// Google issues one for desktop clients and requires it at the token exchange even though a
/// desktop app cannot keep it secret — its own docs say as much. It is not the user's secret.
client_secret: settings.Value([]const u8, .{
    .name = "OAuth client secret (desktop)",
    .description = "The desktop client's secret, which Google requires at the token exchange.",
    .secret = true,
}) = .init(""),

web_client_id: settings.Value([]const u8, .{
    .name = "OAuth client ID (web)",
    .description = "The Google Cloud OAuth client of type \"Web application\" the web build signs in with; its authorized origin must be where the page is served from.",
}) = .init(""),

/// `drive.file` (the default) needs no Google review to publish but only ever shows files
/// fizzy created or the user picked — and on the desktop there is no picker. The full scope
/// shows the whole drive; publishing an app that asks for it needs Google's verification, but
/// accounts listed as testers can use it meanwhile.
full_access: settings.Value(bool, .{
    .name = "Full Drive access",
    .description = "Ask for the whole drive (scope \"drive\") instead of only files fizzy created or you picked (\"drive.file\"). Sign out and in again after changing. Publishing with this on requires Google's app verification.",
}) = .init(false),

root_folder_id: settings.Value([]const u8, .{
    .name = "Root folder id",
    .description = "The Drive folder that appears as the mount's root. \"root\" is My Drive; a folder's id (from its URL) mounts just that folder.",
}) = .init("root"),

/// No longer written: the token lives in the host's secret store (`Host.setSecret`). Kept so a
/// value saved by an earlier build is found and moved over on load.
refresh_token: settings.Value([]const u8, .{
    .name = "Refresh token (legacy)",
    .description = "Older builds kept the refresh token here; it now lives in fizzy's private secret store and this is moved there on load.",
    .secret = true,
}) = .init(""),

account: settings.Value([]const u8, .{
    .name = "Account",
    .description = "The signed-in account's email, which names the mount: gdrive://<account>.",
}) = .init(""),
