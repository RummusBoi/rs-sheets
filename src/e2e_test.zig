const std = @import("std");
const SpreadSheetApp = @import("main_loop.zig").SpreadSheetApp;
const EventPoller = @import("main_loop.zig").EventPoller;
const StandardEventPoller = @import("main_loop.zig").StandardEventPoller;
const sheet_window = @import("sheet_window.zig");
const WindowState = @import("window_state.zig").WindowState;
const sheet = @import("sheet.zig");
const get_cstr_len = @import("helpers.zig").get_cstr_len;
pub const TestStep = struct {
    events: []const sheet_window.c.SDL_Event,
    verifier: *const fn (test_step: *const TestStep, app: *SpreadSheetApp) anyerror!void,
    // pub fn init(events: []sheet_window.c.SDL_Event, verifier:)
};

pub const TestEventPoller = struct {
    event_poller: EventPoller,
    test_steps: []const *const TestStep,
    test_step_index: usize = 0,
    test_step_event_index: usize = 0,
    app: *SpreadSheetApp,
    did_just_poll: bool = false,

    pub fn init(test_steps: []const *const TestStep, app: *SpreadSheetApp) TestEventPoller {
        return TestEventPoller{
            .event_poller = EventPoller{
                .poll_event_fn = poll_event,
            },
            .test_steps = test_steps,
            .app = app,
        };
    }

    fn poll_event(event_poller: *EventPoller, event: [*c]sheet_window.c.SDL_Event) c_int {

        // here we poll all events from sdl. This is required for the gui to function
        var dummy_event: sheet_window.c.SDL_Event = undefined;
        _ = sheet_window.c.SDL_PollEvent(&dummy_event);
        if (dummy_event.type == sheet_window.c.SDL_QUIT) {
            std.debug.print("I want to quit", .{});
            const e = sheet_window.c.SDL_Event{ .type = sheet_window.c.SDL_QUIT };
            event.* = e;
            return 1;
        }
        const self: *TestEventPoller = @fieldParentPtr("event_poller", event_poller);
        if (self.did_just_poll) {
            self.did_just_poll = false;
            return 0;
        }
        std.debug.print("On step {}, event {}\n", .{ self.test_step_index, self.test_step_event_index });
        if (self.test_step_index == self.test_steps.len) {
            event.* = sheet_window.c.SDL_Event{ .type = sheet_window.c.SDL_QUIT };
            std.debug.print("Quitting due to end of test.\n", .{});
            return 1;
        }
        if (self.test_step_event_index == self.test_steps[self.test_step_index].events.len) {
            std.debug.print("Running verifier...\n", .{});
            self.test_steps[self.test_step_index].verifier(self.test_steps[self.test_step_index], self.app) catch |err| {
                std.debug.print("Error: {any}", .{err});
            };
            self.test_step_event_index = 0;
            self.test_step_index += 1;
            return 0;
        }

        const curr_step = self.test_steps[self.test_step_index];
        const e = curr_step.events[self.test_step_event_index];
        event.* = e;
        self.did_just_poll = true;

        self.test_step_event_index += 1;
        return 1;
        // return sheet_window.c.SDL_PollEvent(event);
    }
};

fn enter_text(text: []const u8) [1]sheet_window.c.SDL_Event {
    return .{sheet_window.c.SDL_Event{
        .text = .{
            .type = sheet_window.c.SDL_TEXTINPUT,
            .text = blk: {
                // const s = "hej";
                var arr: [32]u8 = .{0} ** 32;
                std.mem.copyForwards(u8, &arr, text);
                std.debug.print("Inserting '{s}'\n", .{arr});
                break :blk arr;
            },
        },
    }};
}

fn click_cell(state: *WindowState, x: i32, y: i32) [2]sheet_window.c.SDL_Event {
    const pixel_coords = sheet.cell_to_pixel(x, y, state);
    return .{
        sheet_window.c.SDL_Event{ .button = .{
            .type = sheet_window.c.SDL_MOUSEBUTTONDOWN,
            .button = sheet_window.c.SDL_BUTTON_LEFT,
            .x = pixel_coords.x,
            .y = pixel_coords.y,
        } },
        sheet_window.c.SDL_Event{ .button = .{
            .type = sheet_window.c.SDL_MOUSEBUTTONUP,
            .button = sheet_window.c.SDL_BUTTON_LEFT,
            .x = pixel_coords.x,
            .y = pixel_coords.y,
        } },
    };
}

