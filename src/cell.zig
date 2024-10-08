const std = @import("std");
const constants = @import("constants.zig");
const tinyexpr = @cImport({
    @cInclude("tinyexpr.h");
});
const helpers = @import("helpers.zig");
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

    pub fn find_references(self: *Cell, value: []u8) ![]struct { usize, usize, CellPos } {
        var idx: usize = 0;
        var refs = std.ArrayList(struct { usize, usize, CellPos }).init(self.allocator);
        while (idx < value.len) {
            if (parse_cell_ref(value, idx)) |ref| {
                try refs.append(.{ idx, ref.len, ref.cell_pos });
            }

            idx += 1;
        }
        return refs.items;
    }

    fn replace_exprs(self: *Cell, cells: *CellContainer) !struct {
        []u8,
        []CellPos,
    } {
        var result_str = std.ArrayList(u8).init(self.allocator);
        errdefer result_str.deinit();
        var buffer: [1024]u8 = undefined;
        var buffer2: [1024]u8 = undefined;
        const replacements = std.mem.replace(u8, self.raw_value.items, " ", "", &buffer);
        const unfolded_raw_value = unfold_range_exprs(buffer[0 .. self.raw_value.items.len - replacements], &buffer2);

        const refs = try self.find_references(unfolded_raw_value);
        defer cells.allocator.free(refs);

        try result_str.appendSlice(unfolded_raw_value);
        var scratch_buf = std.ArrayList(u8).init(self.allocator);

        var offset: isize = 0;

        for (refs) |ref| {
            scratch_buf.clearRetainingCapacity();
            const position, const len, const other_cell_pos = ref;
            const other_cell = cells.find(other_cell_pos.x, other_cell_pos.y);
            const value = if (other_cell != null) other_cell.?.value.items else &.{};
            try scratch_buf.appendSlice(result_str.items[@intCast(@as(isize, @intCast(position)) + offset + @as(isize, @intCast(len)))..]);
            // result_str.resize(new_len: usize)
            try result_str.resize(@intCast(@as(isize, @intCast(position)) + offset));
            if (value.len > 0) {
                try result_str.appendSlice(value);
                offset = offset + @as(isize, @intCast(value.len)) - @as(isize, @intCast(len));
            } else {
                try result_str.append('0');
                offset = offset + @as(isize, 1 - @as(isize, @intCast(len)));
            }
            try result_str.appendSlice(scratch_buf.items);
        }
        var new_buf: [1024]u8 = undefined;
        std.mem.copyForwards(u8, &new_buf, result_str.items);
        const unfolded_function_value = unfold_function_refs(result_str.items, &new_buf);
        result_str.clearRetainingCapacity();
        try result_str.appendSlice(unfolded_function_value);
        const refs_to_return = try cells.allocator.alloc(CellPos, refs.len);
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
        // _ = try self.find_references(value.items);
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
                } else {
                    try result_str.append('0');
                    // try result_str.append('0');
                }

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
            const replaced_expr, const references = self.replace_exprs(cells) catch {
                const error_message = "Invalid expression";
                try self.value.appendSlice(error_message);
                return;
            };

            defer self.allocator.free(replaced_expr);
            defer self.allocator.free(references);
            if (modify_deps) {
                for (references) |ref| {
                    try cells.register_dependency(self.x, self.y, ref.x, ref.y);
                }
            }

            // check for emptyness. Remember that it is null-terminated!
            if (expr.len == 0) {
                const error_message = "Invalid expression";
                try self.value.appendSlice(error_message);
                return;
            }
            const has_circular_dependency = self.depends_on_itself(cells) catch {
                try self.value.appendSlice("Internal error");
                return;
            };
            if (has_circular_dependency) {
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
    }

    pub fn get_cells_depending_on_this(self: *CellContainer, x: i32, y: i32) ![]*Cell {
        var remaining_cells = std.ArrayList(*Cell).init(self.allocator);
        defer remaining_cells.deinit();
        var result = std.ArrayList(*Cell).init(self.allocator);
        errdefer result.deinit();
        try remaining_cells.append(self.find(x, y) orelse return &.{});
        var index: usize = 0;
        while (index < remaining_cells.items.len) : (index += 1) {
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
        for (entry.items) |_| {
            // std.debug.print("Dependency. From ({}, {}) to ({}, {})\n", .{ get_cell_pos(dependency.*).x, get_cell_pos(dependency.*).y, get_cell_pos(item).x, get_cell_pos(item).y });
        }
    }

    var rev_iter = cells.reverse_dependencies.keyIterator();

    while (rev_iter.next()) |dependency| {
        // const cell = cells.find(get_cell_pos(dependency.*).x, get_cell_pos(dependency.*).y) orelse continue;
        const entry = cells.reverse_dependencies.get(dependency.*).?;
        for (entry.items) |_| {
            // std.debug.print("Reverse Dependency. From ({}, {}) to ({}, {})\n", .{ get_cell_pos(dependency.*).x, get_cell_pos(dependency.*).y, get_cell_pos(item).x, get_cell_pos(item).y });
        }
    }

    cells.remove_all_dependencies(0, 0);

    iter = cells.dependencies.keyIterator();

    while (iter.next()) |dependency| {
        const entry = cells.dependencies.get(dependency.*).?;
        for (entry.items) |_| {
            // std.debug.print("Dependency. From ({}, {}) to ({}, {})\n", .{ get_cell_pos(dependency.*).x, get_cell_pos(dependency.*).y, get_cell_pos(item).x, get_cell_pos(item).y });
        }
    }

    rev_iter = cells.reverse_dependencies.keyIterator();

    while (rev_iter.next()) |dependency| {
        // const cell = cells.find(get_cell_pos(dependency.*).x, get_cell_pos(dependency.*).y) orelse continue;
        const entry = cells.reverse_dependencies.get(dependency.*).?;
        for (entry.items) |_| {
            // std.debug.print("Reverse Dependency. From ({}, {}) to ({}, {})\n", .{ get_cell_pos(dependency.*).x, get_cell_pos(dependency.*).y, get_cell_pos(item).x, get_cell_pos(item).y });
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
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    const cell_0_0 = try cells.add_cell(0, 0, "15");
    const cell_2_0 = try cells.add_cell(2, 0, "=A0*2");

    _ = cell_0_0;

    const refs = try cell_2_0.find_references(cell_2_0.raw_value.items);

    try std.testing.expect(refs.len == 1);
    const index, const len, const cell_pos = refs[0];

    try std.testing.expect(index == 1);
    try std.testing.expect(len == 2);
    try std.testing.expect(cell_pos.x == 0);
    try std.testing.expect(cell_pos.y == 0);
}

test "find multiple references" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    const cell_0_0 = try cells.add_cell(0, 0, "15");
    const cell_15_77 = try cells.add_cell(15, 77, "5");
    var cell_2_0 = try cells.add_cell(2, 0, "=A0*2+P77*2");

    _ = cell_0_0;
    _ = cell_15_77;

    const refs = try cell_2_0.find_references(cell_2_0.raw_value.items);

    try std.testing.expect(refs.len == 2);
    const index_1, const len_1, const cell_pos_1 = refs[0];
    const index_2, const len_2, const cell_pos_2 = refs[1];

    try std.testing.expect(index_1 == 1);
    try std.testing.expect(len_1 == 2);
    try std.testing.expect(cell_pos_1.x == 0);
    try std.testing.expect(cell_pos_1.y == 0);

    try std.testing.expect(index_2 == 6);
    try std.testing.expect(len_2 == 3);
    try std.testing.expect(cell_pos_2.x == 15);
    try std.testing.expect(cell_pos_2.y == 77);
}

test "find no reference" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    const cell_0_0 = try cells.add_cell(0, 0, "15");

    const refs = try cell_0_0.find_references(cell_0_0.raw_value.items);

    try std.testing.expect(refs.len == 0);
}

