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

    const pointer_separator = pointerSeparator(config, type_prefix, pointer_depth);
    const type_separator = typeSeparator(config, type_prefix);
    const pascal_base = config.variable_case == .pascal;
    const base = stripKnownPrefix(
        config,
        scope_prefix,
        type_prefix,
        pointer_depth,
        pointer_separator,
        type_separator,
        pascal_base,
        type_spelling,
        old_name,
    );
    const cased_base = switch (config.variable_case) {
        .lower_camel => try toLowerCamel(allocator, base),
        .pascal => try toPascal(allocator, base),
        .snake => try toSnake(allocator, base),
    };
    defer allocator.free(cased_base);

    const result_len = scope_prefix.len + config.pointer_marker.len * pointer_depth +
        pointer_separator.len + type_prefix.len + type_separator.len + cased_base.len;
    const result = try allocator.alloc(u8, result_len);

    var position: usize = 0;
    position = copyPart(result, position, scope_prefix);
    for (0..pointer_depth) |_| position = copyPart(result, position, config.pointer_marker);
    position = copyPart(result, position, pointer_separator);
    position = copyPart(result, position, type_prefix);
    position = copyPart(result, position, type_separator);
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
    pointer_separator: []const u8,
    type_separator: []const u8,
    pascal_base: bool,
    type_spelling: []const u8,
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

    var matched_expected_prefix = expected_end == config.pointer_marker.len * pointer_depth;
    if (matched_expected_prefix and pointer_separator.len > 0) {
        if (std.mem.startsWith(u8, result[expected_end..], pointer_separator)) {
            expected_end += pointer_separator.len;
        } else {
            matched_expected_prefix = false;
        }
    }

    const has_expected_prefix = expected_end > 0 or type_prefix.len > 0;
    const pointer_boundary = pointer_separator.len > 0 or
        (pointer_depth > 0 and config.pointer_marker[config.pointer_marker.len - 1] == '_');
    if (matched_expected_prefix and has_expected_prefix and
        hasExpectedTypePrefix(
            result[expected_end..],
            type_prefix,
            type_separator,
            pascal_base,
            pointer_boundary,
        ))
        return result[expected_end + type_prefix.len + type_separator.len ..];

    var after_pointers: usize = 0;
    for (0..pointer_depth) |_| {
        if (!std.mem.startsWith(u8, result[after_pointers..], config.pointer_marker)) break;
        after_pointers += config.pointer_marker.len;
    }

    const expected_pointer_length = config.pointer_marker.len * pointer_depth;
    if (after_pointers > 0 and after_pointers == expected_pointer_length) {
        const after_pointer_name = result[after_pointers..];
        if (stripMappedPrefix(config.pointer_mappings.items, type_spelling, after_pointer_name)) |base| return base;
        if (stripMappedPrefix(config.mappings.items, type_spelling, after_pointer_name)) |base| return base;
        if (config.legacy_prefixes) {
            if (stripMappedPrefix(config.legacy_pointer_mappings.items, type_spelling, after_pointer_name)) |base| return base;
            if (stripMappedPrefix(config.legacy_mappings.items, type_spelling, after_pointer_name)) |base| return base;
        } else {
            if (stripMappedPrefix(config.legacy_pointer_mappings.items, type_spelling, after_pointer_name)) |_| return after_pointer_name;
            if (stripMappedPrefix(config.legacy_mappings.items, type_spelling, after_pointer_name)) |_| return after_pointer_name;
        }

        if (type_prefix.len == 0 and
            after_pointers < result.len and std.ascii.isUpper(result[after_pointers]))
            return result[after_pointers..];
    }

    if (pointer_depth > 0) {
        if (stripMappedPrefix(config.pointer_mappings.items, type_spelling, result)) |base| return base;
        if (config.legacy_prefixes) {
            if (stripMappedPrefix(config.legacy_pointer_mappings.items, type_spelling, result)) |base| return base;
        }
    }

    if (stripMappedPrefix(config.mappings.items, type_spelling, result)) |base| return base;
    if (config.legacy_prefixes) {
        if (stripMappedPrefix(config.legacy_mappings.items, type_spelling, result)) |base| return base;
    }

    return result;
}

