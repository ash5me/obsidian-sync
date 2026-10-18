# Obsidian Drive Sync

A small command-line tool, written in Zig, that copies an Obsidian vault to Google Drive. You run it by hand from PowerShell or Command Prompt. It uploads new and changed notes and skips anything that hasn't changed since the last run.

This is a personal project. It runs only on your computer and talks directly to Google. There is no server.

## Requirements

- Windows 10 or 11
- Zig 0.14.x
- A Google account
- A Google Cloud project with the Google Drive API enabled and an OAuth client

## Setup

### 1. Create a Google Cloud OAuth client

1. Go to [console.cloud.google.com](https://console.cloud.google.com) and create a project.
2. Open **APIs & Services → Library**, search for **Google Drive API**, and enable it.
3. Open **OAuth consent screen** (Google may now call this **Google Auth Platform → Audience**). Choose **External**, enter an app name and your email address, and under **Test users** add your own Gmail address. You don't need to publish the app.
4. Open **Credentials → Create credentials → OAuth client ID**. Choose **TVs and Limited Input devices** as the application type, then copy the Client ID and Client secret.

Apps in Testing mode need you to sign in again about every 7 days. The tool detects this and shows a new sign-in code, so nothing breaks.

### 2. Save the credentials

In PowerShell:

```powershell
setx GDRIVE_CLIENT_ID "your-id.apps.googleusercontent.com"
setx GDRIVE_CLIENT_SECRET "your-secret"
```

Close and reopen PowerShell afterward so the variables load.

### 3. Build

From the folder that contains `main.zig`:

```powershell
zig build-exe main.zig -O ReleaseSafe -femit-bin=obsidian-sync.exe
```

## Usage

```powershell
.\obsidian-sync.exe "C:\Users\you\Documents\MyVault"
```

To use a different Drive folder name, add it as a second argument. The default is `Obsidian Vault`.

```powershell
.\obsidian-sync.exe "C:\Users\you\Documents\MyVault" "Obsidian Backup"
```

The first run prints a web address and a short code. Open the address, sign in with your Google account, and enter the code. Later runs don't ask again unless the sign-in expires.

Each run prints one line per uploaded file and a summary at the end. The program exits with code 2 if any file failed. Run it again to retry those files.

## How it works

- The tool creates a folder in the root of your Google Drive with the name you chose, and mirrors your vault's folder structure inside it.
- Files are uploaded in their original format. They are not converted to Google Docs.
- Hidden files and folders (names starting with a dot, such as `.obsidian`, `.trash`, and `.git`) are skipped.
- A file is uploaded only when its modified time differs from the value recorded on the last run.
- Re-running is safe. Existing Drive files are updated, not duplicated.

The tool keeps two files on your computer:

- `%APPDATA%\obsidian-drive-sync\refresh_token.txt` holds your sign-in token.
- `%APPDATA%\obsidian-drive-sync\state-<folder name>.tsv` records each synced file's path, modified time, and Drive file ID.

## Limitations

- **One-way sync.** Changes go from your computer to Drive only. If you delete or rename a note locally, the old copy stays on Drive. Remove it there by hand if you don't want it.
- **Let the tool create the Drive folder.** The app can only see files it created. If you make a folder by hand with the same name, the tool won't use it and will create a second folder.
- **Whole files are loaded into memory.** Files larger than 1 GB will fail.
- **Windows only.** The config location and paths assume Windows.
- **Test it first.** The code was written without being compiled or run here. Try it on a copy of your vault before relying on it.

## Troubleshooting

| Message | What to do |
|---|---|
| `Missing GDRIVE_CLIENT_ID` | Close and reopen PowerShell after running `setx`. |
| `Saved sign-in has expired` | Normal in Testing mode. Follow the new sign-in code. |
| `access_denied` | Your Google account isn't in the Test users list. Add it and try again. |
| `HTTP 403` mentioning `accessNotConfigured` | The Google Drive API isn't enabled for your project. |
| `Sign-in failed: expired_token` | The sign-in code expired before you entered it. Run the tool again. |

## Revoking access

1. Go to [myaccount.google.com/permissions](https://myaccount.google.com/permissions), find the app, and remove its access.
2. Delete the `%APPDATA%\obsidian-drive-sync` folder.
3. Remove the saved credentials:

```powershell
reg delete "HKCU\Environment" /v GDRIVE_CLIENT_ID /f
reg delete "HKCU\Environment" /v GDRIVE_CLIENT_SECRET /f
```

## Privacy

See [PRIVACY.md](PRIVACY.md) for what the tool stores and where your data goes.