test "replace single ref" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var cell_0_0 = try cells.add_cell(0, 0, "15");
    try cell_0_0.value.appendSlice(cell_0_0.raw_value.items);
    var cell_2_0 = try cells.add_cell(2, 0, "=A0*2");

    const result, const refs = try cell_2_0.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=15*2", result);
    try std.testing.expect(refs.len == 1);
    try std.testing.expect(refs[0].x == 0);
    try std.testing.expect(refs[0].y == 0);
}

test "replace two refs" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var cell_0_0 = try cells.add_cell(0, 0, "15");
    try cell_0_0.value.appendSlice(cell_0_0.raw_value.items);

    var cell_1_0 = try cells.add_cell(1, 0, "30");
    try cell_1_0.value.appendSlice(cell_1_0.raw_value.items);

    var cell_2_0 = try cells.add_cell(2, 0, "=A0*B0");

    const result, const refs = try cell_2_0.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=15*30", result);
    try std.testing.expectEqual(refs.len, 2);
    try std.testing.expectEqual(0, refs[0].x);
    try std.testing.expectEqual(0, refs[0].y);
    try std.testing.expectEqual(1, refs[1].x);
    try std.testing.expectEqual(0, refs[1].y);
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

    var cell_3_0 = try cells.add_cell(3, 0, "=A0*B0+C5*C5+15");

    const result, const refs = try cell_3_0.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=15*30+40*40+15", result);
    try std.testing.expectEqual(4, refs.len);
    try std.testing.expectEqual(0, refs[0].x);
    try std.testing.expectEqual(0, refs[0].y);
    try std.testing.expectEqual(1, refs[1].x);
    try std.testing.expectEqual(0, refs[1].y);
    try std.testing.expectEqual(2, refs[2].x);
    try std.testing.expectEqual(5, refs[2].y);
}

