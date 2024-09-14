const std = @import("std");
const constants = @import("constants.zig");
const tinyexpr = @cImport({
    @cInclude("tinyexpr.h");
});

const CellType = enum {
    Float,
    Int,
    String,

    pub fn from_value(value: []const u8) CellType {
        if (value.len == 0) return CellType.String;

        const parsed_int = std.fmt.parseInt(i32, value, 10);
        if (@TypeOf(parsed_int) == i32) return CellType.Int;

        const parsed_float = std.fmt.parseFloat(f32, value);
        if (@TypeOf(parsed_float) == f32) return CellType.Float;

        return CellType.String;
    }
};

pub const Cell = struct {
    x: i32,
    y: i32,
    raw_value: std.ArrayList(u8),
    value: std.ArrayList(u8),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, x: i32, y: i32, value: []const u8) !Cell {
        var raw_value = std.ArrayList(u8).init(allocator);
        try raw_value.appendSlice(value);
        const calculated_value = std.ArrayList(u8).init(allocator);

        return .{ .x = x, .y = y, .raw_value = raw_value, .value = calculated_value, .allocator = allocator };
    }

    fn find_all_references(self: *Cell) ![]struct { usize, usize, CellId } {
        var refs = std.ArrayList(struct { usize, usize, CellId }).init(self.allocator);
        errdefer refs.deinit();

        var reference_start: ?usize = null;
        var reference_number_start: ?usize = null;
        for (1..self.raw_value.items.len + 1) |index| {
            const char: u8 = if (index < self.raw_value.items.len) self.raw_value.items[index] else 0;
            const is_uppercase = char >= constants.capitals_min and char <= constants.capitals_max;
            const is_lowercase = char >= constants.lower_min and char <= constants.lower_max;

            const is_letter = is_lowercase or is_uppercase;
            const is_number = char >= 48 and char <= 57;

            if (is_letter and reference_start == null) {
                reference_start = index;
            } else if (is_number and reference_start != null and reference_number_start == null) {
                reference_number_start = index;
            } else if (reference_start != null and reference_number_start != null and !is_number) {
                // we have now finished a reference and the state is stored in reference_start and reference_number_start.
                const letter_part = self.raw_value.items[reference_start.?..reference_number_start.?];
                const number_part = self.raw_value.items[reference_number_start.?..index];

                const x = try chars_to_column(letter_part);
                const y = try std.fmt.parseInt(u8, number_part, 10);

                try refs.append(.{ reference_start.?, index - reference_start.?, get_cell_id(x, y) });

                reference_start = null;
                reference_number_start = null;
            } else if (reference_start != null and reference_number_start != null and is_number) {
                continue;
            } else {
                reference_start = null;
                reference_number_start = null;
            }
        }
        // _ = std.mem.replace(u8, result_str.items, ",", ".", result_str.items);

        return refs.items;
    }

    fn replace_stuff(self: *Cell, cells: *CellContainer) !struct {
        []u8,
        []CellId,
    } {
        var result_str = std.ArrayList(u8).init(self.allocator);
        errdefer result_str.deinit();

        const refs = try self.find_all_references();

        defer cells.allocator.free(refs);

        try result_str.appendSlice(self.raw_value.items);
        var scratch_buf = std.ArrayList(u8).init(self.allocator);

        var offset: isize = 0;

        for (refs) |ref| {
            scratch_buf.clearRetainingCapacity();
            const position, const len, const other_cell_coords = ref;
            const other_cell = cells.find(get_cell_pos(other_cell_coords).x, get_cell_pos(other_cell_coords).y) orelse continue;
            const value = other_cell.value;
            try scratch_buf.appendSlice(result_str.items[@intCast(@as(isize, @intCast(position)) + offset + @as(isize, @intCast(len)))..]);
            // result_str.resize(new_len: usize)
            try result_str.resize(@intCast(@as(isize, @intCast(position)) + offset));
            if (value.items.len > 0) {
                try result_str.appendSlice(value.items);
            } else {
                try result_str.append('0');
            }
            try result_str.appendSlice(scratch_buf.items);

            offset = offset + @as(isize, @intCast(other_cell.value.items.len)) - @as(isize, @intCast(len));
        }

        const refs_to_return = try cells.allocator.alloc(CellId, refs.len);
        for (0..refs.len) |index| {
            refs_to_return[index] = refs[index][2];
        }
        return .{ result_str.items, refs_to_return };
    }

    fn replace_cell_references(self: *Cell, cells: *CellContainer) !struct {
        []u8,
        []CellId,
    } {
        // Replaces all single cell references with that cell's current value.
        _ = try self.find_all_references();
        // NOTE: The caller must free the return slices
        //  Examples: A2, A13, AA27

        var result_str = std.ArrayList(u8).init(self.allocator);
        errdefer result_str.deinit();
        var refs = std.ArrayList(CellId).init(self.allocator);
        errdefer refs.deinit();

        var reference_start: ?usize = null;
        var reference_number_start: ?usize = null;
        for (1..self.raw_value.items.len + 1) |index| {
            const char: u8 = if (index < self.raw_value.items.len) self.raw_value.items[index] else 0;
            const is_uppercase = char >= constants.capitals_min and char <= constants.capitals_max;
            const is_lowercase = char >= constants.lower_min and char <= constants.lower_max;

            const is_letter = is_lowercase or is_uppercase;
            const is_number = char >= 48 and char <= 57;

            if (char != 0) try result_str.append(char);

            if (is_letter and reference_start == null) {
                reference_start = index;
            } else if (is_number and reference_start != null and reference_number_start == null) {
                reference_number_start = index;
            } else if (reference_start != null and reference_number_start != null and !is_number) {
                // we have now finished a reference and the state is stored in reference_start and reference_number_start.
                const letter_part = self.raw_value.items[reference_start.?..reference_number_start.?];
                const number_part = self.raw_value.items[reference_number_start.?..index];

                const x = try chars_to_column(letter_part);
                const y = try std.fmt.parseInt(u8, number_part, 10);

                const cell = cells.find(x, y);
                try refs.append(get_cell_id(x, y));

                result_str.items.len -= index - reference_start.? + @as(usize, if (char == 0) 0 else 1);
                if (cell != null and cell.?.value.items.len > 0) {
                    try result_str.appendSlice(cell.?.value.items);
                } else try result_str.append('0');

                if (char != 0) try result_str.append(char);

                reference_start = null;
                reference_number_start = null;
            } else if (reference_start != null and reference_number_start != null and is_number) {
                continue;
            } else {
                reference_start = null;
                reference_number_start = null;
            }
        }
        // _ = std.mem.replace(u8, result_str.items, ",", ".", result_str.items);

        return .{ result_str.items, refs.items };
    }

    pub fn depends_on_itself(self: *Cell, cells: *CellContainer) !bool {
        var cells_to_check = std.ArrayList(*Cell).init(cells.allocator);
        try cells_to_check.append(self);
        var index: usize = 0;
        while (index < cells_to_check.items.len) : (index += 1) {
            const cell = cells_to_check.items[index];
            const deps = cells.dependencies.getEntry(get_cell_id(cell.x, cell.y)) orelse continue;
            for (deps.value_ptr.items) |dependency| {
                const dep_coords = get_cell_pos(dependency);
                const dep_cell = cells.find(dep_coords.x, dep_coords.y) orelse continue;
                if (dep_cell == self) {
                    return true;
                }
                const already_checked_this = std.mem.containsAtLeast(*Cell, cells_to_check.items, 1, &.{dep_cell});
                if (!already_checked_this) {
                    try cells_to_check.append(dep_cell);
                }
            }
        }
        return false;
    }

    pub fn refresh_value(self: *Cell, cells: *CellContainer, modify_deps: bool) !void {
        if (modify_deps) {
            cells.remove_all_dependencies(self.x, self.y);
        }
        if (self.raw_value.items.len == 0) {
            self.value.items.len = 0;
            return;
        }
        self.value.items.len = 0;
        if (self.raw_value.items[0] == '=') {
            // calculating expressions has two components.
            // 1:   We do custom replacement of cell references with the corresponding values.
            //      If a "range" reference occurs, for example in "=SUM(A3:A5)", we replace the reference with a comma separated list of references, to produce "=SUM(A3,A4,A5)".
            //      If a "naked" reference occurs, for example in "=A3 + 5 * 3", we replace the reference with the cell's "value" (in this example 7), to produce "=7 + 5 * 3"
            //      If a "function" reference occurs, for example in "=SUM(5,3)", we replace the reference with the equivalent C calculation, to produce "=(5+3)"
            // 2:   Pass the resulting expression to the tinyexpr library to compute the result.
            if (self.raw_value.items.len == 1) {
                const error_message = "Invalid expression";
                try self.value.appendSlice(error_message);
                return;
            }
            const expr = self.raw_value.items[1..];
            const replaced_expr, const references = self.replace_stuff(cells) catch {
                const error_message = "Invalid expression";
                try self.value.appendSlice(error_message);
                return;
            };

            defer self.allocator.free(replaced_expr);
            defer self.allocator.free(references);
            if (modify_deps) {
                for (references) |ref| {
                    try cells.register_dependency(self.x, self.y, get_cell_pos(ref).x, get_cell_pos(ref).y);
                }
            }
            // check for emptyness. Remember that it is null-terminated!
            if (expr.len == 0) {
                const error_message = "Invalid expression";
                try self.value.appendSlice(error_message);
                return;
            }
            const has_circular_dependency = self.depends_on_itself(cells) catch {
                std.debug.print("Could not check for circular dependency.", .{});
                try self.value.appendSlice("Internal error");
                return;
            };
            if (has_circular_dependency) {
                std.debug.print("Detected circular dependency for cell {}, {}\n", .{ self.x, self.y });
                try self.value.appendSlice("Circular dependency");
                return;
            }
            const null_terminated_expr = try self.allocator.dupeZ(u8, replaced_expr[1..]);
            defer self.allocator.free(null_terminated_expr);
            const result = tinyexpr.te_interp(null_terminated_expr, 0);

            var res_buffer: [64]u8 = .{0} ** 64;
            const float_as_str = std.fmt.formatFloat(&res_buffer, result, .{ .mode = .decimal }) catch {
                const error_message = "Expression too large";
                try self.value.appendSlice(error_message);
                return;
            };
            try self.value.appendSlice(float_as_str);
        } else {
            // try self.value.appendSlice(error_msg);
            try self.value.appendSlice(self.raw_value.items);
            return;
        }
    }

    pub fn deinit(self: *Cell) void {
        self.allocator.free(self.raw_value);
    }

    pub fn value_append(self: *Cell, char: u8) !void {
        try self.raw_value.append(char);
    }

    pub fn value_delete(self: *Cell) void {
        if (self.raw_value.items.len == 0) return;
        _ = self.raw_value.swapRemove(self.raw_value.items.len - 1);
    }
};

