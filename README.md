# Google Drive plugin

Sign in to Google Drive and it appears in the explorer as a folder (`gdrive://<account>`):
browse, open, edit, save, create, rename, delete, search — on the desktop and in the web build.

Users click **File › Connect Google Drive…**, sign in on Google's page, and are back in fizzy
with the drive mounted. Nothing below is for them. It is the **one-time registration of fizzy
as an app with Google**, done by whoever publishes fizzy; the result is two public client IDs
that become defaults in this plugin's settings.

This is an ordinary third-party plugin (the same shape as pixi): fizzy knows nothing about
Google. Natively it ships through the plugin store; the web build links it in because a
browser cannot load plugins at runtime (`web_plugin_dirs` in fizzy's `build.zig`).

## Install (development)

```sh
cd ~/dev/fizzyedit/drive
zig build          # → drive.dylib into fizzy's plugins dir
zig build test
```

Then in fizzy open the plugin store and press **Load** on *Google Drive* — a dropped-in plugin
is not run until it has been enabled once. Build modes must match: a Debug fizzy loads a
Debug plugin (`AbiBuildEnvMismatch` otherwise).

## Publisher setup (once, ~10 minutes)

All of it happens in the [Google Cloud console](https://console.cloud.google.com/).

### 1. A project

**Select a project › New project** — name it `fizzy` (anything works; users never see it).

### 2. Enable the Drive API and the Picker API

**APIs & Services › Library** → search *Google Drive API* → **Enable**. Without this every
call fails with "API not enabled". Then the same for *Google Picker API*: the folder chooser
(**Open Google Drive Folder…**) is Google's own picker.

### 3. The consent screen

**APIs & Services › OAuth consent screen** (or *Google Auth Platform › Branding* in the newer
console).

- User type: **External**.
- App name `fizzy`, your email as user-support and developer contact. Logo/links optional.
- **Scopes** → *Add or remove scopes* → tick `https://www.googleapis.com/auth/drive`
  ("See, edit, create, and delete all of your Google Drive files"). The plugin always asks
  for the whole drive — with the narrower `drive.file` a fresh sign-in shows an empty drive
  until every file has been picked one by one. It is a *restricted* scope: testers can use it
  as soon as it is added, and publishing to everyone later means Google's app verification.
- **Test users** → add your own Google account(s). While the app's *Publishing status* is
  **Testing**, only listed accounts can sign in (max 100). When it is time for strangers to
  use it, press **Publish app** — with only `drive.file` requested that takes effect
  immediately, no verification.

### 4. Two OAuth clients

**APIs & Services › Credentials › Create credentials › OAuth client ID**, twice:

| Client | Type | Settings | Goes into |
|---|---|---|---|
| desktop | **Desktop app** | none | `credentials.zon` → `client_id`, `client_secret` |
| web | **Web application** | *Authorized JavaScript origins*: `http://localhost:8765` for the local dev server, plus the real origin the web build is served from (e.g. `https://fizzyed.it`). *Authorized redirect URIs*: the same origins with `/oauth-callback.html` appended — `http://localhost:8765/oauth-callback.html`. | `credentials.zon` → `web_client_id` |

Google issues the desktop client a "secret" and requires it at the token exchange even though
a desktop app cannot keep a secret — Google's own docs say so. It is the *app's* credential,
not any user's, and is safe to ship as a default; it does not grant access to anything by
itself.

### 5. An API key, for the folder picker

**Credentials › Create credentials › API key.** Google's Picker needs one beside the user's
token. Under *Restrict key*: API restrictions → *Google Picker API* only. Leave the
application (referrer) restriction off, or the desktop's `http://127.0.0.1:*` page cannot use
it — the key grants nothing on its own.

### 6. Put the IDs in `credentials.zon`

```sh
cp credentials.zon.example credentials.zon   # gitignored
```

Fill in `client_id`, `client_secret` (desktop), `web_client_id` and `api_key`, then
`zig build`. They are baked into the plugin; users never see them. CI does the same from the
environment — `FIZZY_DRIVE_CLIENT_ID`, `FIZZY_DRIVE_CLIENT_SECRET`, `FIZZY_DRIVE_WEB_CLIENT_ID`,
`FIZZY_DRIVE_API_KEY` — because `zig build` generates `credentials.zon` from those when the
file is missing.

## What users see

The whole drive as a folder, `gdrive://<account>`. **File › Open Google Drive Folder…** (also
in the account menu at the bottom of the rail) opens Google's folder picker in the browser;
the chosen folder — shared ones included — becomes the root, `gdrive://<account>/<folder>`.
**Open Google Drive** goes back to the whole drive.

## How it works

`plugin.zig` owns the account and nothing else: `core.vfs.drive.Client` speaks Drive's REST,
`core.transport` moves bytes, `Host.mount` puts the result in the explorer beside the disk.

- **Desktop**: PKCE → system browser → a one-shot loopback listener on `127.0.0.1` receives
  the code (and checks `state`) → token exchange → `about?fields=user` names the mount →
  refresh token saved in settings so the next launch signs in silently; refreshed two minutes
  before expiry.
- **Web**: Google's implicit grant through fizzy's provider-agnostic OAuth popup
  (`core.transport.WebOAuth` → `oauth-callback.html`): the access token comes back in the
  redirect's fragment, no exchange, no secret. Re-asked with `prompt=none` before the hourly
  expiry. No refresh tokens exist for browser apps.

Sign-in state and errors surface as toasts; details in the log with the `drive:` prefix.
