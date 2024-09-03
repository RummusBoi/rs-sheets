pub const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
    @cInclude("SDL2/SDL2_gfxPrimitives.h");
});
pub const std = @import("std");
const constants = @import("constants.zig");
const CacheError = error{
    CouldNotCache,
};
const CachedTexture = struct {
    value: []u8,
    key: []u8,
    texture: *c.SDL_Texture,
    allocator: *std.mem.Allocator,

    pub fn init(value: []u8, texture: *c.SDL_Texture, allocator: *std.mem.Allocator) !CachedTexture {
        const heap_value = try allocator.alloc(u8, value.len);
        heap_value.* = value.*;

        return CachedTexture{ .value = heap_value, .texture = texture, .allocator = allocator };
    }

    pub fn deinit(self: *CachedTexture) void {
        self.allocator.free(self.value);
        self.allocator.free(self.key);
        c.SDL_DestroyTexture(self.texture);
    }
};

pub const SheetWindow = struct {
    win: *c.SDL_Window,
    font: *c.TTF_Font,
    font_color: c.SDL_Color,
    renderer: *c.SDL_Renderer,
    cached_textures: std.ArrayList(CachedTexture),
    allocator: *std.mem.Allocator,

    pub fn init(width: u32, height: u32, allocator: *std.mem.Allocator) !SheetWindow {
        _ = c.SDL_Init(c.SDL_INIT_EVERYTHING);

        _ = c.TTF_Init();
        // _ = c.SDL_RecordGesture(-1);

        const font: *c.TTF_Font = c.TTF_OpenFont("assets/fonts/NaturalMono-Regular.ttf", 13) orelse sdl_panic("Loading font");
        const font_color: c.SDL_Color = .{ .r = 255, .g = 255, .b = 255 };
        const win = c.SDL_CreateWindow("RS Sheets", c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED, @intCast(width), @intCast(height), 0) orelse sdl_panic("Creating window");

        c.SDL_SetWindowResizable(win, 1);
        const renderer = c.SDL_CreateRenderer(win, 0, c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC) orelse sdl_panic("Creating renderer");
        if (c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND) != 0) {
            sdl_panic("Setting blend mode.");
        }

        return SheetWindow{
            .win = win,
            .font_color = font_color,
            .font = font,
            .renderer = renderer,
            .cached_textures = std.ArrayList(CachedTexture).init(allocator.*),
            .allocator = allocator,
        };
    }

    pub fn draw_background(self: *SheetWindow) !void {
        if (c.SDL_SetRenderDrawColor(self.renderer, 255, 255, 255, 255) != 0) {
            sdl_panic("Setting render color to white");
        }
        if (c.SDL_RenderClear(self.renderer) != 0) {
            sdl_panic("Coloring background");
        }
    }

    fn find_cached_texture_for_value(self: *SheetWindow, value: []const u8, key: []const u8) ?*c.SDL_Texture {
        for (self.cached_textures.items) |cached| {
            const is_equal = std.mem.eql(u8, cached.key, key) and std.mem.eql(u8, cached.value, value);
            if (is_equal) return cached.texture;
        }
        return null;
    }

    fn cache_texture(self: *SheetWindow, texture: *c.SDL_Texture, value: []const u8, key: []const u8) !void {
        std.debug.print("Caching texture for {s}\n", .{value});
        const value_arr = try self.allocator.alloc(u8, value.len);
        const key_arr = try self.allocator.alloc(u8, key.len);
        std.mem.copyForwards(u8, value_arr, value);
        std.mem.copyForwards(u8, key_arr, key);

        try self.cached_textures.append(CachedTexture{ .texture = texture, .value = value_arr, .key = key_arr, .allocator = self.allocator });
    }

    pub fn draw_row_label(self: *SheetWindow, value: []u8, y: i32, highlight: bool) !void {
        // const a_pos_x = constants.CELL_START_X
        const bg_color = 200;
        if (c.SDL_SetRenderDrawColor(self.renderer, if (highlight) bg_color else 255, if (highlight) bg_color else 255, if (highlight) bg_color else 255, 255) != 0) {
            sdl_panic("Setting draw color to white.");
        }
        if (c.SDL_RenderFillRect(self.renderer, &.{ .x = 0, .y = y, .w = 20, .h = constants.CELL_HEIGHT }) != 0) {
            sdl_panic("Drawing label background.");
        }
        if (c.SDL_SetRenderDrawColor(self.renderer, 0, 0, 0, 255) != 0) {
            sdl_panic("Setting draw color to black.");
        }
        if (c.SDL_RenderDrawLine(self.renderer, 0, y, 20, y) != 0) {
            sdl_panic("Drawing line for label.");
        }
        if (c.SDL_RenderDrawLine(self.renderer, 20, y, 20, y + constants.CELL_HEIGHT) != 0) {
            sdl_panic("Drawing line for label.");
        }
        const c_str = try std.heap.page_allocator.dupeZ(u8, value);
        defer std.heap.page_allocator.free(c_str);
        var w: c_int = undefined;
        var h: c_int = undefined;
        if (c.TTF_SizeText(self.font, c_str, &w, &h) != 0) {
            sdl_panic("Getting text size");
        }
        const texture_key = if (highlight) "label-highlight" else "label";
        const texture = self.find_cached_texture_for_value(value, texture_key) orelse blk: {
            std.debug.print("Could not find texture for value {s}\n", .{value});
            const font_color: c.SDL_Color = .{ .r = 0, .g = 0, .b = 0 };

            const surface = c.TTF_RenderText_Shaded(self.font, c_str, font_color, .{ .a = 255, .r = if (highlight) bg_color else 255, .g = if (highlight) bg_color else 255, .b = if (highlight) bg_color else 255 });
            defer c.SDL_FreeSurface(surface);
            const texture = c.SDL_CreateTextureFromSurface(self.renderer, surface) orelse {
                sdl_panic("Creating text texture.");
            };
            self.cache_texture(texture, value, texture_key) catch {
                std.debug.print("Could not cache texture.", .{});
            };
            break :blk texture;
        };
        const dest_rect: c.SDL_Rect = .{ .x = 3, .y = y + 3, .w = w, .h = h };
        if (c.SDL_RenderCopy(self.renderer, texture, null, &dest_rect) != 0) {
            sdl_panic("Could not render");
        }
    }

    pub fn draw_column_label(self: *SheetWindow, value: []u8, x: i32, highlight: bool) !void {
        // const a_pos_x = constants.CELL_START_X
        const bg_color = 200;
        if (c.SDL_SetRenderDrawColor(self.renderer, if (highlight) bg_color else 255, if (highlight) bg_color else 255, if (highlight) bg_color else 255, 255) != 0) {
            sdl_panic("Setting draw color to white.");
        }
        if (c.SDL_RenderFillRect(self.renderer, &.{ .x = x, .y = 0, .w = constants.CELL_WIDTH, .h = 20 }) != 0) {
            sdl_panic("Drawing label background.");
        }
        if (c.SDL_SetRenderDrawColor(self.renderer, 0, 0, 0, 255) != 0) {
            sdl_panic("Setting draw color to black.");
        }
        if (c.SDL_RenderDrawLine(self.renderer, x, 0, x, 20) != 0) {
            sdl_panic("Drawing line for label.");
        }
        if (c.SDL_RenderDrawLine(self.renderer, x, 20, x + constants.CELL_WIDTH, 20) != 0) {
            sdl_panic("Drawing line for label.");
        }
        const c_str = try std.heap.page_allocator.dupeZ(u8, value);
        defer std.heap.page_allocator.free(c_str);
        var w: c_int = undefined;
        var h: c_int = undefined;
        if (c.TTF_SizeText(self.font, c_str, &w, &h) != 0) {
            sdl_panic("Getting text size");
        }
        const texture_key = if (highlight) "label-highlight" else "label";

        const texture = self.find_cached_texture_for_value(value, texture_key) orelse blk: {
            std.debug.print("Could not find texture for value {s}\n", .{value});
            const font_color: c.SDL_Color = .{ .r = 0, .g = 0, .b = 0 };

            const surface = c.TTF_RenderText_Shaded(self.font, c_str, font_color, .{ .a = 255, .r = if (highlight) bg_color else 255, .g = if (highlight) bg_color else 255, .b = if (highlight) bg_color else 255 });
            defer c.SDL_FreeSurface(surface);
            const texture = c.SDL_CreateTextureFromSurface(self.renderer, surface) orelse {
                sdl_panic("Creating text texture.");
            };
            self.cache_texture(texture, value, texture_key) catch {
                std.debug.print("Could not cache texture.", .{});
            };
            break :blk texture;
        };
        const dest_rect: c.SDL_Rect = .{ .x = x + @divTrunc(constants.CELL_WIDTH, 2) - @divTrunc(w, 2), .y = 2, .w = w, .h = h };
        if (c.SDL_RenderCopy(self.renderer, texture, null, &dest_rect) != 0) {
            sdl_panic("Could not render");
        }
    }

    pub fn draw_cell(self: *SheetWindow, x: i32, y: i32, value: []const u8, thick: bool, with_cursor: bool, make_darker: bool) !void {
        const outer: c.SDL_Rect = .{ .x = x, .y = y, .w = constants.CELL_WIDTH + constants.CELL_WALL_WIDTH, .h = constants.CELL_HEIGHT + constants.CELL_WALL_WIDTH };
        const wall_width: i32 = constants.CELL_WALL_WIDTH * (if (thick) @as(i32, 2) else @as(i32, 1));
        const inner: c.SDL_Rect = .{ .x = x + wall_width, .y = y + wall_width, .w = constants.CELL_WIDTH - wall_width * 2 + constants.CELL_WALL_WIDTH, .h = constants.CELL_HEIGHT - wall_width * 2 + constants.CELL_WALL_WIDTH };

        if (c.SDL_SetRenderDrawColor(self.renderer, if (make_darker) 200 else if (make_darker) 200 else 150, if (make_darker) 200 else 150, if (make_darker) 200 else 150, 255) != 0) {
            sdl_panic("Setting draw color to black.");
        }
        if (c.SDL_RenderFillRect(self.renderer, &outer) != 0) {
            sdl_panic("Rendering outer rect.");
        }

        if (c.SDL_SetRenderDrawColor(self.renderer, 255, 255, 255, 255) != 0) {
            sdl_panic("Setting draw color to white.");
        }
        if (c.SDL_RenderFillRect(self.renderer, &inner) != 0) {
            sdl_panic("Rendering inner rect.");
        }
        const c_str = try std.heap.page_allocator.dupeZ(u8, value);
        defer std.heap.page_allocator.free(c_str);
        var w: c_int = undefined;
        var h: c_int = undefined;
        if (c.TTF_SizeText(self.font, c_str, &w, &h) != 0) {
            sdl_panic("Getting text size");
        }
        if (value.len > 0) {
            const texture = self.find_cached_texture_for_value(value, "cell") orelse blk: {
                std.debug.print("Could not find texture for value {s}\n", .{value});
                const font_color: c.SDL_Color = .{ .r = 0, .g = 0, .b = 0 };

                const surface = c.TTF_RenderText_Shaded(self.font, c_str, font_color, .{ .a = 255, .r = 255, .g = 255, .b = 255 });
                defer c.SDL_FreeSurface(surface);
                const texture = c.SDL_CreateTextureFromSurface(self.renderer, surface) orelse {
                    sdl_panic("Creating text texture.");
                };
                self.cache_texture(texture, value, "cell") catch {
                    std.debug.print("Could not cache texture.", .{});
                };
                break :blk texture;
            };
            const dest_rect: c.SDL_Rect = .{ .x = outer.x + 3, .y = outer.y + 3, .w = w, .h = h };
            if (c.SDL_RenderCopy(self.renderer, texture, null, &dest_rect) != 0) {
                sdl_panic("Could not render");
            }
        }

        if (!with_cursor) return;
        const timestamp = std.time.milliTimestamp();
        if (@rem(timestamp, 1000) < 500) return;
        if (c.SDL_SetRenderDrawColor(self.renderer, 0, 0, 0, 255) != 0) {
            sdl_panic("Setting color to black");
        }
        if (c.SDL_RenderDrawLine(self.renderer, outer.x + 3 + w, outer.y + 5, outer.x + 3 + w, outer.y + h + 2) != 0) {
            sdl_panic("Rending cursor");
        }
    }

    pub fn draw_area(self: *SheetWindow, x: i32, y: i32, w: i32, h: i32) !void {
        const rect = c.SDL_Rect{ .x = x, .y = y, .w = w, .h = h };
        if (c.SDL_SetRenderDrawColor(self.renderer, 50, 50, 50, 25) != 0) {
            sdl_panic("Setting color to gray.");
        }
        if (c.SDL_RenderFillRect(self.renderer, &rect) != 0) {
            sdl_panic("Rendering outer rect.");
        }
    }

    pub fn delete_unused_textures(self: *SheetWindow, values: []const []u8, key: []const u8) void {
        var index: usize = 0;
        // super stupid way of removing textures
        while (index < self.cached_textures.items.len) {
            const texture = &self.cached_textures.items[index];
            if (!std.mem.eql(u8, texture.key, key)) {
                index += 1;
                continue;
            }
            const texture_val = texture.value[0..texture.value.len];
            if (!in_slice(texture_val, values)) {
                std.debug.print("Deleting texture {s}\n", .{texture_val});
                texture.deinit();
                _ = self.cached_textures.swapRemove(index);
            } else {
                index += 1;
            }
        }
    }

    pub fn render_present(self: *SheetWindow) !void {
        c.SDL_RenderPresent(self.renderer);
    }
};