const CellId = i32;

pub fn get_cell_id(x: i32, y: i32) CellId {
    const a = 10000 * x + y;
    return a;
}

pub fn get_cell_pos(id: CellId) struct { x: i32, y: i32 } {
    return .{ .x = @divTrunc((id - @rem(id, 10000)), 10000), .y = @rem(id, 10000) };
}

pub const CellContainer = struct {
    _cells: std.ArrayList(*Cell),
    _cell_index: std.AutoHashMap(CellId, usize),
    dependencies: std.AutoHashMap(CellId, std.ArrayList(CellId)),
    reverse_dependencies: std.AutoHashMap(CellId, std.ArrayList(CellId)),
    allocator: std.mem.Allocator,
    pub fn init(capacity: u32, allocator: std.mem.Allocator) !CellContainer {
        const cells = try allocator.alloc(*Cell, capacity);
        var array_list = std.ArrayList(*Cell).init(allocator);
        try array_list.appendSlice(cells);

        return CellContainer{
            ._cells = array_list,
            ._cell_index = std.AutoHashMap(CellId, usize).init(allocator),
            .dependencies = std.AutoHashMap(CellId, std.ArrayList(CellId)).init(allocator),
            .reverse_dependencies = std.AutoHashMap(CellId, std.ArrayList(CellId)).init(allocator),
            .allocator = allocator,
        };
    }
    pub fn add_cell(self: *CellContainer, x: i32, y: i32, value: []const u8) !*Cell {
        const cell = try Cell.init(self.allocator, x, y, value);
        const heap_cell = (try self.allocator.create(Cell));
        heap_cell.* = cell;

        try self._cells.append(heap_cell);

        self._cell_index.put(10000 * x + y, self._cells.items.len - 1) catch |err| {
            _ = self._cells.pop();
            return err;
        };
        return heap_cell;
    }

    pub fn remove_cell(self: *CellContainer, x: i32, y: i32) void {
        const index = self._cell_index.fetchRemove(10000 * x + y) orelse return;
        self._cells.swapRemove(index.value);
    }
    pub fn find(self: CellContainer, x: i32, y: i32) ?*Cell {
        const index = self._cell_index.get(10000 * x + y) orelse return null;
        return self._cells.items[index];
    }
    pub fn find_index(self: CellContainer, x: i32, y: i32) ?usize {
        return self._cell_index.get(10000 * x + y);
    }
    pub fn ensure_cell(self: *CellContainer, x: i32, y: i32) !*Cell {
        if (self.find(x, y)) |existing_cell| {
            return existing_cell;
        } else {
            return try self.add_cell(x, y, &.{});
        }
    }

    pub fn register_dependency(self: *CellContainer, x: i32, y: i32, dependency_x: i32, dependency_y: i32) !void {
        const cell_dependencies = try self.dependencies.getOrPutValue(get_cell_id(x, y), std.ArrayList(CellId).init(self.allocator));
        try cell_dependencies.value_ptr.append(get_cell_id(dependency_x, dependency_y));

        const dependency_dependencies = self.reverse_dependencies.getOrPutValue(get_cell_id(dependency_x, dependency_y), std.ArrayList(CellId).init(self.allocator)) catch |err| {
            _ = cell_dependencies.value_ptr.pop();
            return err;
        };

        dependency_dependencies.value_ptr.append(get_cell_id(x, y)) catch |err| {
            _ = cell_dependencies.value_ptr.pop();
            return err;
        };
    }

    pub fn remove_all_dependencies(self: *CellContainer, x: i32, y: i32) void {
        if (self.dependencies.getEntry(get_cell_id(x, y))) |dependencies| {
            for (dependencies.value_ptr.items) |dependency| {
                var reverse_dependencies = self.reverse_dependencies.getEntry(dependency) orelse continue;
                if (std.mem.indexOfScalar(CellId, reverse_dependencies.value_ptr.items, get_cell_id(x, y))) |index| {
                    _ = reverse_dependencies.value_ptr.swapRemove(index);
                }
            }
            dependencies.value_ptr.clearRetainingCapacity();
        }
        // if (self.reverse_dependencies.getEntry(get_cell_id(x, y))) |reverse_dependencies| {
        //     for (reverse_dependencies.value_ptr.items) |reverse_dependency| {
        //         var dependencies = self.dependencies.getEntry(reverse_dependency) orelse continue;
        //         if (std.mem.indexOfScalar(CellId, dependencies.value_ptr.items, get_cell_id(x, y))) |index| {
        //             _ = dependencies.value_ptr.swapRemove(index);
        //         }
        //     }
        //     reverse_dependencies.value_ptr.clearRetainingCapacity();
        // }
    }

    pub fn get_cells_depending_on_this(self: *CellContainer, x: i32, y: i32) ![]*Cell {
        var remaining_cells = std.ArrayList(*Cell).init(self.allocator);
        defer remaining_cells.deinit();
        var result = std.ArrayList(*Cell).init(self.allocator);
        errdefer result.deinit();
        try remaining_cells.append(self.find(x, y) orelse return &.{});
        var index: usize = 0;
        std.debug.print("Getting cells depending on {}, {}\n", .{ x, y });
        while (index < remaining_cells.items.len) : (index += 1) {
            // std.debug.print("Remaining cells: {any}\n", .{remaining_cells.items});
            const cell = remaining_cells.items[index];
            // the first cell is "this cell", and that doesnt depend on itself
            if (cell.x != x or cell.y != y) {
                try result.append(cell);
            }
            if (self.reverse_dependencies.get(get_cell_id(cell.x, cell.y))) |reverse_dependencies| {
                for (reverse_dependencies.items) |rev_dep| {
                    const this_cell = self.find(get_cell_pos(rev_dep).x, get_cell_pos(rev_dep).y) orelse continue;
                    const already_checked_this = std.mem.containsAtLeast(*Cell, remaining_cells.items, 1, &.{this_cell});
                    if (!already_checked_this) {
                        try remaining_cells.append(this_cell);
                    }
                }
            }
        }

        return result.items;

        // for (self.reverse_dependencies.getEntry(get_cell_id(x, y))) |*reverse_dependencies| {
        //     for ()
        // }
    }
};

