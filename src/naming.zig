const std = @import("std");
const config_mod = @import("config.zig");

pub const VariableScope = enum {
    local,
    static_local,
    member,
    static_member,
    global,
    static_global,
};

pub fn variableName(
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    scope: VariableScope,
    is_top_level_const: bool,
    type_spelling: []const u8,
    pointer_depth: usize,
    old_name: []const u8,
) !?[]u8 {
    const alternatives = switch (scope) {
        .local => config.local_alternatives.items,
        .static_local => config.static_local_alternatives.items,
        .member => config.member_alternatives.items,
        .static_member => config.static_member_alternatives.items,
        .global => config.global_alternatives.items,
        .static_global => config.static_global_alternatives.items,
    };

    if (matchesAlternative(alternatives, old_name)) return try allocator.dupe(u8, old_name);

    if (is_top_level_const) {
        const const_alternatives = switch (scope) {
            .local => config.const_local_alternatives.items,
            .static_local => config.const_static_local_alternatives.items,
            .member => config.const_member_alternatives.items,
            .static_member => config.const_static_member_alternatives.items,
            .global => config.const_global_alternatives.items,
            .static_global => config.const_static_global_alternatives.items,
        };

        if (matchesAlternative(const_alternatives, old_name)) return try allocator.dupe(u8, old_name);
    }

    const type_prefix = config.typePrefix(type_spelling, pointer_depth) orelse return null;
    const scope_prefix = switch (scope) {
        .local => config.local_prefix,
        .static_local => config.static_local_prefix,
        .member => config.member_prefix,
        .static_member => config.static_member_prefix,
        .global => config.global_prefix,
        .static_global => config.static_global_prefix,
    };

    const base = stripKnownPrefix(config, scope_prefix, type_prefix, pointer_depth, old_name);
    const cased_base = switch (config.variable_case) {
        .lower_camel => try toLowerCamel(allocator, base),
        .pascal => try toPascal(allocator, base),
        .snake => try toSnake(allocator, base),
    };
    defer allocator.free(cased_base);

    const result_len = scope_prefix.len + config.pointer_marker.len * pointer_depth + type_prefix.len + cased_base.len;
    const result = try allocator.alloc(u8, result_len);

    var position: usize = 0;
    position = copyPart(result, position, scope_prefix);
    for (0..pointer_depth) |_| position = copyPart(result, position, config.pointer_marker);
    position = copyPart(result, position, type_prefix);
    _ = copyPart(result, position, cased_base);

    return result;
}

fn matchesAlternative(alternatives: []const config_mod.VariableStyle, name: []const u8) bool {
    for (alternatives) |style| switch (style) {
        .upper_snake => if (isUpperSnake(name)) return true,
    };

    return false;
}

fn isUpperSnake(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isUpper(name[0])) return false;

    var previous_underscore = false;
    for (name) |ch| {
        if (ch == '_') {
            if (previous_underscore) return false;
            previous_underscore = true;
        } else {
            if (!std.ascii.isUpper(ch) and !std.ascii.isDigit(ch)) return false;
            previous_underscore = false;
        }
    }

    return !previous_underscore;
}

pub fn functionName(
    allocator: std.mem.Allocator,
    function_case: config_mod.FunctionCase,
    old_name: []const u8,
) ![]u8 {
    return switch (function_case) {
        .lower_camel => toLowerCamel(allocator, old_name),
        .pascal => toPascal(allocator, old_name),
        .snake => toSnake(allocator, old_name),
        .unchanged => allocator.dupe(u8, old_name),
    };
}

fn copyPart(output: []u8, position: usize, part: []const u8) usize {
    @memcpy(output[position..][0..part.len], part);
    return position + part.len;
}