test "replace refs with range expression" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var cell_0_0 = try cells.add_cell(0, 0, "15");
    try cell_0_0.value.appendSlice(cell_0_0.raw_value.items);

    var cell_1_0 = try cells.add_cell(0, 1, "30");
    try cell_1_0.value.appendSlice(cell_1_0.raw_value.items);

    var cell_2_0 = try cells.add_cell(0, 2, "40");
    try cell_2_0.value.appendSlice(cell_2_0.raw_value.items);

    var cell_15_15 = try cells.add_cell(15, 15, "=A0:A2");

    const result, const refs = try cell_15_15.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=15,30,40", result);
    try std.testing.expectEqual(3, refs.len);
    try std.testing.expectEqual(0, refs[0].x);
    try std.testing.expectEqual(0, refs[0].y);
    try std.testing.expectEqual(0, refs[1].x);
    try std.testing.expectEqual(1, refs[1].y);
    try std.testing.expectEqual(0, refs[2].x);
    try std.testing.expectEqual(2, refs[2].y);
}

test "replace_exprs with empty cell" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var cell_2_0 = try cells.add_cell(0, 2, "40");
    try cell_2_0.value.appendSlice(cell_2_0.raw_value.items);

    var cell_15_15 = try cells.add_cell(15, 15, "=A0+A1");

    const result, const refs = try cell_15_15.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=0+0", result);
    try std.testing.expectEqual(2, refs.len);
    try std.testing.expectEqual(0, refs[0].x);
    try std.testing.expectEqual(0, refs[0].y);
    try std.testing.expectEqual(0, refs[1].x);
    try std.testing.expectEqual(1, refs[1].y);
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

test "unfold_range_exprs_and_find_refs_v2" {
    const allocator = std.heap.c_allocator;

    // Initialize a Cell with a raw_value containing a range reference
    const cell = try Cell.init(allocator, 0, 0, "=A1:A3,");
    // defer cell.deinit();

    // Call the function
    var buff: [20]u8 = .{0} ** 20;
    const result = unfold_range_exprs(cell.raw_value.items, &buff);
    // Check the unfolded string
    const expected_str = "=A1,A2,A3,";
    try std.testing.expectEqualStrings(expected_str, result);
}
test "unfold_range_exprs_and_find_refs_multiple_values" {
    const allocator = std.heap.c_allocator;

    // Initialize a Cell with a raw_value containing a range reference
    const cell = try Cell.init(allocator, 0, 0, "=A1:A3, B1:B3");
    // defer cell.deinit();

    // Call the function
    var buff: [30]u8 = .{0} ** 30;
    const result = unfold_range_exprs(cell.raw_value.items, &buff);
    // Check the unfolded string
    const expected_str = "=A1,A2,A3, B1,B2,B3";
    try std.testing.expectEqualStrings(expected_str, result);
}

test "unfold_range_exprs_in_sum" {
    const allocator = std.heap.c_allocator;

    // Initialize a Cell with a raw_value containing a range reference
    const cell = try Cell.init(allocator, 0, 0, "=SUM(A1:A3)");
    // defer cell.deinit();

    // Call the function
    var buff: [20]u8 = .{0} ** 20;
    const result = unfold_range_exprs(cell.raw_value.items, &buff);
    // Check the unfolded string
    const expected_str = "=SUM(A1,A2,A3)";
    try std.testing.expectEqualStrings(expected_str, result);
}

test "replace_exprs_in_sum" {
    const allocator = std.heap.c_allocator;

    var cells = try CellContainer.init(9, allocator);
    var cell = try cells.add_cell(0, 0, "=SUM(A1:A2)");

    // Call the function

    const result = try cell.replace_exprs(&cells);
    // Check the unfolded string
    const expected_str = "=(0+0)";
    try std.testing.expectEqualStrings(expected_str, result[0]);
}

