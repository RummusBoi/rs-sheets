const c = @import("sheet_window.zig").c;
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

pub const EquationDependency = struct {
    equation_cell: CellCoords, // cell with the equation
    current_dependency: ?usize, // dependency we are currently selecting
    dependencies: []Area, // all dependencies
    _dep_buffer: [10]Area, // buffer for dependencies
};

pub const SelectionMode = union(enum) {
    /// No selection is active.
    Nothing: void,
    /// A single cell is selected.
    SingleCell: CellCoords,
    /// A rectangular area of cells is selected.
    Area: Area,
    /// We are editing an equation and we are selecting a list of dependencies.
    EquationDependency: EquationDependency,
};

pub fn update_area(area: *Area, arrow_direction: Direction) void {
    const move_x: i32 = if (arrow_direction == Direction.Left) -1 else if (arrow_direction == Direction.Right) 1 else 0;
    const move_y: i32 = if (arrow_direction == Direction.Up) -1 else if (arrow_direction == Direction.Down) 1 else 0;
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
    if (area.y + area.h <= -1) {
        area.h = -area.y - 1;
    }
    if (area.x + area.w <= -1) {
        area.w = -area.x - 1;
    }
}

pub const Direction = enum {
    Up,
    Down,
    Left,
    Right,
    pub fn from_sdl_scancode(scancode: c_uint) Direction {
        switch (scancode) {
            c.SDL_SCANCODE_UP => return Direction.Up,
            c.SDL_SCANCODE_DOWN => return Direction.Down,
            c.SDL_SCANCODE_LEFT => return Direction.Left,
            c.SDL_SCANCODE_RIGHT => return Direction.Right,
            else => return Direction.Up,
        }
    }
};

// Note on EquationDependency:
// This is a special mode that is entered when we are editing an equation.
// If the user at any point presses OPTION + ARROW, we will add a dependency to 'dependencies', and that dependency will be referenced from 'current_dependency'.
// (The user should in the future be able to navigate the text editor with the arrow keys.)
// Example:
// 0. User selects cell (0, 0).
// 1. User types '=avg(' to start editing an equation.
//  - We enter EquationDependency mode with 'equation_cell' set to (0, 0).
// 2. Users starts holding down OPTION
// 3. User presses RIGHT
//  - We add a new dependency to 'dependencies' and set 'current_dependency' to 0.
// 4. User navigates to the cell they want to reference.
// 5. User releases OPTION
// 6. User types ') + sum('
// 7. User starts holding down OPTION
// 8. User presses RIGHT
//  - We add a new dependency to 'dependencies' and set 'current_dependency' to 1.
// 9. User navigates to a range they want to reference.
// 10. User starts holding down SHIFT (this starts the selection part of the equation editing)
// 11. User selects the range they want to reference.
// 12. User releases SHIFT
// 13. User can use arrow keys to move the selection around.
// 14. User releases OPTION
// 15. User types ')'
// 16. User presses ENTER
//  - We exit EquationDependency mode and evaluate the equation.

// SUMMARY:
// - Holding down OPTION allows the user to select a cell.
// - Holding down SHIFT while holding down OPTION allows the user to select a range.
// - Releasing SHIFT while holding down OPTION allows the user to move the selection around.
