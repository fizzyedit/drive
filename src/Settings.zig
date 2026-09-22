//! The Drive plugin's user settings. The app's OAuth clients are not here — they are the
//! publisher's, baked in from `credentials.zon` at build time — and neither is the refresh
//! token, which lives in the host's secret store. What is left is what a user might actually
//! want to change.
const sdk = @import("fizzy_sdk");
const settings = sdk.settings;

root_folder_id: settings.Value([]const u8, .{
    .name = "Root folder id",
    .description = "The Drive folder that appears as the mount's root: \"root\" is My Drive; otherwise the folder chosen with Open Google Drive Folder….",
}) = .init("root"),

root_folder_name: settings.Value([]const u8, .{
    .name = "Root folder name",
    .description = "The chosen folder's name, which names the mount: gdrive://<account>/<name>.",
}) = .init(""),

account: settings.Value([]const u8, .{
    .name = "Account",
    .description = "The signed-in account's email, which names the mount: gdrive://<account>.",
}) = .init(""),

full_drive_scope: settings.Value(bool, .{
    .name = "Access the whole Drive",
    .description = "Ask Google for access to every file instead of only the folders you pick. " ++
        "Google treats this as a restricted scope: a build asking for it can only sign in accounts " ++
        "added as testers on the Cloud project it was built with, until that project passes " ++
        "Google's verification and security assessment. Off means the folder picker decides what " ++
        "this plugin can see.",
}) = .init(false),