test "asd" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);
    try cells.register_dependency(0, 0, 2, 2);

    var iter = cells.dependencies.keyIterator();

    while (iter.next()) |dependency| {
        const entry = cells.dependencies.get(dependency.*).?;
        for (entry.items) |item| {
            std.debug.print("Dependency. From ({}, {}) to ({}, {})\n", .{ get_cell_pos(dependency.*).x, get_cell_pos(dependency.*).y, get_cell_pos(item).x, get_cell_pos(item).y });
        }
    }

    var rev_iter = cells.reverse_dependencies.keyIterator();

    while (rev_iter.next()) |dependency| {
        // const cell = cells.find(get_cell_pos(dependency.*).x, get_cell_pos(dependency.*).y) orelse continue;
        const entry = cells.reverse_dependencies.get(dependency.*).?;
        for (entry.items) |item| {
            std.debug.print("Reverse Dependency. From ({}, {}) to ({}, {})\n", .{ get_cell_pos(dependency.*).x, get_cell_pos(dependency.*).y, get_cell_pos(item).x, get_cell_pos(item).y });
        }
    }

    cells.remove_all_dependencies(0, 0);

    iter = cells.dependencies.keyIterator();

    while (iter.next()) |dependency| {
        const entry = cells.dependencies.get(dependency.*).?;
        for (entry.items) |item| {
            std.debug.print("Dependency. From ({}, {}) to ({}, {})\n", .{ get_cell_pos(dependency.*).x, get_cell_pos(dependency.*).y, get_cell_pos(item).x, get_cell_pos(item).y });
        }
    }

    rev_iter = cells.reverse_dependencies.keyIterator();

    while (rev_iter.next()) |dependency| {
        // const cell = cells.find(get_cell_pos(dependency.*).x, get_cell_pos(dependency.*).y) orelse continue;
        const entry = cells.reverse_dependencies.get(dependency.*).?;
        for (entry.items) |item| {
            std.debug.print("Reverse Dependency. From ({}, {}) to ({}, {})\n", .{ get_cell_pos(dependency.*).x, get_cell_pos(dependency.*).y, get_cell_pos(item).x, get_cell_pos(item).y });
        }
    }
}
fn chars_to_column(chars: []const u8) !i32 {
    // translates the given chars to the corresponding column.
    // Example: chars_to_column("A") -> 0, chars_to_column("AB") -> 26
    const length = chars.len;
    var sum: i32 = 0;
    for (chars, 0..) |char, index| {
        const upper_char = if (char >= constants.capitals_min and char <= constants.capitals_max) char else (char + constants.lower_to_upper);
        const char_as_number = upper_char - constants.capitals_min + 1; // add 1 here because otherwise the "A" in "AB" would just be 0.
        sum += char_as_number * std.math.pow(i32, 25, @as(i32, @intCast(length - index)) - 1);
    }
    return sum - 1;
}

