// This file should be responsible for knowing where the user is in the sheet.
// It should figure out which cells need to be rendered, and should call sheet_window with the correct cells
const WindowState = @import("window_state.zig").WindowState;
const SheetWindow = @import("sheet_window.zig").SheetWindow;
const Cell = @import("cell.zig").Cell;
const column_to_chars = @import("cell.zig").column_to_chars;
const CellContainer = @import("cell.zig").CellContainer;
const constants = @import("constants.zig");
const std = @import("std");

pub fn cell_to_pixel(
    cell_x: i32,
    cell_y: i32,
    state: *const WindowState,
) struct { x: i32, y: i32 } {
    return .{ .x = cell_x * constants.CELL_WIDTH - state.x, .y = cell_y * constants.CELL_HEIGHT - state.y };
}

pub fn pixel_to_cell(
    pixel_x: i32,
    pixel_y: i32,
    state: *const WindowState,
) ?CellCoords {
    const x = @divTrunc((pixel_x + state.x), constants.CELL_WIDTH);
    const y = @divTrunc((pixel_y + state.y), constants.CELL_HEIGHT);
    if (x < 0 or y < 0) return null;
    return .{ .x = x, .y = y };
}

pub fn refresh_cell_values_for_cell(cells: *CellContainer, coords: CellCoords, modify_deps: bool) usize {
    const this_cell = cells.find(coords.x, coords.y) orelse return 0;
    this_cell.refresh_value(cells, modify_deps) catch {
        std.debug.print("Could not update cell.", .{});
        return 0;
    };
    const cells_to_update = cells.get_cells_depending_on_this(coords.x, coords.y) catch {
        std.debug.print("Could not fetch cells to update.", .{});
        return 0;
    };
    defer cells.allocator.free(cells_to_update);
    var total_updates: usize = 1;
    for (cells_to_update) |cell| {
        total_updates += refresh_cell_values_for_cell(cells, .{ .x = cell.x, .y = cell.y }, false);
    }
    return total_updates;
}

pub fn refresh_all_cell_values(cells: *CellContainer) void {
    for (cells._cells.items) |cell| {
        cell.refresh_value(cells, true) catch {
            std.debug.print("Failed when refreshing cell value for cell '{}'", .{cell});
        };
    }
}

pub fn render_cells(state: *const WindowState, sheet_window: *SheetWindow, cells: *CellContainer, selected_cell: ?CellCoords, is_editing: bool) !void {
    // first we remove all the unused textures given our new values
    // const value_slice = try std.heap.page_allocator.alloc([]u8, cells._cells.items.len * 2);
    var value_set = std.StringHashMap(bool).init(cells.allocator);
    defer value_set.deinit();

    for (cells._cells.items) |cell| {
        try value_set.put(cell.value.items, true);
        try value_set.put(cell.raw_value.items, true);
    }
    sheet_window.delete_unused_textures(value_set, "cell");

    const pixel_offset_x = state.x - constants.CELL_START_X;
    const pixel_offset_y = state.y - constants.CELL_START_Y;

    const cell_offset_x = @divFloor(pixel_offset_x, constants.CELL_WIDTH);
    const cell_offset_y = @divFloor(pixel_offset_y, constants.CELL_HEIGHT);
    const horizontal_cell_count = @divTrunc(state.width, constants.CELL_WIDTH) + 2;
    const vertical_cell_count = @divTrunc(state.height, constants.CELL_HEIGHT) + 2;

    var x: i32 = @max(cell_offset_x, 0);
    var found_selected_cell: ?*Cell = null;

    while (x < cell_offset_x + horizontal_cell_count) : (x += 1) {
        var y: i32 = @max(cell_offset_y, 0);
        while (y < cell_offset_y + vertical_cell_count) : (y += 1) {
            const coords = cell_to_pixel(x, y, state);
            const cell = cells.find(x, y);
            const val = if (cell == null) &.{} else cell.?.value.items;

            const is_the_selected_cell = (selected_cell != null) and x == selected_cell.?.x and y == selected_cell.?.y;
            // we want to skip the selected cell so we can render that one on top at the end.
            if (is_the_selected_cell) {
                found_selected_cell = cells.find(selected_cell.?.x, selected_cell.?.y);
                continue;
            }
            try sheet_window.draw_cell(coords.x, coords.y, val, false, false, false);
        }
    }

    if (found_selected_cell) |cell| {
        // render the raw value when we are editing
        const cell_value = if (is_editing) cell.raw_value.items else (cell.value.items);
        const pixel_coords = cell_to_pixel(cell.x, cell.y, state);
        try sheet_window.draw_cell(pixel_coords.x, pixel_coords.y, cell_value, true, is_editing, is_editing);
    }
}