fn select_area(state: *WindowState, from_x: i32, from_y: i32, to_x: i32, to_y: i32) [3]sheet_window.c.SDL_Event {
    const from_pixel_coords = sheet.cell_to_pixel(from_x, from_y, state);
    const to_pixel_coords = sheet.cell_to_pixel(to_x, to_y, state);
    return .{
        sheet_window.c.SDL_Event{ .button = .{
            .type = sheet_window.c.SDL_MOUSEBUTTONDOWN,
            .button = sheet_window.c.SDL_BUTTON_LEFT,
            .x = from_pixel_coords.x,
            .y = from_pixel_coords.y,
        } },
        sheet_window.c.SDL_Event{ .button = .{
            .type = sheet_window.c.SDL_MOUSEMOTION,
            .button = sheet_window.c.SDL_BUTTON_LEFT,
            .x = to_pixel_coords.x,
            .y = to_pixel_coords.y,
        } },
        sheet_window.c.SDL_Event{ .button = .{
            .type = sheet_window.c.SDL_MOUSEBUTTONUP,
            .button = sheet_window.c.SDL_BUTTON_LEFT,
            .x = to_pixel_coords.x,
            .y = to_pixel_coords.y,
        } },
    };
}

fn click_key(key: c_int) [2]sheet_window.c.SDL_Event {
    return .{
        sheet_window.c.SDL_Event{ .key = .{
            .type = sheet_window.c.SDL_KEYDOWN,
            .keysym = .{ .sym = key },
        } },
        sheet_window.c.SDL_Event{ .key = .{
            .type = sheet_window.c.SDL_KEYUP,
            .keysym = .{ .sym = key },
        } },
    };
}

fn click_copy() [4]sheet_window.c.SDL_Event {
    return .{
        sheet_window.c.SDL_Event{ .key = .{
            .type = sheet_window.c.SDL_KEYDOWN,
            .keysym = .{ .scancode = sheet_window.c.SDL_SCANCODE_LGUI },
        } },
        sheet_window.c.SDL_Event{ .key = .{
            .type = sheet_window.c.SDL_KEYDOWN,
            .keysym = .{ .scancode = sheet_window.c.SDL_SCANCODE_C },
        } },
        sheet_window.c.SDL_Event{ .key = .{
            .type = sheet_window.c.SDL_KEYUP,
            .keysym = .{ .scancode = sheet_window.c.SDL_SCANCODE_C },
        } },
        sheet_window.c.SDL_Event{ .key = .{
            .type = sheet_window.c.SDL_KEYUP,
            .keysym = .{ .scancode = sheet_window.c.SDL_SCANCODE_LGUI },
        } },
    };
}

fn click_paste() [4]sheet_window.c.SDL_Event {
    return .{
        sheet_window.c.SDL_Event{ .key = .{
            .type = sheet_window.c.SDL_KEYDOWN,
            .keysym = .{ .scancode = sheet_window.c.SDL_SCANCODE_LGUI },
        } },
        sheet_window.c.SDL_Event{ .key = .{
            .type = sheet_window.c.SDL_KEYDOWN,
            .keysym = .{ .scancode = sheet_window.c.SDL_SCANCODE_V },
        } },
        sheet_window.c.SDL_Event{ .key = .{
            .type = sheet_window.c.SDL_KEYUP,
            .keysym = .{ .scancode = sheet_window.c.SDL_SCANCODE_V },
        } },
        sheet_window.c.SDL_Event{ .key = .{
            .type = sheet_window.c.SDL_KEYUP,
            .keysym = .{ .scancode = sheet_window.c.SDL_SCANCODE_LGUI },
        } },
    };
}

fn click_down() [2]sheet_window.c.SDL_Event {
    return .{
        sheet_window.c.SDL_Event{ .key = .{
            .type = sheet_window.c.SDL_KEYDOWN,
            .keysym = .{ .scancode = sheet_window.c.SDL_SCANCODE_DOWN },
        } },
        sheet_window.c.SDL_Event{ .key = .{
            .type = sheet_window.c.SDL_KEYUP,
            .keysym = .{ .scancode = sheet_window.c.SDL_SCANCODE_DOWN },
        } },
    };
}

fn click_up() [2]sheet_window.c.SDL_Event {
    return .{
        sheet_window.c.SDL_Event{ .key = .{
            .type = sheet_window.c.SDL_KEYDOWN,
            .keysym = .{ .scancode = sheet_window.c.SDL_SCANCODE_UP },
        } },
        sheet_window.c.SDL_Event{ .key = .{
            .type = sheet_window.c.SDL_KEYUP,
            .keysym = .{ .scancode = sheet_window.c.SDL_SCANCODE_UP },
        } },
    };
}

fn click_right() [2]sheet_window.c.SDL_Event {
    return .{
        sheet_window.c.SDL_Event{ .key = .{
            .type = sheet_window.c.SDL_KEYDOWN,
            .keysym = .{ .scancode = sheet_window.c.SDL_SCANCODE_RIGHT },
        } },
        sheet_window.c.SDL_Event{ .key = .{
            .type = sheet_window.c.SDL_KEYUP,
            .keysym = .{ .scancode = sheet_window.c.SDL_SCANCODE_RIGHT },
        } },
    };
}

