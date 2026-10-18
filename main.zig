//! Obsidian Drive Sync (Zig 0.16)
//! Uploads an Obsidian vault to a folder in Google Drive.
//!
//! Usage: obsidian-sync <vault-folder> [drive-folder-name]
//! Needs client_secret.json in the current folder or next to the .exe.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const drive_api = "https://www.googleapis.com/drive/v3/files";
const upload_api = "https://www.googleapis.com/upload/drive/v3/files";
const device_code_url = "https://oauth2.googleapis.com/device/code";
const token_url = "https://oauth2.googleapis.com/token";
const oauth_scope = "https://www.googleapis.com/auth/drive.file";
const form_type = "application/x-www-form-urlencoded";
const folder_mime = "application/vnd.google-apps.folder";
const boundary = "obsidian_sync_boundary_9d2f1c";
const secret_file_name = "client_secret.json";
const default_drive_name = "Obsidian Vault";
const save_every = 25; // save the manifest this often, so an interrupted run keeps its progress
const max_attempts = 5; // tries for rate-limit and server errors

const ManifestEntry = struct { mtime: i96, id: []const u8 };
const HttpResult = struct { status: u16, body: []const u8 };
const Credentials = struct { client_id: []const u8, client_secret: []const u8 };
const Session = struct { access: []const u8, refresh: []const u8 };

const Ctx = struct {
    io: Io,
    persist: Allocator, // lives for the whole run (folder ids, manifest, tokens)
    scratch: Allocator, // lives for one file (file contents, HTTP bodies)
    client: *std.http.Client,
    creds: Credentials,
    refresh_token: []const u8,
    token: []const u8, // current access token, replaced when it expires
    root_id: []const u8,
    folders: std.StringHashMap([]const u8),
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("Usage: obsidian-sync <vault-folder> [drive-folder-name]\n", .{});
        std.process.exit(1);
    }
    const vault_path: []const u8 = args[1];
    const drive_name: []const u8 = if (args.len >= 3) args[2] else default_drive_name;

    const creds = try loadClientCredentials(io, arena);

    const config_dir = try configDir(init.environ_map, arena);
    try Io.Dir.cwd().createDirPath(io, config_dir);
    const token_file = try std.fs.path.join(arena, &.{ config_dir, "refresh_token.txt" });
    const state_file = try statePath(arena, config_dir, drive_name);

    const vault = Io.Dir.cwd().openDir(io, vault_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open vault folder \"{s}\": {s}\n", .{ vault_path, @errorName(err) });
        std.process.exit(1);
    };
    defer vault.close(io);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const session = try signIn(io, arena, &client, creds, token_file);

    var ctx = Ctx{
        .io = io,
        .persist = arena,
        .scratch = arena,
        .client = &client,
        .creds = creds,
        .refresh_token = session.refresh,
        .token = session.access,
        .root_id = "",
        .folders = std.StringHashMap([]const u8).init(arena),
    };
    const root = (try findItem(&ctx, "root", drive_name, true)) orelse
        try createFolder(&ctx, "root", drive_name);
    ctx.root_id = try arena.dupe(u8, root);

    var manifest = try loadManifest(io, arena, state_file);
    var walker = try vault.walk(arena);
    defer walker.deinit();

    std.debug.print("Syncing \"{s}\" -> Google Drive folder \"{s}\"\n", .{ vault_path, drive_name });

    var uploaded: usize = 0;
    var unchanged: usize = 0;
    var failed: usize = 0;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or isHidden(entry.path)) continue;

        // The walker reuses its path buffer, so keep our own copy.
        const rel = try arena.dupe(u8, entry.path);
        const stat = vault.statFile(io, rel, .{}) catch |err| {
            std.debug.print("  cannot read {s}: {s}\n", .{ rel, @errorName(err) });
            failed += 1;
            continue;
        };
        const mtime: i96 = stat.mtime.nanoseconds;

        const prev = manifest.get(rel);
        if (prev) |p| {
            if (p.mtime == mtime) {
                unchanged += 1;
                continue;
            }
        }

        // Scratch memory for this one file, freed at the end of the iteration.
        var scratch_state = std.heap.ArenaAllocator.init(gpa);
        defer scratch_state.deinit();
        ctx.scratch = scratch_state.allocator();

        const id = syncFile(&ctx, vault, rel, prev) catch |err| {
            if (err == error.SignInExpired) {
                try saveManifest(io, arena, state_file, &manifest);
                return err;
            }
            std.debug.print("  FAILED {s}: {s}\n", .{ rel, @errorName(err) });
            failed += 1;
            continue;
        };
        try manifest.put(rel, .{ .mtime = mtime, .id = try arena.dupe(u8, id) });
        uploaded += 1;
        std.debug.print("  uploaded {s}\n", .{rel});

        if (uploaded % save_every == 0) try saveManifest(io, arena, state_file, &manifest);
    }

    try saveManifest(io, arena, state_file, &manifest);
    std.debug.print("\nDone: {d} uploaded, {d} unchanged, {d} failed.\n", .{ uploaded, unchanged, failed });
    if (failed > 0) std.process.exit(2);
}