fn ttf_panic(base_msg: []const u8) noreturn {
    std.debug.print("TTF panic detected.\n", .{});
    const message = c.TTF_GetError() orelse @panic("Unknown error in TTF.");

    var ptr: u32 = 0;
    char_loop: while (true) {
        const char = message[ptr];
        if (char == 0) {
            break :char_loop;
        }
        ptr += 1;
    }
    var zig_slice: []const u8 = undefined;
    zig_slice.len = ptr;
    zig_slice.ptr = message;

    var full_msg: [256]u8 = undefined;
    join_strs(base_msg, zig_slice, &full_msg);

    @panic(&full_msg);
}
fn sdl_panic(base_msg: []const u8) noreturn {
    std.debug.print("SDL panic detected.\n", .{});
    const message = c.SDL_GetError() orelse @panic("Unknown error in SDL.");

    var ptr: u32 = 0;
    char_loop: while (true) {
        const char = message[ptr];
        if (char == 0) {
            break :char_loop;
        }
        ptr += 1;
    }
    var zig_slice: []const u8 = undefined;
    zig_slice.len = ptr;
    zig_slice.ptr = message;

    var full_msg: [256]u8 = undefined;
    join_strs(base_msg, zig_slice, &full_msg);

    @panic(&full_msg);
}

fn join_strs(s1: []const u8, s2: []const u8, buf: []u8) void {
    for (s1, 0..) |char, index| {
        buf[index] = char;
    }
    for (s2, 0..) |char, index| {
        buf[s1.len + index] = char;
    }
}

fn in_slice(value: []const u8, slice: []const []u8) bool {
    for (slice) |slice_str| {
        if (std.mem.eql(u8, value, slice_str)) {
            return true;
        }
    }
    return false;
}