fn stripKnownPrefix(
    config: *const config_mod.Config,
    scope_prefix: []const u8,
    type_prefix: []const u8,
    pointer_depth: usize,
    name: []const u8,
) []const u8 {
    var result = name;
    if (scope_prefix.len > 0 and std.mem.startsWith(u8, result, scope_prefix)) {
        result = result[scope_prefix.len..];
    } else inline for (.{
        config.local_prefix,
        config.static_local_prefix,
        config.member_prefix,
        config.static_member_prefix,
        config.global_prefix,
        config.static_global_prefix,
    }) |known_scope| {
        if (known_scope.len > 0 and std.mem.startsWith(u8, result, known_scope)) {
            result = result[known_scope.len..];
            break;
        }
    }

    var expected_end: usize = 0;
    for (0..pointer_depth) |_| {
        if (!std.mem.startsWith(u8, result[expected_end..], config.pointer_marker)) break;
        expected_end += config.pointer_marker.len;
    }

    if (expected_end == config.pointer_marker.len * pointer_depth and
        hasConventionPrefix(result[expected_end..], type_prefix))
        return result[expected_end + type_prefix.len ..];

    var after_pointers: usize = 0;
    while (config.pointer_marker.len > 0 and
        std.mem.startsWith(u8, result[after_pointers..], config.pointer_marker))
    {
        after_pointers += config.pointer_marker.len;
    }

    if (after_pointers > 0) {
        if (stripMappedPrefix(config.pointer_mappings.items, result[after_pointers..])) |base| return base;
        if (stripMappedPrefix(config.mappings.items, result[after_pointers..])) |base| return base;
    }

    if (stripMappedPrefix(config.pointer_mappings.items, result)) |base| return base;
    if (stripMappedPrefix(config.mappings.items, result)) |base| return base;
    return result;
}

fn stripMappedPrefix(mappings: []const config_mod.TypeMapping, name: []const u8) ?[]const u8 {
    for (mappings) |mapping| if (hasConventionPrefix(name, mapping.prefix))
        return name[mapping.prefix.len..];
    return null;
}

fn hasConventionPrefix(name: []const u8, prefix: []const u8) bool {
    return prefix.len > 0 and name.len > prefix.len and std.mem.startsWith(u8, name, prefix) and
        std.ascii.isUpper(name[prefix.len]);
}

fn toPascal(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var capitalize = true;
    for (input) |ch| {
        if (ch == '_' or ch == '-' or ch == ' ') {
            capitalize = true;
            continue;
        }
        try out.append(allocator, if (capitalize) std.ascii.toUpper(ch) else ch);
        capitalize = false;
    }

    return out.toOwnedSlice(allocator);
}

fn toLowerCamel(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const pascal = try toPascal(allocator, input);
    if (pascal.len == 0) return pascal;

    var run: usize = 0;
    while (run < pascal.len and std.ascii.isUpper(pascal[run])) : (run += 1) {}

    const lower_count = if (run > 1 and run < pascal.len) run - 1 else run;
    for (pascal[0..lower_count]) |*ch| ch.* = std.ascii.toLower(ch.*);

    return pascal;
}

fn toSnake(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (input, 0..) |ch, i| {
        if (ch == '-' or ch == ' ') {
            if (out.items.len > 0 and out.items[out.items.len - 1] != '_') try out.append(allocator, '_');
            continue;
        }
        if (std.ascii.isUpper(ch) and i > 0 and input[i - 1] != '_' and
            (!std.ascii.isUpper(input[i - 1]) or (i + 1 < input.len and std.ascii.isLower(input[i + 1]))))
            try out.append(allocator, '_');
        try out.append(allocator, std.ascii.toLower(ch));
    }

    return out.toOwnedSlice(allocator);
}

test "variable naming strips an existing convention" {
    const allocator = std.testing.allocator;
    var config = try config_mod.Config.initDefaults(allocator);
    defer config.deinit(allocator);

    const first = (try variableName(allocator, &config, .member, false, "int", 0, "numberOfSlice")).?;
    defer allocator.free(first);
    try std.testing.expectEqualStrings("m_nNumberOfSlice", first);

    const second = (try variableName(allocator, &config, .member, false, "int", 0, "m_sNumberOfSlice")).?;
    defer allocator.free(second);
    try std.testing.expectEqualStrings("m_nNumberOfSlice", second);
}

test "pointer depth sits between scope and type prefixes" {
    const allocator = std.testing.allocator;
    var config = try config_mod.Config.initDefaults(allocator);
    defer config.deinit(allocator);

    const member = (try variableName(allocator, &config, .member, false, "char", 1, "name")).?;
    defer allocator.free(member);
    try std.testing.expectEqualStrings("m_psName", member);

    const global = (try variableName(allocator, &config, .global, false, "const char", 2, "names")).?;
    defer allocator.free(global);
    try std.testing.expectEqualStrings("g_ppsNames", global);

    const corrected = (try variableName(allocator, &config, .member, false, "char", 1, "m_pchName")).?;
    defer allocator.free(corrected);
    try std.testing.expectEqualStrings("m_psName", corrected);

    const integer = (try variableName(allocator, &config, .member, false, "int", 1, "count")).?;
    defer allocator.free(integer);
    try std.testing.expectEqualStrings("m_pnCount", integer);
}