fn click_left() [2]sheet_window.c.SDL_Event {
    return .{
        sheet_window.c.SDL_Event{ .key = .{
            .type = sheet_window.c.SDL_KEYDOWN,
            .keysym = .{ .scancode = sheet_window.c.SDL_SCANCODE_LEFT },
        } },
        sheet_window.c.SDL_Event{ .key = .{
            .type = sheet_window.c.SDL_KEYUP,
            .keysym = .{ .scancode = sheet_window.c.SDL_SCANCODE_LEFT },
        } },
    };
}

const TestEnterDataInSingleCell = struct {
    // test that clicking a cell and entering data fills the cell
    test_step: TestStep,

    pub fn init(state: *WindowState) TestEnterDataInSingleCell {
        // const cell = sheet.cell_to_pixel(3, 3, state);
        var event_arr = std.ArrayList(sheet_window.c.union_SDL_Event).init(std.heap.c_allocator);
        event_arr.appendSlice(&click_cell(state, 3, 3)) catch @panic("Could not allocate memory.");
        event_arr.append(sheet_window.c.SDL_Event{
            .text = .{
                .type = sheet_window.c.SDL_TEXTINPUT,
                .text = blk: {
                    // const s = "hej";
                    var arr: [32]u8 = .{0} ** 32;
                    arr[0] = 'h';
                    arr[1] = 'e';
                    arr[2] = 'j';
                    // std.mem.copyForwards(u8, &arr, s);
                    std.debug.print("Inserting '{s}'\n", .{arr});
                    break :blk arr;
                },
            },
        }) catch @panic("Could not allocate memory.");

        const test_step = TestStep{
            .events = event_arr.items,
            .verifier = verifier,
        };
        std.debug.print("Event content: {s}, {}", .{ test_step.events[2].text.text, test_step.events[2].text.type });
        return TestEnterDataInSingleCell{ .test_step = test_step };
    }
    pub fn verifier(_: *const TestStep, app: *SpreadSheetApp) !void {
        const cell = app.cells.find(3, 3);
        try std.testing.expect(cell != null);
        const expected_value = "hej";
        try std.testing.expectEqualStrings(expected_value, cell.?.value.items);
    }
};

const TestSelectedCell = struct {
    test_step: TestStep,
    pub fn init(state: *WindowState) TestEnterDataInSingleCell {
        var event_arr = std.ArrayList(sheet_window.c.union_SDL_Event).init(std.heap.c_allocator);

        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_ESCAPE)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_cell(state, 4, 4)) catch @panic("Could not allocate memory.");
        const test_step = TestStep{
            .events = event_arr.items,
            .verifier = verifier,
        };
        return TestEnterDataInSingleCell{ .test_step = test_step };
    }
    pub fn verifier(_: *const TestStep, app: *SpreadSheetApp) !void {
        const cell = app.cells.find(4, 4);
        try std.testing.expect(cell != null);

        std.testing.expectEqual(false, app.is_editing) catch |err| {
            std.debug.print("Expected to be editing after clicking cell.\n", .{});
            return err;
        };
        std.testing.expectEqual(sheet.CellCoords{ .x = 4, .y = 4 }, app.selected_cell) catch |err| {
            std.debug.print("Expected selected cell to be set.\n", .{});
            return err;
        };
        std.testing.expectEqual(null, app.selected_area) catch |err| {
            std.debug.print("Expected selected area to be null.\n", .{});
            return err;
        };
    }
};

const TestEnterEnablesEdit = struct {
    test_step: TestStep,
    pub fn init(state: *WindowState) TestEnterEnablesEdit {
        var event_arr = std.ArrayList(sheet_window.c.union_SDL_Event).init(std.heap.c_allocator);

        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_ESCAPE)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_cell(state, 5, 5)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_RETURN)) catch @panic("Could not allocate memory.");

        const test_step = TestStep{
            .events = event_arr.items,
            .verifier = verifier,
        };
        return TestEnterEnablesEdit{ .test_step = test_step };
    }
    pub fn verifier(_: *const TestStep, app: *SpreadSheetApp) !void {
        const cell = app.cells.find(5, 5);
        try std.testing.expect(cell != null);

        std.testing.expectEqual(true, app.is_editing) catch |err| {
            std.debug.print("Expected to be editing after clicking cell.\n", .{});
            return err;
        };
    }
};

