pub fn get_cstr_len(c_str: [*]u8) usize {
    var found_null = false;
    var index: usize = 0;
    while (!found_null) : (index += 1) {
        found_null = c_str[index] == 0;
    }
    return index - 1;
}
