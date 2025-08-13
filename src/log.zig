const std = @import("std");
const axe = @import("axe");

pub const config = axe.Axe(.{
    .format = "[%l%s%L] %m\n",
    .scope_format = " %",
    .loc_format = " %f:%F:%l",
    .level_text = .{
        .debug = "DEBUG",
        .info = "INFO ",
        .warn = "WARN ",
        .err = "ERROR",
    },
    .styles = .{
        .debug = &.{.dim},
    },
});