const TestMovingDuringEdit = struct {
    test_step: TestStep,
    pub fn init(state: *WindowState) TestMovingDuringEdit {
        var event_arr = std.ArrayList(sheet_window.c.union_SDL_Event).init(std.heap.c_allocator);

        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_ESCAPE)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_cell(state, 0, 0)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_cell(state, 5, 5)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_RETURN)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_down()) catch @panic("Could not allocate memory.");
        const test_step = TestStep{
            .events = event_arr.items,
            .verifier = verifier,
        };
        return TestMovingDuringEdit{ .test_step = test_step };
    }
    pub fn verifier(_: *const TestStep, app: *SpreadSheetApp) !void {
        const cell = app.cells.find(5, 6);
        try std.testing.expect(cell != null);

        std.testing.expectEqual(false, app.is_editing) catch |err| {
            std.debug.print("Expected to be editing after clicking cell.\n", .{});
            return err;
        };
        std.testing.expectEqual(sheet.CellCoords{ .x = 5, .y = 6 }, app.selected_cell) catch |err| {
            std.debug.print("Expected selected cell to be set.\n", .{});
            return err;
        };
        std.testing.expectEqual(null, app.selected_area) catch |err| {
            std.debug.print("Expected selected area to be null.\n", .{});
            return err;
        };
    }
};

const TestKeyboardNavigation = struct {
    test_step: TestStep,
    pub fn init(state: *WindowState) TestKeyboardNavigation {
        var event_arr = std.ArrayList(sheet_window.c.union_SDL_Event).init(std.heap.c_allocator);

        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_ESCAPE)) catch @panic("Could not allocate memory.");

        event_arr.appendSlice(&click_cell(state, 6, 6)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_down()) catch @panic("Could not allocate memory.");

        event_arr.appendSlice(&click_right()) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_right()) catch @panic("Could not allocate memory.");

        event_arr.appendSlice(&click_up()) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_up()) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_up()) catch @panic("Could not allocate memory.");

        event_arr.appendSlice(&click_left()) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_left()) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_left()) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_left()) catch @panic("Could not allocate memory.");

        const test_step = TestStep{
            .events = event_arr.items,
            .verifier = verifier,
        };
        return TestKeyboardNavigation{ .test_step = test_step };
    }
    pub fn verifier(_: *const TestStep, app: *SpreadSheetApp) !void {
        const cell = app.cells.find(4, 4);
        try std.testing.expect(cell != null);

        std.testing.expectEqual(false, app.is_editing) catch |err| {
            std.debug.print("Expected to be editing after clicking cell.\n", .{});
            return err;
        };
        std.testing.expectEqual(sheet.CellCoords{ .x = 4, .y = 4 }, app.selected_cell) catch |err| {
            std.debug.print("Expected selected cell to be set.\n", .{});
            return err;
        };
        std.testing.expectEqual(null, app.selected_area) catch |err| {
            std.debug.print("Expected selected area to be null.\n", .{});
            return err;
        };
    }
};

const TestOutOfBoundKeyboard = struct {
    test_step: TestStep,
    pub fn init(state: *WindowState) TestOutOfBoundKeyboard {
        var event_arr = std.ArrayList(sheet_window.c.union_SDL_Event).init(std.heap.c_allocator);

        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_ESCAPE)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_cell(state, 0, 0)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_left()) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_up()) catch @panic("Could not allocate memory.");

        const test_step = TestStep{
            .events = event_arr.items,
            .verifier = verifier,
        };
        return TestOutOfBoundKeyboard{ .test_step = test_step };
    }
    pub fn verifier(_: *const TestStep, app: *SpreadSheetApp) !void {
        const cell = app.cells.find(0, 0);
        try std.testing.expect(cell != null);

        std.testing.expectEqual(false, app.is_editing) catch |err| {
            std.debug.print("Expected to be editing after clicking cell.\n", .{});
            return err;
        };
        std.testing.expectEqual(sheet.CellCoords{ .x = 0, .y = 0 }, app.selected_cell) catch |err| {
            std.debug.print("Expected selected cell to be set.\n", .{});
            return err;
        };
        std.testing.expectEqual(null, app.selected_area) catch |err| {
            std.debug.print("Expected selected area to be null.\n", .{});
            return err;
        };
    }
};

const TestAreaSelectClearsCell = struct {
    test_step: TestStep,
    pub fn init(state: *WindowState) TestAreaSelectClearsCell {
        var event_arr = std.ArrayList(sheet_window.c.union_SDL_Event).init(std.heap.c_allocator);

        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_ESCAPE)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_cell(state, 0, 0)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_RETURN)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&select_area(state, 1, 1, 5, 5)) catch @panic("Could not allocate memory.");

        const test_step = TestStep{
            .events = event_arr.items,
            .verifier = verifier,
        };
        return TestAreaSelectClearsCell{ .test_step = test_step };
    }
    pub fn verifier(_: *const TestStep, app: *SpreadSheetApp) !void {
        const cell = app.cells.find(0, 0);
        try std.testing.expect(cell != null);

        std.testing.expectEqual(false, app.is_editing) catch |err| {
            std.debug.print("Expected to not be editing.\n", .{});
            return err;
        };
        std.testing.expectEqual(null, app.selected_cell) catch |err| {
            std.debug.print("Expected selected cell to be null.\n", .{});
            return err;
        };
        std.testing.expectEqual(sheet.Area{ .x = 1, .y = 1, .w = 5, .h = 5 }, app.selected_area) catch |err| {
            std.debug.print("Expected selected area to be set.\n", .{});
            return err;
        };
    }
};

