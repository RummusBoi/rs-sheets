pub fn get_cstr_len(c_str: [*]u8) usize {
    var found_null = false;
    var index: usize = 0;
    while (!found_null) : (index += 1) {
        found_null = c_str[index] == 0;
    }
    return index - 1;
}

pub fn swap_remove(T: type, slice: []T, index: usize) []T {
    slice[index] = slice[slice.len - 1];
    return slice[0 .. slice.len - 1];
}

pub fn toLowercase(slice: []u8) void {
    const A = 'A';
    const Z = 'Z';
    const diff: u8 = @intCast('a' - 'A');

    for (slice) |*c| {
        if (c.* >= A and c.* <= Z) {
            c.* += diff;
        }
    }
}