pub fn column_to_chars(column: i32, dest: []u8) usize {
    // 0 must map to A, 25 maps to Z

    if (column < 26) {
        dest[0] = @as(u8, @intCast(column)) + constants.capitals_min;

        return 1;
    }

    if (column < 26 * 26) {
        dest[1] = @intCast(@rem(column, 26) + constants.capitals_min);
        dest[0] = @intCast(@divTrunc((column - @rem(column, 26)), 26) + constants.capitals_min - 1);
        return 2;
    }

    if (column < 26 * 26 * 26) {
        dest[2] = @intCast(@rem(column, 26) + constants.capitals_min);
        dest[1] = @intCast(@divTrunc((column - @rem(column, 26)), 26) + constants.capitals_min - 1);
        dest[0] = @intCast(@divTrunc(column - @divTrunc(column - @rem(column, 26), 26), 26) + constants.capitals_min - 1);
        return 3;
    }

    @panic("We dont support this many columns..");
}

test "column to chars 5" {
    const column = 5;
    var res: [5]u8 = undefined;
    const len = column_to_chars(column, &res);
    const expected = "F";
    try std.testing.expect(std.mem.eql(u8, expected, res[0..len]));
}

test "column to chars 29" {
    const column = 29;
    var res: [5]u8 = undefined;
    const len = column_to_chars(column, &res);
    const expected = "AD";
    try std.testing.expect(std.mem.eql(u8, expected, res[0..len]));
}