const TestSelectCellClearsArea = struct {
    test_step: TestStep,
    pub fn init(state: *WindowState) TestSelectCellClearsArea {
        var event_arr = std.ArrayList(sheet_window.c.union_SDL_Event).init(std.heap.c_allocator);

        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_ESCAPE)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&select_area(state, 1, 1, 5, 5)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_cell(state, 0, 0)) catch @panic("Could not allocate memory.");

        const test_step = TestStep{
            .events = event_arr.items,
            .verifier = verifier,
        };
        return TestSelectCellClearsArea{ .test_step = test_step };
    }
    pub fn verifier(_: *const TestStep, app: *SpreadSheetApp) !void {
        const cell = app.cells.find(0, 0);
        try std.testing.expect(cell != null);

        std.testing.expectEqual(false, app.is_editing) catch |err| {
            std.debug.print("Expected to not be editing.\n", .{});
            return err;
        };
        std.testing.expectEqual(sheet.CellCoords{ .x = 0, .y = 0 }, app.selected_cell) catch |err| {
            std.debug.print("Expected selected cell to be set.\n", .{});
            return err;
        };
        std.testing.expectEqual(null, app.selected_area) catch |err| {
            std.debug.print("Expected selected area to be null.\n", .{});
            return err;
        };
    }
};

const TestArrowAfterAreaSelect = struct {
    test_step: TestStep,
    pub fn init(state: *WindowState) TestArrowAfterAreaSelect {
        var event_arr = std.ArrayList(sheet_window.c.union_SDL_Event).init(std.heap.c_allocator);

        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_ESCAPE)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&select_area(state, 1, 1, 5, 5)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_down()) catch @panic("Could not allocate memory.");

        const test_step = TestStep{
            .events = event_arr.items,
            .verifier = verifier,
        };
        return TestArrowAfterAreaSelect{ .test_step = test_step };
    }
    pub fn verifier(_: *const TestStep, app: *SpreadSheetApp) !void {
        const cell = app.cells.find(0, 0);
        try std.testing.expect(cell != null);

        std.testing.expectEqual(false, app.is_editing) catch |err| {
            std.debug.print("Expected to not be editing.\n", .{});
            return err;
        };
        std.testing.expectEqual(sheet.CellCoords{ .x = 1, .y = 2 }, app.selected_cell) catch |err| {
            std.debug.print("Expected selected cell to be set.\n", .{});
            return err;
        };
        std.testing.expectEqual(null, app.selected_area) catch |err| {
            std.debug.print("Expected selected area to be null.\n", .{});
            return err;
        };
    }
};

const TestArrowAfterAreaSelect2 = struct {
    test_step: TestStep,
    pub fn init(state: *WindowState) TestArrowAfterAreaSelect2 {
        var event_arr = std.ArrayList(sheet_window.c.union_SDL_Event).init(std.heap.c_allocator);

        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_ESCAPE)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&select_area(state, 5, 5, 1, 1)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_down()) catch @panic("Could not allocate memory.");

        const test_step = TestStep{
            .events = event_arr.items,
            .verifier = verifier,
        };
        return TestArrowAfterAreaSelect2{ .test_step = test_step };
    }
    pub fn verifier(_: *const TestStep, app: *SpreadSheetApp) !void {
        std.testing.expectEqual(false, app.is_editing) catch |err| {
            std.debug.print("Expected to not be editing.\n", .{});
            return err;
        };
        std.testing.expectEqual(sheet.CellCoords{ .x = 5, .y = 6 }, app.selected_cell) catch |err| {
            std.debug.print("Expected selected cell to be set.\n", .{});
            return err;
        };
        std.testing.expectEqual(null, app.selected_area) catch |err| {
            std.debug.print("Expected selected area to be null.\n", .{});
            return err;
        };
    }
};

const TestEnterAfterAreaSelect = struct {
    test_step: TestStep,
    pub fn init(state: *WindowState) TestEnterAfterAreaSelect {
        var event_arr = std.ArrayList(sheet_window.c.union_SDL_Event).init(std.heap.c_allocator);

        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_ESCAPE)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&select_area(state, 1, 1, 5, 5)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_RETURN)) catch @panic("Could not allocate memory.");

        const test_step = TestStep{
            .events = event_arr.items,
            .verifier = verifier,
        };
        return TestEnterAfterAreaSelect{ .test_step = test_step };
    }
    pub fn verifier(_: *const TestStep, app: *SpreadSheetApp) !void {
        std.testing.expectEqual(true, app.is_editing) catch |err| {
            std.debug.print("Expected to not be editing.\n", .{});
            return err;
        };
        std.testing.expectEqual(sheet.CellCoords{ .x = 1, .y = 1 }, app.selected_cell) catch |err| {
            std.debug.print("Expected selected cell to be set.\n", .{});
            return err;
        };
        std.testing.expectEqual(null, app.selected_area) catch |err| {
            std.debug.print("Expected selected area to be null.\n", .{});
            return err;
        };
    }
};

