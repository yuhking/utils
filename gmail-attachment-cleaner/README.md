# Gmail Attachment Cleaner

*English | [日本語](./README.ja.md)*

A Windows app that bulk-removes attachments from Gmail over IMAP, keeping the message body intact.

Intro post (Japanese): https://shoroji.com/2026/09/5099/

## Features

- Search a folder for mails with attachments and list them (sorted by total attachment size, largest first)
- Remove attachments from checked mails; the original mail with attachments is moved to a configured folder (or deleted entirely if none is set)
- Automatically inserts a `Deleted: filename (size)` note at the top of the body for each removed attachment
- Double-click a mail in the list to view it rendered like a real mail client (with attachment/whole-mail deletion available right from that view)
- Independent "Protect" and "Delete mail" columns let you guard specific mails, or mark them for full deletion instead of just stripping attachments
- Bilingual UI (Japanese/English), switchable at runtime; UI strings live in external `lang_ja.ini` / `lang_en.ini` files so wording can be tweaked without recompiling
- All IMAP communication runs on a background thread, so the UI never freezes during processing

## Requirements

- Delphi (developed on RAD Studio 12; Indy10 ships with it)
- For SSL/TLS connections, place `libeay32.dll` / `ssleay32.dll` (32-bit OpenSSL) next to the built exe
  - e.g. https://indy.fulgan.com/SSL/

## Building

1. Open `imap_attachment_cleaner.dproj` in Delphi
2. Build & run with F9 (or `dcc32 imap_attachment_cleaner.dpr`)
3. Place `lang_ja.ini` / `lang_en.ini` next to the built exe (external files used for the language switch)

## Usage

1. Fill in the connection details (IMAP server, username, password, etc.) plus the target folder and move-to folder in the left panel, then optionally save it as a profile with "1. Save this profile"
2. "2. Connect" → (by default, this automatically continues into) "3. List mails"
3. Check the mails whose attachments you want removed, then "4. Remove selected attachments"
4. To delete a mail entirely instead, check it in the "Delete mail" column and click "5. Delete selected mails"

Settings are saved to `imap_settings.ini` next to the exe (the password is lightly obfuscated, not encrypted — handle this file with care).

## How it works

IMAP has no command to modify part of an existing message (such as stripping just the attachments), so this tool achieves the same practical result as follows:

1. Download the target message in full
2. Strip attachment parts in memory only, keeping the body/subject/from/etc. intact; insert a note listing the removed attachment filenames at the top of the body
3. `APPEND` the attachment-free message back into the original folder as a new message
4. If a move-to folder is configured, preserve the original (attachment-bearing) message there — using a Gmail label operation for regular labels, or `COPY` for special-use folders like Trash. If no folder is configured, flag the original for deletion instead
5. Finally, run `EXPUNGE` to remove the flagged originals

This is essentially the same idea as Thunderbird's "Remove Attachments" feature. If an error occurs partway through, the original message may be left flagged for deletion (still recoverable until `EXPUNGE` runs). If you're concerned, back up the folder server-side beforehand.

## Notes & known limitations

- This operation (especially with no move-to folder configured) **cannot be undone**. Test it on a throwaway folder or copied mails before running it on your real mailbox.
- Move-to folder names may need to be ASCII-only depending on the server (non-ASCII folder names require IMAP's Modified UTF-7 encoding, which isn't always handled automatically). When in doubt, use an ASCII name like the default `DeletedAttachments`.
- Listing is lightweight — it only fetches message structure, never attachment contents — but "largest first" only sorts within whatever the search managed to collect before stopping. To reliably find the largest attachments across the whole folder, set the search count to 0 (unlimited).

## Status

Testing is complete and the tool is being prepared for release. Once ready, a Release build will be added to this folder.
