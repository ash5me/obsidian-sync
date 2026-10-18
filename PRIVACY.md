# Privacy

Obsidian Drive Sync is a personal project. It isn't a commercial service, and no one operates a server that receives your data. The program runs on your own computer and communicates directly with Google.

## What the tool accesses

**Your vault files.** The tool reads the file names, folder structure, contents, and modified times of the notes and attachments in the folder you give it. It reads these only on your computer and uploads them to your Google Drive.

**Your Google account.** You sign in through Google's own device sign-in page. The tool asks for one permission, `drive.file`. Under that permission, the tool can only see and modify files and folders it created. It cannot read, change, or delete the rest of your Drive.

**Your Google Cloud credentials.** The OAuth client ID and client secret are stored as Windows user environment variables, which you set with `setx`. Windows stores these in plain text in your user registry hive, so anyone with access to your Windows user account can read them.

## What is stored on your computer

The tool keeps two files in `%APPDATA%\obsidian-drive-sync`:

- `refresh_token.txt` contains a long-lived token that lets the tool access your Drive. Treat it like a password. Anyone who has this file, along with your client ID and secret, can use the tool's access until you revoke it.
- `state-<folder name>.tsv` lists each synced file's relative path, last-known modified time, and Google Drive file ID. The tool uses it to skip unchanged files.

The tool doesn't store your note contents anywhere on your computer except in your vault itself.

## Where your data goes

Your files go to Google, and nowhere else. The tool connects only to `oauth2.googleapis.com` (for sign-in) and `www.googleapis.com` and `www.googleapis.com/upload` (for Drive). It has no analytics, telemetry, crash reporting, advertising, or third-party services.

Files are stored in Google Drive as they are, in a folder you named. Google's [privacy policy](https://policies.google.com/privacy) covers what Google does with data stored in Drive. Google encrypts data in transit and at rest, but it doesn't end-to-end encrypt Drive files, so Google can access their contents. If you need that protection for your notes, encrypt the vault or choose a different service.

## Who can see your data

Only you and anyone with access to your Google account can see the files in your Drive folder. The tool doesn't share files, make them public, or change sharing settings.

## What the tool never does

- It never deletes files on your computer or in Google Drive.
- It never reads Drive files it didn't create.
- It never sends data anywhere other than Google.

## Your controls

- **Revoke access** at [myaccount.google.com/permissions](https://myaccount.google.com/permissions). Once removed, the saved token stops working.
- **Delete local data** by removing the `%APPDATA%\obsidian-drive-sync` folder and the `GDRIVE_CLIENT_ID` and `GDRIVE_CLIENT_SECRET` environment variables.
- **Delete uploaded data** by deleting the folder in Google Drive.

## Changes

This document describes the code as it was written. If the tool changes how it handles data, this document should change too.