const TestEnterAfterAreaSelect2 = struct {
    test_step: TestStep,
    pub fn init(state: *WindowState) TestEnterAfterAreaSelect2 {
        var event_arr = std.ArrayList(sheet_window.c.union_SDL_Event).init(std.heap.c_allocator);

        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_ESCAPE)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&select_area(state, 5, 5, 1, 1)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_RETURN)) catch @panic("Could not allocate memory.");

        const test_step = TestStep{
            .events = event_arr.items,
            .verifier = verifier,
        };
        return TestEnterAfterAreaSelect2{ .test_step = test_step };
    }
    pub fn verifier(_: *const TestStep, app: *SpreadSheetApp) !void {
        std.testing.expectEqual(true, app.is_editing) catch |err| {
            std.debug.print("Expected to not be editing.\n", .{});
            return err;
        };
        std.testing.expectEqual(sheet.CellCoords{ .x = 5, .y = 5 }, app.selected_cell) catch |err| {
            std.debug.print("Expected selected cell to be set.\n", .{});
            return err;
        };
        std.testing.expectEqual(null, app.selected_area) catch |err| {
            std.debug.print("Expected selected area to be null.\n", .{});
            return err;
        };
    }
};

const TestTextInputAfterAreaSelect = struct {
    test_step: TestStep,
    pub fn init(state: *WindowState) TestTextInputAfterAreaSelect {
        var event_arr = std.ArrayList(sheet_window.c.union_SDL_Event).init(std.heap.c_allocator);

        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_ESCAPE)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&select_area(state, 1, 1, 5, 5)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&enter_text("test")) catch @panic("Could not allocate memory.");

        const test_step = TestStep{
            .events = event_arr.items,
            .verifier = verifier,
        };
        return TestTextInputAfterAreaSelect{ .test_step = test_step };
    }
    pub fn verifier(_: *const TestStep, app: *SpreadSheetApp) !void {
        std.testing.expectEqual(true, app.is_editing) catch |err| {
            std.debug.print("Expected to be editing.\n", .{});
            return err;
        };
        std.testing.expectEqual(sheet.CellCoords{ .x = 1, .y = 1 }, app.selected_cell) catch |err| {
            std.debug.print("Expected selected cell to be set.\n", .{});
            return err;
        };
        std.testing.expectEqual(null, app.selected_area) catch |err| {
            std.debug.print("Expected selected area to be null.\n", .{});
            return err;
        };

        const cell = app.cells.find(1, 1);
        try std.testing.expect(cell != null);
        const expected_value = "test";
        std.testing.expectEqualStrings(expected_value, cell.?.value.items) catch |err| {
            std.debug.print("Expected cell to have text", .{});
            return err;
        };
    }
};

const TestCopySelectedCell = struct {
    test_step: TestStep,
    pub fn init(state: *WindowState) TestCopySelectedCell {
        var event_arr = std.ArrayList(sheet_window.c.union_SDL_Event).init(std.heap.c_allocator);

        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_ESCAPE)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_cell(state, 2, 2)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&enter_text("test")) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_copy()) catch @panic("Could not allocate memory.");

        const test_step = TestStep{
            .events = event_arr.items,
            .verifier = verifier,
        };
        return TestCopySelectedCell{ .test_step = test_step };
    }
    pub fn verifier(_: *const TestStep, app: *SpreadSheetApp) !void {
        std.testing.expectEqual(true, app.is_editing) catch |err| {
            std.debug.print("Expected to be editing.\n", .{});
            return err;
        };
        std.testing.expectEqual(sheet.CellCoords{ .x = 2, .y = 2 }, app.selected_cell) catch |err| {
            std.debug.print("Expected selected cell to be set.\n", .{});
            return err;
        };
        std.testing.expectEqual(null, app.selected_area) catch |err| {
            std.debug.print("Expected selected area to be null.\n", .{});
            return err;
        };
        // check that copy didnt remove data
        const cell = app.cells.find(2, 2);
        try std.testing.expect(cell != null);
        const expected_value = "test";
        try std.testing.expectEqualStrings(expected_value, cell.?.value.items);

        // check clipboard content
        const clipboard = sheet_window.c.SDL_GetClipboardText();
        var c_str_slice: []u8 = undefined;
        c_str_slice.ptr = clipboard;
        c_str_slice.len = get_cstr_len(clipboard);
        std.testing.expectEqualStrings("test", c_str_slice) catch |err| {
            std.debug.print("Expected string content.", .{});
            return err;
        };
    }
};

