const std = @import("std");
const SpreadSheetApp = @import("main_loop.zig").SpreadSheetApp;
const EventPoller = @import("main_loop.zig").EventPoller;
const StandardEventPoller = @import("main_loop.zig").StandardEventPoller;
const TestEventPoller = @import("main_loop.zig").TestEventPoller;
const TestStep = @import("main_loop.zig").TestStep;
const sheet_window = @import("sheet_window.zig");
const WindowState = @import("window_state.zig").WindowState;
const sheet = @import("sheet.zig");
const run_e2e = @import("e2e_test.zig").run_e2e;
var index: usize = 0;
fn test_poll(event: [*c]sheet_window.c.SDL_Event) callconv(.C) c_int {
    var dummy_event: sheet_window.c.SDL_Event = undefined;
    _ = sheet_window.c.SDL_PollEvent(&dummy_event);
    if (dummy_event.type == sheet_window.c.SDL_QUIT) {
        std.debug.print("I want to quit", .{});
        const e = sheet_window.c.SDL_Event{ .type = sheet_window.c.SDL_QUIT };
        event.* = e;
        return 1;
    }

    if (index == 0) {
        event.* = sheet_window.c.SDL_Event{ .button = .{
            .type = sheet_window.c.SDL_MOUSEBUTTONDOWN,
            .button = sheet_window.c.SDL_BUTTON_LEFT,
            .x = 200,
            .y = 200,
        } };
    } else if (index == 1) {
        event.* = sheet_window.c.SDL_Event{ .button = .{
            .type = sheet_window.c.SDL_MOUSEBUTTONUP,
            .button = sheet_window.c.SDL_BUTTON_LEFT,
            .x = 200,
            .y = 200,
        } };
    } else if (index == 2) {
        var text: [32]u8 = .{0} ** 32;
        std.mem.copyForwards(u8, &text, "hej med jer");
        event.* = sheet_window.c.SDL_Event{ .text = sheet_window.c.SDL_TextInputEvent{
            .text = text,
            .type = sheet_window.c.SDL_TEXTINPUT,
        } };
    } else {
        return 0;
    }
    index += 1;
    return 1;
}

fn return_true(_: *SpreadSheetApp) bool {
    return true;
}

pub fn main() !void {
    try run_e2e();
    // var args = std.process.args();
    // if (args.inner.count < 2) {
    //     @panic("Expected exactly 2 arguments to program.");
    // }
    // if (args.inner.count > 2) {
    //     @panic("Expected exactly 2 arguments to program.");
    // }
    // _ = args.skip(); // skip this file
    // const filepath = args.next() orelse {
    //     @panic("Something went wrong.");
    // };
    // var app = try SpreadSheetApp.init(filepath);
    // try app.render_and_present_next_frame(true);

    // var event_poller = StandardEventPoller.init();
    // while (true) {
    //     if (try app.update(&event_poller.event_poller)) {
    //         return;
    //     }
    //     // try app.update();

    //     try app.render_and_present_next_frame(false);
    //     app.sleep_until_next_frame();
    // }
}