// fn column_to_chars()

test "chars to column A" {
    const chars = "A";
    const res = try chars_to_column(chars);
    try std.testing.expect(res == 0);
}
test "chars to column E" {
    const chars = "E";
    const res = try chars_to_column(chars);
    try std.testing.expect(res == 4);
}
test "chars to column AB" {
    const chars = "AB";
    const res = try chars_to_column(chars);
    try std.testing.expect(res == 26);
}

test "find single reference" {
    std.debug.print("\n\n", .{});
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    const cell_0_0 = try cells.add_cell(0, 0, "15");
    const cell_2_0 = try cells.add_cell(2, 0, "=A0*2");

    _ = cell_0_0;

    const refs = try cell_2_0.find_all_references();

    try std.testing.expect(refs.len == 1);
    const index, const len, const cell_id = refs[0];

    try std.testing.expect(index == 1);
    try std.testing.expect(len == 2);
    try std.testing.expect(cell_id == 0);
}

test "find multiple references" {
    std.debug.print("\n\n", .{});
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    const cell_0_0 = try cells.add_cell(0, 0, "15");
    const cell_15_77 = try cells.add_cell(15, 77, "5");
    var cell_2_0 = try cells.add_cell(2, 0, "=A0*2+P77*2");

    _ = cell_0_0;
    _ = cell_15_77;

    const refs = try cell_2_0.find_all_references();

    try std.testing.expect(refs.len == 2);
    const index_1, const len_1, const cell_id_1 = refs[0];
    const index_2, const len_2, const cell_id_2 = refs[1];

    try std.testing.expect(index_1 == 1);
    try std.testing.expect(len_1 == 2);
    try std.testing.expect(cell_id_1 == 0);

    try std.testing.expect(index_2 == 6);
    try std.testing.expect(len_2 == 3);
    try std.testing.expect(cell_id_2 == get_cell_id(15, 77));
}