const TestCopyPasteSelectedCellNoEdit = struct {
    test_step: TestStep,
    pub fn init(state: *WindowState) TestCopyPasteSelectedCellNoEdit {
        var event_arr = std.ArrayList(sheet_window.c.union_SDL_Event).init(std.heap.c_allocator);

        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_ESCAPE)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_cell(state, 2, 2)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&enter_text("test")) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_copy()) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_cell(state, 3, 2)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_paste()) catch @panic("Could not allocate memory.");

        const test_step = TestStep{
            .events = event_arr.items,
            .verifier = verifier,
        };
        return TestCopyPasteSelectedCellNoEdit{ .test_step = test_step };
    }
    pub fn verifier(_: *const TestStep, app: *SpreadSheetApp) !void {
        std.testing.expectEqual(false, app.is_editing) catch |err| {
            std.debug.print("Expected to be editing.\n", .{});
            return err;
        };
        std.testing.expectEqual(sheet.CellCoords{ .x = 3, .y = 2 }, app.selected_cell) catch |err| {
            std.debug.print("Expected selected cell to be set.\n", .{});
            return err;
        };
        std.testing.expectEqual(null, app.selected_area) catch |err| {
            std.debug.print("Expected selected area to be null.\n", .{});
            return err;
        };
        // check that the paste wrote data
        const cell = app.cells.find(3, 2);
        try std.testing.expect(cell != null);
        const expected_value = "test";
        try std.testing.expectEqualStrings(expected_value, cell.?.value.items);
    }
};

const TestCopyPasteSelectedCellWithEdit = struct {
    test_step: TestStep,
    pub fn init(state: *WindowState) TestCopyPasteSelectedCellWithEdit {
        var event_arr = std.ArrayList(sheet_window.c.union_SDL_Event).init(std.heap.c_allocator);

        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_ESCAPE)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_cell(state, 2, 2)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&enter_text("test")) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_copy()) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_cell(state, 3, 2)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_RETURN)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_paste()) catch @panic("Could not allocate memory.");

        const test_step = TestStep{
            .events = event_arr.items,
            .verifier = verifier,
        };
        return TestCopyPasteSelectedCellWithEdit{ .test_step = test_step };
    }
    pub fn verifier(_: *const TestStep, app: *SpreadSheetApp) !void {
        std.testing.expectEqual(true, app.is_editing) catch |err| {
            std.debug.print("Expected to be editing.\n", .{});
            return err;
        };
        std.testing.expectEqual(sheet.CellCoords{ .x = 3, .y = 2 }, app.selected_cell) catch |err| {
            std.debug.print("Expected selected cell to be set.\n", .{});
            return err;
        };
        std.testing.expectEqual(null, app.selected_area) catch |err| {
            std.debug.print("Expected selected area to be null.\n", .{});
            return err;
        };
        // check that the paste wrote data
        const cell = app.cells.find(3, 2);
        try std.testing.expect(cell != null);
        const expected_value = "test";
        try std.testing.expectEqualStrings(expected_value, cell.?.value.items);
    }
};

