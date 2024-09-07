const std = @import("std");

const sheet_window = @import("sheet_window.zig");

const window_title = "zig-gamedev: minimal zgpu zgui";
const sheet = @import("sheet.zig");
const Cell = @import("cell.zig").Cell;
const CellContainer = @import("cell.zig").CellContainer;
const get_cell_pos = @import("cell.zig").get_cell_pos;
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

    std.debug.print("Found filepath: {s}\n", .{filepath});

    var allocator = std.heap.c_allocator;

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
    var prev_frame_wheel_x: f64 = 0;
    var prev_frame_wheel_y: f64 = 0;

    var selected_cell: ?sheet.CellCoords = null;
    var selected_area: ?sheet.Area = null;
    // var selected_area: ?{

    var left_button_is_down = false;
    var is_holding_shift: bool = false;
    var is_holding_cmd: bool = false;
    var is_editing: bool = false;
    var did_just_paste: bool = false;

    var is_first_frame = true;
    var frame: u64 = 0;
    while (true) {
        var event_was_polled = false;
        var cell_was_updated = false;
        var frametime: i32 = 0;
        if (!is_first_frame) {
            // std.debug.print("Cells: {}\n", .{cells._cells.items.len});

            var event: sheet_window.c.SDL_Event = undefined;

            while (sheet_window.c.SDL_PollEvent(&event) != 0) {
                var get_mousewheel_event = false;
                event_was_polled = true;

                switch (event.type) {
                    sheet_window.c.SDL_QUIT => {
                        sheet_window.c.SDL_Quit();
                        return;
                    },
                    sheet_window.c.SDL_MOUSEWHEEL => blk: {
                        get_mousewheel_event = true;
                        // state.x += @divTrunc((prev_frame_wheel_x orelse 0) + (event.wheel.x + event.wheel.x * @as(i32, @intCast(@abs(event.wheel.x)))), 2);
                        // state.y -= @divTrunc((prev_frame_wheel_y orelse 0) + (event.wheel.y + event.wheel.y * @as(i32, @intCast(@abs(event.wheel.y)))), 2);
                        // const x_sign: f32 = if (event.wheel.x > 0) 1 else -1;
                        // const y_sign: f32 = if (event.wheel.y > 0) 1 else -1;
                        const preciseX = @as(f64, @floatCast(event.wheel.preciseX + prev_frame_wheel_x)) / 2;
                        const preciseY = @as(f64, @floatCast(event.wheel.preciseY + prev_frame_wheel_y)) / 2;
                        prev_frame_wheel_x = preciseX;
                        prev_frame_wheel_y = preciseY;
                        const total_vel = std.math.sqrt(preciseX * preciseX + preciseY * preciseY);
                        const scaled_vel = @abs(5 * total_vel + 2 * @abs(std.math.pow(f64, total_vel, 2)));
                        std.debug.print("Total vel: {}\n", .{total_vel});
                        std.debug.print("Scaled vel: {}\n", .{scaled_vel});
                        if (scaled_vel < 0.0001) {
                            break :blk;
                        }
                        // const angle = std.math.tan(preciseX / preciseY);
                        const scale_factor = @abs(scaled_vel / total_vel);

                        const x_vel: i32 = @intFromFloat(scale_factor * preciseX);
                        const y_vel: i32 = @intFromFloat(scale_factor * preciseY);
                        state.x += x_vel;
                        state.y -= y_vel;

                        // scroll_vel_x = @floatFromInt(-event.wheel.x);
                        // scroll_vel_y = @floatFromInt(event.wheel.y);
                    },
                    sheet_window.c.SDL_MOUSEBUTTONDOWN => {
                        if (event.button.button == sheet_window.c.SDL_BUTTON_LEFT) {
                            left_button_is_down = true;
                            const maybe_cell = sheet.pixel_to_cell(event.button.x, event.button.y, &state);

                            if (maybe_cell) |cell| {
                                if (is_holding_shift) {
                                    const coords = if (selected_cell) |cell_coords| .{ .x = cell_coords.x, .y = cell_coords.y } else if (selected_area) |area| .{ .x = area.x, .y = area.y } else continue;
                                    var w = cell.x - coords.x;
                                    var h = cell.y - coords.y;
                                    w += if (w > 0) 1 else -1;
                                    h += if (h > 0) 1 else -1;
                                    selected_area = .{ .x = coords.x, .y = coords.y, .w = w, .h = h };
                                    selected_cell = null;
                                } else {
                                    _ = cells.ensure_cell(cell.x, cell.y) catch {
                                        std.debug.print("Failed when ensuring cell", .{});
                                        continue;
                                    };
                                    selected_cell = .{ .x = cell.x, .y = cell.y };
                                    selected_area = null;
                                }
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
                                    if (area.w == 1 and area.h == 1) {
                                        selected_cell = .{ .x = area.x, .y = area.y };
                                        selected_area = null;
                                    }
                                } else if (selected_cell) |cell| {
                                    var w = mouse_cell.x - cell.x;
                                    var h = mouse_cell.y - cell.y;

                                    if (w == 0 and h == 0) continue;
                                    w += if (w > 0) 1 else -1;
                                    h += if (h > 0) 1 else -1;
                                    selected_area = .{ .x = cell.x, .y = cell.y, .w = w, .h = h };
                                    selected_cell = null;
                                }
                            }
                        }
                    },
                    sheet_window.c.SDL_TEXTINPUT => {
                        cell_was_updated = true; // we flip the bool here to ensure that we always update
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
                            cell_was_updated = true;
                            if (selected_cell) |cell_coords| {
                                if (cells.find(cell_coords.x, cell_coords.y)) |cell| {
                                    if (is_editing) cell.value_delete() else cell.raw_value.items.len = 0;
                                }
                            } else if (selected_area) |area| {
                                did_just_paste = true;
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
                                const start_save = std.time.microTimestamp();
                                write_cells_to_csv_file(&allocator, cells) catch {
                                    std.debug.print("Failed to save changes..\n", .{});
                                    continue;
                                };
                                const end_save = std.time.microTimestamp();

                                const in_milliseconds = @as(f32, @floatFromInt(end_save - start_save)) / @as(f32, 1000);
                                std.debug.print("Succesfully saved to file {s} in {d:.2}ms\n", .{ filepath, in_milliseconds });
                            }
                        } else if (scancode == sheet_window.c.SDL_SCANCODE_C) {
                            if (!is_holding_cmd) continue;
                            std.debug.print("Copying", .{});
                            if (selected_cell) |cell_coords| {
                                if (cells.find(cell_coords.x, cell_coords.y)) |cell| {
                                    const cell_value = cell.raw_value.items;
                                    const c_str = try allocator.dupeZ(u8, cell_value);
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
                                did_just_paste = true;

                                const maybe_cell_coords = block: {
                                    if (selected_cell) |cell| break :block cell;
                                    if (selected_area) |area| {
                                        break :block sheet.CellCoords{ .x = area.x, .y = area.y };
                                    }
                                    break :block null;
                                };
                                if (maybe_cell_coords) |cell_coords| {
                                    const clipboard = sheet_window.c.SDL_GetClipboardText();
                                    std.debug.print("Pasting value '{s}'", .{clipboard});
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
                                    var max_width: i32 = 1;
                                    var height: i32 = 0;
                                    if (c_str_slice[c_str_slice.len - 1] == '\n') c_str_slice.len -= 1;
                                    for (0..c_str_slice.len + 1) |ind| {
                                        const char = if (ind < c_str_slice.len) c_str_slice[ind] else 0;
                                        if (char == '\t') {
                                            curr_width += 1;
                                            curr_cell_coords.x += 1;
                                            curr_cell = cells.ensure_cell(curr_cell_coords.x, curr_cell_coords.y) catch {
                                                std.debug.print("Failed when ensure that cell existed.", .{});
                                                break :blk;
                                            };
                                            curr_cell.raw_value.items.len = 0;
                                        } else if (char == '\n' or char == 0) {
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
                                    if (max_width == 1 and height == 1) {
                                        selected_cell = .{ .x = cell_coords.x, .y = cell_coords.y };
                                    } else {
                                        selected_area = .{ .x = cell_coords.x, .y = cell_coords.y, .w = max_width, .h = height };
                                    }
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

        // const before_refresh = std.time.milliTimestamp();

        // const before_render_cells = std.time.milliTimestamp();

        // _ = millis_elapsed;

        if (event_was_polled or is_first_frame) {
            try display.draw_background();
            std.debug.print("\n", .{});
            if (cell_was_updated) {
                if (selected_cell) |cell| {
                    const start = std.time.milliTimestamp();
                    const count = sheet.refresh_cell_values_for_cell(&cells, cell, true);
                    const end = std.time.milliTimestamp();
                    std.debug.print("[Frame {}]Refreshing {} cells took {}ms\n", .{ frame, count, end - start });
                }
                // sheet.refresh_all_cell_values(&cells);
            }
            if (did_just_paste) {
                const start = std.time.milliTimestamp();
                if (selected_area) |area| {
                    for (@intCast(area.x)..@intCast(area.x + area.w)) |x| {
                        for (@intCast(area.y)..@intCast(area.y + area.h)) |y| {
                            const cell = cells.find(@intCast(x), @intCast(y)) orelse continue;
                            try cell.refresh_value(&cells, true);
                            // sheet.refresh_cell_values_for_cell(&cells, .{ .x = @intCast(x), .y = @intCast(y) });
                        }
                    }
                }
                if (selected_cell) |cell_coords| {
                    const cell = cells.find(@intCast(cell_coords.x), @intCast(cell_coords.y)) orelse continue;
                    try cell.refresh_value(&cells, true);
                }
                did_just_paste = false;
                const end = std.time.milliTimestamp();

                std.debug.print("[Frame {}]Refreshing values took {}ms", .{ frame, end - start });
            }
            if (is_first_frame) {
                sheet.refresh_all_cell_values(&cells);
            }
            // var iter = cells.dependencies.keyIterator();

            // while (iter.next()) |dependency| {
            //     const entry = cells.dependencies.get(dependency.*).?;
            //     for (entry.items) |item| {
            //         std.debug.print("Dependency. From ({}, {}) to ({}, {})\n", .{ get_cell_pos(dependency.*).x, get_cell_pos(dependency.*).y, get_cell_pos(item).x, get_cell_pos(item).y });
            //     }
            // }

            // std.debug.print("\n\n", .{});
            // var rev_iter = cells.reverse_dependencies.keyIterator();

            // while (rev_iter.next()) |dependency| {
            //     // const cell = cells.find(get_cell_pos(dependency.*).x, get_cell_pos(dependency.*).y) orelse continue;
            //     const entry = cells.reverse_dependencies.get(dependency.*).?;
            //     for (entry.items) |item| {
            //         std.debug.print("Reverse Dependency. From ({}, {}) to ({}, {})\n", .{ get_cell_pos(dependency.*).x, get_cell_pos(dependency.*).y, get_cell_pos(item).x, get_cell_pos(item).y });
            //     }
            // }

            const start = std.time.milliTimestamp();
            try sheet.render_cells(&state, &display, &cells, selected_cell, is_editing);
            const end = std.time.milliTimestamp();
            std.debug.print("[Frame {}]Rendering cells took {}ms\n", .{ frame, end - start });
            std.debug.print("[Frame {}]Drew all cells\n", .{frame});
            if (selected_area) |area| {
                try sheet.render_selections(&state, &display, area);
            }
            // const before_labels = std.time.milliTimestamp();

            try sheet.render_row_labels(&state, &display, selected_area, selected_cell);
            try sheet.render_column_labels(&state, &display, selected_area, selected_cell);

            try display.render_present();

            const sleep_time = @max(next_frame - std.time.nanoTimestamp(), 0);
            if (!is_first_frame) std.time.sleep(@intCast(sleep_time));

            const nanos_elapsed = std.time.nanoTimestamp() - prev_frame;
            frametime = @intFromFloat(@as(f32, @floatFromInt(nanos_elapsed)) / @as(f32, @floatFromInt(1000000)));
            std.debug.print("[Frame {}]Frametime: {}ms\n", .{ frame, frametime });
            frame += 1;
        } else {
            std.time.sleep(time_per_frame);
        } //else if (is_editing) {
        //     std.debug.print("in here", .{});
        //     if (selected_cell) |cell_coords| {
        //         std.debug.print("in here2", .{});
        //         if (cells.find(cell_coords.x, cell_coords.y)) |cell| {
        //             std.debug.print("in here3", .{});
        //             const pixel_coords = sheet.cell_to_pixel(cell.x, cell.y, &state);
        //             try display.draw_cell(pixel_coords.x, pixel_coords.y, cell.raw_value.items, true, true, true);
        //             try display.render_present();
        //         }
        //     }
        // }
        // const before_render_selections = std.time.milliTimestamp();

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
        prev_frame = std.time.nanoTimestamp();
        next_frame = prev_frame + time_per_frame;
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