test "find no reference" {
    std.debug.print("\n\n", .{});
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    const cell_0_0 = try cells.add_cell(0, 0, "15");

    const refs = try cell_0_0.find_all_references();

    try std.testing.expect(refs.len == 0);
}

test "replace single ref" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var cell_0_0 = try cells.add_cell(0, 0, "15");
    try cell_0_0.value.appendSlice(cell_0_0.raw_value.items);
    var cell_2_0 = try cells.add_cell(2, 0, "=A0*2");

    const result, const refs = try cell_2_0.replace_stuff(&cells);
    std.debug.print("{s}, {any}\n\n", .{ result, refs });
    try std.testing.expectEqualStrings("=15*2", result);
    try std.testing.expect(refs.len == 1);
    try std.testing.expect(refs[0] == 0);
}

test "replace two refs" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var cell_0_0 = try cells.add_cell(0, 0, "15");
    try cell_0_0.value.appendSlice(cell_0_0.raw_value.items);

    var cell_1_0 = try cells.add_cell(1, 0, "30");
    try cell_1_0.value.appendSlice(cell_1_0.raw_value.items);

    var cell_2_0 = try cells.add_cell(2, 0, "=A0*B0");

    const result, const refs = try cell_2_0.replace_stuff(&cells);
    std.debug.print("{s}, {any}\n\n", .{ result, refs });
    try std.testing.expectEqualStrings("=15*30", result);
    try std.testing.expectEqual(refs.len, 2);
    try std.testing.expectEqual(0, refs[0]);
    try std.testing.expectEqual(10000, refs[1]);
}

