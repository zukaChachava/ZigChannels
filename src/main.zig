const std = @import("std");
const channels = @import("channels");

pub fn main() !void {
    // try channelExample();
    try topicExample();
}

// -- Topic Example

fn topicExample() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try channels.Topic(i32).init(allocator);
    const writer = topic.createWriter();
    const firstReader = try topic.createReader();
    const secondReader = try topic.createReader();

    const writerThread = try std.Thread.spawn(.{}, topicWriter, .{writer});
    const firstReaderThread = try std.Thread.spawn(.{}, topicReader, .{firstReader, "FirstReader"});
    const secondReaderThread = try std.Thread.spawn(.{}, topicReader, .{secondReader, "SecondReader"});
    
    firstReaderThread.join();
    secondReaderThread.join();
    writerThread.join();

    topic.deinit();
}

fn topicWriter(writer: channels.TopicWriter(i32)) !void {
    var i: i32 = 0;

    while(i < 10) : (i += 1){
        try writer.write(i);
        //std.debug.print("Writing {}\n", .{i});
    }

    try writer.complete();
}

fn topicReader(reader: *channels.TopicReader(i32), readerName: []const u8) !void {
    while(reader.read()) | number | {
        std.debug.print("{s} : {any}\n", .{readerName, number});
    }
}

// -- Topic Example

// -- Channel Example

fn channelExample() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    
    const channel = try channels.Channel(i32).init(allocator);
    defer channel.deinit();

    const writerThread = try std.Thread.spawn(.{}, channelWriter, .{channel});
    const readerThread = try std.Thread.spawn(.{}, channelReader, .{channel});

    writerThread.join();
    readerThread.join();

    std.debug.print("Program finished\n", .{});
}

fn channelWriter(channel: *channels.Channel(i32)) !void {
    var i: i32 = 0;
    const writerChannel = channel.getWriter();

    while (i < 10) : (i += 1)
        try writerChannel.write(i);

    try writerChannel.complete();
}

fn channelReader(channel: *channels.Channel(i32)) void {
    const readerChannel = channel.getReader();
    var data = readerChannel.read();

    while (data != null) : (data = readerChannel.read())
        std.debug.print("Received Data: {any}\n", .{data});

    std.debug.print("Reading completed\n", .{});
}

// -- Channel Example
