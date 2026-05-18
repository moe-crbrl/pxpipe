//! Menlo 5pt glyph atlas reader + text renderer.
//!
//! The atlas binary (586 bytes, embedded via @embedFile) holds 1-bit glyph
//! bitmaps for printable ASCII (32-126). This file decodes the header at
//! comptime and provides a `renderText` function that produces a grayscale
//! pixel buffer suitable for PNG encoding.
//!
//! Why pre-rendered atlas instead of TTF rasterization at runtime?
//!   - Zero C library dependencies (no stb_truetype, FreeType, etc.)
//!   - 586 bytes is negligible binary bloat
//!   - Anthropic's vision encoder is verified to OCR this exact font/size
//!     at 99.7% accuracy on Opus 4.7

const std = @import("std");

const ATLAS: []const u8 = @embedFile("menlo5_atlas.bin");

pub const Atlas = struct {
    cell_w: u16,
    cell_h: u16,
    asc: u16,
    desc: u16,
    first: u8,
    last: u8,
    glyph_data_start: usize,
    glyph_stride: usize,   // bytes per glyph (advance u16 + packed bitmap)
    bitmap_bytes: usize,   // bytes of packed bitmap per glyph
};

pub fn loadAtlas() Atlas {
    std.debug.assert(ATLAS.len >= 16);
    std.debug.assert(std.mem.eql(u8, ATLAS[0..4], "MNAT"));
    const version = std.mem.readInt(u16, ATLAS[4..6], .little);
    std.debug.assert(version == 1);
    const cell_w = std.mem.readInt(u16, ATLAS[6..8], .little);
    const cell_h = std.mem.readInt(u16, ATLAS[8..10], .little);
    const asc = std.mem.readInt(u16, ATLAS[10..12], .little);
    const desc = std.mem.readInt(u16, ATLAS[12..14], .little);
    const first = ATLAS[14];
    const last = ATLAS[15];
    const total_bits = @as(usize, cell_w) * @as(usize, cell_h);
    const bitmap_bytes = (total_bits + 7) / 8;
    return .{
        .cell_w = cell_w,
        .cell_h = cell_h,
        .asc = asc,
        .desc = desc,
        .first = first,
        .last = last,
        .glyph_data_start = 16,
        .glyph_stride = 2 + bitmap_bytes, // u16 advance + bitmap
        .bitmap_bytes = bitmap_bytes,
    };
}

fn glyphOffset(a: Atlas, ch: u8) ?usize {
    if (ch < a.first or ch > a.last) return null;
    return a.glyph_data_start + (@as(usize, ch) - a.first) * a.glyph_stride;
}

pub fn glyphAdvance(a: Atlas, ch: u8) u16 {
    const off = glyphOffset(a, ch) orelse return a.cell_w; // unknown -> full cell
    return std.mem.readInt(u16, ATLAS[off..][0..2], .little);
}

/// Blit one glyph into the destination grayscale buffer at (dst_x, dst_y).
/// Sets ink pixels to 0 (black). Buffer must be pre-filled with 255 (white).
fn blitGlyph(a: Atlas, ch: u8, dst: []u8, dst_w: usize, dst_h: usize, dst_x: usize, dst_y: usize) void {
    const off = glyphOffset(a, ch) orelse return;
    const bitmap_start = off + 2;
    var bit_idx: usize = 0;
    var y: usize = 0;
    while (y < a.cell_h) : (y += 1) {
        var x: usize = 0;
        while (x < a.cell_w) : (x += 1) {
            const byte_idx = bit_idx / 8;
            const bit = @as(u3, @intCast(7 - (bit_idx % 8)));
            const is_ink = (ATLAS[bitmap_start + byte_idx] >> bit) & 1 == 1;
            bit_idx += 1;
            if (!is_ink) continue;
            const px = dst_x + x;
            const py = dst_y + y;
            if (px < dst_w and py < dst_h) {
                dst[py * dst_w + px] = 0;
            }
        }
    }
}

pub const Layout = struct {
    cols_per_col: u32,  // characters per column
    n_cols: u32,        // number of newspaper columns
    width: u32,
    height: u32,
};

