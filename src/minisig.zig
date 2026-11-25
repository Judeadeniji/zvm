//! Minisign (`Ed25519` + `BLAKE2b-512`) signature parser and verifier for official Zig releases.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const EnvironMap = std.process.Environ.Map;
const Ed25519 = std.crypto.sign.Ed25519;
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;
const Base64Decoder = std.base64.standard.Decoder;
const errors = @import("errors.zig");
const Paths = @import("paths.zig").Paths;
const build_options = @import("build_options");

pub const MinisigError = errors.MinisigError;

/// Default Zig Software Foundation Minisign public key (`https://ziglang.org/download/`),
/// injectable at compile time via `-Dminisig-key=...` and overridable at runtime via
/// `--minisig-key`, `ZVM_MINISIG_PUBLIC_KEY`, or `<base_dir>/minisig.pub`.
pub const default_zig_public_key_b64: []const u8 = build_options.minisig_public_key;

pub const PublicKey = struct {
    key_id: [8]u8,
    ed25519: Ed25519.PublicKey,

    /// Parses either a single base64 key line or a standard 2-line minisign `.pub` file.
    pub fn parse(text: []const u8) MinisigError!PublicKey {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or std.mem.startsWith(u8, line, "untrusted comment:")) continue;
            return parseBase64(line);
        }
        return MinisigError.InvalidPublicKey;
    }

    pub fn parseBase64(encoded: []const u8) MinisigError!PublicKey {
        const trimmed = std.mem.trim(u8, encoded, " \t\r\n");
        var decoded: [42]u8 = undefined;
        const out_len = Base64Decoder.calcSizeForSlice(trimmed) catch return MinisigError.InvalidPublicKey;
        if (out_len != decoded.len) return MinisigError.InvalidPublicKey;

        Base64Decoder.decode(&decoded, trimmed) catch return MinisigError.InvalidPublicKey;
        if (!std.mem.eql(u8, decoded[0..2], "Ed")) return MinisigError.UnsupportedKeyAlgorithm;

        const ed_pk = Ed25519.PublicKey.fromBytes(decoded[10..42].*) catch return MinisigError.InvalidPublicKey;
        return .{
            .key_id = decoded[2..10].*,
            .ed25519 = ed_pk,
        };
    }
};

/// Resolves the Minisign public key text using precedence:
/// 1. `cli_override` (`--minisig-key`)
/// 2. `ZVM_MINISIG_PUBLIC_KEY` env var
/// 3. `<paths.base_dir>/minisig.pub` file
/// 4. Built-in `default_zig_public_key_b64`
pub fn resolvePublicKeyText(
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
    cli_override: ?[]const u8,
) (Allocator.Error || Io.Dir.ReadFileError)![]u8 {
    if (cli_override) |k| {
        const trimmed = std.mem.trim(u8, k, " \t\r\n");
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed);
    }

    if (environ_map) |env| {
        if (env.get("ZVM_MINISIG_PUBLIC_KEY")) |env_k| {
            const trimmed = std.mem.trim(u8, env_k, " \t\r\n");
            if (trimmed.len > 0) return allocator.dupe(u8, trimmed);
        }
    }

    const pub_path = try std.fs.path.join(allocator, &.{ paths.base_dir, "minisig.pub" });
    defer allocator.free(pub_path);

    var buf: [512]u8 = undefined;
    if (Io.Dir.cwd().readFile(io, pub_path, &buf)) |bytes| {
        const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    return allocator.dupe(u8, default_zig_public_key_b64);
}