// ---------- local helpers ----------

fn configDir(environ: *std.process.Environ.Map, arena: Allocator) ![]const u8 {
    const base = environ.get("APPDATA") orelse ".";
    return std.fs.path.join(arena, &.{ base, "obsidian-drive-sync" });
}

fn statePath(arena: Allocator, dir: []const u8, drive_name: []const u8) ![]const u8 {
    const safe = try arena.alloc(u8, drive_name.len);
    for (drive_name, 0..) |c, i| safe[i] = if (std.ascii.isAlphanumeric(c)) c else '_';
    const file = try std.fmt.allocPrint(arena, "state-{s}.tsv", .{safe});
    return std.fs.path.join(arena, &.{ dir, file });
}

fn isHidden(rel: []const u8) bool {
    var parts = std.mem.tokenizeAny(u8, rel, "/\\");
    while (parts.next()) |part| {
        if (part[0] == '.') return true; // .obsidian, .trash, .git, ...
    }
    return false;
}

fn lastSeparator(s: []const u8) ?usize {
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if (s[i] == '/' or s[i] == '\\') return i;
    }
    return null;
}

fn mimeFor(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    const table = .{
        .{ ".md", "text/markdown" },
        .{ ".txt", "text/plain" },
        .{ ".json", "application/json" },
        .{ ".canvas", "application/json" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".webp", "image/webp" },
        .{ ".svg", "image/svg+xml" },
        .{ ".pdf", "application/pdf" },
    };
    inline for (table) |row| {
        if (std.ascii.eqlIgnoreCase(ext, row[0])) return row[1];
    }
    return "application/octet-stream";
}

// Manifest format, one line per file: <mtime_ns>\t<drive_file_id>\t<relative_path>
fn loadManifest(io: Io, alloc: Allocator, path: []const u8) !std.StringHashMap(ManifestEntry) {
    var map = std.StringHashMap(ManifestEntry).init(alloc);
    const data = Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 << 20)) catch return map;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var fields = std.mem.splitScalar(u8, line, '\t');
        const mtime_text = fields.next() orelse continue;
        const id = fields.next() orelse continue;
        const rel = fields.rest();
        if (rel.len == 0) continue;
        const mtime = std.fmt.parseInt(i96, mtime_text, 10) catch continue;
        try map.put(rel, .{ .mtime = mtime, .id = id });
    }
    return map;
}

