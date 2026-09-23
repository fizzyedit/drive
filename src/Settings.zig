//! The Drive plugin's user settings. The app's OAuth clients are not here — they are the
//! publisher's, baked in from `credentials.zon` at build time — and neither is the refresh
//! token, which lives in the host's secret store. What is left is what a user might actually
//! want to change.
const sdk = @import("fizzy_sdk");
const settings = sdk.settings;

root_folder_id: settings.Value([]const u8, .{
    .name = "Root folder id",
    .description = "The Drive folder that appears as the mount's root. \"root\" is My Drive, which is what signing in mounts; another id re-roots the mount at that folder.",
}) = .init("root"),

root_folder_name: settings.Value([]const u8, .{
    .name = "Root folder name",
    .description = "The root folder's name when it is not My Drive, which names the mount: gdrive://<account>/<name>.",
}) = .init(""),

account: settings.Value([]const u8, .{
    .name = "Account",
    .description = "The signed-in account's email, which names the mount: gdrive://<account>.",
}) = .init(""),