pub const ParsedSignature = struct {
    prehashed: bool,
    key_id: [8]u8,
    signature: [64]u8,
    trusted_comment: []const u8,
    global_signature: [64]u8,

    /// Parses a 4-line `.minisig` file buffer. `trusted_comment` slices into `minisig_text`.
    pub fn parse(minisig_text: []const u8) MinisigError!ParsedSignature {
        var lines = std.mem.splitScalar(u8, minisig_text, '\n');

        const line1 = std.mem.trimEnd(u8, lines.next() orelse return MinisigError.InvalidSignatureFormat, "\r");
        if (!std.mem.startsWith(u8, line1, "untrusted comment: ")) {
            return MinisigError.InvalidSignatureFormat;
        }

        const line2 = std.mem.trim(u8, lines.next() orelse return MinisigError.InvalidSignatureFormat, " \t\r");
        var sig_bytes: [74]u8 = undefined;
        const sig_len = Base64Decoder.calcSizeForSlice(line2) catch return MinisigError.InvalidSignatureFormat;
        if (sig_len != sig_bytes.len) return MinisigError.InvalidSignatureFormat;
        Base64Decoder.decode(&sig_bytes, line2) catch return MinisigError.InvalidSignatureFormat;

        const prehashed = if (std.mem.eql(u8, sig_bytes[0..2], "ED"))
            true
        else if (std.mem.eql(u8, sig_bytes[0..2], "Ed"))
            false
        else
            return MinisigError.UnsupportedSignatureAlgorithm;

        const line3 = std.mem.trimEnd(u8, lines.next() orelse return MinisigError.InvalidSignatureFormat, "\r");
        const prefix = "trusted comment: ";
        if (!std.mem.startsWith(u8, line3, prefix)) {
            return MinisigError.InvalidSignatureFormat;
        }
        const trusted_comment = line3[prefix.len..];

        const line4 = std.mem.trim(u8, lines.next() orelse return MinisigError.InvalidSignatureFormat, " \t\r");
        var global_sig: [64]u8 = undefined;
        const g_len = Base64Decoder.calcSizeForSlice(line4) catch return MinisigError.InvalidSignatureFormat;
        if (g_len != global_sig.len) return MinisigError.InvalidSignatureFormat;
        Base64Decoder.decode(&global_sig, line4) catch return MinisigError.InvalidSignatureFormat;

        return .{
            .prehashed = prehashed,
            .key_id = sig_bytes[2..10].*,
            .signature = sig_bytes[10..74].*,
            .trusted_comment = trusted_comment,
            .global_signature = global_sig,
        };
    }
};

/// Verifies an in-memory payload against a `.minisig` signature and base64 public key.
pub fn verifyBytes(
    allocator: Allocator,
    payload: []const u8,
    minisig_text: []const u8,
    pubkey_b64: []const u8,
) (MinisigError || Allocator.Error)!void {
    const pk = try PublicKey.parse(pubkey_b64);
    const sig = try ParsedSignature.parse(minisig_text);
    if (!std.mem.eql(u8, &pk.key_id, &sig.key_id)) return MinisigError.KeyIdMismatch;

    const ed_sig = Ed25519.Signature.fromBytes(sig.signature);
    if (sig.prehashed) {
        var digest: [Blake2b512.digest_length]u8 = undefined;
        Blake2b512.hash(payload, &digest, .{});
        ed_sig.verify(&digest, pk.ed25519) catch return MinisigError.SignatureVerificationFailed;
    } else {
        ed_sig.verify(payload, pk.ed25519) catch return MinisigError.SignatureVerificationFailed;
    }

    try verifyGlobalSignature(allocator, pk.ed25519, sig);
}

/// Verifies a file on disk against a `.minisig` signature and base64 public key.
pub fn verifyFile(
    io: Io,
    allocator: Allocator,
    file_path: []const u8,
    minisig_text: []const u8,
    pubkey_b64: []const u8,
) (MinisigError || Allocator.Error || Io.File.OpenError || Io.File.ReadPositionalError || Io.Dir.ReadFileAllocError)!void {
    const pk = try PublicKey.parse(pubkey_b64);
    const sig = try ParsedSignature.parse(minisig_text);
    if (!std.mem.eql(u8, &pk.key_id, &sig.key_id)) return MinisigError.KeyIdMismatch;

    var file = try Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);

    const ed_sig = Ed25519.Signature.fromBytes(sig.signature);
    if (sig.prehashed) {
        var hasher = Blake2b512.init(.{});
        var buf: [32 * 1024]u8 = undefined;
        var offset: u64 = 0;
        while (true) {
            const n = try file.readPositionalAll(io, &buf, offset);
            if (n == 0) break;
            hasher.update(buf[0..n]);
            offset += n;
        }
        var digest: [Blake2b512.digest_length]u8 = undefined;
        hasher.final(&digest);
        ed_sig.verify(&digest, pk.ed25519) catch return MinisigError.SignatureVerificationFailed;
    } else {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .unlimited);
        defer allocator.free(bytes);
        ed_sig.verify(bytes, pk.ed25519) catch return MinisigError.SignatureVerificationFailed;
    }

    try verifyGlobalSignature(allocator, pk.ed25519, sig);
}

fn verifyGlobalSignature(
    allocator: Allocator,
    pk: Ed25519.PublicKey,
    sig: ParsedSignature,
) (MinisigError || Allocator.Error)!void {
    const global_msg = try allocator.alloc(u8, sig.signature.len + sig.trusted_comment.len);
    defer allocator.free(global_msg);
    @memcpy(global_msg[0..sig.signature.len], &sig.signature);
    @memcpy(global_msg[sig.signature.len..], sig.trusted_comment);

    const ed_global = Ed25519.Signature.fromBytes(sig.global_signature);
    ed_global.verify(global_msg, pk) catch return MinisigError.GlobalSignatureVerificationFailed;
}

