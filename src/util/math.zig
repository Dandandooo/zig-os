const std = @import("std");

pub inline fn ROUND_UP(comptime T: type, numerator: T, denominator: T) T {
    return numerator + ((denominator - (numerator % denominator)) % denominator);
}

pub inline fn ROUND_DOWN(comptime T: type, numerator: T, denominator: T) T {
    return numerator - (numerator % denominator);
}

pub inline fn DIV_CEIL(comptime T: type, numerator: T, denominator: T) T {
    return (numerator - 1) / denominator + 1;
}

pub inline fn DIV_FLOOR(comptime T: type, numerator: T, denominator: T) T {
    return numerator / denominator;
}
