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
- **Scopes** → *Add or remove scopes* → tick `https://www.googleapis.com/auth/drive.file`
  ("See, edit, create and delete only the specific Google Drive files you use with this app").
  That is the only scope the plugin asks for, and the folder picker is how the user says which
  folder they mean — under this scope the picker's `setAppId` (step 5) is what actually hands
  the app what was picked.
- **Do not add `…/auth/drive`.** The whole drive is a *restricted* scope: an app requesting it
  can only sign in accounts listed as test users until the Cloud project passes Google's
  verification *and* an annual third-party security assessment. `drive.file` is non-sensitive,
  so nothing is reviewed and there is no test-user cap. The plugin can still ask for the whole
  drive — *Access the whole Drive* in its settings — which is for people running it against
  their own Cloud project, not for a published build.
- **Test users** → add your own Google account while the *Publishing status* is **Testing**.
  With only `drive.file` requested you can press **Publish app** whenever you like; it takes
  effect immediately, with no review.

### 4. Two OAuth clients

**APIs & Services › Credentials › Create credentials › OAuth client ID**, twice:

| Client | Type | Settings | Goes into |
|---|---|---|---|
| desktop | **Desktop app** | none | `credentials.zon` → `client_id`, `client_secret` |
| web | **Web application** | *Authorized JavaScript origins*: `http://localhost:8765` for the local dev server, plus the real origin the web build is served from (e.g. `https://fizzyed.it`). *Authorized redirect URIs*: the same origins with `/oauth-callback.html` appended — `http://localhost:8765/oauth-callback.html`. | `credentials.zon` → `web_client_id` |

Google issues the desktop client a "secret" and requires it at the token exchange even though
a desktop app cannot keep a secret — RFC 8252 (*OAuth 2.0 for Native Apps*) classes installed
apps as public clients for exactly this reason, and Google's own docs say the same. What
protects the flow is PKCE, which this plugin does (S256, plus a `state` nonce). The secret is
the *app's* credential, not any user's, and grants nothing by itself.

**What ends up in a published binary**, measured rather than assumed: the desktop build carries
`client_id`, `client_secret` and `api_key`; the web build carries `web_client_id` and `api_key`.
Neither carries the other's client. Client ids are public by design — they appear in the URL
the user sees while consenting — and an API key in a browser app is public too; both are
protected by *restriction* in the console, not by secrecy.

### 5. An API key and the project number, for the folder picker

**Credentials › Create credentials › API key.** Google's Picker needs one beside the user's
token. Under *Restrict key*: API restrictions → *Google Picker API* only. Leave the
application (referrer) restriction off, or the desktop's `http://127.0.0.1:*` page cannot use
it — the key grants nothing on its own.

**And the project number** — the numeric id on the project's dashboard (*Cloud overview ›
Dashboard › Project number*), not the project *id* string. The picker sends it as `setAppId`,
and under `drive.file` that call is what grants this app the folder the user picked: without
it the picker returns an id the plugin is then not allowed to open. It goes into
`credentials.zon` as `project_number`.

Two APIs have to be enabled for any of this to work, under **APIs & Services › Enable APIs and
services**: **Google Drive API** and **Google Picker API**. Enabling an API asks for no scopes;
scopes live only on the consent screen (step 3), and the API key has none at all.

### 6. Put the IDs in `credentials.zon`

```sh
cp credentials.zon.example credentials.zon   # gitignored
```

Fill in `client_id`, `client_secret` (desktop), `web_client_id`, `api_key` and
`project_number`, then `zig build`. They are baked into the plugin; users never see them. CI
does the same from the environment — `FIZZY_DRIVE_CLIENT_ID`, `FIZZY_DRIVE_CLIENT_SECRET`,
`FIZZY_DRIVE_WEB_CLIENT_ID`, `FIZZY_DRIVE_API_KEY`, `FIZZY_DRIVE_PROJECT_NUMBER` — passed to
the release workflow as one `DRIVE_BUILD_ENV` secret of KEY=VALUE lines, because `zig build`
generates `credentials.zon` from those when the
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
