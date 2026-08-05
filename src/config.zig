const std = @import("std");

pub const FunctionCase = enum {
    lower_camel,
    snake,
    unchanged,
};

pub const TypeMapping = struct {
    type_name: []const u8,
    prefix: []const u8,
};

pub const Config = struct {
    member_prefix: []const u8 = "m_",
    static_member_prefix: []const u8 = "m_",
    global_prefix: []const u8 = "g_",
    member_function_case: FunctionCase = .lower_camel,
    free_function_case: FunctionCase = .lower_camel,
    use_canonical_type: bool = true,
    pointer_marker: []const u8 = "p",
    mappings: std.ArrayList(TypeMapping) = .empty,
    pointer_mappings: std.ArrayList(TypeMapping) = .empty,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        self.mappings.deinit(allocator);
        self.pointer_mappings.deinit(allocator);
    }

    pub fn initDefaults(allocator: std.mem.Allocator) !Config {
        var config = Config{};
        errdefer config.deinit(allocator);

        const defaults = [_]TypeMapping{
            .{ .type_name = "bool", .prefix = "b" },
            .{ .type_name = "char", .prefix = "ch" },
            .{ .type_name = "short", .prefix = "n" },
            .{ .type_name = "int", .prefix = "n" },
            .{ .type_name = "long", .prefix = "n" },
            .{ .type_name = "long long", .prefix = "n" },
            .{ .type_name = "unsigned int", .prefix = "n" },
            .{ .type_name = "unsigned long", .prefix = "n" },
            .{ .type_name = "float", .prefix = "f" },
            .{ .type_name = "double", .prefix = "d" },
            .{ .type_name = "std::string", .prefix = "s" },
            .{ .type_name = "std::basic_string<char>", .prefix = "s" },
            .{ .type_name = "std::vector", .prefix = "vec" },
            .{ .type_name = "std::map", .prefix = "map" },
        };

        try config.mappings.appendSlice(allocator, &defaults);
        try config.pointer_mappings.append(allocator, .{ .type_name = "char", .prefix = "s" });

        return config;
    }

    pub fn typePrefix(self: *const Config, spelling: []const u8, pointer_depth: usize) ?[]const u8 {
        const normalized = normalizeTypeSpelling(spelling);

        if (pointer_depth > 0) {
            if (findMapping(self.pointer_mappings.items, normalized)) |prefix| return prefix;
        }

        return findMapping(self.mappings.items, normalized);
    }

    fn findMapping(mappings: []const TypeMapping, spelling: []const u8) ?[]const u8 {
        var i = mappings.len;
        while (i > 0) {
            i -= 1;
            const mapping = mappings[i];

            if (std.mem.eql(u8, spelling, mapping.type_name)) return mapping.prefix;
            if (std.mem.startsWith(u8, spelling, mapping.type_name) and
                spelling.len > mapping.type_name.len and
                spelling[mapping.type_name.len] == '<') return mapping.prefix;
        }

        return null;
    }

    fn normalizeTypeSpelling(spelling: []const u8) []const u8 {
        var result = std.mem.trim(u8, spelling, " \t");
        var changed = true;

        while (changed) {
            changed = false;
            inline for (.{ "const ", "volatile ", "restrict " }) |qualifier| {
                if (std.mem.startsWith(u8, result, qualifier)) {
                    result = std.mem.trimStart(u8, result[qualifier.len..], " \t");
                    changed = true;
                }
            }
        }

        return result;
    }
};

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: ?[]const u8) !Config {
    var config = try Config.initDefaults(allocator);
    errdefer config.deinit(allocator);

    const config_path = path orelse "cpp-ident-renamer.toml";

    const contents = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => if (path == null) return config else return err,
        else => return err,
    };
    defer allocator.free(contents);

    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_number: usize = 0;

    while (lines.next()) |raw_line| {
        line_number += 1;

        const without_comment = stripComment(raw_line);
        const line = std.mem.trim(u8, without_comment, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            continue;
        }

        const equals = std.mem.indexOfScalar(u8, line, '=') orelse {
            std.log.err("{s}:{d}: expected key = value", .{ config_path, line_number });
            return error.InvalidConfig;
        };
        const key = std.mem.trim(u8, line[0..equals], " \t");
        const value_text = std.mem.trim(u8, line[equals + 1 ..], " \t");

        if (std.mem.eql(u8, section, "scope")) {
            const value = try parseString(allocator, value_text);
            if (std.mem.eql(u8, key, "member")) config.member_prefix = value else if (std.mem.eql(u8, key, "static_member")) config.static_member_prefix = value else if (std.mem.eql(u8, key, "global")) config.global_prefix = value else return invalidKey(config_path, line_number, section, key);
        } else if (std.mem.eql(u8, section, "functions")) {
            const value = try parseString(allocator, value_text);
            const function_case = parseFunctionCase(value) orelse {
                std.log.err("{s}:{d}: function case must be camel, snake, or unchanged", .{ config_path, line_number });
                return error.InvalidConfig;
            };
            if (std.mem.eql(u8, key, "member")) config.member_function_case = function_case else if (std.mem.eql(u8, key, "free")) config.free_function_case = function_case else return invalidKey(config_path, line_number, section, key);
        } else if (std.mem.eql(u8, section, "types")) {
            const type_name = try parseKey(allocator, key);
            const prefix = try parseString(allocator, value_text);
            try config.mappings.append(allocator, .{ .type_name = type_name, .prefix = prefix });
        } else if (std.mem.eql(u8, section, "pointers")) {
            const value = try parseString(allocator, value_text);
            if (std.mem.eql(u8, key, "marker")) {
                if (value.len == 0) return error.InvalidConfig;
                config.pointer_marker = value;
            } else {
                const type_name = try parseKey(allocator, key);
                try config.pointer_mappings.append(allocator, .{ .type_name = type_name, .prefix = value });
            }
        } else if (section.len == 0 and std.mem.eql(u8, key, "use_canonical_type")) {
            config.use_canonical_type = if (std.mem.eql(u8, value_text, "true")) true else if (std.mem.eql(u8, value_text, "false")) false else return error.InvalidConfig;
        } else {
            return invalidKey(config_path, line_number, section, key);
        }
    }

    return config;
}