fn saveManifest(io: Io, alloc: Allocator, path: []const u8, map: *std.StringHashMap(ManifestEntry)) !void {
    var out: std.ArrayList(u8) = .empty;
    var it = map.iterator();
    while (it.next()) |kv| {
        try out.print(alloc, "{d}\t{s}\t{s}\n", .{ kv.value_ptr.mtime, kv.value_ptr.id, kv.key_ptr.* });
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

// ---------- client credentials ----------

fn fileExists(io: Io, path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// Looks for client_secret.json in the current folder first, then next to the .exe.
fn findClientSecretFile(io: Io, alloc: Allocator) ?[]const u8 {
    if (fileExists(io, secret_file_name)) return secret_file_name;
    const exe_dir = std.process.executableDirPathAlloc(io, alloc) catch return null;
    const path = std.fs.path.join(alloc, &.{ exe_dir, secret_file_name }) catch return null;
    return if (fileExists(io, path)) path else null;
}

/// Google wraps the values under a key that depends on the client type
/// (for example "installed", "web", or "limited_input_device"), so search for it.
fn findCredentialsObject(json: std.json.Value) ?std.json.Value {
    if (jsonString(json, "client_id") != null) return json;
    if (json != .object) return null;
    var it = json.object.iterator();
    while (it.next()) |entry| {
        const v = entry.value_ptr.*;
        if (v == .object and jsonString(v, "client_id") != null) return v;
    }
    return null;
}

fn loadClientCredentials(io: Io, alloc: Allocator) !Credentials {
    const path = findClientSecretFile(io, alloc) orelse {
        std.debug.print(
            "{s} not found. Put it in the project folder, next to obsidian-sync.exe.\n",
            .{secret_file_name},
        );
        std.process.exit(1);
    };
    const data = Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch |err| {
        std.debug.print("Cannot read {s}: {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };
    const json = parseJson(alloc, data) catch {
        std.debug.print("{s} is not valid JSON.\n", .{path});
        std.process.exit(1);
    };
    const obj = findCredentialsObject(json) orelse {
        std.debug.print("{s} has no client_id and client_secret.\n", .{path});
        std.process.exit(1);
    };
    const client_id = jsonString(obj, "client_id") orelse return error.MissingClientId;
    const client_secret = jsonString(obj, "client_secret") orelse return error.MissingClientSecret;
    return .{ .client_id = client_id, .client_secret = client_secret };
}

// ---------- OAuth ----------

/// Uses the saved refresh token if it still works, otherwise starts the device sign-in.
fn signIn(io: Io, alloc: Allocator, client: *std.http.Client, creds: Credentials, token_path: []const u8) !Session {
    if (Io.Dir.cwd().readFileAlloc(io, token_path, alloc, .limited(4096))) |saved| {
        const refresh = std.mem.trim(u8, saved, " \r\n\t");
        if (refresh.len > 0) {
            if (try exchangeRefreshToken(alloc, client, creds, refresh)) |access| {
                return .{ .access = access, .refresh = refresh };
            }
            std.debug.print("Saved sign-in has expired, starting a new one.\n", .{});
        }
    } else |_| {}

    return deviceLogin(io, alloc, client, creds, token_path);
}

/// Returns a new access token, or null if Google rejects the refresh token.
fn exchangeRefreshToken(
    alloc: Allocator,
    client: *std.http.Client,
    creds: Credentials,
    refresh: []const u8,
) !?[]const u8 {
    const body = try formBody(alloc, &.{
        .{ "client_id", creds.client_id },
        .{ "client_secret", creds.client_secret },
        .{ "refresh_token", refresh },
        .{ "grant_type", "refresh_token" },
    });
    const res = try httpRequest(alloc, client, .POST, token_url, &[_]std.http.Header{}, form_type, body);
    const json = try parseJson(alloc, res.body);
    return jsonString(json, "access_token");
}

/// Gets a new access token when the current one expires partway through a run.
fn refreshAccessToken(ctx: *Ctx) !void {
    const access = (try exchangeRefreshToken(ctx.persist, ctx.client, ctx.creds, ctx.refresh_token)) orelse {
        std.debug.print("Your Google sign-in has expired. Run the tool again to sign in.\n", .{});
        return error.SignInExpired;
    };
    ctx.token = access;
}

fn nowSeconds(io: Io) i64 {
    const ns = Io.Timestamp.now(io, .real).nanoseconds;
    return @intCast(@divFloor(ns, std.time.ns_per_s));
}

fn deviceLogin(
    io: Io,
    alloc: Allocator,
    client: *std.http.Client,
    creds: Credentials,
    token_path: []const u8,
) !Session {
    const start_body = try formBody(alloc, &.{
        .{ "client_id", creds.client_id },
        .{ "scope", oauth_scope },
    });
    const start = try httpRequest(alloc, client, .POST, device_code_url, &[_]std.http.Header{}, form_type, start_body);
    if (start.status != 200) {
        std.debug.print("Could not start sign-in: {s}\n", .{start.body});
        return error.LoginFailed;
    }
    const start_json = try parseJson(alloc, start.body);
    const device_code = jsonString(start_json, "device_code") orelse return error.BadResponse;
    const user_code = jsonString(start_json, "user_code") orelse return error.BadResponse;
    const verify_url = jsonString(start_json, "verification_url") orelse
        jsonString(start_json, "verification_uri") orelse "https://www.google.com/device";
    const expires_in = jsonInt(start_json, "expires_in") orelse 1800;
    var interval: i64 = jsonInt(start_json, "interval") orelse 5;

    std.debug.print(
        "\nSign in to Google Drive:\n  1. Open {s}\n  2. Enter the code: {s}\n\nWaiting for approval...\n",
        .{ verify_url, user_code },
    );

    const deadline = nowSeconds(io) + expires_in;
    while (nowSeconds(io) < deadline) {
        try Io.sleep(io, Io.Duration.fromSeconds(interval), .real);

        const poll_body = try formBody(alloc, &.{
            .{ "client_id", creds.client_id },
            .{ "client_secret", creds.client_secret },
            .{ "device_code", device_code },
            .{ "grant_type", "urn:ietf:params:oauth:grant-type:device_code" },
        });
        const poll = try httpRequest(alloc, client, .POST, token_url, &[_]std.http.Header{}, form_type, poll_body);
        const poll_json = try parseJson(alloc, poll.body);

        if (jsonString(poll_json, "access_token")) |access| {
            const refresh = jsonString(poll_json, "refresh_token") orelse return error.BadResponse;
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = token_path, .data = refresh });
            return .{ .access = access, .refresh = refresh };
        }
        const reason = jsonString(poll_json, "error") orelse "unknown_error";
        if (std.mem.eql(u8, reason, "authorization_pending")) continue;
        if (std.mem.eql(u8, reason, "slow_down")) {
            interval += 5;
            continue;
        }
        std.debug.print("Sign-in failed: {s}\n", .{reason});
        return error.LoginFailed;
    }
    return error.LoginTimedOut;
}

// ---------- Google Drive ----------

fn ensureDir(ctx: *Ctx, rel_dir: []const u8) ![]const u8 {
    if (rel_dir.len == 0) return ctx.root_id;
    if (ctx.folders.get(rel_dir)) |id| return id;

    const split = lastSeparator(rel_dir);
    const parent_rel: []const u8 = if (split) |i| rel_dir[0..i] else "";
    const name: []const u8 = if (split) |i| rel_dir[i + 1 ..] else rel_dir;

    const parent_id = try ensureDir(ctx, parent_rel);
    const found = (try findItem(ctx, parent_id, name, true)) orelse try createFolder(ctx, parent_id, name);

    const key = try ctx.persist.dupe(u8, rel_dir);
    const id = try ctx.persist.dupe(u8, found);
    try ctx.folders.put(key, id);
    return id;
}

fn syncFile(ctx: *Ctx, vault: Io.Dir, rel: []const u8, prev: ?ManifestEntry) ![]const u8 {
    const dir_rel = std.fs.path.dirname(rel) orelse "";
    const name = std.fs.path.basename(rel);
    const parent_id = try ensureDir(ctx, dir_rel);
    const content = try vault.readFileAlloc(ctx.io, rel, ctx.scratch, .limited(1 << 30));
    const mime = mimeFor(name);

    // 1. Update the Drive file we uploaded last time.
    if (prev) |p| {
        if (try updateFile(ctx, p.id, mime, content)) |id| return id;
    }
    // 2. Otherwise, if a file with this name already exists (e.g. after an interrupted run), update it.
    if (try findItem(ctx, parent_id, name, false)) |existing| {
        if (try updateFile(ctx, existing, mime, content)) |id| return id;
    }
    // 3. Otherwise create it.
    return createFile(ctx, parent_id, name, mime, content);
}

fn escapeQuery(alloc: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (c == '\'' or c == '\\') try out.append(alloc, '\\');
        try out.append(alloc, c);
    }
    return out.items;
}

fn findItem(ctx: *Ctx, parent_id: []const u8, name: []const u8, is_folder: bool) !?[]const u8 {
    const a = ctx.scratch;
    const op: []const u8 = if (is_folder) "=" else "!=";
    const q = try std.fmt.allocPrint(
        a,
        "name = '{s}' and '{s}' in parents and mimeType {s} '{s}' and trashed = false",
        .{ try escapeQuery(a, name), parent_id, op, folder_mime },
    );
    var url: std.ArrayList(u8) = .empty;
    try url.appendSlice(a, drive_api ++ "?fields=files(id)&q=");
    try appendUrlEncoded(a, &url, q);

    const res = try apiRequest(ctx, .GET, url.items, null, null);
    try expectOk(res);
    const json = try parseJson(a, res.body);
    const files = jsonField(json, "files") orelse return null;
    if (files != .array or files.array.items.len == 0) return null;
    return jsonString(files.array.items[0], "id");
}

fn createFolder(ctx: *Ctx, parent_id: []const u8, name: []const u8) ![]const u8 {
    const a = ctx.scratch;
    const name_json = try std.json.Stringify.valueAlloc(a, name, .{});
    const body = try std.fmt.allocPrint(
        a,
        "{{\"name\":{s},\"mimeType\":\"{s}\",\"parents\":[\"{s}\"]}}",
        .{ name_json, folder_mime, parent_id },
    );
    const res = try apiRequest(ctx, .POST, drive_api, "application/json", body);
    try expectOk(res);
    const json = try parseJson(a, res.body);
    return jsonString(json, "id") orelse return error.BadResponse;
}

fn createFile(ctx: *Ctx, parent_id: []const u8, name: []const u8, mime: []const u8, content: []const u8) ![]const u8 {
    const a = ctx.scratch;
    const name_json = try std.json.Stringify.valueAlloc(a, name, .{});
    const meta = try std.fmt.allocPrint(a, "{{\"name\":{s},\"parents\":[\"{s}\"]}}", .{ name_json, parent_id });
    const body = try std.fmt.allocPrint(
        a,
        "--{s}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{s}\r\n--{s}\r\nContent-Type: {s}\r\n\r\n{s}\r\n--{s}--\r\n",
        .{ boundary, meta, boundary, mime, content, boundary },
    );
    const url = upload_api ++ "?uploadType=multipart";
    const ct = "multipart/related; boundary=" ++ boundary;
    const res = try apiRequest(ctx, .POST, url, ct, body);
    try expectOk(res);
    const json = try parseJson(a, res.body);
    return jsonString(json, "id") orelse return error.BadResponse;
}

/// Returns null if the file no longer exists on Drive (404).
fn updateFile(ctx: *Ctx, file_id: []const u8, mime: []const u8, content: []const u8) !?[]const u8 {
    const a = ctx.scratch;
    const url = try std.fmt.allocPrint(a, "{s}/{s}?uploadType=media", .{ upload_api, file_id });
    const res = try apiRequest(ctx, .PATCH, url, mime, content);
    if (res.status == 404) return null;
    try expectOk(res);
    const json = try parseJson(a, res.body);
    return jsonString(json, "id") orelse return error.BadResponse;
}

// ---------- HTTP and JSON helpers ----------

/// Sends an authorized request to Google Drive. If the access token has expired it is
/// refreshed once and the request retried. Rate-limit and server errors are retried
/// a few times with a growing pause.
fn apiRequest(
    ctx: *Ctx,
    method: std.http.Method,
    url: []const u8,
    content_type: ?[]const u8,
    payload: ?[]const u8,
) !HttpResult {
    var refreshed = false;
    var attempt: u64 = 0;
    while (true) : (attempt += 1) {
        const auth = try std.fmt.allocPrint(ctx.scratch, "Bearer {s}", .{ctx.token});
        const headers = [_]std.http.Header{.{ .name = "Authorization", .value = auth }};
        const res = try httpRequest(ctx.scratch, ctx.client, method, url, &headers, content_type, payload);

        if (res.status == 401 and !refreshed) {
            refreshed = true;
            try refreshAccessToken(ctx);
            continue;
        }
        const retryable = res.status == 429 or res.status >= 500;
        if (retryable and attempt + 1 < max_attempts) {
            const pause_seconds: i64 = @intCast((attempt + 1) * 2);
            try Io.sleep(ctx.io, Io.Duration.fromSeconds(pause_seconds), .real);
            continue;
        }
        return res;
    }
}

fn httpRequest(
    alloc: Allocator,
    client: *std.http.Client,
    method: std.http.Method,
    url: []const u8,
    headers: []const std.http.Header,
    content_type: ?[]const u8,
    payload: ?[]const u8,
) !HttpResult {
    var body: Io.Writer.Allocating = .init(alloc);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .extra_headers = headers,
        .headers = .{ .content_type = if (content_type) |t| .{ .override = t } else .default },
        .response_writer = &body.writer,
    });
    return .{ .status = @intFromEnum(result.status), .body = body.written() };
}

fn expectOk(res: HttpResult) !void {
    if (res.status < 200 or res.status > 299) {
        std.debug.print("HTTP {d}: {s}\n", .{ res.status, res.body });
        return error.HttpRequestFailed;
    }
}

fn formBody(alloc: Allocator, pairs: []const [2][]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pairs, 0..) |pair, i| {
        if (i > 0) try out.append(alloc, '&');
        try appendUrlEncoded(alloc, &out, pair[0]);
        try out.append(alloc, '=');
        try appendUrlEncoded(alloc, &out, pair[1]);
    }
    return out.items;
}

fn appendUrlEncoded(alloc: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(alloc, c);
        } else {
            try out.print(alloc, "%{X:0>2}", .{c});
        }
    }
}

fn parseJson(alloc: Allocator, body: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{});
}

fn jsonField(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn jsonString(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = jsonField(v, key) orelse return null;
    return if (f == .string) f.string else null;
}

fn jsonInt(v: std.json.Value, key: []const u8) ?i64 {
    const f = jsonField(v, key) orelse return null;
    return if (f == .integer) f.integer else null;
}
