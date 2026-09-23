# Google Drive plugin

Sign in to Google Drive and it appears in the explorer as a folder (`gdrive://<account>`):
browse, open, edit, save, create, rename, delete, search — on the desktop and in the web build.

Users click **File › Connect Google Drive…**, sign in on Google's page once, and are back in
fizzy with the drive mounted and open. Everything after that — browsing, choosing which folder
to work in — happens in fizzy. Nothing below is for them. It is the **one-time registration of fizzy
as an app with Google**, done by whoever publishes fizzy; the result is two public client IDs
that become defaults in this plugin's settings.

This is an ordinary third-party plugin (the same shape as pixi): fizzy knows nothing about
Google. Natively it ships through the plugin store; the web build installs it from that same
store, as a wasm side module the page links at runtime.

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

### 2. Enable the Drive API

**APIs & Services › Library** → search *Google Drive API* → **Enable**. Without this every
call fails with "API not enabled". Nothing else needs enabling — no Picker API, no API key, no
project number: the drive is browsed inside fizzy, not through a Google widget.

### 3. The consent screen

**APIs & Services › OAuth consent screen** (or *Google Auth Platform › Branding* in the newer
console).

- User type: **External**.
- App name `fizzy`, your email as user-support and developer contact. Logo/links optional.
- **Scopes** → *Add or remove scopes* → tick `https://www.googleapis.com/auth/drive`
  ("See, edit, create and delete all of your Google Drive files"). It is the only scope the
  plugin asks for, and it has to be this one: `drive.file` grants access an item at a time, and
  a folder granted that way hands over the *folder object* alone — its children do not list and
  each one 404s, so the tree opens empty. A drive you can browse is a drive you have access to.
- **What that costs, plainly.** Google calls `…/auth/drive` *restricted*. Until the project
  passes verification **and** an annual third-party security assessment (CASA Tier 2):
  - users see an **unverified app** screen before the consent screen. They can continue through
    *Advanced*, and everything works afterwards — it is a warning, not a block;
  - at most **100 accounts, ever**, can grant it. The cap is per project, counts for the
    project's lifetime and cannot be reset or raised without verification.

  That is fine for a plugin among friends and for anyone building it against their own Cloud
  project. It is the thing to fix before a build is handed to a large audience.
- **Test users** → while *Publishing status* is **Testing**, only accounts listed here can sign
  in at all. Pressing **Publish app** moves to *In production*, where any account may sign in,
  still unverified, still under the 100-account cap.

### 4. Two OAuth clients

**APIs & Services › Credentials › Create credentials › OAuth client ID**, twice:

| Client | Type | Settings | Goes into |
|---|---|---|---|
| desktop | **Desktop app** | none | `credentials.zon` → `client_id`, `client_secret` |
| web | **Web application** | *Authorized JavaScript origins*: `http://localhost:8765` for the local dev server, plus the real origin the web build is served from (e.g. `https://fizzyed.it`). Only the web build needs these: the desktop's folder picker is part of Google's consent screen (`trigger_onepick`) and has no web origin at all. *Authorized redirect URIs*: the same origins with `/oauth-callback.html` appended — `http://localhost:8765/oauth-callback.html`. | `credentials.zon` → `web_client_id` |

Google issues the desktop client a "secret" and requires it at the token exchange even though
a desktop app cannot keep a secret — RFC 8252 (*OAuth 2.0 for Native Apps*) classes installed
apps as public clients for exactly this reason, and Google's own docs say the same. What
protects the flow is PKCE, which this plugin does (S256, plus a `state` nonce). The secret is
the *app's* credential, not any user's, and grants nothing by itself.

**What ends up in a published binary**, measured rather than assumed: the desktop build carries
`client_id` and `client_secret`; the web build carries `web_client_id`.
Neither carries the other's client. Client ids are public by design — they appear in the URL
the user sees while consenting — and an API key in a browser app is public too; both are
protected by *restriction* in the console, not by secrecy.

### 6. Put the IDs in `credentials.zon`

```sh
cp credentials.zon.example credentials.zon   # gitignored
```

Fill in `client_id`, `client_secret` (desktop) and `web_client_id`, then `zig build`. They are baked into the plugin; users never see them. CI
does the same from the environment — `FIZZY_DRIVE_CLIENT_ID`, `FIZZY_DRIVE_CLIENT_SECRET`,
`FIZZY_DRIVE_WEB_CLIENT_ID`, `FIZZY_DRIVE_API_KEY`, `FIZZY_DRIVE_PROJECT_NUMBER` — passed to
the release workflow as one `DRIVE_BUILD_ENV` secret of KEY=VALUE lines, because `zig build`
generates `credentials.zon` from those when the
file is missing.

## What users see

The whole drive as a folder, `gdrive://<account>`. Connecting mounts it and opens it, and from
there it is browsed in fizzy's own tree like any other folder — no browser, no Google UI, no
re-consent. **File › Open Google Drive** (also in the account menu at the bottom of the rail)
opens it again after you have opened something else.

A subfolder can be the root instead — `root_folder_id` in the plugin's settings, which names it
`gdrive://<account>/<folder>`. Nothing in the UI sets that yet.

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