fn stripMappedPrefix(
    mappings: []const config_mod.TypeMapping,
    type_spelling: []const u8,
    name: []const u8,
) ?[]const u8 {
    for (mappings) |mapping| {
        if (!config_mod.typeNameMatches(type_spelling, mapping.type_name)) continue;
        if (stripConventionPrefix(name, mapping.prefix)) |base| return base;
    }
    return null;
}

fn pointerSeparator(
    config: *const config_mod.Config,
    type_prefix: []const u8,
    pointer_depth: usize,
) []const u8 {
    if (pointer_depth == 0 or type_prefix.len > 0 or config.variable_case == .pascal)
        return "";
    if (config.pointer_marker[config.pointer_marker.len - 1] == '_') return "";

    return "_";
}

fn typeSeparator(
    config: *const config_mod.Config,
    type_prefix: []const u8,
) []const u8 {
    if (config.variable_case == .pascal or type_prefix.len == 0) return "";
    if (type_prefix[type_prefix.len - 1] == '_') return "";

    return "_";
}

fn hasExpectedTypePrefix(
    name: []const u8,
    prefix: []const u8,
    type_separator: []const u8,
    pascal_base: bool,
    pointer_boundary: bool,
) bool {
    const combined_length = prefix.len + type_separator.len;
    if (name.len <= combined_length or !std.mem.startsWith(u8, name, prefix))
        return false;
    if (!std.mem.startsWith(u8, name[prefix.len..], type_separator)) return false;

    if (pointer_boundary or type_separator.len > 0 or
        (prefix.len > 0 and prefix[prefix.len - 1] == '_')) return true;
    return pascal_base and std.ascii.isUpper(name[combined_length]);
}