test "replace_exprs_in_sum_initted_cells" {
    const allocator = std.heap.c_allocator;

    var cells = try CellContainer.init(9, allocator);
    var cell = try cells.add_cell(0, 0, "=SUM(a1:a2)");
    var cell_0_1 = try cells.add_cell(0, 1, "1");
    var cell_0_2 = try cells.add_cell(0, 2, "2");

    try cell_0_1.refresh_value(&cells, true);
    try cell_0_2.refresh_value(&cells, true);

    // Call the function

    const result = try cell.replace_exprs(&cells);
    // Check the unfolded string
    const expected_str = "=(1+2)";
    try std.testing.expectEqualStrings(expected_str, result[0]);
}

fn isLetter(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn columnToNumber(col_str: []const u8) usize {
    var result: usize = 0;
    for (col_str) |c| {
        const uppercase_c = if (c >= 'a' and c <= 'z') c - ('a' - 'A') else c;
        result = result * 26 + @as(usize, @intCast(uppercase_c - 'A' + 1));
    }
    return result;
}

fn numberToColumn(num: usize, allocator: *std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    while (num > 0) : (num /= 26) {
        var rem = num % 26;
        if (rem == 0) {
            rem = 26;
            num -= 26;
        }
        try buf.prepend(@as(u8, @intCast('A' + rem - 1)));
    }

    return buf.toOwnedSlice();
}

fn parse_cell_ref(input: []const u8, start_idx: usize) ?struct { len: usize, cell_pos: CellPos } {
    var idx = start_idx;
    const len = input.len;

    const col_start = idx;
    while (idx < len and ((input[idx] >= 'A' and input[idx] <= 'Z') or (input[idx] >= 'a' and input[idx] <= 'z'))) {
        idx += 1;
    }
    if (col_start == idx) {
        // No letters found
        return null;
    }
    const col_str = input[col_start..idx];

    const row_start = idx;
    while (idx < len and input[idx] >= '0' and input[idx] <= '9') {
        idx += 1;
    }
    if (row_start == idx) {
        // No digits found
        return null;
    }
    const row_str = input[row_start..idx];

    const col_num: i32 = chars_to_column(col_str) catch return null;
    const row_num: i32 = std.fmt.parseInt(i32, row_str, 10) catch {
        return null;
    };
    if (idx < len and input[idx] == '(') {
        return null;
    }
    return .{ .len = idx - start_idx, .cell_pos = CellPos{ .x = col_num, .y = row_num } };
}

fn parse_fun_ref(input: []const u8, start_idx: usize) ?struct { start: usize, len: usize, arg_start: usize, arg_len: usize } {
    var idx = start_idx;
    const len = input.len;

    // Parse function name
    const fun_start = idx;
    while (idx < len and isLetter(input[idx])) {
        idx += 1;
    }
    if (fun_start == idx) {
        // No function name found
        return null;
    }
    const fun_len = idx - fun_start;

    // Expect an opening parenthesis
    if (idx >= len or input[idx] != '(') {
        return null;
    }
    idx += 1;

    // Parse argument
    const arg_start = idx;
    var paren_count: u32 = 1;
    while (idx < len and paren_count > 0) {
        if (input[idx] == '(') {
            paren_count += 1;
        } else if (input[idx] == ')') {
            paren_count -= 1;
        }
        idx += 1;
    }
    if (paren_count != 0) {
        // Unmatched parentheses
        return null;
    }
    const arg_len = idx - arg_start - 1; // Exclude the closing parenthesis

    return .{ .start = fun_start, .len = fun_len, .arg_start = arg_start, .arg_len = arg_len };
}

pub fn unfold_range_exprs(input: []const u8, output_buffer: []u8) []u8 {
    var input_idx: usize = 0;
    var output_idx: usize = 0;

    while (input_idx < input.len) {
        const c = input[input_idx];
        if (c >= 'A' and c <= 'Z' or c >= 'a' and c <= 'z') blk: {
            const range = parse_range(input, input_idx) orelse break :blk;
            // Range successfully parsed
            // Expand the range
            input_idx += range.len;

            const start_col: usize = @intCast(@min(range.start_cell.x, range.end_cell.x));
            const end_col: usize = @intCast(@max(range.start_cell.x, range.end_cell.x));
            const start_row: usize = @intCast(@min(range.start_cell.y, range.end_cell.y));
            const end_row: usize = @intCast(@max(range.start_cell.y, range.end_cell.y));
            var first_cell_in_range = true;
            // For col in start_col to end_col
            for (start_col..end_col + 1) |col_num| {
                var col_str_buf: [10]u8 = undefined;
                const col_str = num_to_col_str(@intCast(col_num), &col_str_buf) orelse break :blk;

                // For row in start_row to end_row
                for (start_row..end_row + 1) |row_num| {
                    // Append ',' if not the first cell
                    if (!first_cell_in_range) {
                        if (output_idx >= output_buffer.len) {
                            // Output buffer overflow
                            return output_buffer[0..output_idx];
                        }
                        output_buffer[output_idx] = ',';
                        output_idx += 1;
                    } else {
                        first_cell_in_range = false;
                    }

                    // Append col_str
                    if (output_idx + col_str.len > output_buffer.len) {
                        // Output buffer overflow
                        @panic("Buffer overflow in outputbuffer");
                    }
                    std.mem.copyForwards(u8, output_buffer[output_idx..], col_str);
                    output_idx += col_str.len;

                    // Append row number
                    var row_str_buf: [10]u8 = undefined;
                    const actual_row_str = std.fmt.bufPrint(&row_str_buf, "{}", .{row_num}) catch {
                        // Error formatting row number
                        continue;
                    };
                    if (output_idx + actual_row_str.len > output_buffer.len) {
                        // Output buffer overflow
                        @panic("Buffer overflow in outputbuffer");
                    }
                    std.mem.copyForwards(u8, output_buffer[output_idx..], row_str_buf[0..actual_row_str.len]);
                    output_idx += actual_row_str.len;
                }
            }
            continue;
        }
        // Copy the current character to output
        if (output_idx >= output_buffer.len) {
            // Output buffer overflow
            return output_buffer[0..output_idx];
        }
        output_buffer[output_idx] = input[input_idx];
        output_idx += 1;
        input_idx += 1;
    }
    return output_buffer[0..output_idx];
}

const BuiltinFunction = enum {
    // BUILTINS from tinyexpr
    Abs,
    Acos,
    Asin,
    Atan,
    AtanTwo,
    Ceil,
    Cos,
    Cosh,
    E,
    Exp,
    Fac,
    Floor,
    Ln,
    Log,
    Log10,
    Ncr,
    Npr,
    Pi,
    Pow,
    Sin,
    Sinh,
    Sqrt,
    Tan,
    Tanh,
};
const CellFunction = enum {
    // Custom functions added by moi
    Sum,
    Avg,
    Min,
    Max,
};
const Function = union(enum) {
    CellFunction: CellFunction,
    BuiltinFunction: BuiltinFunction,
};

fn unfold_function(function: CellFunction, args: []const u8, result: []u8) ![]u8 {
    // Unfold the function with the given arguments
    // example: unfold_function(CellFunction.Sum, "A1,A2,A3", result) -> "A1+A2+A3"
    // Note that to support nested functions, we need to parse the arguments and unfold them recursively

    var buf: [1024]u8 = undefined;
    const unfolded_args = unfold_function_refs(args, &buf);

    switch (function) {
        CellFunction.Sum => {
            const result_len = (std.fmt.bufPrint(result, "({s})", .{unfolded_args}) catch @panic("Buffer overflow")).len;
            _ = std.mem.replace(u8, result, ",", "+", result);
            return result[0..result_len];
        },
        CellFunction.Avg => {
            const result_len = (std.fmt.bufPrint(result, "(({s})/{d})", .{ unfolded_args, 1 + std.mem.count(u8, unfolded_args, ",") }) catch @panic("Buffer overflow")).len;
            _ = std.mem.replace(u8, result, ",", "+", result);
            return result[0..result_len];
        },
        CellFunction.Min => {
            var min_so_far: ?f64 = null;
            var spliterator = std.mem.split(u8, unfolded_args, ",");
            while (spliterator.next()) |arg| {
                var inner_buf: [1024]u8 = undefined;
                std.mem.copyForwards(u8, &inner_buf, arg);
                inner_buf[arg.len] = 0; // ensure null-termination.

                const res = tinyexpr.te_interp(&inner_buf, 0);

                min_so_far = if (min_so_far != null) @min(min_so_far.?, res) else res;
            }
            const result_len = (std.fmt.bufPrint(result, "{}", .{min_so_far.?}) catch @panic("Buffer overflow")).len;
            return result[0..result_len];
        },
        CellFunction.Max => {
            var max_so_far: ?f64 = null;
            var spliterator = std.mem.split(u8, unfolded_args, ",");
            while (spliterator.next()) |arg| {
                var inner_buf: [1024]u8 = undefined;
                std.mem.copyForwards(u8, &inner_buf, arg);
                inner_buf[arg.len] = 0; // ensure null-termination.

                const res = tinyexpr.te_interp(&inner_buf, 0);

                max_so_far = if (max_so_far != null) @max(max_so_far.?, res) else res;
            }
            const result_len = (std.fmt.bufPrint(result, "{}", .{max_so_far.?}) catch @panic("Buffer overflow")).len;
            return result[0..result_len];
        },
    }
    return result;
}

fn get_function_from_name(name: []const u8) ?Function {
    var lowercase_name: [32]u8 = .{0} ** 32;
    std.mem.copyForwards(u8, &lowercase_name, name);
    helpers.toLowercase(lowercase_name[0..name.len]);
    const lowercase_slice = lowercase_name[0..name.len];

    // custom functions
    if (std.mem.eql(u8, lowercase_slice, "sum")) return Function{ .CellFunction = .Sum };
    if (std.mem.eql(u8, lowercase_slice, "avg")) return Function{ .CellFunction = .Avg };
    if (std.mem.eql(u8, lowercase_slice, "min")) return Function{ .CellFunction = .Min };
    if (std.mem.eql(u8, lowercase_slice, "max")) return Function{ .CellFunction = .Max };

    // builtin functions
    if (std.mem.eql(u8, lowercase_slice, "abs")) return Function{ .BuiltinFunction = .Abs };
    if (std.mem.eql(u8, lowercase_slice, "acos")) return Function{ .BuiltinFunction = .Acos };
    if (std.mem.eql(u8, lowercase_slice, "asin")) return Function{ .BuiltinFunction = .Asin };
    if (std.mem.eql(u8, lowercase_slice, "atan")) return Function{ .BuiltinFunction = .Atan };
    if (std.mem.eql(u8, lowercase_slice, "atan2")) return Function{ .BuiltinFunction = .AtanTwo };
    if (std.mem.eql(u8, lowercase_slice, "ceil")) return Function{ .BuiltinFunction = .Ceil };
    if (std.mem.eql(u8, lowercase_slice, "cos")) return Function{ .BuiltinFunction = .Cos };
    if (std.mem.eql(u8, lowercase_slice, "cosh")) return Function{ .BuiltinFunction = .Cosh };
    if (std.mem.eql(u8, lowercase_slice, "e")) return Function{ .BuiltinFunction = .E };
    if (std.mem.eql(u8, lowercase_slice, "exp")) return Function{ .BuiltinFunction = .Exp };
    if (std.mem.eql(u8, lowercase_slice, "fac")) return Function{ .BuiltinFunction = .Fac };
    if (std.mem.eql(u8, lowercase_slice, "floor")) return Function{ .BuiltinFunction = .Floor };
    if (std.mem.eql(u8, lowercase_slice, "ln")) return Function{ .BuiltinFunction = .Ln };
    if (std.mem.eql(u8, lowercase_slice, "log")) return Function{ .BuiltinFunction = .Log };
    if (std.mem.eql(u8, lowercase_slice, "log10")) return Function{ .BuiltinFunction = .Log10 };
    if (std.mem.eql(u8, lowercase_slice, "ncr")) return Function{ .BuiltinFunction = .Ncr };
    if (std.mem.eql(u8, lowercase_slice, "npr")) return Function{ .BuiltinFunction = .Npr };
    if (std.mem.eql(u8, lowercase_slice, "pi")) return Function{ .BuiltinFunction = .Pi };
    if (std.mem.eql(u8, lowercase_slice, "pow")) return Function{ .BuiltinFunction = .Pow };
    if (std.mem.eql(u8, lowercase_slice, "sin")) return Function{ .BuiltinFunction = .Sin };
    if (std.mem.eql(u8, lowercase_slice, "sinh")) return Function{ .BuiltinFunction = .Sinh };
    if (std.mem.eql(u8, lowercase_slice, "sqrt")) return Function{ .BuiltinFunction = .Sqrt };
    if (std.mem.eql(u8, lowercase_slice, "tan")) return Function{ .BuiltinFunction = .Tan };
    if (std.mem.eql(u8, lowercase_slice, "tanh")) return Function{ .BuiltinFunction = .Tanh };

    return null;
}

pub fn unfold_function_refs(value: []const u8, result: []u8) []u8 {
    // Scans through the input value and replaces all function references with the equivalent C calculation.
    // If an unknown function is found, "Unknown function [function]" is returned.
    var idx: usize = 0;
    var output_idx: usize = 0;
    while (idx < value.len) {
        if (parse_fun_ref(value, idx)) |ref| {
            // Replace the function reference with the equivalent C calculation
            // For example, replace "SUM(5,3)" with "(5+3)"
            const function = get_function_from_name(value[ref.start .. ref.start + ref.len]);
            if (function == null) {
                return std.fmt.bufPrint(result, "Unknown function [{s}]", .{value[ref.start .. ref.start + ref.len]}) catch @panic("Buffer overflow");
            }

            var buf: [512]u8 = .{0} ** 512;
            switch (function.?) {
                .CellFunction => |cell_function| {
                    const unfolded_args = try unfold_function(cell_function, value[ref.arg_start .. ref.arg_start + ref.arg_len], &buf);
                    std.mem.copyForwards(u8, result[output_idx..], unfolded_args);
                    output_idx += unfolded_args.len;
                    idx += ref.len + ref.arg_len + 2;
                },
                .BuiltinFunction => |_| {
                    std.mem.copyForwards(u8, result[output_idx..], value[ref.start .. ref.start + ref.len + ref.arg_len + 2]);
                    idx += ref.len + ref.arg_len + 2;
                    output_idx += ref.len + ref.arg_len + 2;
                },
            }
        } else {
            result[output_idx] = value[idx];
            output_idx += 1;
            idx += 1;
        }
    }
    return result[0..output_idx];
}

fn parse_range(input: []const u8, start_idx: usize) ?struct { len: usize, start_cell: CellPos, end_cell: CellPos } {
    var idx = start_idx;
    const start_cell = parse_cell_ref(input, idx) orelse return null;
    idx = start_idx + start_cell.len;
    if (idx >= input.len or input[idx] != ':') {
        return null;
    }
    idx += 1;
    const end_cell = parse_cell_ref(input, idx) orelse return null;
    idx = idx + end_cell.len;
    return .{ .len = idx - start_idx, .start_cell = start_cell.cell_pos, .end_cell = end_cell.cell_pos };
}

test "unfold_function_refs" {
    var buf: [100]u8 = undefined;
    const input = "SUM(5,3)";
    const result = unfold_function_refs(input, &buf);
    const expected = "(5+3)";
    try std.testing.expectEqualStrings(expected, result);
}
test "unfold_function_lowercase" {
    var buf: [100]u8 = undefined;
    const input = "sum(5,3)";
    const result = unfold_function_refs(input, &buf);
    const expected = "(5+3)";
    try std.testing.expectEqualStrings(expected, result);
}

test "unfold_nested_function" {
    var buf: [100]u8 = undefined;
    const input = "sum(5,sum(3,2))";
    const result = unfold_function_refs(input, &buf);
    const expected = "(5+(3+2))";
    try std.testing.expectEqualStrings(expected, result);
}

test "unfold_nested_function_crazyness" {
    var buf: [100]u8 = undefined;
    const input = "avg(5,avg(3,2)+sum(1,2)*avg(5,4,2,3))";
    const result = unfold_function_refs(input, &buf);
    const expected = "((5+((3+2)/2)+(1+2)*((5+4+2+3)/4))/2)";
    try std.testing.expectEqualStrings(expected, result);
}

test "parse_range" {
    const input = "A1:B2";
    const result = parse_range(input, 0) orelse @panic("Failed to parse range");

    try std.testing.expectEqual(5, result.len);
    try std.testing.expectEqual(0, result.start_cell.x);
    try std.testing.expectEqual(1, result.start_cell.y);
    try std.testing.expectEqual(1, result.end_cell.x);
    try std.testing.expectEqual(2, result.end_cell.y);
}
test "parse_range_b" {
    const input = "B7:B8";
    const result = parse_range(input, 0) orelse @panic("Failed to parse range");

    try std.testing.expectEqual(5, result.len);
    try std.testing.expectEqual(1, result.start_cell.x);
    try std.testing.expectEqual(7, result.start_cell.y);
    try std.testing.expectEqual(1, result.end_cell.x);
    try std.testing.expectEqual(8, result.end_cell.y);
}
test "parse_range_lowercase" {
    const input = "a1:b2";
    const result = parse_range(input, 0) orelse @panic("Failed to parse range");

    try std.testing.expectEqual(5, result.len);
    try std.testing.expectEqual(0, result.start_cell.x);
    try std.testing.expectEqual(1, result.start_cell.y);
    try std.testing.expectEqual(1, result.end_cell.x);
    try std.testing.expectEqual(2, result.end_cell.y);
}

test "parse_cell_ref" {
    const input = "A1";
    const result = parse_cell_ref(input, 0) orelse @panic("Failed to parse cell ref");

    try std.testing.expectEqual(2, result.len);
    try std.testing.expectEqual(0, result.cell_pos.x);
    try std.testing.expectEqual(1, result.cell_pos.y);
}

test "parse_cell_ref_b" {
    const input = "B1";
    const result = parse_cell_ref(input, 0) orelse @panic("Failed to parse cell ref");

    try std.testing.expectEqual(2, result.len);
    try std.testing.expectEqual(1, result.cell_pos.x);
    try std.testing.expectEqual(1, result.cell_pos.y);
}

test "parse_cell_ref_lowercase" {
    const input = "a1";
    const result = parse_cell_ref(input, 0) orelse @panic("Failed to parse cell ref");

    try std.testing.expectEqual(2, result.len);
    try std.testing.expectEqual(0, result.cell_pos.x);
    try std.testing.expectEqual(1, result.cell_pos.y);
}

test "parse_cell_ref_does_not_find_atan2" {
    const input = "atan2()";
    const result = parse_cell_ref(input, 0);
    try std.testing.expectEqual(null, result);
}

test "parse_range_with_other_characters" {
    const input = ", A1:B2";
    const first_result = parse_range(input, 0);
    try std.testing.expectEqual(null, first_result);
    const result = parse_range(input, 2) orelse @panic("Failed to parse cell ref");
    try std.testing.expectEqual(5, result.len);
    try std.testing.expectEqual(0, result.start_cell.x);
    try std.testing.expectEqual(1, result.start_cell.y);
    try std.testing.expectEqual(1, result.end_cell.x);
    try std.testing.expectEqual(2, result.end_cell.y);
}

fn num_to_col_str(col_num: u32, col_str: []u8) ?[]u8 {
    // col_str is the buffer to hold the column letters
    // Returns the length of the string written to col_str
    var num = col_num + 1;
    var temp_buf: [10]u8 = undefined; // Max column letters we can have is 10 (arbitrary)
    var temp_idx: usize = 0;
    while (num > 0) {
        num -= 1;
        const rem: u8 = @intCast(num % 26);
        temp_buf[temp_idx] = rem + 'A';
        temp_idx += 1;
        num = num / 26;
    }
    // Now, temp_buf[0..temp_idx] contains the letters in reverse order
    // We need to reverse them into col_str
    if (temp_idx > col_str.len) {
        // Not enough space in col_str
        return null;
    }
    for (0..temp_idx) |i| {
        col_str[i] = temp_buf[temp_idx - i - 1];
    }
    return col_str[0..temp_idx];
}

const CellPos = struct {
    x: i32,
    y: i32,
};

// TEST custom functions

test "replace_exprs for SUM function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=SUM(2, 3)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=(2+3)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for AVG function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=AVG(2, 3)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=((2+3)/2)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for MIN function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=MIN(2, 3)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=2", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for MAX function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=MAX(2, 3)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=3", result);
    try std.testing.expectEqual(0, refs.len);
}