const TestCopyPasteArea = struct {
    test_step: TestStep,
    pub fn init(state: *WindowState) TestCopyPasteArea {
        var event_arr = std.ArrayList(sheet_window.c.union_SDL_Event).init(std.heap.c_allocator);

        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_ESCAPE)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_cell(state, 0, 5)) catch @panic("Could not allocate memory.");

        event_arr.appendSlice(&enter_text("05")) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_RETURN)) catch @panic("Could not allocate memory.");

        event_arr.appendSlice(&enter_text("06")) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_RETURN)) catch @panic("Could not allocate memory.");

        event_arr.appendSlice(&enter_text("07")) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_RETURN)) catch @panic("Could not allocate memory.");

        event_arr.appendSlice(&enter_text("08")) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_RETURN)) catch @panic("Could not allocate memory.");

        event_arr.appendSlice(&click_cell(state, 1, 5)) catch @panic("Could not allocate memory.");

        event_arr.appendSlice(&enter_text("15")) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_RETURN)) catch @panic("Could not allocate memory.");

        event_arr.appendSlice(&enter_text("16")) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_RETURN)) catch @panic("Could not allocate memory.");

        event_arr.appendSlice(&enter_text("17")) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_RETURN)) catch @panic("Could not allocate memory.");

        event_arr.appendSlice(&enter_text("18")) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_key(sheet_window.c.SDLK_RETURN)) catch @panic("Could not allocate memory.");

        event_arr.appendSlice(&click_cell(state, 2, 5)) catch @panic("Could not allocate memory.");

        event_arr.appendSlice(&enter_text("THIS SHOULD BE OVERWRITTEN")) catch @panic("Could not allocate memory.");

        event_arr.appendSlice(&select_area(state, 0, 5, 1, 8)) catch @panic("Could not allocate memory.");

        event_arr.appendSlice(&click_copy()) catch @panic("Could not allocate memory.");

        event_arr.appendSlice(&click_cell(state, 2, 5)) catch @panic("Could not allocate memory.");
        event_arr.appendSlice(&click_paste()) catch @panic("Could not allocate memory.");

        const test_step = TestStep{
            .events = event_arr.items,
            .verifier = verifier,
        };
        return TestCopyPasteArea{ .test_step = test_step };
    }
    pub fn verifier(_: *const TestStep, app: *SpreadSheetApp) !void {
        try std.testing.expectEqualStrings("05", app.cells.find(0, 5).?.value.items);
        try std.testing.expectEqualStrings("06", app.cells.find(0, 6).?.value.items);
        try std.testing.expectEqualStrings("07", app.cells.find(0, 7).?.value.items);
        try std.testing.expectEqualStrings("08", app.cells.find(0, 8).?.value.items);

        try std.testing.expectEqualStrings("15", app.cells.find(1, 5).?.value.items);
        try std.testing.expectEqualStrings("16", app.cells.find(1, 6).?.value.items);
        try std.testing.expectEqualStrings("17", app.cells.find(1, 7).?.value.items);
        try std.testing.expectEqualStrings("18", app.cells.find(1, 8).?.value.items);

        try std.testing.expectEqualStrings("05", app.cells.find(2, 5).?.value.items);
        try std.testing.expectEqualStrings("06", app.cells.find(2, 6).?.value.items);
        try std.testing.expectEqualStrings("07", app.cells.find(2, 7).?.value.items);
        try std.testing.expectEqualStrings("08", app.cells.find(2, 8).?.value.items);

        try std.testing.expectEqualStrings("15", app.cells.find(3, 5).?.value.items);
        try std.testing.expectEqualStrings("16", app.cells.find(3, 6).?.value.items);
        try std.testing.expectEqualStrings("17", app.cells.find(3, 7).?.value.items);
        try std.testing.expectEqualStrings("18", app.cells.find(3, 8).?.value.items);

        std.testing.expectEqual(null, app.selected_cell) catch |err| {
            std.debug.print("Expected selected cell to be null.\n", .{});
            return err;
        };
        std.testing.expectEqual(sheet.Area{ .x = 2, .y = 5, .w = 2, .h = 4 }, app.selected_area) catch |err| {
            std.debug.print("Expected selected area to be set.\n", .{});
            return err;
        };
        // check that the paste wrote data
    }
};

pub fn run_e2e() !void {
    var app = try SpreadSheetApp.init("/Users/dkRaHySa/Desktop/programs/rs-sheets/src/assets/e2e_test.csv");
    try app.render_and_present_next_frame(true);
    const step_1 = TestEnterDataInSingleCell.init(&app.state);
    const step_2 = TestSelectedCell.init(&app.state);
    const step_3 = TestEnterEnablesEdit.init(&app.state);
    const step_4 = TestMovingDuringEdit.init(&app.state);
    const step_5 = TestKeyboardNavigation.init(&app.state);
    const step_6 = TestOutOfBoundKeyboard.init(&app.state);
    const step_7 = TestAreaSelectClearsCell.init(&app.state);
    const step_8 = TestSelectCellClearsArea.init(&app.state);
    const step_9 = TestArrowAfterAreaSelect.init(&app.state);
    const step_10 = TestArrowAfterAreaSelect2.init(&app.state);
    const step_11 = TestEnterAfterAreaSelect.init(&app.state);
    const step_12 = TestTextInputAfterAreaSelect.init(&app.state);
    const step_13 = TestCopySelectedCell.init(&app.state);
    const step_14 = TestCopyPasteSelectedCellNoEdit.init(&app.state);
    const step_15 = TestCopyPasteSelectedCellWithEdit.init(&app.state);
    const step_16 = TestCopyPasteArea.init(&app.state);

    const steps: [16]*const TestStep = .{ &step_1.test_step, &step_2.test_step, &step_3.test_step, &step_4.test_step, &step_5.test_step, &step_6.test_step, &step_7.test_step, &step_8.test_step, &step_9.test_step, &step_10.test_step, &step_11.test_step, &step_12.test_step, &step_13.test_step, &step_14.test_step, &step_15.test_step, &step_16.test_step };

    var event_poller = TestEventPoller.init(&steps, &app);
    while (true) {
        if (try app.update(&event_poller.event_poller)) {
            return;
        }
        // try app.update();

        try app.render_and_present_next_frame(false);
        app.sleep_until_next_frame();
    }
}
