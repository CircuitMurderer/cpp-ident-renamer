const std = @import("std");
const scanner = @import("scanner.zig");

const max_source_size = 1024 * 1024 * 1024;

const FileSnapshot = struct {
    path: []const u8,
    original: []u8,
    updated: []u8,
    replacement_count: usize,
};

pub const Transaction = struct {
    files: std.ArrayList(FileSnapshot) = .empty,
    replacement_count: usize = 0,

    pub fn deinit(self: *Transaction, allocator: std.mem.Allocator) void {
        for (self.files.items) |snapshot| {
            allocator.free(snapshot.path);
            allocator.free(snapshot.original);
            allocator.free(snapshot.updated);
        }
        self.files.deinit(allocator);
    }

    pub fn rollback(self: *const Transaction, io: std.Io, allocator: std.mem.Allocator) !void {
        var i = self.files.items.len;
        while (i > 0) {
            i -= 1;
            const snapshot = self.files.items[i];
            const current = try std.Io.Dir.cwd().readFileAlloc(
                io,
                snapshot.path,
                allocator,
                .limited(max_source_size),
            );
            defer allocator.free(current);

            if (!std.mem.eql(u8, current, snapshot.updated)) {
                std.log.err("cannot safely roll back {s}: file changed after cpp-ident-renamer wrote it", .{snapshot.path});
                return error.SourceChangedDuringVerification;
            }

            try writeAtomic(io, snapshot.path, snapshot.original);
        }
    }
};

pub fn apply(
    io: std.Io,
    allocator: std.mem.Allocator,
    replacements: []const scanner.Replacement,
) !Transaction {
    var transaction = Transaction{};
    errdefer transaction.deinit(allocator);

    var start: usize = 0;
    while (start < replacements.len) {
        var end = start + 1;
        while (end < replacements.len and std.mem.eql(u8, replacements[start].file, replacements[end].file)) : (end += 1) {}

        const original = try std.Io.Dir.cwd().readFileAlloc(
            io,
            replacements[start].file,
            allocator,
            .limited(max_source_size),
        );
        var original_owned = true;
        errdefer if (original_owned) allocator.free(original);

        const updated = try buildUpdatedFile(allocator, original, replacements[start..end]);
        var updated_owned = true;
        errdefer if (updated_owned) allocator.free(updated);

        const path = try allocator.dupe(u8, replacements[start].file);
        var path_owned = true;
        errdefer if (path_owned) allocator.free(path);

        try transaction.files.append(allocator, .{
            .path = path,
            .original = original,
            .updated = updated,
            .replacement_count = end - start,
        });

        original_owned = false;
        updated_owned = false;
        path_owned = false;
        transaction.replacement_count += end - start;
        start = end;
    }

    var written: usize = 0;
    errdefer {
        var i = written;
        while (i > 0) {
            i -= 1;
            const snapshot = transaction.files.items[i];
            writeAtomic(io, snapshot.path, snapshot.original) catch |err| {
                std.log.err("rollback failed for {s}: {t}", .{ snapshot.path, err });
            };
        }
    }

    for (transaction.files.items) |snapshot| {
        const current = try std.Io.Dir.cwd().readFileAlloc(
            io,
            snapshot.path,
            allocator,
            .limited(max_source_size),
        );
        defer allocator.free(current);

        if (!std.mem.eql(u8, current, snapshot.original)) return error.SourceChangedBeforeFix;
        try writeAtomic(io, snapshot.path, snapshot.updated);
        written += 1;
    }

    return transaction;
}

fn buildUpdatedFile(
    allocator: std.mem.Allocator,
    original: []const u8,
    replacements: []const scanner.Replacement,
) ![]u8 {
    var updated_len = original.len;
    var source_position: usize = 0;
    for (replacements) |replacement| {
        const offset: usize = @intCast(replacement.offset);
        if (offset < source_position) return error.OverlappingReplacements;
        if (offset > original.len or replacement.old_name.len > original.len - offset)
            return error.InvalidReplacementOffset;
        if (!std.mem.eql(u8, original[offset .. offset + replacement.old_name.len], replacement.old_name))
            return error.SourceTextMismatch;

        updated_len = try std.math.sub(usize, updated_len, replacement.old_name.len);
        updated_len = try std.math.add(usize, updated_len, replacement.new_name.len);
        source_position = offset + replacement.old_name.len;
    }

    const updated = try allocator.alloc(u8, updated_len);
    errdefer allocator.free(updated);

    source_position = 0;
    var destination_position: usize = 0;
    for (replacements) |replacement| {
        const offset: usize = @intCast(replacement.offset);
        destination_position = copyPart(updated, destination_position, original[source_position..offset]);
        destination_position = copyPart(updated, destination_position, replacement.new_name);
        source_position = offset + replacement.old_name.len;
    }

    _ = copyPart(updated, destination_position, original[source_position..]);

    return updated;
}

fn copyPart(output: []u8, position: usize, part: []const u8) usize {
    @memcpy(output[position..][0..part.len], part);
    return position + part.len;
}

fn writeAtomic(io: std.Io, path: []const u8, contents: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(io, path, .{});

    var atomic = try cwd.createFileAtomic(io, path, .{
        .permissions = stat.permissions,
        .replace = true,
    });
    defer atomic.deinit(io);

    try atomic.file.writeStreamingAll(io, contents);
    try atomic.replace(io);
}

test "builds a file from ordered semantic replacements" {
    const allocator = std.testing.allocator;
    const replacements = [_]scanner.Replacement{
        .{ .file = "sample.cpp", .offset = 4, .old_name = "old", .new_name = "first" },
        .{ .file = "sample.cpp", .offset = 12, .old_name = "old", .new_name = "second" },
    };

    const updated = try buildUpdatedFile(allocator, "int old = old;", &replacements);
    defer allocator.free(updated);
    try std.testing.expectEqualStrings("int first = second;", updated);
}

test "rejects stale source text" {
    const allocator = std.testing.allocator;
    const replacements = [_]scanner.Replacement{
        .{ .file = "sample.cpp", .offset = 4, .old_name = "different", .new_name = "value" },
    };
    try std.testing.expectError(
        error.SourceTextMismatch,
        buildUpdatedFile(allocator, "int old;", &replacements),
    );
}