// TEST builtin functions

test "replace_exprs for ABS function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=ABS(-3)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=ABS(-3)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for ACOS function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=ACOS(1)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=ACOS(1)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for ASIN function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=ASIN(1)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=ASIN(1)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for ATAN function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=ATAN(1)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=ATAN(1)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for ATAN2 function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=ATAN2(1, 1)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=ATAN2(1,1)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for CEIL function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=CEIL(1.5)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=CEIL(1.5)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for COS function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=COS(1)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=COS(1)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for COSH function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=COSH(1)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=COSH(1)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for E function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=E()");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=E()", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for EXP function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=EXP(1)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=EXP(1)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for FAC function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=FAC(5)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=FAC(5)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for FLOOR function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=FLOOR(1.5)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=FLOOR(1.5)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for LN function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=LN(1)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=LN(1)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for LOG function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=LOG(1)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=LOG(1)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for LOG10 function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=LOG10(1)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=LOG10(1)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for NCR function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=NCR(5, 2)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=NCR(5,2)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for NPR function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=NPR(5, 2)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=NPR(5,2)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for PI function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=PI()");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=PI()", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for POW function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=POW(2, 3)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=POW(2,3)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for SIN function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=SIN(1)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=SIN(1)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for SINH function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=SINH(1)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=SINH(1)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for SQRT function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=SQRT(4)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=SQRT(4)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for TAN function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=TAN(1)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=TAN(1)", result);
    try std.testing.expectEqual(0, refs.len);
}

test "replace_exprs for TANH function" {
    const allocator = std.heap.c_allocator;
    var cells = try CellContainer.init(0, allocator);

    var test_cell = try cells.add_cell(0, 0, "=TANH(1)");
    const result, const refs = try test_cell.replace_exprs(&cells);
    try std.testing.expectEqualStrings("=TANH(1)", result);
    try std.testing.expectEqual(0, refs.len);
}
