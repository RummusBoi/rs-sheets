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
const get_cstr_len = @import("helpers.zig").get_cstr_len;
pub const EventPoller = struct {
    poll_event_fn: *const fn (event_poller: *EventPoller, event: [*c]sheet_window.c.SDL_Event) c_int,

    pub fn poll_event(self: *EventPoller, event: [*c]sheet_window.c.SDL_Event) c_int {
        return self.poll_event_fn(self, event);
    }
};

pub const StandardEventPoller = struct {
    event_poller: EventPoller,
    pub fn init() StandardEventPoller {
        const event_poller = EventPoller{ .poll_event_fn = poll_event };
        return StandardEventPoller{ .event_poller = event_poller };
    }

    fn poll_event(_: *EventPoller, event: [*c]sheet_window.c.SDL_Event) c_int {
        // var self: *StandardEventPoller = @fieldParentPtr("event_poller", EventPoller);
        return sheet_window.c.SDL_PollEvent(event);
    }
};

const SelectionMode = union(enum) {
    Nothing: void,
    SingleCell: sheet.CellCoords,
    Area: sheet.Area,
};

pub const SpreadSheetApp = struct {
    cells: CellContainer,
    display: sheet_window.SheetWindow,
    state: WindowState,
    allocator: std.mem.Allocator,
    time_per_frame: i128,
    prev_frame: i128 = 0,
    next_frame: i128 = 0,
    prev_frame_wheel_x: f64 = 0,
    prev_frame_wheel_y: f64 = 0,
    selection_mode: SelectionMode,

    left_button_is_down: bool = false,
    is_holding_shift: bool = false,
    is_holding_cmd: bool = false,
    is_editing: bool = false,
    update_selected_area: bool = false,
    event_was_polled: bool = false,
    cell_was_updated: bool = false,

    frame: u64 = 0,

    filepath: []const u8,
    print_frametimes: bool,

    pub fn init(filepath: []const u8, print_frametimes: bool, target_framerate: i32) !SpreadSheetApp {
        const startup = std.time.milliTimestamp();

        std.debug.print("Found filepath: {s}\n", .{filepath});

        const allocator = std.heap.c_allocator;

        // const before_read_cells = std.time.milliTimestamp();
        var cells = try read_cells_from_csv_file(allocator, filepath);
        sheet.refresh_all_cell_values(&cells);
        // const after_read_cells = std.time.milliTimestamp();
        const default_width = 1000;
        const default_height = 1000;

        // 130ms
        // const before_sheet_window_init = std.time.milliTimestamp();
        const display = try sheet_window.SheetWindow.init(default_width, default_height, allocator);
        // const after_sheet_window_init = std.time.milliTimestamp();

        // std.debug.print("Initting sheet window: {}\n", .{after_sheet_window_init - before_sheet_window_init});
        const state: WindowState = .{ .x = -100, .y = -100, .zoomLevel = 1, .width = default_width, .height = default_height };
        // var scroll_vel_x: f64 = 0;
        // var scroll_vel_y: f64 = 0;
        // const scroll_friction: f64 = 0.1;
        // const scroll_sensitivity: f64 = 10;

        const time_per_frame: i128 = @intFromFloat(1.0 / @as(f32, @floatFromInt(target_framerate)) * @as(f32, 1000000000));

        // cells[0] = .{ .x = 0, .y = 0, .value = "hejsa" };
        // cells[1] = .{ .x = 10, .y = 0, .value = "hejsa v2" };
        // cells[2] = .{ .x = 5, .y = 5, .value = "hejsa v3" };
        const prev_frame = std.time.nanoTimestamp();
        const next_frame = prev_frame + time_per_frame;
        const finish = std.time.milliTimestamp();

        std.debug.print("\n\nFull startup took {}ms\n", .{finish - startup});

        return SpreadSheetApp{
            .cells = cells,
            .display = display,
            .state = state,
            .prev_frame = prev_frame,
            .next_frame = next_frame,
            .time_per_frame = time_per_frame,
            .allocator = std.heap.c_allocator,
            .filepath = filepath,
            .print_frametimes = print_frametimes,
            .selection_mode = SelectionMode.Nothing,
        };
    }
    pub fn sleep_until_next_frame(self: *SpreadSheetApp) void {
        const sleep_time = @max(self.next_frame - std.time.nanoTimestamp(), 0);
        std.time.sleep(@intCast(sleep_time));
        const nanos_elapsed = std.time.nanoTimestamp() - self.prev_frame;

        self.prev_frame = std.time.nanoTimestamp();
        self.next_frame = self.prev_frame + self.time_per_frame;

        const frametime: i32 = @intFromFloat(@as(f32, @floatFromInt(nanos_elapsed)) / @as(f32, @floatFromInt(1000000)));
        if (self.event_was_polled) {
            if (self.print_frametimes) {
                std.debug.print("[Frame {}]Frametime: {}ms\n\n", .{ self.frame, frametime });
            }
            self.frame += 1;
        }
    }
    pub fn render_and_present_next_frame(self: *SpreadSheetApp, force_render: bool) !void {
        if (!self.event_was_polled and !force_render) {
            self.prev_frame = std.time.nanoTimestamp();
            self.next_frame = self.prev_frame + self.time_per_frame;
            return;
        }

        try self.display.draw_background();
        if (self.cell_was_updated) {
            switch (self.selection_mode) {
                SelectionMode.SingleCell => |cell_coords| {
                    const start = std.time.microTimestamp();
                    var skip_cells = std.ArrayList(*Cell).init(self.allocator);
                    const count = sheet.refresh_cell_values_for_cell(&self.cells, cell_coords, &skip_cells, true);
                    const end = std.time.microTimestamp();
                    if (self.print_frametimes) {
                        std.debug.print("[Frame {}]Refreshing {} cells took {}us\n", .{ self.frame, count, end - start });
                    }
                },
                else => {},
            }
        }
        if (self.update_selected_area) {
            self.update_selected_area = false;
            const start = std.time.microTimestamp();

            switch (self.selection_mode) {
                SelectionMode.Area => |area| {
                    const min_x = if (area.w > 0) area.x else (area.x + area.w + 1);
                    const min_y = if (area.h > 0) area.y else (area.y + area.h + 1);
                    const max_x = if (area.w > 0) area.x + area.w else (area.x + 1);
                    const max_y = if (area.h > 0) area.y + area.h else (area.y + 1);

                    for (@intCast(min_x)..@intCast(max_x)) |x| {
                        for (@intCast(min_y)..@intCast(max_y)) |y| {
                            const cell = self.cells.find(@intCast(x), @intCast(y)) orelse continue;
                            try cell.refresh_value(&self.cells, true);
                            // sheet.refresh_cell_values_for_cell(&cells, .{ .x = @intCast(x), .y = @intCast(y) });
                        }
                    }
                },
                SelectionMode.SingleCell => |cell_coords| {
                    const cell = self.cells.ensure_cell(@intCast(cell_coords.x), @intCast(cell_coords.y)) catch |err| {
                        std.debug.print("Failed when ensuring cell.", .{});
                        return err;
                    };
                    try cell.refresh_value(&self.cells, true);
                },
                else => {},
            }

            const end = std.time.microTimestamp();

            if (self.print_frametimes) {
                std.debug.print("[Frame {}]Refreshing values took {}us", .{ self.frame, end - start });
            }
        }
        const start = std.time.microTimestamp();
        const selected_cell = if (self.selection_mode == SelectionMode.SingleCell) self.selection_mode.SingleCell else null;
        try sheet.render_cells(&self.state, &self.display, &self.cells, selected_cell, self.is_editing);
        const end = std.time.microTimestamp();
        if (self.print_frametimes) {
            std.debug.print("[Frame {}]Rendering cells took {}us\n", .{ self.frame, end - start });
        }

        const selected_area = if (self.selection_mode == SelectionMode.Area) self.selection_mode.Area else null;
        if (selected_area != null) {
            try sheet.render_selections(&self.state, &self.display, self.selection_mode.Area);
        }
        // const before_labels = std.time.microTimestamp();

        try sheet.render_row_labels(&self.state, &self.display, selected_area, selected_cell);
        try sheet.render_column_labels(&self.state, &self.display, selected_area, selected_cell);

        try self.display.render_present();
    }
    pub fn update(self: *SpreadSheetApp, event_poller: *EventPoller) !bool {
        var event: sheet_window.c.SDL_Event = undefined;
        self.event_was_polled = false;
        while (event_poller.poll_event(&event) != 0) {
            var get_mousewheel_event = false;
            self.event_was_polled = true;

            switch (event.type) {
                sheet_window.c.SDL_QUIT => {
                    sheet_window.c.SDL_Quit();
                    return true;
                },
                sheet_window.c.SDL_MOUSEWHEEL => blk: {
                    get_mousewheel_event = true;
                    // state.x += @divTrunc((prev_frame_wheel_x orelse 0) + (event.wheel.x + event.wheel.x * @as(i32, @intCast(@abs(event.wheel.x)))), 2);
                    // state.y -= @divTrunc((prev_frame_wheel_y orelse 0) + (event.wheel.y + event.wheel.y * @as(i32, @intCast(@abs(event.wheel.y)))), 2);
                    // const x_sign: f32 = if (event.wheel.x > 0) 1 else -1;
                    // const y_sign: f32 = if (event.wheel.y > 0) 1 else -1;
                    const preciseX = @as(f64, @floatCast(event.wheel.preciseX + self.prev_frame_wheel_x)) / 2;
                    const preciseY = @as(f64, @floatCast(event.wheel.preciseY + self.prev_frame_wheel_y)) / 2;
                    self.prev_frame_wheel_x = preciseX;
                    self.prev_frame_wheel_y = preciseY;
                    const total_vel = std.math.sqrt(preciseX * preciseX + preciseY * preciseY);
                    const scaled_vel = @abs(5 * total_vel + 2 * @abs(std.math.pow(f64, total_vel, 2)));
                    if (scaled_vel < 0.0001) {
                        break :blk;
                    }
                    // const angle = std.math.tan(preciseX / preciseY);
                    const scale_factor = @abs(scaled_vel / total_vel);

                    const x_vel: i32 = @intFromFloat(scale_factor * preciseX);
                    const y_vel: i32 = @intFromFloat(scale_factor * preciseY);
                    self.state.x += x_vel;
                    self.state.y -= y_vel;

                    // scroll_vel_x = @floatFromInt(-event.wheel.x);
                    // scroll_vel_y = @floatFromInt(event.wheel.y);
                },
                sheet_window.c.SDL_MOUSEBUTTONDOWN => {
                    if (event.button.button == sheet_window.c.SDL_BUTTON_LEFT) {
                        self.left_button_is_down = true;
                        self.is_editing = false;

                        const maybe_cell = sheet.pixel_to_cell(event.button.x, event.button.y, &self.state);

                        if (maybe_cell) |cell| {
                            if (self.is_holding_shift) {
                                const coords = switch (self.selection_mode) {
                                    .SingleCell => |cell_coords| .{ .x = cell_coords.x, .y = cell_coords.y },
                                    .Area => |area| .{ .x = area.x, .y = area.y },
                                    else => continue,
                                };
                                var w = cell.x - coords.x;
                                var h = cell.y - coords.y;
                                w += if (w > 0) 1 else -1;
                                h += if (h > 0) 1 else -1;
                                self.selection_mode = .{ .Area = .{ .x = coords.x, .y = coords.y, .w = w, .h = h } };
                            } else {
                                _ = self.cells.ensure_cell(cell.x, cell.y) catch {
                                    std.debug.print("Failed when ensuring cell", .{});
                                    continue;
                                };
                                self.selection_mode = .{ .SingleCell = .{ .x = cell.x, .y = cell.y } };
                            }
                            // self.selected_cell = .{ .x = cell.x, .y = cell.y };
                        }
                    }
                },
                sheet_window.c.SDL_MOUSEBUTTONUP => {
                    if (event.button.button == sheet_window.c.SDL_BUTTON_LEFT) {
                        self.left_button_is_down = false;
                        switch (self.selection_mode) {
                            SelectionMode.Area => |area| {
                                if (area.w == 1 and area.h == 1) {
                                    self.selection_mode = .{ .SingleCell = .{
                                        .x = area.x,
                                        .y = area.y,
                                    } };
                                    _ = try self.cells.ensure_cell(area.x, area.y);
                                }
                            },
                            else => {},
                        }
                    }
                },
                sheet_window.c.SDL_MOUSEMOTION => {
                    if (self.left_button_is_down) {
                        const maybe_cell = sheet.pixel_to_cell(event.button.x, event.button.y, &self.state);
                        if (maybe_cell) |mouse_cell| {
                            switch (self.selection_mode) {
                                SelectionMode.SingleCell => |cell| {
                                    var w = mouse_cell.x - cell.x;
                                    var h = mouse_cell.y - cell.y;

                                    if (w == 0 and h == 0) continue;
                                    w += if (w > 0) 1 else -1;
                                    h += if (h > 0) 1 else -1;
                                    self.selection_mode = .{ .Area = .{ .x = cell.x, .y = cell.y, .w = w, .h = h } };
                                },
                                SelectionMode.Area => |*area| {
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
                                        self.selection_mode = .{ .SingleCell = .{ .x = area.x, .y = area.y } };
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                },
                sheet_window.c.SDL_TEXTINPUT => {
                    self.cell_was_updated = true; // we flip the bool here to ensure that we always update the cell when we get text input.
                    const selected_cell_coords: sheet.CellCoords = switch (self.selection_mode) {
                        SelectionMode.SingleCell => |cell_coords| blk: {
                            if (!self.is_editing) {
                                self.is_editing = true;
                                if (self.cells.find(cell_coords.x, cell_coords.y)) |cell| {
                                    cell.raw_value.items.len = 0;
                                }
                            }
                            break :blk cell_coords;
                        },
                        SelectionMode.Area => |area| blk: {
                            self.is_editing = true;
                            self.selection_mode = .{ .SingleCell = .{ .x = area.x, .y = area.y } };
                            break :blk .{ .x = area.x, .y = area.y };
                        },
                        else => continue,
                    };
                    const selected_cell = self.cells.ensure_cell(selected_cell_coords.x, selected_cell_coords.y) catch {
                        std.debug.print("Failed when ensuring cell exists", .{});
                        continue;
                    };
                    const text_len = get_cstr_len(&event.text.text);
                    var text: []u8 = undefined;
                    text.ptr = &event.text.text;
                    text.len = text_len;

                    for (text) |char| {
                        selected_cell.value_append(char) catch {
                            std.debug.print("Could not append char '{}'", .{char});
                        };
                    }
                },
                sheet_window.c.SDL_KEYDOWN => {
                    const keycode = event.key.keysym.sym;

                    if (keycode == sheet_window.c.SDLK_ESCAPE) {
                        switch (self.selection_mode) {
                            SelectionMode.SingleCell => {
                                if (!self.is_editing) {
                                    self.selection_mode = .Nothing;
                                } else if (self.is_editing) {
                                    self.is_editing = false;
                                }
                            },
                            SelectionMode.Area => |area| {
                                self.selection_mode = .{ .SingleCell = .{ .x = area.x, .y = area.y } };

                                self.is_editing = false;
                            },
                            else => continue,
                        }
                    } else if (keycode == sheet_window.c.SDLK_RETURN) {
                        switch (self.selection_mode) {
                            .SingleCell => |*cell_coords| {
                                if (!self.is_editing) {
                                    self.is_editing = true;
                                } else {
                                    cell_coords.y += 1;
                                    _ = self.cells.ensure_cell(cell_coords.x, cell_coords.y) catch {
                                        std.debug.print("Failed when ensuring cell exists", .{});
                                        cell_coords.y -= 1; // undo the change
                                        continue;
                                    };
                                }
                            },
                            .Area => |area| {
                                self.selection_mode = .{ .SingleCell = .{ .x = area.x + (if (area.w > 0) area.w - 1 else area.w + 1), .y = area.y + if (area.h > 0) area.h - 1 else area.h + 1 } };
                                self.is_editing = true;
                            },
                            else => continue,
                        }
                    } else if (keycode == sheet_window.c.SDLK_LSHIFT) {
                        self.is_holding_shift = true;
                    } else if (keycode == sheet_window.c.SDLK_BACKSPACE) {
                        self.cell_was_updated = true;
                        switch (self.selection_mode) {
                            .SingleCell => |cell_coords| {
                                if (self.cells.find(cell_coords.x, cell_coords.y)) |cell| {
                                    if (self.is_editing) cell.value_delete() else cell.raw_value.items.len = 0;
                                }
                            },
                            .Area => |area| {
                                self.update_selected_area = true;
                                const min_x = if (area.w > 0) area.x else (area.x + area.w + 1);
                                const min_y = if (area.h > 0) area.y else (area.y + area.h + 1);
                                const max_x = if (area.w > 0) area.x + area.w else (area.x + 1);
                                const max_y = if (area.h > 0) area.y + area.h else (area.y + 1);
                                for (@intCast(min_y)..@intCast(max_y)) |y| {
                                    for (@intCast(min_x)..@intCast(max_x)) |x| {
                                        if (self.cells.find(@intCast(x), @intCast(y))) |cell| {
                                            cell.raw_value.items.len = 0;
                                        }
                                    }
                                }
                            },
                            else => continue,
                        }
                    } else if (keycode == sheet_window.c.SDLK_TAB) {
                        switch (self.selection_mode) {
                            .SingleCell => |*cell_coords| {
                                cell_coords.x += 1;
                                _ = self.cells.ensure_cell(cell_coords.x, cell_coords.y) catch {
                                    std.debug.print("Failed when ensuring cell exists. ", .{});
                                };
                            },
                            .Area => |area| {
                                self.selection_mode = .{ .SingleCell = .{ .x = area.x + 1, .y = area.y } };
                                _ = self.cells.ensure_cell(self.selection_mode.SingleCell.x, self.selection_mode.SingleCell.y) catch {
                                    std.debug.print("Failed when ensuring cell exists. ", .{});
                                };
                            },
                            else => continue,
                        }
                    }
                    const scancode = event.key.keysym.scancode;
                    if (scancode == sheet_window.c.SDL_SCANCODE_LEFT or
                        scancode == sheet_window.c.SDL_SCANCODE_RIGHT or
                        scancode == sheet_window.c.SDL_SCANCODE_UP or
                        scancode == sheet_window.c.SDL_SCANCODE_DOWN)
                    {
                        self.handle_arrow_press(scancode);
                    } else if (scancode == sheet_window.c.SDL_SCANCODE_S) {
                        if (self.is_holding_cmd) {
                            const start_save = std.time.microTimestamp();
                            write_cells_to_csv_file(&self.allocator, self.cells) catch {
                                std.debug.print("Failed to save changes..\n", .{});
                                continue;
                            };
                            const end_save = std.time.microTimestamp();

                            const in_milliseconds = @as(f32, @floatFromInt(end_save - start_save)) / @as(f32, 1000);
                            std.debug.print("Succesfully saved to file {s} in {d:.2}ms\n", .{ self.filepath, in_milliseconds });
                        }
                    } else if (scancode == sheet_window.c.SDL_SCANCODE_C) {
                        if (self.is_holding_cmd) self.handle_copy();
                    } else if (scancode == sheet_window.c.SDL_SCANCODE_V) {
                        if (self.is_holding_cmd) self.handle_paste();
                    } else if (scancode == sheet_window.c.SDL_SCANCODE_LGUI) {
                        self.is_holding_cmd = true;
                    }
                },
                sheet_window.c.SDL_KEYUP => {
                    const scancode = event.key.keysym.scancode;
                    const keycode = event.key.keysym.sym;
                    if (keycode == sheet_window.c.SDLK_LSHIFT) {
                        self.is_holding_shift = false;
                    }
                    if (scancode == sheet_window.c.SDL_SCANCODE_LGUI) {
                        self.is_holding_cmd = false;
                    }
                },
                sheet_window.c.SDL_WINDOWEVENT => {
                    if (event.window.event == sheet_window.c.SDL_WINDOWEVENT_RESIZED) {
                        if (sheet_window.c.SDL_RenderSetViewport(self.display.renderer, &.{ .x = 0, .y = 0, .w = event.window.data1, .h = event.window.data2 }) != 0) {
                            @panic("Couldnt resize window");
                        }
                        self.state.width = event.window.data1;
                        self.state.height = event.window.data2;
                    }
                },
                else => {},
            }
            if (!get_mousewheel_event) {
                self.prev_frame_wheel_x = 0;
                self.prev_frame_wheel_y = 0;
            }
        }
        return false;
    }

    fn handle_arrow_press(self: *SpreadSheetApp, scancode: c_uint) void {
        var move_x: i32 = 0;
        var move_y: i32 = 0;

        switch (scancode) {
            sheet_window.c.SDL_SCANCODE_LEFT => {
                move_x = -1;
                move_y = 0;
            },
            sheet_window.c.SDL_SCANCODE_RIGHT => {
                move_x = 1;
                move_y = 0;
            },
            sheet_window.c.SDL_SCANCODE_DOWN => {
                move_x = 0;
                move_y = 1;
            },
            sheet_window.c.SDL_SCANCODE_UP => {
                move_x = 0;
                move_y = -1;
            },
            else => return,
        }

        switch (self.selection_mode) {
            SelectionMode.Nothing => return,
            SelectionMode.SingleCell => |*cell_coords| {
                self.is_editing = false;
                if (self.is_holding_shift) {
                    self.selection_mode = .{ .Area = .{ .x = cell_coords.x, .y = cell_coords.y, .w = if (move_x == 0) 1 else 2 * move_x, .h = if (move_y == 0) 1 else 2 * move_y } };
                } else {
                    cell_coords.x = @max(0, cell_coords.x + move_x);
                    cell_coords.y = @max(0, cell_coords.y + move_y);
                    _ = self.cells.ensure_cell(cell_coords.x, cell_coords.y) catch {
                        std.debug.print("Failed when ensuring cell.", .{});
                        return;
                    };
                }
            },
            SelectionMode.Area => |*area| {
                if (self.is_holding_shift) {
                    area.w += move_x;
                    area.h += move_y;
                    if (area.x + area.w < -1) {
                        area.w = -area.x - 1;
                    }

                    if (area.w == 0) {
                        area.w += 2 * move_x;
                    }
                    if (area.h == 0) {
                        area.h += 2 * move_y;
                    }
                    if (area.y + area.h < -1) {
                        area.h = -area.y - 1;
                    }
                } else {
                    self.selection_mode = .{ .SingleCell = .{ .x = move_x + area.x + (if (area.w > 0) area.w - 1 else area.w + 1), .y = move_y + area.y + if (area.h > 0) area.h - 1 else area.h + 1 } };
                    _ = self.cells.ensure_cell(self.selection_mode.SingleCell.x, self.selection_mode.SingleCell.y) catch {
                        std.debug.print("Failed when ensuring cell.", .{});
                        return;
                    };
                }
            },
        }
    }

    fn handle_copy(self: *SpreadSheetApp) void {
        switch (self.selection_mode) {
            .SingleCell => |cell_coords| {
                if (self.cells.find(cell_coords.x, cell_coords.y)) |cell| {
                    const cell_value = cell.raw_value.items;
                    const c_str = self.allocator.dupeZ(u8, cell_value) catch {
                        std.debug.print("Could not allocate for clipboard buffer.", .{});
                        return;
                    };
                    defer self.allocator.free(c_str);
                    if (sheet_window.c.SDL_SetClipboardText(c_str) != 0) {
                        std.debug.print("Could not paste text to clipboard.", .{});
                    }
                }
            },
            .Area => |area| {
                var clipboard_buffer = std.ArrayList(u8).init(self.allocator);
                defer clipboard_buffer.deinit();

                const min_x = if (area.w > 0) area.x else (area.x + area.w + 1);
                const min_y = if (area.h > 0) area.y else (area.y + area.h + 1);
                const max_x = if (area.w > 0) area.x + area.w else (area.x + 1);
                const max_y = if (area.h > 0) area.y + area.h else (area.y + 1);
                for (@intCast(min_y)..@intCast(max_y)) |y| {
                    for (@intCast(min_x)..@intCast(max_x)) |x| {
                        if (self.cells.find(@intCast(x), @intCast(y))) |cell| {
                            clipboard_buffer.appendSlice(cell.raw_value.items) catch {
                                std.debug.print("Could not allocate for clipboard buffer.", .{});
                                return;
                            };
                        }
                        // this skips the last item in a row, so that we avoid have \t\n at the end.
                        if (x < max_x - 1) {
                            clipboard_buffer.append('\t') catch {
                                std.debug.print("Could not allocate for clipboard buffer.", .{});
                                return;
                            };
                        }
                    }
                    if (y < max_y - 1) {
                        clipboard_buffer.append('\n') catch {
                            std.debug.print("Could not allocate for clipboard buffer.", .{});
                            return;
                        };
                    }
                }
                clipboard_buffer.append(0) catch {
                    std.debug.print("Could not allocate for clipboard buffer.", .{});
                    return;
                };
                if (sheet_window.c.SDL_SetClipboardText(clipboard_buffer.items.ptr) != 0) {
                    std.debug.print("Could not set the clipboard to value '{any}", .{clipboard_buffer.items});
                    return;
                }
            },
            else => return,
        }
    }

    fn handle_paste(self: *SpreadSheetApp) void {
        self.update_selected_area = true;
        const cell_coords: sheet.CellCoords = switch (self.selection_mode) {
            .SingleCell => |cell_coords| cell_coords,
            .Area => |area| .{ .x = area.x, .y = area.y },
            else => return,
        };

        const clipboard = sheet_window.c.SDL_GetClipboardText();
        defer sheet_window.c.SDL_free(clipboard);

        var c_str_slice: []u8 = undefined;
        c_str_slice.ptr = clipboard;
        c_str_slice.len = get_cstr_len(clipboard);
        var curr_cell_coords: sheet.CellCoords = .{ .x = cell_coords.x, .y = cell_coords.y };
        var curr_cell: *Cell = self.cells.ensure_cell(curr_cell_coords.x, curr_cell_coords.y) catch {
            std.debug.print("Failed when ensure that cell existed.", .{});
            return;
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
                curr_cell = self.cells.ensure_cell(curr_cell_coords.x, curr_cell_coords.y) catch {
                    std.debug.print("Failed when ensure that cell existed.", .{});
                    return;
                };
                curr_cell.raw_value.items.len = 0;
            } else if (char == '\n' or char == 0) {
                curr_width += 1;
                max_width = @max(max_width, curr_width);
                curr_width = 0;
                height += 1;
                curr_cell_coords.y += 1;
                curr_cell_coords.x = cell_coords.x;
                curr_cell = self.cells.ensure_cell(curr_cell_coords.x, curr_cell_coords.y) catch {
                    std.debug.print("Failed when ensure that cell existed.", .{});
                    return;
                };
                if (char != 0) {
                    curr_cell.raw_value.items.len = 0;
                }
            } else {
                curr_cell.raw_value.append(char) catch {
                    std.debug.print("Failed when appending cell value.", .{});
                    return;
                };
            }
        }

        // the pasted value might not end with a newline:
        max_width = @max(curr_width, max_width);
        if (max_width == 1 and height == 1) {
            self.selection_mode = .{ .SingleCell = .{ .x = cell_coords.x, .y = cell_coords.y } };
        } else {
            self.selection_mode = .{ .Area = .{ .x = cell_coords.x, .y = cell_coords.y, .w = max_width, .h = height } };
        }
    }
};