fn stripConventionPrefix(name: []const u8, prefix: []const u8) ?[]const u8 {
    if (prefix.len == 0 or name.len <= prefix.len or !std.mem.startsWith(u8, name, prefix))
        return null;

    const base = name[prefix.len..];
    if (prefix[prefix.len - 1] == '_' or std.ascii.isUpper(base[0])) return base;

    if (base[0] == '_' and base.len > 1) return base[1..];
    return null;
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

test "variable naming applies and preserves its configured convention" {
    const allocator = std.testing.allocator;
    var config = try config_mod.Config.initDefaults(allocator);
    defer config.deinit(allocator);
    try config.mappings.append(allocator, .{ .type_name = "int", .prefix = "n" });
    try config.mappings.append(allocator, .{ .type_name = "std::string", .prefix = "s" });

    const first = (try variableName(allocator, &config, .member, false, "int", 0, "numberOfSlice")).?;
    defer allocator.free(first);
    try std.testing.expectEqualStrings("m_nNumberOfSlice", first);

    const second = (try variableName(allocator, &config, .member, false, "int", 0, "m_nNumberOfSlice")).?;
    defer allocator.free(second);
    try std.testing.expectEqualStrings("m_nNumberOfSlice", second);
}

test "legacy prefixes only apply to their actual type and pointer state" {
    const allocator = std.testing.allocator;
    var config = try config_mod.Config.initDefaults(allocator);
    defer config.deinit(allocator);
    config.variable_case = .lower_camel;

    const unrelated = (try variableName(allocator, &config, .member, false, "int", 0, "m_sValue")).?;
    defer allocator.free(unrelated);
    try std.testing.expectEqualStrings("m_sValue", unrelated);

    const integer = (try variableName(allocator, &config, .member, false, "int", 0, "m_nValue")).?;
    defer allocator.free(integer);
    try std.testing.expectEqualStrings("m_value", integer);

    const string = (try variableName(allocator, &config, .member, false, "std::string", 0, "m_sValue")).?;
    defer allocator.free(string);
    try std.testing.expectEqualStrings("m_value", string);

    const non_pointer_char = (try variableName(allocator, &config, .member, false, "char", 0, "m_sValue")).?;
    defer allocator.free(non_pointer_char);
    try std.testing.expectEqualStrings("m_sValue", non_pointer_char);

    const pointer_char = (try variableName(allocator, &config, .member, false, "char", 1, "m_pchName")).?;
    defer allocator.free(pointer_char);
    try std.testing.expectEqualStrings("m_p_name", pointer_char);
}

test "legacy prefix migration can be disabled independently" {
    const allocator = std.testing.allocator;
    var config = try config_mod.Config.initDefaults(allocator);
    defer config.deinit(allocator);
    config.variable_case = .lower_camel;
    config.legacy_prefixes = false;

    const integer = (try variableName(allocator, &config, .member, false, "int", 0, "m_nValue")).?;
    defer allocator.free(integer);
    try std.testing.expectEqualStrings("m_nValue", integer);

    const string = (try variableName(allocator, &config, .member, false, "std::string", 0, "m_sValue")).?;
    defer allocator.free(string);
    try std.testing.expectEqualStrings("m_sValue", string);

    const pointer_char = (try variableName(allocator, &config, .member, false, "char", 1, "m_psName")).?;
    defer allocator.free(pointer_char);
    try std.testing.expectEqualStrings("m_p_sName", pointer_char);

    try config.mappings.append(allocator, .{ .type_name = "int", .prefix = "n" });
    const configured = (try variableName(allocator, &config, .member, false, "int", 0, "m_nValue")).?;
    defer allocator.free(configured);
    try std.testing.expectEqualStrings("m_n_value", configured);
}

test "automatic prefix separators migrate in one pass across cases" {
    const allocator = std.testing.allocator;
    var config = try config_mod.Config.initDefaults(allocator);
    defer config.deinit(allocator);

    config.variable_case = .lower_camel;
    const camel = (try variableName(allocator, &config, .member, false, "int", 0, "m_n_value")).?;
    defer allocator.free(camel);
    try std.testing.expectEqualStrings("m_value", camel);

    const camel_again = (try variableName(allocator, &config, .member, false, "int", 0, camel)).?;
    defer allocator.free(camel_again);
    try std.testing.expectEqualStrings(camel, camel_again);

    const pointer = (try variableName(allocator, &config, .member, false, "int", 1, "m_pn_value")).?;
    defer allocator.free(pointer);
    try std.testing.expectEqualStrings("m_p_value", pointer);

    config.variable_case = .snake;
    const snake = (try variableName(allocator, &config, .member, false, "int", 0, "m_n_value")).?;
    defer allocator.free(snake);
    try std.testing.expectEqualStrings("m_value", snake);

    config.variable_case = .pascal;
    try config.mappings.append(allocator, .{ .type_name = "int", .prefix = "n" });

    const pascal = (try variableName(allocator, &config, .member, false, "int", 0, "m_n_value")).?;
    defer allocator.free(pascal);
    try std.testing.expectEqualStrings("m_nValue", pascal);

    const pascal_again = (try variableName(allocator, &config, .member, false, "int", 0, pascal)).?;
    defer allocator.free(pascal_again);
    try std.testing.expectEqualStrings(pascal, pascal_again);
}

test "pointer depth sits between scope and type prefixes" {
    const allocator = std.testing.allocator;
    var config = try config_mod.Config.initDefaults(allocator);
    defer config.deinit(allocator);
    try config.mappings.append(allocator, .{ .type_name = "int", .prefix = "n" });
    try config.pointer_mappings.append(allocator, .{ .type_name = "char", .prefix = "s" });

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
    try config.mappings.append(allocator, .{ .type_name = "int", .prefix = "n" });
    try config.pointer_mappings.append(allocator, .{ .type_name = "char", .prefix = "s" });

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

test "empty type prefixes separate pointer markers for camel and snake" {
    const allocator = std.testing.allocator;
    var config = try config_mod.Config.initDefaults(allocator);
    defer config.deinit(allocator);

    const pascal = (try variableName(allocator, &config, .member, false, "int", 1, "funcName")).?;
    defer allocator.free(pascal);
    try std.testing.expectEqualStrings("m_pFuncName", pascal);

    config.variable_case = .lower_camel;
    const camel = (try variableName(allocator, &config, .member, false, "int", 1, "funcName")).?;
    defer allocator.free(camel);
    try std.testing.expectEqualStrings("m_p_funcName", camel);

    const camel_again = (try variableName(allocator, &config, .member, false, "int", 1, camel)).?;
    defer allocator.free(camel_again);
    try std.testing.expectEqualStrings(camel, camel_again);

    config.variable_case = .snake;
    const snake = (try variableName(allocator, &config, .member, false, "int", 1, "FuncName")).?;
    defer allocator.free(snake);
    try std.testing.expectEqualStrings("m_p_func_name", snake);

    const double_pointer = (try variableName(allocator, &config, .member, false, "int", 2, "FuncName")).?;
    defer allocator.free(double_pointer);
    try std.testing.expectEqualStrings("m_pp_func_name", double_pointer);
}

test "camel and snake append only a missing type separator" {
    const allocator = std.testing.allocator;
    var config = try config_mod.Config.initDefaults(allocator);
    defer config.deinit(allocator);

    config.variable_case = .lower_camel;
    try config.mappings.append(allocator, .{ .type_name = "int", .prefix = "n" });

    const natural_prefix = (try variableName(allocator, &config, .member, false, "int", 0, "number")).?;
    defer allocator.free(natural_prefix);
    try std.testing.expectEqualStrings("m_n_number", natural_prefix);

    const natural_prefix_again = (try variableName(allocator, &config, .member, false, "int", 0, natural_prefix)).?;
    defer allocator.free(natural_prefix_again);
    try std.testing.expectEqualStrings(natural_prefix, natural_prefix_again);

    try config.mappings.append(allocator, .{ .type_name = "int", .prefix = "n_" });

    const camel = (try variableName(allocator, &config, .member, false, "int", 0, "func_name")).?;
    defer allocator.free(camel);
    try std.testing.expectEqualStrings("m_n_funcName", camel);

    const camel_again = (try variableName(allocator, &config, .member, false, "int", 0, camel)).?;
    defer allocator.free(camel_again);
    try std.testing.expectEqualStrings(camel, camel_again);

    try config.mappings.append(allocator, .{ .type_name = "int", .prefix = "n__" });
    const preserved = (try variableName(allocator, &config, .member, false, "int", 0, "num")).?;
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings("m_n__num", preserved);

    try config.mappings.append(allocator, .{ .type_name = "int", .prefix = "n_" });

    config.variable_case = .snake;

    const snake = (try variableName(allocator, &config, .member, false, "int", 0, "FuncName")).?;
    defer allocator.free(snake);
    try std.testing.expectEqualStrings("m_n_func_name", snake);

    const snake_again = (try variableName(allocator, &config, .member, false, "int", 0, snake)).?;
    defer allocator.free(snake_again);
    try std.testing.expectEqualStrings(snake, snake_again);

    const pointer = (try variableName(allocator, &config, .member, false, "int", 1, "FuncName")).?;
    defer allocator.free(pointer);
    try std.testing.expectEqualStrings("m_pn_func_name", pointer);

    const pointer_again = (try variableName(allocator, &config, .member, false, "int", 1, pointer)).?;
    defer allocator.free(pointer_again);
    try std.testing.expectEqualStrings(pointer, pointer_again);
}

test "global upper snake is accepted as an alternative" {
    const allocator = std.testing.allocator;
    var config = try config_mod.Config.initDefaults(allocator);
    defer config.deinit(allocator);
    try config.mappings.append(allocator, .{ .type_name = "int", .prefix = "n" });
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