pub fn render_selections(state: *const WindowState, sheet_window: *SheetWindow, selected_area: Area) !void {
    const upper_left_x = @min(selected_area.x, selected_area.x + selected_area.w + @as(i32, if (selected_area.w > 0) -1 else 1));
    const upper_left_y = @min(selected_area.y, selected_area.y + selected_area.h + @as(i32, if (selected_area.h > 0) -1 else 1));
    const lower_right_x = @max(selected_area.x, selected_area.x + selected_area.w + @as(i32, if (selected_area.w > 0) -1 else 1));
    const lower_right_y = @max(selected_area.y, selected_area.y + selected_area.h + @as(i32, if (selected_area.h > 0) -1 else 1));

    const upper_left = cell_to_pixel(upper_left_x, upper_left_y, state);
    const lower_right = cell_to_pixel(lower_right_x + 1, lower_right_y + 1, state);

    try sheet_window.draw_area(upper_left.x, upper_left.y, lower_right.x - upper_left.x, lower_right.y - upper_left.y);
}

pub fn render_row_labels(state: *const WindowState, sheet_window: *SheetWindow, selected_area: ?Area, selected_cell: ?CellCoords) !void {
    var label_index: i32 = @max(0, @divTrunc(state.y, constants.CELL_HEIGHT));
    while (label_index < @divTrunc(state.y + state.height, constants.CELL_HEIGHT)) : (label_index += 1) {
        const y: i32 = label_index * constants.CELL_HEIGHT - state.y;
        var buf: [32]u8 = .{0} ** 32;
        const label_len = std.fmt.formatIntBuf(&buf, label_index, 10, .upper, .{});
        var is_selected = false;
        if (selected_cell) |cell| {
            is_selected = is_selected or (label_index == cell.y);
        }
        if (selected_area) |area| {
            const area_max = @max(area.y, if (area.h > 0) area.y + area.h - 1 else area.y + area.h + 1);
            const area_min = @min(area.y, if (area.h > 0) area.y + area.h - 1 else area.y + area.h + 1);
            is_selected = is_selected or (label_index >= area_min and label_index <= area_max);
        }
        try sheet_window.draw_row_label(buf[0..label_len], y, is_selected);
    }
}

pub fn render_column_labels(state: *const WindowState, sheet_window: *SheetWindow, selected_area: ?Area, selected_cell: ?CellCoords) !void {
    var label_index: i32 = @max(0, @divTrunc(state.x, constants.CELL_WIDTH));
    while (label_index < @divTrunc(state.x + state.width, constants.CELL_WIDTH)) : (label_index += 1) {
        const x: i32 = label_index * constants.CELL_WIDTH - state.x;
        var buf: [32]u8 = .{0} ** 32;

        const label_len = column_to_chars(label_index, &buf);

        var is_selected = false;
        if (selected_cell) |cell| {
            is_selected = is_selected or (label_index == cell.x);
        }
        if (selected_area) |area| {
            const area_max = @max(area.x, if (area.w > 0) area.x + area.w - 1 else area.x + area.w + 1);
            const area_min = @min(area.x, if (area.w > 0) area.x + area.w - 1 else area.x + area.w + 1);
            is_selected = is_selected or (label_index >= area_min and label_index <= area_max);
        }
        try sheet_window.draw_column_label(buf[0..label_len], x, is_selected);
    }
}

// returns index to cell with the given coordinates

pub const CellCoords = struct {
    x: i32,
    y: i32,
};

pub const Area = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};
