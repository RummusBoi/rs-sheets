const std = @import("std");
const Cell = @import("cell.zig").Cell;
const CellContainer = @import("cell.zig").CellContainer;
const CsvError = error{
    IncorrectNumberOfCells,
    CouldNotReadPath,
};

// this file is responsible for reading the given CSV file and return a CellContainer with all the given data in it.
//
pub fn read_cells_from_csv_file(allocator: *std.mem.Allocator, path: []const u8) !CellContainer {
    const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
    const contents = try file.readToEndAlloc(allocator.*, 1024);
    defer allocator.free(contents);

    return try parse_contents(contents, allocator);
}

fn parse_contents(contents: []u8, allocator: *std.mem.Allocator) !CellContainer {
    // reads the given contents and produces a CellContainer.
    // NOTE (Rasmus): How do we escape commas in the CSV file? Just put double quotes around any cell that contains a comma.

    var container = try CellContainer.init(0, allocator);

    const first_newline = std.mem.indexOfScalar(u8, contents, '\n');
    const first_line = if (first_newline) |index| contents[0..index] else contents;
    const expected_cells_per_line = std.mem.count(u8, first_line, &.{','}) + @as(usize, 1);
    const stripped_contents = if (contents[contents.len - 1] == '\n') contents[0 .. contents.len - 1] else contents;
    var line_spliterator = std.mem.splitScalar(u8, stripped_contents, '\n');

    // basically go through every "record" and if it is set, create a new cell and append it to the container._cells
    var x: i32 = 0;
    var y: i32 = 0;
    while (line_spliterator.next()) |line| : (y += 1) {
        x = 0;
        // const cells_on_this_line = std.mem.count(u8, line, &.{','}) + 1;
        // if (cells_on_this_line != expected_cells_per_line) return CsvError.IncorrectNumberOfCells;
        // var cell_spliterator = std.mem.splitScalar(u8, line, ',');

        var inside_quotes = false;
        var cell_start_index: usize = 0;
        var cells_on_this_line: i32 = 0;
        for (0..line.len + 1) |index| {
            const char = if (index < line.len) line[index] else (0);
            if (char == '"' and inside_quotes) {
                inside_quotes = false;
            } else if (char == '"') {
                inside_quotes = true;
            } else if (!inside_quotes and (char == ',' or char == 0)) {
                cells_on_this_line += 1;
                const cell_value = line[cell_start_index..index];
                cell_start_index = index + 1;
                if (cell_value.len == 0) {
                    x += 1;
                    continue;
                }
                var escaped_cell_value = try allocator.alloc(u8, cell_value.len);
                defer allocator.free(escaped_cell_value);
                escaped_cell_value = remove_escape_characters(cell_value, escaped_cell_value);
                _ = try container.add_cell(x, y, escaped_cell_value);
                x += 1;
            }
        }
        if (cells_on_this_line != expected_cells_per_line) return CsvError.IncorrectNumberOfCells;

        // while (cell_spliterator.next()) |cell_content| : (x += 1) {
        //     if (cell_content.len == 0) continue;
        //     _ = try container.add_cell(x, y, cell_content);
        // }
    }

    return container;
}

pub fn write_cells_to_csv_file(allocator: *std.mem.Allocator, cells: CellContainer) !void {
    var highest_x_found: i32 = 0;
    var highest_y_found: i32 = 0;
    for (cells._cells.items) |cell| {
        if (cell.raw_value.items.len == 0) continue;
        highest_x_found = @max(cell.x, highest_x_found);
        highest_y_found = @max(cell.y, highest_y_found);
    }
    var args = std.process.args();
    _ = args.skip();
    const path = args.next() orelse {
        std.debug.print("Failed to save file", .{});
        return CsvError.CouldNotReadPath;
    };
    const file = try std.fs.openFileAbsolute(path, .{ .mode = .write_only });

    var file_contents = std.ArrayList(u8).init(allocator.*);
    for (0..@intCast(highest_y_found + 1)) |y| {
        for (0..@intCast(highest_x_found + 1)) |x| {
            if (cells.find(@intCast(x), @intCast(y))) |cell| {
                const dest_buffer = try allocator.alloc(u8, cell.raw_value.items.len * 2 + 2);
                defer allocator.free(dest_buffer);
                const escaped_cell_value = insert_escape_characters(cell.raw_value.items, dest_buffer);
                try file_contents.appendSlice(escaped_cell_value);
            }
            if (x < highest_x_found) try file_contents.append(',');
        }
        if (y < highest_y_found) try file_contents.append('\n');
    }

    _ = try file.write(file_contents.items);
}

fn insert_escape_characters(value: []const u8, dest_buffer: []u8) []u8 {
    // for now, we wrap every cell in quotes, since that will always work although less efficient.
    // "     => ""
    // value => "value"
    const replacements = std.mem.replace(u8, value, "\"", "\"\"", dest_buffer);
    const replaced_size = value.len + replacements; // each replacement introduces one new character

    var index: usize = replaced_size + 1;
    while (index != 0) : (index -= 1) {
        dest_buffer[index] = dest_buffer[index - 1];
    }

    dest_buffer[0] = '"';
    dest_buffer[replaced_size + 1] = '"';

    return dest_buffer[0 .. replaced_size + 2];
}

fn remove_escape_characters(value: []const u8, dest_buffer: []u8) []u8 {
    // "  =>
    // "" => "
    var replacements = std.mem.replace(u8, value, &.{'"'}, "", dest_buffer);
    replacements += std.mem.replace(u8, dest_buffer, "\"\"", "\"", dest_buffer);
    return dest_buffer[0 .. value.len - replacements];
}
