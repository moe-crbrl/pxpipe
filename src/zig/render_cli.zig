//! Small CLI that proves the Zig renderer end-to-end:
//!   render_cli <input.txt> <output.png>
//!
//! Reads text, renders via menlo5 atlas, encodes as 2-color indexed PNG with
//! libdeflate (zlib container for IDAT), writes the file. The output should
//! be visually identical to what the Python proxy produces and OCR-able by
//! Opus 4.7 at the same 99.7% accuracy we already measured.

const std = @import("std");
const menlo5 = @import("menlo5.zig");

const c = @cImport({
    @cInclude("libdeflate.h");
});

fn writePngChunk(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, chunk_type: *const [4]u8, data: []const u8) !void {
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(data.len), .big);
    try buf.appendSlice(alloc, &len_bytes);
    try buf.appendSlice(alloc, chunk_type);
    try buf.appendSlice(alloc, data);
    // CRC32 over chunk_type + data
    var crc_data = std.ArrayList(u8).empty;
    defer crc_data.deinit(alloc);
    try crc_data.appendSlice(alloc, chunk_type);
    try crc_data.appendSlice(alloc, data);
    const crc = std.hash.Crc32.hash(crc_data.items);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc, .big);
    try buf.appendSlice(alloc, &crc_bytes);
}

/// Encode 8-bit grayscale (0=black, 255=white) as a 2-color indexed PNG.
pub fn encodePng(alloc: std.mem.Allocator, pixels: []const u8, width: u32, height: u32) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    // PNG signature
    try out.appendSlice(alloc, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });

    // IHDR: 8-bit indexed color
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8;   // bit depth
    ihdr[9] = 3;   // color type 3 = indexed
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writePngChunk(&out, alloc, "IHDR", &ihdr);

    // PLTE: 2 colors (0=black, 1=white)
    const palette = [_]u8{ 0, 0, 0, 255, 255, 255 };
    try writePngChunk(&out, alloc, "PLTE", &palette);

    // IDAT: scanlines with filter byte. Map 255→1 (white), 0→0 (black).
    const stride = 1 + width;
    const raw = try alloc.alloc(u8, stride * height);
    defer alloc.free(raw);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const off = y * stride;
        raw[off] = 0; // filter: None
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            raw[off + 1 + x] = if (pixels[y * width + x] == 0) 0 else 1;
        }
    }

    // Compress with libdeflate (zlib format)
    const compressor = c.libdeflate_alloc_compressor(6) orelse return error.OutOfMemory;
    defer c.libdeflate_free_compressor(compressor);
    const bound = c.libdeflate_zlib_compress_bound(compressor, raw.len);
    const compressed = try alloc.alloc(u8, bound);
    defer alloc.free(compressed);
    const csize = c.libdeflate_zlib_compress(compressor, raw.ptr, raw.len, compressed.ptr, bound);
    if (csize == 0) return error.CompressFailed;

    try writePngChunk(&out, alloc, "IDAT", compressed[0..csize]);
    try writePngChunk(&out, alloc, "IEND", &[_]u8{});

    return out.toOwnedSlice(alloc);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var it = init.args.iterate();
    _ = it.next();
    const in_path = it.next() orelse {
        std.debug.print("usage: render_cli <input.txt> <output.png>\n", .{});
        return error.MissingArg;
    };
    const out_path = it.next() orelse return error.MissingArg;

    // Read input via libc to avoid 0.16 fs API churn
    const path_z = try std.fmt.allocPrintSentinel(alloc, "{s}", .{in_path}, 0);
    defer alloc.free(path_z);
    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    var tmp: [8192]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &tmp, tmp.len);
        if (n <= 0) break;
        try buf.appendSlice(alloc, tmp[0..@intCast(n)]);
    }
    const text = buf.items;

    // Render
    const r = try menlo5.renderText(alloc, text);
    defer alloc.free(r.pixels);
    std.debug.print("rendered: {d}x{d} ({d} px)\n", .{ r.width, r.height, r.width * r.height });

    // Encode
    const png = try encodePng(alloc, r.pixels, r.width, r.height);
    defer alloc.free(png);
    std.debug.print("png bytes: {d}\n", .{png.len});

    // Write via libc
    const out_z = try std.fmt.allocPrintSentinel(alloc, "{s}", .{out_path}, 0);
    defer alloc.free(out_z);
    const out_fd = std.c.open(out_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (out_fd < 0) return error.OpenFailed;
    defer _ = std.c.close(out_fd);
    _ = std.c.write(out_fd, png.ptr, png.len);
    std.debug.print("wrote {s}\n", .{out_path});
}
