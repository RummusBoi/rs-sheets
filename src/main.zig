const std = @import("std");

const sheet_window = @import("sheet_window.zig");

const window_title = "zig-gamedev: minimal zgpu zgui";
const sheet = @import("sheet.zig");
const Cell = @import("cell.zig").Cell;
const CellContainer = @import("cell.zig").CellContainer;
const find_cell = @import("cell.zig").find_cell;
const read_cells_from_csv_file = @import("fileparser.zig").read_cells_from_csv_file;
const write_cells_to_csv_file = @import("fileparser.zig").write_cells_to_csv_file;
const WindowState = @import("window_state.zig").WindowState;
pub fn main() !void {
    const startup = std.time.milliTimestamp();
    var args = std.process.args();
    if (args.inner.count < 2) {
        @panic("Expected exactly 2 arguments to program.");
    }
    if (args.inner.count > 2) {
        @panic("Expected exactly 2 arguments to program.");
    }
    _ = args.skip(); // skip this file
    const filepath = args.next() orelse {
        @panic("Something went wrong.");
    };

    std.debug.print("Found filepath: {s}", .{filepath});

    var allocator = std.heap.page_allocator;
    // const before_read_cells = std.time.milliTimestamp();
    var cells = try read_cells_from_csv_file(&allocator, filepath);
    // const after_read_cells = std.time.milliTimestamp();
    const default_width = 1000;
    const default_height = 1000;

    // 130ms
    // const before_sheet_window_init = std.time.milliTimestamp();
    var display = try sheet_window.SheetWindow.init(default_width, default_height, &allocator);
    // const after_sheet_window_init = std.time.milliTimestamp();

    // std.debug.print("Initting sheet window: {}\n", .{after_sheet_window_init - before_sheet_window_init});
    var state: WindowState = .{ .x = -100, .y = -100, .zoomLevel = 1, .width = default_width, .height = default_height };
    // var scroll_vel_x: f64 = 0;
    // var scroll_vel_y: f64 = 0;
    // const scroll_friction: f64 = 0.1;
    // const scroll_sensitivity: f64 = 10;

    const time_per_frame: i128 = @intFromFloat(1.0 / @as(f32, @floatFromInt(60)) * @as(f32, 1000000000));

    // cells[0] = .{ .x = 0, .y = 0, .value = "hejsa" };
    // cells[1] = .{ .x = 10, .y = 0, .value = "hejsa v2" };
    // cells[2] = .{ .x = 5, .y = 5, .value = "hejsa v3" };
    var prev_frame = std.time.nanoTimestamp();
    var next_frame = prev_frame + time_per_frame;
    var prev_frame_wheel_x: ?i32 = null;
    var prev_frame_wheel_y: ?i32 = null;

    var selected_cell: ?sheet.CellCoords = null;
    var selected_area: ?sheet.Area = null;
    // var selected_area: ?{

    var left_button_is_down = false;
    var is_holding_shift: bool = false;
    var is_holding_cmd: bool = false;
    var is_editing: bool = false;

    var is_first_frame = true;

    while (true) {
        if (!is_first_frame) {
            const sleep_time = @max(next_frame - std.time.nanoTimestamp(), 0);

            std.time.sleep(@intCast(sleep_time));
            const nanos_elapsed = std.time.nanoTimestamp() - prev_frame;

            const millis_elapsed: i32 = @intFromFloat(@as(f32, @floatFromInt(nanos_elapsed)) / @as(f32, @floatFromInt(1000000)));
            _ = millis_elapsed;
            // std.debug.print("Frametime: {}ms\n", .{millis_elapsed});
            prev_frame = std.time.nanoTimestamp();
            next_frame = prev_frame + time_per_frame;

            var event: sheet_window.c.SDL_Event = undefined;

            while (sheet_window.c.SDL_PollEvent(&event) != 0) {
                var get_mousewheel_event = false;
                switch (event.type) {
                    sheet_window.c.SDL_QUIT => {
                        sheet_window.c.SDL_Quit();
                        return;
                    },
                    sheet_window.c.SDL_MOUSEWHEEL => {
                        get_mousewheel_event = true;
                        state.x += @divTrunc((prev_frame_wheel_x orelse 0) + (event.wheel.x + event.wheel.x * @as(i32, @intCast(@abs(event.wheel.x)))), 2);
                        state.y -= @divTrunc((prev_frame_wheel_y orelse 0) + (event.wheel.y + event.wheel.y * @as(i32, @intCast(@abs(event.wheel.y)))), 2);

                        prev_frame_wheel_x = event.wheel.x;
                        prev_frame_wheel_y = event.wheel.y;

                        // scroll_vel_x = @floatFromInt(-event.wheel.x);
                        // scroll_vel_y = @floatFromInt(event.wheel.y);
                    },
                    sheet_window.c.SDL_MOUSEBUTTONDOWN => {
                        if (event.button.button == sheet_window.c.SDL_BUTTON_LEFT) {
                            left_button_is_down = true;
                            const maybe_cell = sheet.pixel_to_cell(event.button.x, event.button.y, &state);
                            if (maybe_cell) |cell| {
                                selected_area = .{ .x = cell.x, .y = cell.y, .w = 1, .h = 1 };
                                selected_cell = null;
                                // selected_cell = .{ .x = cell.x, .y = cell.y };
                            }
                        }
                    },
                    sheet_window.c.SDL_MOUSEBUTTONUP => {
                        if (event.button.button == sheet_window.c.SDL_BUTTON_LEFT) {
                            left_button_is_down = false;
                            if (selected_area) |area| {
                                if (area.w == 1 and area.h == 1) {
                                    selected_cell = .{ .x = area.x, .y = area.y };
                                    _ = try cells.ensure_cell(selected_cell.?.x, selected_cell.?.y);
                                    selected_area = null;
                                }
                            }
                        }
                    },
                    sheet_window.c.SDL_MOUSEMOTION => {
                        if (left_button_is_down) {
                            const maybe_cell = sheet.pixel_to_cell(event.button.x, event.button.y, &state);
                            if (maybe_cell) |mouse_cell| {
                                if (selected_area) |*area| {
                                    if (area.x <= mouse_cell.x) {
                                        area.w = mouse_cell.x - area.x + 1;
                                    } else {
                                        area.w = mouse_cell.x - area.x - 1;
                                    }
                                    if (area.y <= mouse_cell.y) {
                                        area.h = mouse_cell.y - area.y + 1;
                                    } else {
                                        area.h = mouse_cell.y - area.y - 1;
                                    }
                                    if (area.w != 1 or area.h != 1) {
                                        selected_cell = null;
                                    }
                                }
                            }
                        }
                    },
                    sheet_window.c.SDL_TEXTINPUT => {
                        if (!is_editing) {
                            is_editing = true;
                            if (selected_cell) |cell_coords| {
                                if (cells.find(cell_coords.x, cell_coords.y)) |cell| {
                                    cell.raw_value.items.len = 0;
                                }
                            }
                        }
                        const text_len = get_cstr_len(&event.text.text);
                        var text: []u8 = undefined;
                        text.ptr = &event.text.text;
                        text.len = text_len;
                        if (selected_area) |area| {
                            selected_cell = .{ .x = area.x, .y = area.y };
                            selected_area = null;
                        }
                        if (selected_cell == null) continue;
                        const matching_cell = cells.find(selected_cell.?.x, selected_cell.?.y) orelse blk: {
                            const new_cell = try cells.add_cell(selected_cell.?.x, selected_cell.?.y, "");
                            break :blk new_cell;
                        };
                        for (text) |char| {
                            matching_cell.value_append(char) catch {
                                std.debug.print("Could not append char '{}'", .{char});
                            };
                        }
                    },
                    sheet_window.c.SDL_KEYDOWN => {
                        const keycode = event.key.keysym.sym;

                        if (keycode == sheet_window.c.SDLK_ESCAPE) {
                            if (selected_area) |area| {
                                selected_cell = .{ .x = area.x, .y = area.y };
                                selected_area = null;
                                is_editing = false;
                            } else if (!is_editing) {
                                selected_cell = null;
                            } else if (is_editing) {
                                is_editing = false;
                            }
                        } else if (keycode == sheet_window.c.SDLK_RETURN) {
                            if (!is_editing) {
                                is_editing = true;
                            } else if (is_editing) {
                                if (selected_cell) |*cell| {
                                    cell.y += 1;
                                    _ = cells.ensure_cell(cell.x, cell.y) catch {
                                        std.debug.print("Failed when ensuring cell exists", .{});
                                        continue;
                                    };
                                }
                            }
                        } else if (keycode == sheet_window.c.SDLK_LSHIFT) {
                            is_holding_shift = true;
                        } else if (keycode == sheet_window.c.SDLK_BACKSPACE) {
                            if (selected_cell) |cell_coords| {
                                if (cells.find(cell_coords.x, cell_coords.y)) |cell| {
                                    if (is_editing) cell.value_delete() else cell.raw_value.items.len = 0;
                                }
                            } else if (selected_area) |area| {
                                const min_x = if (area.w > 0) area.x else (area.x + area.w + 1);
                                const min_y = if (area.h > 0) area.y else (area.y + area.h + 1);
                                const max_x = if (area.w > 0) area.x + area.w else (area.x + 1);
                                const max_y = if (area.h > 0) area.y + area.h else (area.y + 1);
                                for (@intCast(min_y)..@intCast(max_y)) |y| {
                                    for (@intCast(min_x)..@intCast(max_x)) |x| {
                                        if (cells.find(@intCast(x), @intCast(y))) |cell| {
                                            cell.raw_value.items.len = 0;
                                        }
                                    }
                                }
                            }
                        } else if (keycode == sheet_window.c.SDLK_TAB) {
                            if (selected_cell) |*cell_coords| {
                                cell_coords.x += 1;
                                _ = cells.ensure_cell(cell_coords.x, cell_coords.y) catch {
                                    std.debug.print("Failed when ensuring cell exists. ", .{});
                                };
                            } else if (selected_area) |*area| {
                                selected_cell = .{ .x = area.x + 1, .y = area.y };
                                selected_area = null;
                                _ = cells.ensure_cell(selected_cell.?.x, selected_cell.?.y) catch {
                                    std.debug.print("Failed when ensuring cell exists. ", .{});
                                };
                            }
                        }
                        const scancode = event.key.keysym.scancode;
                        if (scancode == sheet_window.c.SDL_SCANCODE_LEFT) {
                            if (is_holding_shift) {
                                if (selected_cell) |cell| {
                                    selected_area = .{ .x = cell.x, .y = cell.y, .w = -2, .h = 1 };
                                    selected_cell = null;
                                } else if (selected_area) |*area| {
                                    if (area.x + area.w == -1) continue;
                                    if (area.w == 1) area.w = -2 else area.w -= 1;
                                }
                            } else {
                                if (selected_cell) |*cell| {
                                    is_editing = false;
                                    cell.x = @max(0, cell.x - 1);
                                    _ = try cells.ensure_cell(cell.x, cell.y);
                                } else if (selected_area) |*area| {
                                    selected_cell = .{ .x = @max(area.x - 1, 0), .y = area.y };
                                    selected_area = null;
                                }
                            }
                        } else if (scancode == sheet_window.c.SDL_SCANCODE_RIGHT) {
                            if (is_holding_shift) {
                                if (selected_cell) |cell| {
                                    selected_area = .{ .x = cell.x, .y = cell.y, .w = 2, .h = 1 };
                                    selected_cell = null;
                                } else if (selected_area) |*area| {
                                    if (area.w == -1) area.w = 2 else area.w += 1;
                                }
                            } else {
                                if (selected_cell) |*cell| {
                                    is_editing = false;
                                    cell.x = cell.x + 1;
                                    _ = try cells.ensure_cell(cell.x, cell.y);
                                } else if (selected_area) |*area| {
                                    selected_cell = .{ .x = area.x + 1, .y = area.y };
                                    selected_area = null;
                                }
                            }
                        } else if (scancode == sheet_window.c.SDL_SCANCODE_DOWN) {
                            if (is_holding_shift) {
                                if (selected_cell) |cell| {
                                    selected_area = .{ .x = cell.x, .y = cell.y, .w = 1, .h = 2 };
                                    selected_cell = null;
                                } else if (selected_area) |*area| {
                                    if (area.h == -1) area.h = 2 else area.h += 1;
                                }
                            } else {
                                if (selected_cell) |*cell| {
                                    is_editing = false;
                                    cell.y = cell.y + 1;
                                    _ = try cells.ensure_cell(cell.x, cell.y);
                                } else if (selected_area) |*area| {
                                    selected_cell = .{ .x = area.x, .y = area.y + 1 };
                                    selected_area = null;
                                }
                            }
                        } else if (scancode == sheet_window.c.SDL_SCANCODE_UP) {
                            if (is_holding_shift) {
                                if (selected_cell) |cell| {
                                    selected_area = .{ .x = cell.x, .y = cell.y, .w = 1, .h = -2 };
                                    selected_cell = null;
                                } else if (selected_area) |*area| {
                                    if (area.y + area.h == -1) continue;
                                    if (area.h == 1) area.h = -2 else area.h -= 1;
                                }
                            } else {
                                if (selected_cell) |*cell| {
                                    is_editing = false;
                                    cell.y = @max(0, cell.y - 1);
                                    _ = try cells.ensure_cell(cell.x, cell.y);
                                } else if (selected_area) |*area| {
                                    selected_cell = .{ .x = area.x, .y = @max(area.y - 1, 0) };
                                    selected_area = null;
                                }
                            }
                        } else if (scancode == sheet_window.c.SDL_SCANCODE_S) {
                            if (is_holding_cmd) {
                                write_cells_to_csv_file(&allocator, cells) catch {
                                    std.debug.print("Failed to save changes..", .{});
                                };
                            }
                        } else if (scancode == sheet_window.c.SDL_SCANCODE_C) {
                            if (!is_holding_cmd) continue;
                            std.debug.print("Copying", .{});
                            if (selected_cell) |cell_coords| {
                                if (cells.find(cell_coords.x, cell_coords.y)) |cell| {
                                    const cell_value = cell.raw_value.items;
                                    const c_str = try std.heap.page_allocator.dupeZ(u8, cell_value);
                                    defer allocator.free(c_str);
                                    if (sheet_window.c.SDL_SetClipboardText(c_str) != 0) {
                                        std.debug.print("Could not paste text to clipboard.", .{});
                                    } else {
                                        std.debug.print("Copied {s}", .{c_str});
                                    }
                                }
                            } else if (selected_area) |area| blk: {
                                var clipboard_buffer = std.ArrayList(u8).init(allocator);
                                defer clipboard_buffer.deinit();

                                const min_x = if (area.w > 0) area.x else (area.x + area.w + 1);
                                const min_y = if (area.h > 0) area.y else (area.y + area.h + 1);
                                const max_x = if (area.w > 0) area.x + area.w else (area.x + 1);
                                const max_y = if (area.h > 0) area.y + area.h else (area.y + 1);
                                for (@intCast(min_y)..@intCast(max_y)) |y| {
                                    for (@intCast(min_x)..@intCast(max_x)) |x| {
                                        if (cells.find(@intCast(x), @intCast(y))) |cell| {
                                            clipboard_buffer.appendSlice(cell.raw_value.items) catch {
                                                std.debug.print("Could not allocate for clipboard buffer.", .{});
                                                break :blk;
                                            };
                                        }
                                        // this skips the last item in a row, so that we avoid have \t\n at the end.
                                        if (x < max_x - 1) {
                                            clipboard_buffer.append('\t') catch {
                                                std.debug.print("Could not allocate for clipboard buffer.", .{});
                                                break :blk;
                                            };
                                        }
                                    }
                                    if (y < max_y - 1) {
                                        clipboard_buffer.append('\n') catch {
                                            std.debug.print("Could not allocate for clipboard buffer.", .{});
                                            break :blk;
                                        };
                                    }
                                }
                                clipboard_buffer.append(0) catch {
                                    std.debug.print("Could not allocate for clipboard buffer.", .{});
                                    break :blk;
                                };
                                if (sheet_window.c.SDL_SetClipboardText(clipboard_buffer.items.ptr) != 0) {
                                    std.debug.print("Could not set the clipboard to value '{any}", .{clipboard_buffer.items});
                                    break :blk;
                                } else {
                                    std.debug.print("Set the clipboard to value '{any}'", .{clipboard_buffer.items});
                                }
                            }
                        } else if (scancode == sheet_window.c.SDL_SCANCODE_V) blk: {
                            if (is_holding_cmd) {
                                std.debug.print("pasting", .{});
                                if (selected_cell) |cell_coords| {
                                    const clipboard = sheet_window.c.SDL_GetClipboardText();
                                    defer sheet_window.c.SDL_free(clipboard);

                                    var c_str_slice: []u8 = undefined;
                                    c_str_slice.ptr = clipboard;
                                    c_str_slice.len = get_cstr_len(clipboard);
                                    var curr_cell_coords: sheet.CellCoords = .{ .x = cell_coords.x, .y = cell_coords.y };
                                    var curr_cell: *Cell = cells.ensure_cell(curr_cell_coords.x, curr_cell_coords.y) catch {
                                        std.debug.print("Failed when ensure that cell existed.", .{});
                                        break :blk;
                                    };
                                    curr_cell.raw_value.items.len = 0;
                                    var curr_width: i32 = 0;
                                    var max_width: i32 = 0;
                                    var height: i32 = 1;

                                    for (c_str_slice) |char| {
                                        if (char == '\t') {
                                            curr_cell_coords.x += 1;
                                            curr_cell = cells.ensure_cell(curr_cell_coords.x, curr_cell_coords.y) catch {
                                                std.debug.print("Failed when ensure that cell existed.", .{});
                                                break :blk;
                                            };
                                            curr_cell.raw_value.items.len = 0;
                                            curr_width += 1;
                                        } else if (char == '\n') {
                                            curr_width += 1;
                                            max_width = @max(max_width, curr_width);
                                            curr_width = 0;
                                            height += 1;
                                            curr_cell_coords.y += 1;
                                            curr_cell_coords.x = cell_coords.x;
                                            curr_cell = cells.ensure_cell(curr_cell_coords.x, curr_cell_coords.y) catch {
                                                std.debug.print("Failed when ensure that cell existed.", .{});
                                                break :blk;
                                            };
                                            curr_cell.raw_value.items.len = 0;
                                        } else {
                                            curr_cell.raw_value.append(char) catch {
                                                std.debug.print("Failed when appending cell value.", .{});
                                                break :blk;
                                            };
                                        }
                                    }

                                    // the pasted value might not end with a newline:
                                    max_width = @max(curr_width, max_width);
                                    selected_area = .{ .x = cell_coords.x, .y = cell_coords.y, .w = max_width, .h = height };
                                    selected_cell = null;
                                    std.debug.print("Selected area: {}", .{selected_area.?});
                                }
                            }
                        } else if (scancode == sheet_window.c.SDL_SCANCODE_LGUI) {
                            is_holding_cmd = true;
                        }
                    },
                    sheet_window.c.SDL_KEYUP => {
                        const scancode = event.key.keysym.scancode;
                        const keycode = event.key.keysym.sym;
                        if (keycode == sheet_window.c.SDLK_LSHIFT) {
                            is_holding_shift = false;
                        }
                        if (scancode == sheet_window.c.SDL_SCANCODE_LGUI) {
                            is_holding_cmd = false;
                        }
                    },
                    sheet_window.c.SDL_WINDOWEVENT => {
                        if (event.window.event == sheet_window.c.SDL_WINDOWEVENT_RESIZED) {
                            if (sheet_window.c.SDL_RenderSetViewport(display.renderer, &.{ .x = 0, .y = 0, .w = event.window.data1, .h = event.window.data2 }) != 0) {
                                @panic("Couldnt resize window");
                            }
                            state.width = event.window.data1;
                            state.height = event.window.data2;
                        }
                    },
                    else => {},
                }
                if (!get_mousewheel_event) {
                    prev_frame_wheel_x = 0;
                    prev_frame_wheel_y = 0;
                }
            }
        }
        // if (scroll_vel_x > 0) {
        //     std.debug.print("Scroll x: {}\n", .{scroll_vel_x});
        //     scroll_vel_x *= 1 - scroll_friction;
        // }

        // if (scroll_vel_x < 0) {
        //     std.debug.print("Scroll x: {}\n", .{scroll_vel_x});
        //     scroll_vel_x *= 1 - scroll_friction;
        // }
        // if (scroll_vel_y > 0) {
        //     std.debug.print("Scroll y: {}\n", .{scroll_vel_y});
        //     scroll_vel_y *= 1 - scroll_friction;
        // }

        // if (scroll_vel_y < 0) {
        //     std.debug.print("Scroll y: {}\n", .{scroll_vel_y});
        //     scroll_vel_y *= 1 - scroll_friction;
        // }
        // if (@abs(scroll_vel_x) < 0.0005) scroll_vel_x = 0;
        // if (@abs(scroll_vel_y) < 0.0005) scroll_vel_y = 0;
        // state.x += @intFromFloat(scroll_sensitivity * scroll_vel_x);
        // state.y += @intFromFloat(scroll_sensitivity * scroll_vel_y);

        // const before_background = std.time.milliTimestamp();
        try display.draw_background();
        // const before_refresh = std.time.milliTimestamp();
        sheet.refresh_cell_values(&cells);
        // const before_render_cells = std.time.milliTimestamp();

        try sheet.render_cells(&state, &display, &cells, selected_cell, is_editing);
        // const before_render_selections = std.time.milliTimestamp();
        if (selected_area) |area| {
            try sheet.render_selections(&state, &display, area);
        }
        // const before_labels = std.time.milliTimestamp();

        try sheet.render_row_labels(&state, &display, selected_area, selected_cell);
        try sheet.render_column_labels(&state, &display, selected_area, selected_cell);

        try display.render_present();
        const finish = std.time.milliTimestamp();

        // std.debug.print("Read cells: {}\n", .{after_read_cells - before_read_cells});
        // std.debug.print("Render background: {}\n", .{before_refresh - before_background});
        // std.debug.print("Refresh cells: {}\n", .{before_render_cells - before_refresh});
        // std.debug.print("Render cells: {}\n", .{before_render_selections - before_render_cells});
        // std.debug.print("Render selections: {}\n", .{before_labels - before_render_selections});
        // std.debug.print("Render background: {}\n", .{before_present - before_labels});
        if (is_first_frame) {
            std.debug.print("\n\nFull startup took {}ms\n", .{finish - startup});
            is_first_frame = false;
        }
        // @panic("hej");
    }
}

fn get_cstr_len(c_str: [*]u8) usize {
    var found_null = false;
    var index: usize = 0;
    while (!found_null) : (index += 1) {
        found_null = c_str[index] == 0;
    }
    return index - 1;
}