test "replace three refs" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var cell_0_0 = try cells.add_cell(0, 0, "15");
    try cell_0_0.value.appendSlice(cell_0_0.raw_value.items);

    var cell_1_0 = try cells.add_cell(1, 0, "30");
    try cell_1_0.value.appendSlice(cell_1_0.raw_value.items);

    var cell_2_0 = try cells.add_cell(2, 5, "40");
    try cell_2_0.value.appendSlice(cell_2_0.raw_value.items);

    var cell_3_0 = try cells.add_cell(3, 0, "=A0*B0+C5*pow(C5,15)");

    const result, const refs = try cell_3_0.replace_stuff(&cells);
    std.debug.print("{s}, {any}\n\n", .{ result, refs });
    try std.testing.expectEqualStrings("=15*30+40*pow(40,15)", result);
    try std.testing.expectEqual(4, refs.len);
    try std.testing.expectEqual(0, refs[0]);
    try std.testing.expectEqual(10000, refs[1]);
    try std.testing.expectEqual(20005, refs[2]);
}

test "Depends directly on itself" {
    var cells = try CellContainer.init(0, std.heap.c_allocator);
    const cell_0_0 = try cells.add_cell(0, 0, "=A0");
    try cell_0_0.refresh_value(&cells, true);
    const result = try cell_0_0.depends_on_itself(&cells);
    try std.testing.expectEqual(true, result);
}

test "Part of cycle 2 elems" {
    var cells = try CellContainer.init(0, std.heap.c_allocator);
    const cell_0_0 = try cells.add_cell(0, 0, "=B0");
    const cell_1_0 = try cells.add_cell(1, 0, "=A0");
    try cell_0_0.refresh_value(&cells, true);
    try cell_1_0.refresh_value(&cells, true);
    const result = try cell_1_0.depends_on_itself(&cells);
    try std.testing.expectEqual(true, result);
}

test "Complex graph true" {
    var cells = try CellContainer.init(0, std.heap.c_allocator);
    const cell_0_0 = try cells.add_cell(0, 0, "=B0+C0+A1");
    const cell_0_1 = try cells.add_cell(0, 1, "=15");
    const cell_1_0 = try cells.add_cell(1, 0, "=D0");
    const cell_2_0 = try cells.add_cell(2, 0, "=A0");
    const cell_3_0 = try cells.add_cell(3, 0, "=A0");
    try cell_0_0.refresh_value(&cells, true);
    try cell_0_1.refresh_value(&cells, true);
    try cell_1_0.refresh_value(&cells, true);
    try cell_2_0.refresh_value(&cells, true);
    try cell_3_0.refresh_value(&cells, true);
    const result = try cell_0_0.depends_on_itself(&cells);
    try std.testing.expectEqual(true, result);
}