test "local and static variables keep Hungarian type prefixes" {
    const allocator = std.testing.allocator;
    var config = try config_mod.Config.initDefaults(allocator);
    defer config.deinit(allocator);

    const local = (try variableName(allocator, &config, .local, false, "char", 1, "funcName")).?;
    defer allocator.free(local);
    try std.testing.expectEqualStrings("psFuncName", local);

    const static_local = (try variableName(allocator, &config, .static_local, false, "char", 1, "funcName")).?;
    defer allocator.free(static_local);
    try std.testing.expectEqualStrings("s_psFuncName", static_local);

    const static_member = (try variableName(allocator, &config, .static_member, false, "int", 0, "count")).?;
    defer allocator.free(static_member);
    try std.testing.expectEqualStrings("s_nCount", static_member);
}

test "camel variables allow an empty type prefix" {
    const allocator = std.testing.allocator;
    var config = try config_mod.Config.initDefaults(allocator);
    defer config.deinit(allocator);
    config.variable_case = .lower_camel;
    try config.mappings.append(allocator, .{ .type_name = "int", .prefix = "" });

    const member = (try variableName(allocator, &config, .member, false, "int", 0, "func_name")).?;
    defer allocator.free(member);
    try std.testing.expectEqualStrings("m_funcName", member);

    const migrated = (try variableName(allocator, &config, .member, false, "int", 0, "m_nFuncName")).?;
    defer allocator.free(migrated);
    try std.testing.expectEqualStrings("m_funcName", migrated);
}

test "snake variables allow an empty type prefix" {
    const allocator = std.testing.allocator;
    var config = try config_mod.Config.initDefaults(allocator);
    defer config.deinit(allocator);
    config.variable_case = .snake;
    try config.mappings.append(allocator, .{ .type_name = "int", .prefix = "" });

    const member = (try variableName(allocator, &config, .member, false, "int", 0, "FuncName")).?;
    defer allocator.free(member);
    try std.testing.expectEqualStrings("m_func_name", member);
}

test "global upper snake is accepted as an alternative" {
    const allocator = std.testing.allocator;
    var config = try config_mod.Config.initDefaults(allocator);
    defer config.deinit(allocator);
    try config.global_alternatives.append(allocator, .upper_snake);

    const alternative = (try variableName(allocator, &config, .global, false, "int", 0, "TIME_ESCAPE")).?;
    defer allocator.free(alternative);
    try std.testing.expectEqualStrings("TIME_ESCAPE", alternative);

    const primary = (try variableName(allocator, &config, .global, false, "int", 0, "g_nTimeEscape")).?;
    defer allocator.free(primary);
    try std.testing.expectEqualStrings("g_nTimeEscape", primary);

    const invalid = (try variableName(allocator, &config, .global, false, "int", 0, "time_escape")).?;
    defer allocator.free(invalid);
    try std.testing.expect(!std.mem.eql(u8, "time_escape", invalid));
}

test "const alternatives require a top-level const variable" {
    const allocator = std.testing.allocator;
    var config = try config_mod.Config.initDefaults(allocator);
    defer config.deinit(allocator);
    try config.const_global_alternatives.append(allocator, .upper_snake);

    const accepted = (try variableName(allocator, &config, .global, true, "int", 0, "TIME_ESCAPE")).?;
    defer allocator.free(accepted);
    try std.testing.expectEqualStrings("TIME_ESCAPE", accepted);

    const rejected = (try variableName(allocator, &config, .global, false, "int", 0, "TIME_ESCAPE")).?;
    defer allocator.free(rejected);
    try std.testing.expect(!std.mem.eql(u8, "TIME_ESCAPE", rejected));
}

test "function casing handles PascalCase and initialisms" {
    const allocator = std.testing.allocator;

    const normal = try functionName(allocator, .lower_camel, "GetSize");
    defer allocator.free(normal);
    try std.testing.expectEqualStrings("getSize", normal);

    const acronym = try functionName(allocator, .lower_camel, "HTTPServer");
    defer allocator.free(acronym);
    try std.testing.expectEqualStrings("httpServer", acronym);

    const pascal = try functionName(allocator, .pascal, "compute_value");
    defer allocator.free(pascal);
    try std.testing.expectEqualStrings("ComputeValue", pascal);

    const snake = try functionName(allocator, .snake, "CalculateHTTPValue");
    defer allocator.free(snake);
    try std.testing.expectEqualStrings("calculate_http_value", snake);
}