fn parseKey(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len > 0 and trimmed[0] == '"') return parseString(allocator, trimmed);
    if (trimmed.len == 0) return error.InvalidConfig;

    for (trimmed) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-'))
        return error.InvalidConfig;

    return allocator.dupe(u8, trimmed);
}

fn parseFunctionCase(value: []const u8) ?FunctionCase {
    if (std.mem.eql(u8, value, "camel")) return .lower_camel;
    if (std.mem.eql(u8, value, "snake")) return .snake;
    if (std.mem.eql(u8, value, "unchanged")) return .unchanged;

    return null;
}

fn parseString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len < 2 or trimmed[0] != '"' or trimmed[trimmed.len - 1] != '"')
        return error.InvalidConfig;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 1;
    while (i + 1 < trimmed.len) : (i += 1) {
        if (trimmed[i] == '\\') {
            i += 1;
            if (i + 1 > trimmed.len) return error.InvalidConfig;
            try result.append(allocator, switch (trimmed[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                '"' => '"',
                else => return error.InvalidConfig,
            });
        } else {
            try result.append(allocator, trimmed[i]);
        }
    }

    return result.toOwnedSlice(allocator);
}

fn stripComment(line: []const u8) []const u8 {
    var quoted = false;
    var escaped = false;

    for (line, 0..) |ch, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch == '\\' and quoted) {
            escaped = true;
        } else if (ch == '"') {
            quoted = !quoted;
        } else if (ch == '#' and !quoted) {
            return line[0..i];
        }
    }

    return line;
}

fn invalidKey(path: []const u8, line: usize, section: []const u8, key: []const u8) error{InvalidConfig} {
    std.log.err("{s}:{d}: unknown key [{s}].{s}", .{ path, line, section, key });
    return error.InvalidConfig;
}

test "TOML type keys may be bare or quoted" {
    const allocator = std.testing.allocator;
    const bare = try parseKey(allocator, "int");
    defer allocator.free(bare);
    try std.testing.expectEqualStrings("int", bare);

    const quoted = try parseKey(allocator, "\"project::Request\"");
    defer allocator.free(quoted);
    try std.testing.expectEqualStrings("project::Request", quoted);
}
