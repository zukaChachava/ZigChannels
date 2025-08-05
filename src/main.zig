const std = @import("std");
const channels = @import("channels");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const channel = try channels.Channel(i32).init(allocator);
    defer channel.deinit();

    const writerThread = try std.Thread.spawn(.{}, writer, .{channel});
    const readerThread = try std.Thread.spawn(.{}, reader, .{channel});

    writerThread.join();
    readerThread.join();
}


fn writer(channel: *channels.Channel(i32)) !void {
    var i: i32 = 0;
    const writerChannel = channel.getWriter();

    while (i < 10) : (i += 1) {
        try writerChannel.write(i);
    }

    writerChannel.complete();
}

fn reader(channel: *channels.Channel(i32)) void {
    const readerChannel = channel.getReader();

    while(!channel.completed){
        const data = readerChannel.read();

        if(data == null)
            break;

        std.debug.print("Received data: {}\n", .{data.?});
    }

    std.debug.print("Reading completed\n", .{});
}