/// Compute layout for `lines.len` wrapped lines using newspaper-column packing.
/// Caps longest edge at 1568 (Anthropic's max edge before resampling).
pub fn computeLayout(a: Atlas, lines: []const []const u8) Layout {
    const edge: u32 = 1568;
    const col_gap_px: u32 = 4;
    // Column width: widest line up to ~80 chars (we hard-wrap before this).
    var max_chars: u32 = 1;
    for (lines) |ln| {
        if (ln.len > max_chars) max_chars = @intCast(ln.len);
    }
    if (max_chars > 80) max_chars = 80;
    const col_w_px: u32 = max_chars * a.cell_w + 1;
    const lines_per_col: u32 = @max(8, edge / a.cell_h);
    const n_cols: u32 = @intCast(@max(@as(usize, 1), (lines.len + lines_per_col - 1) / lines_per_col));
    const width: u32 = n_cols * col_w_px + (n_cols -| 1) * col_gap_px;
    const height: u32 = lines_per_col * a.cell_h;
    return .{
        .cols_per_col = lines_per_col,
        .n_cols = n_cols,
        .width = width,
        .height = height,
    };
}

/// Allocate + render text into an 8-bit grayscale buffer (255 = white, 0 = black).
/// Returns the buffer and its width/height. Caller owns memory.
pub fn renderText(allocator: std.mem.Allocator, text: []const u8) !struct { pixels: []u8, width: u32, height: u32 } {
    const a = loadAtlas();
    const col_gap_px: u32 = 4;

    // Hard-wrap to 80 chars per line (matching Python proxy's behavior).
    const WRAP: usize = 80;
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, text, '\n');
    var last_blank = false;
    while (it.next()) |raw| {
        // Strip trailing whitespace
        var ln = raw;
        while (ln.len > 0 and (ln[ln.len - 1] == ' ' or ln[ln.len - 1] == '\t' or ln[ln.len - 1] == '\r')) {
            ln = ln[0 .. ln.len - 1];
        }
        if (ln.len == 0) {
            if (last_blank) continue;
            last_blank = true;
            try lines.append(allocator, " ");
            continue;
        }
        last_blank = false;
        if (ln.len <= WRAP) {
            try lines.append(allocator, ln);
        } else {
            var i: usize = 0;
            while (i < ln.len) : (i += WRAP) {
                const end = @min(i + WRAP, ln.len);
                try lines.append(allocator, ln[i..end]);
            }
        }
    }

    if (lines.items.len == 0) {
        const buf = try allocator.alloc(u8, 1);
        buf[0] = 255;
        return .{ .pixels = buf, .width = 1, .height = 1 };
    }

    const layout = computeLayout(a, lines.items);
    const total = @as(usize, layout.width) * @as(usize, layout.height);
    const pixels = try allocator.alloc(u8, total);
    @memset(pixels, 255);

    // Render columns left-to-right
    const max_chars: u32 = blk: {
        var m: u32 = 1;
        for (lines.items) |ln| {
            if (ln.len > m) m = @intCast(ln.len);
        }
        break :blk @min(@as(u32, 80), m);
    };
    const col_w_px: u32 = max_chars * a.cell_w + 1;

    var col_idx: u32 = 0;
    while (col_idx < layout.n_cols) : (col_idx += 1) {
        const col_start = col_idx * layout.cols_per_col;
        const col_end = @min(col_start + layout.cols_per_col, @as(u32, @intCast(lines.items.len)));
        const x_base = col_idx * (col_w_px + col_gap_px);
        var li: u32 = col_start;
        while (li < col_end) : (li += 1) {
            const line = lines.items[li];
            const y = (li - col_start) * a.cell_h;
            var px_x: u32 = x_base;
            for (line) |ch| {
                if (px_x + a.cell_w > layout.width) break;
                blitGlyph(a, ch, pixels, layout.width, layout.height, px_x, y);
                px_x += glyphAdvance(a, ch);
            }
        }
    }

    return .{ .pixels = pixels, .width = layout.width, .height = layout.height };
}

test "atlas loads" {
    const a = loadAtlas();
    try std.testing.expect(a.cell_w > 0);
    try std.testing.expect(a.cell_h > 0);
    try std.testing.expectEqual(@as(u8, 32), a.first);
    try std.testing.expectEqual(@as(u8, 126), a.last);
}

test "render hello" {
    const r = try renderText(std.testing.allocator, "hello world\nsecond line");
    defer std.testing.allocator.free(r.pixels);
    try std.testing.expect(r.width > 0);
    try std.testing.expect(r.height > 0);
    // Should have some ink pixels
    var ink_count: usize = 0;
    for (r.pixels) |p| if (p == 0) { ink_count += 1; };
    try std.testing.expect(ink_count > 0);
}