test "Complex graph false" {
    var cells = try CellContainer.init(0, std.heap.c_allocator);
    const cell_0_0 = try cells.add_cell(0, 0, "=B0+C0+A1");
    const cell_0_1 = try cells.add_cell(0, 1, "=15");
    const cell_1_0 = try cells.add_cell(1, 0, "=D0");
    const cell_2_0 = try cells.add_cell(2, 0, "=D0");
    const cell_3_0 = try cells.add_cell(3, 0, "5");
    try cell_0_0.refresh_value(&cells, true);
    try cell_0_1.refresh_value(&cells, true);
    try cell_1_0.refresh_value(&cells, true);
    try cell_2_0.refresh_value(&cells, true);
    try cell_3_0.refresh_value(&cells, true);
    const result = try cell_0_0.depends_on_itself(&cells);
    try std.testing.expectEqual(false, result);
}

test "Subgraph with circular dependency true" {
    var cells = try CellContainer.init(0, std.heap.c_allocator);
    const cell_0_0 = try cells.add_cell(0, 0, "=B0+C0+A1");
    const cell_0_1 = try cells.add_cell(0, 1, "=15");
    const cell_1_0 = try cells.add_cell(1, 0, "=D0");
    const cell_2_0 = try cells.add_cell(2, 0, "=C0");
    const cell_3_0 = try cells.add_cell(3, 0, "=A0");
    try cell_0_0.refresh_value(&cells, true);
    try cell_0_1.refresh_value(&cells, true);
    try cell_1_0.refresh_value(&cells, true);
    try cell_2_0.refresh_value(&cells, true);
    try cell_3_0.refresh_value(&cells, true);
    const result = try cell_0_0.depends_on_itself(&cells);
    try std.testing.expectEqual(true, result);
}

test "Subgraph with circular dependency false" {
    var cells = try CellContainer.init(0, std.heap.c_allocator);
    const cell_0_0 = try cells.add_cell(0, 0, "=B0+C0+A1");
    const cell_0_1 = try cells.add_cell(0, 1, "=15");
    const cell_1_0 = try cells.add_cell(1, 0, "=D0");
    const cell_2_0 = try cells.add_cell(2, 0, "=C0");
    const cell_3_0 = try cells.add_cell(3, 0, "=15");
    try cell_0_0.refresh_value(&cells, true);
    try cell_0_1.refresh_value(&cells, true);
    try cell_1_0.refresh_value(&cells, true);
    try cell_2_0.refresh_value(&cells, true);
    try cell_3_0.refresh_value(&cells, true);
    const result = try cell_0_0.depends_on_itself(&cells);
    try std.testing.expectEqual(false, result);
}

test "Subgraph with invalid expr false" {
    var cells = try CellContainer.init(0, std.heap.c_allocator);
    const cell_0_0 = try cells.add_cell(0, 0, "=B0+C0");
    const cell_0_1 = try cells.add_cell(0, 1, "=D");
    const cell_1_0 = try cells.add_cell(1, 0, "=15");
    try cell_0_0.refresh_value(&cells, true);
    try cell_0_1.refresh_value(&cells, true);
    try cell_1_0.refresh_value(&cells, true);
    const result = try cell_0_0.depends_on_itself(&cells);
    try std.testing.expectEqual(false, result);
}

test "Subgraph with invalid expr true" {
    var cells = try CellContainer.init(0, std.heap.c_allocator);
    const cell_0_0 = try cells.add_cell(0, 0, "=B0+C0");
    const cell_0_1 = try cells.add_cell(0, 1, "=D");
    const cell_1_0 = try cells.add_cell(1, 0, "=A0");
    try cell_0_0.refresh_value(&cells, true);
    try cell_0_1.refresh_value(&cells, true);
    try cell_1_0.refresh_value(&cells, true);
    const result = try cell_0_0.depends_on_itself(&cells);
    try std.testing.expectEqual(true, result);
}
