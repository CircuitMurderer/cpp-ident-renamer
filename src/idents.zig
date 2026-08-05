const std = @import("std");
const scanner = @import("scanner.zig");

pub const file_name = "idents.tsv";

const max_file_size = 16 * 1024 * 1024;
const marker_length = std.crypto.hash.sha2.Sha256.digest_length * 2;

pub const Selection = struct {
    contents: []u8,
    markers: std.StringHashMap(void),

    pub fn deinit(self: *Selection, allocator: std.mem.Allocator) void {
        self.markers.deinit();
        allocator.free(self.contents);
    }

    pub fn contains(self: *const Selection, diagnostic: scanner.Diagnostic) bool {
        if (!isFixable(diagnostic)) return false;

        const value = marker(diagnostic);
        return self.markers.contains(value[0..]);
    }

    pub fn countSelected(self: *const Selection, diagnostics: []const scanner.Diagnostic) usize {
        var count: usize = 0;
        for (diagnostics) |diagnostic| if (self.contains(diagnostic)) {
            count += 1;
        };
        return count;
    }
};

pub fn load(
    io: std.Io,
    allocator: std.mem.Allocator,
    project_root: []const u8,
) !Selection {
    const path = try std.fs.path.join(allocator, &.{ project_root, file_name });
    defer allocator.free(path);

    const contents = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_file_size),
    ) catch |err| switch (err) {
        error.FileNotFound => try allocator.alloc(u8, 0),
        else => return err,
    };

    return parseOwned(allocator, contents);
}

pub fn write(
    io: std.Io,
    allocator: std.mem.Allocator,
    project_root: []const u8,
    diagnostics: []const scanner.Diagnostic,
) !usize {
    const path = try std.fs.path.join(allocator, &.{ project_root, file_name });
    defer allocator.free(path);

    const cwd = std.Io.Dir.cwd();
    var atomic = try cwd.createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);

    var count: usize = 0;
    for (diagnostics) |diagnostic| {
        if (!isFixable(diagnostic)) continue;

        const value = marker(diagnostic);
        const line = try std.fmt.allocPrint(
            allocator,
            "{s}\t{s}\t{s}\t{s}\t{s}:{d}:{d}\n",
            .{
                value[0..],
                @tagName(diagnostic.kind),
                diagnostic.old_name,
                diagnostic.suggested_name.?,
                diagnostic.file,
                diagnostic.line,
                diagnostic.column,
            },
        );
        defer allocator.free(line);

        try atomic.file.writeStreamingAll(io, line);
        count += 1;
    }

    try atomic.replace(io);
    return count;
}

fn parseOwned(allocator: std.mem.Allocator, contents: []u8) !Selection {
    var markers = std.StringHashMap(void).init(allocator);
    errdefer markers.deinit();
    errdefer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (trimmed.len < marker_length) continue;
        if (trimmed.len > marker_length and !std.ascii.isWhitespace(trimmed[marker_length])) continue;

        const candidate = trimmed[0..marker_length];
        if (!isHex(candidate)) continue;
        try markers.put(candidate, {});
    }

    return .{
        .contents = contents,
        .markers = markers,
    };
}

fn isFixable(diagnostic: scanner.Diagnostic) bool {
    return diagnostic.kind != .unmapped_type and diagnostic.suggested_name != null;
}

fn marker(diagnostic: scanner.Diagnostic) [marker_length]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    updatePart(&hasher, @tagName(diagnostic.kind));
    updatePart(&hasher, diagnostic.usr);
    updatePart(&hasher, diagnostic.old_name);
    updatePart(&hasher, diagnostic.suggested_name.?);
    updatePart(&hasher, diagnostic.file);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn updatePart(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hasher.update(value);
    hasher.update(&.{0});
}

fn isHex(value: []const u8) bool {
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

test "selection accepts valid markers and ignores invalid lines" {
    const allocator = std.testing.allocator;
    const diagnostic = scanner.Diagnostic{
        .file = "/project/sample.cpp",
        .line = 7,
        .column = 9,
        .offset = 42,
        .kind = .variable,
        .usr = "c:sample.cpp@42@value",
        .old_name = "value",
        .suggested_name = "iValue",
        .type_spelling = "int",
    };
    const value = marker(diagnostic);
    const contents = try std.fmt.allocPrint(
        allocator,
        "# reviewed identifiers\ninvalid\n{s}\tvariable\tvalue\tiValue\n",
        .{value[0..]},
    );

    var selection = try parseOwned(allocator, contents);
    defer selection.deinit(allocator);

    try std.testing.expect(selection.contains(diagnostic));
    try std.testing.expectEqual(@as(usize, 1), selection.markers.count());
}

test "marker changes when the proposed rename changes" {
    const first = scanner.Diagnostic{
        .file = "/project/sample.cpp",
        .line = 7,
        .column = 9,
        .offset = 42,
        .kind = .function,
        .usr = "c:@F@bad_name#",
        .old_name = "bad_name",
        .suggested_name = "BadName",
        .type_spelling = null,
    };
    var second = first;
    second.suggested_name = "badName";

    try std.testing.expect(!std.mem.eql(u8, marker(first)[0..], marker(second)[0..]));
}