test "parse official ziglang.org minisign key and real signature header" {
    const pk = try PublicKey.parse(default_zig_public_key_b64);
    const sample_sig =
        "untrusted comment: signature from minisign secret key\n" ++
        "RUSGOq2NVecA2VBoEOeGzBPCLUN923PdJ8Siq4/5/Yft5EkLCQS/d3Z26i8qvr3E/yADtLLDGeS1g1yq6GHQXNI2oLMXynajRgo=\n" ++
        "trusted comment: timestamp:1790965431\tfile:zig-x86_64-linux-0.17.0.tar.xz\thashed\n" ++
        "sRbmsqhOqH2oWybcev78e/pu1CRtIZ2Ga/YW2G/WGv79JHI2Sat9FpkGSo2Sik31aJbuPjxGV8tAdBgci59rDQ==\n";

    const parsed = try ParsedSignature.parse(sample_sig);
    try std.testing.expect(parsed.prehashed);
    try std.testing.expectEqualSlices(u8, &pk.key_id, &parsed.key_id);
    try std.testing.expectEqualStrings("timestamp:1790965431\tfile:zig-x86_64-linux-0.17.0.tar.xz\thashed", parsed.trusted_comment);
}

test "verifyBytes and verifyFile with generated Ed25519 keypair" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Encoder = std.base64.standard.Encoder;

    const kp = Ed25519.KeyPair.generate(io);
    const key_id = [8]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };

    var pk_raw: [42]u8 = undefined;
    @memcpy(pk_raw[0..2], "Ed");
    pk_raw[2..10].* = key_id;
    pk_raw[10..42].* = kp.public_key.toBytes();
    var pk_b64: [Encoder.calcSize(42)]u8 = undefined;
    _ = Encoder.encode(&pk_b64, &pk_raw);

    const payload = "zig archive binary payload";
    var digest: [Blake2b512.digest_length]u8 = undefined;
    Blake2b512.hash(payload, &digest, .{});

    const data_sig = (try kp.sign(&digest, null)).toBytes();

    var sig_raw: [74]u8 = undefined;
    @memcpy(sig_raw[0..2], "ED");
    sig_raw[2..10].* = key_id;
    sig_raw[10..74].* = data_sig;
    var sig_b64: [Encoder.calcSize(74)]u8 = undefined;
    _ = Encoder.encode(&sig_b64, &sig_raw);

    const trusted_comment = "timestamp:1700000000\tfile:test.tar.xz\thashed";
    var global_msg: [64 + trusted_comment.len]u8 = undefined;
    global_msg[0..64].* = data_sig;
    @memcpy(global_msg[64..], trusted_comment);
    const global_sig = (try kp.sign(&global_msg, null)).toBytes();
    var global_b64: [Encoder.calcSize(64)]u8 = undefined;
    _ = Encoder.encode(&global_b64, &global_sig);

    const minisig_text = try allocator.print(
        "untrusted comment: test\n{s}\ntrusted comment: {s}\n{s}\n",
        .{ sig_b64, trusted_comment, global_b64 },
    );
    defer allocator.free(minisig_text);

    try verifyBytes(allocator, payload, minisig_text, &pk_b64);
    try std.testing.expectError(MinisigError.SignatureVerificationFailed, verifyBytes(allocator, "tampered", minisig_text, &pk_b64));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "artifact.bin" });
    defer allocator.free(tmp_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = payload });

    try verifyFile(io, allocator, tmp_path, minisig_text, &pk_b64);
}

test "resolvePublicKeyText honors CLI, env, minisig.pub, and default fallback" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();
    try paths.ensureDirs(io);

    const k_default = try resolvePublicKeyText(&paths, io, allocator, null, null);
    defer allocator.free(k_default);
    try std.testing.expectEqualStrings(default_zig_public_key_b64, k_default);

    const pub_path = try std.fs.path.join(allocator, &.{ paths.base_dir, "minisig.pub" });
    defer allocator.free(pub_path);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = pub_path,
        .data = "untrusted comment: custom\nRWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U\n",
    });
    const k_file = try resolvePublicKeyText(&paths, io, allocator, null, null);
    defer allocator.free(k_file);
    _ = try PublicKey.parse(k_file);

    var env = EnvironMap.init(allocator);
    defer env.deinit();
    try env.put("ZVM_MINISIG_PUBLIC_KEY", "ENV_KEY");
    const k_env = try resolvePublicKeyText(&paths, io, allocator, &env, null);
    defer allocator.free(k_env);
    try std.testing.expectEqualStrings("ENV_KEY", k_env);

    const k_cli = try resolvePublicKeyText(&paths, io, allocator, &env, "CLI_KEY");
    defer allocator.free(k_cli);
    try std.testing.expectEqualStrings("CLI_KEY", k_cli);
}
