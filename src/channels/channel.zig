const std = @import("std");
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const DoublyLinkedList = std.DoublyLinkedList;
const ChannelError = @import("./common.zig").ChannelError;

/// Creates a thread-safe point-to-point communication channel for type T.
///
/// A Channel provides FIFO (first-in-first-out) message passing between threads.
/// Messages sent by writers are received by readers in the order they were sent.
/// Only one reader will receive each message (point-to-point semantics).
///
/// The channel uses a mutex and condition variable for thread-safe operations
/// and efficient blocking when no data is available.
///
/// ## Example
/// ```zig
/// const channel = try Channel(i32).init(allocator);
/// defer channel.deinit();
///
/// const writer = channel.getWriter();
/// const reader = channel.getReader();
///
/// try writer.write(42);
/// const value = reader.read(); // Returns 42
/// ```
///
/// @param T The type of data that will be transmitted through the channel
/// @return A channel type that can be instantiated with init()
pub fn Channel(comptime T: type) type {
    return struct {
        allocator: Allocator,
        data: DoublyLinkedList(T),
        mutex: Thread.Mutex,
        signal: Thread.Condition,
        completed: bool,

        const Self = @This();

        /// Initializes a new channel instance.
        ///
        /// Creates and allocates memory for a new channel that can be used for
        /// thread-safe communication between producers and consumers.
        ///
        /// The channel starts in an uncompleted state and is ready to send/receive messages.
        /// You must call deinit() when done to prevent memory leaks.
        ///
        /// ## Example
        /// ```zig
        /// var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        /// const allocator = gpa.allocator();
        /// defer _ = gpa.deinit();
        ///
        /// const channel = try Channel(i32).init(allocator);
        /// defer channel.deinit();
        /// ```
        ///
        /// @param allocator The allocator to use for internal memory management
        /// @return A pointer to the newly created channel
        /// @error OutOfMemory if memory allocation fails
        pub fn init(allocator: Allocator) ChannelError!*Self {
            const channel = allocator.create(Self) catch |err| switch (err) {
                error.OutOfMemory => return ChannelError.OutOfMemory,
                else => unreachable,
            };

            channel.* = .{ .allocator = allocator, .data = DoublyLinkedList(T){}, .mutex = Thread.Mutex{}, .signal = Thread.Condition{}, .completed = false };

            return channel;
        }

        /// Creates a reader interface for receiving data from this channel.
        ///
        /// Returns a Reader instance that can be used to read messages from the channel.
        /// The reader will block when no data is available and wake up when new data
        /// is written to the channel.
        ///
        /// Multiple readers can be created, but each message will only be received
        /// by one reader (point-to-point semantics).
        ///
        /// ## Example
        /// ```zig
        /// const reader = channel.getReader();
        /// const data = reader.read(); // Blocks until data is available
        /// ```
        ///
        /// @param self Pointer to the channel instance
        /// @return A Reader instance for this channel
        pub fn getReader(self: *Self) Reader(T) {
            return .{ .channel = self };
        }

        /// Creates a writer interface for sending data to this channel.
        ///
        /// Returns a Writer instance that can be used to send messages to the channel.
        /// The writer is lightweight and can be copied freely.
        ///
        /// Multiple writers can send to the same channel safely.
        ///
        /// ## Example
        /// ```zig
        /// const writer = channel.getWriter();
        /// try writer.write(42); // Send data to the channel
        /// ```
        ///
        /// @param self Pointer to the channel instance
        /// @return A Writer instance for this channel
        pub fn getWriter(self: *Self) Writer(T) {
            return .{ .channel = self };
        }

        /// Cleans up channel resources and deallocates memory.
        ///
        /// Destroys all remaining messages in the channel queue and deallocates
        /// the channel itself. This must be called when the channel is no longer
        /// needed to prevent memory leaks.
        ///
        /// After calling deinit(), the channel pointer becomes invalid and should
        /// not be used.
        ///
        /// ## Example
        /// ```zig
        /// const channel = try Channel(i32).init(allocator);
        /// defer channel.deinit(); // Recommended pattern
        ///
        /// // Or manually:
        /// channel.deinit();
        /// ```
        ///
        /// @param self Pointer to the channel instance
        pub fn deinit(self: *Self) void {
            while (self.data.len != 0) {
                const node = self.data.popFirst().?;
                self.allocator.destroy(node);
            }

            self.allocator.destroy(self);
        }
    };
}

/// Writer interface for sending data to a channel.
///
/// A Writer provides a thread-safe interface for sending messages to a channel.
/// Writers are lightweight handles that contain only a pointer to the channel,
/// making them cheap to copy and pass around.
///
/// Multiple writers can safely write to the same channel concurrently.
/// Messages are delivered to readers in FIFO order.
///
/// ## Thread Safety
/// All Writer operations are thread-safe and can be called from multiple
/// threads simultaneously.
///
/// @param T The type of data that can be written to the channel
pub fn Writer(comptime T: type) type {
    return struct {
        channel: *Channel(T),
        const Self = @This();

        /// Writes a message to the channel.
        ///
        /// Sends data to the channel, making it available for readers to consume.
        /// If the channel has been completed (via complete()), this operation will
        /// return an error.
        ///
        /// The operation is atomic and thread-safe. After successfully writing,
        /// any waiting readers will be notified via condition variable signaling.
        ///
        /// ## Behavior
        /// - If readers are waiting, one reader will be woken up immediately
        /// - If no readers are waiting, the message is queued for later consumption
        /// - Messages are delivered to readers in FIFO order
        ///
        /// ## Example
        /// ```zig
        /// const writer = channel.getWriter();
        /// try writer.write(42);
        /// try writer.write("hello");
        /// ```
        ///
        /// @param self The writer instance
        /// @param data The data to send to the channel
        /// @error ChannelClosed if the channel has been completed
        /// @error OutOfMemory if memory allocation for the message fails
        pub fn write(self: Self, data: T) ChannelError!void {
            self.channel.mutex.lock();
            defer self.channel.mutex.unlock();

            if (self.channel.completed)
                return ChannelError.ChannelClosed;

            const node = self.channel.allocator.create(std.DoublyLinkedList(T).Node) catch |err| switch (err) {
                error.OutOfMemory => return ChannelError.OutOfMemory,
                else => unreachable,
            };

            node.data = data;
            self.channel.data.append(node);
            self.channel.signal.signal();
        }

        /// Marks the channel as completed, signaling no more data will be sent.
        ///
        /// Completes the channel, indicating that no more messages will be written.
        /// This causes all current and future readers to eventually return null
        /// after consuming any remaining messages.
        ///
        /// After completion:
        /// - New write() calls will return ChannelError.ChannelClosed
        /// - Additional complete() calls will return ChannelError.ChannelClosed
        /// - Readers will return null after consuming remaining messages
        /// - All waiting readers are immediately notified via broadcast
        ///
        /// ## Example
        /// ```zig
        /// const writer = channel.getWriter();
        /// try writer.write(1);
        /// try writer.write(2);
        /// try writer.complete(); // Signal end of data
        ///
        /// // This would return an error:
        /// // try writer.write(3); // ChannelError.ChannelClosed
        /// ```
        ///
        /// @param self The writer instance
        /// @error ChannelClosed if the channel is already completed
        pub fn complete(self: Self) ChannelError!void {
            self.channel.mutex.lock();
            defer self.channel.mutex.unlock();

            if (self.channel.completed)
                return ChannelError.ChannelClosed;

            self.channel.completed = true;
            self.channel.signal.broadcast();
        }
    };
}

/// Reader interface for receiving data from a channel.
///
/// A Reader provides a thread-safe interface for receiving messages from a channel.
/// Readers are lightweight handles that contain only a pointer to the channel,
/// making them cheap to copy and pass around.
///
/// Multiple readers can safely read from the same channel concurrently, but each
/// message will only be delivered to one reader (point-to-point semantics).
/// Messages are received in FIFO order.
///
/// ## Thread Safety
/// All Reader operations are thread-safe and can be called from multiple
/// threads simultaneously.
///
/// ## Blocking Behavior
/// The read() operation will block if no data is available and the channel
/// is not completed, using efficient condition variable waiting (no busy-polling).
///
/// @param T The type of data that can be read from the channel
pub fn Reader(comptime T: type) type {
    return struct {
        channel: *Channel(T),

        const Self = @This();

        /// Reads a message from the channel.
        ///
        /// Attempts to read data from the channel. The behavior depends on the
        /// current state of the channel:
        ///
        /// - **Data available**: Returns the next message immediately
        /// - **No data, channel open**: Blocks until data arrives or channel is completed
        /// - **No data, channel completed**: Returns null immediately
        ///
        /// The operation is atomic and thread-safe. When multiple readers are
        /// waiting, only one will receive each message (point-to-point semantics).
        ///
        /// ## Blocking Behavior
        /// This method uses condition variables for efficient blocking. When no data
        /// is available, the calling thread will sleep (not consume CPU) until:
        /// - A writer sends new data (wakes up via signal())
        /// - The channel is completed (wakes up via broadcast())
        ///
        /// ## Return Values
        /// - `T`: The next message from the channel
        /// - `null`: The channel is completed and no more messages are available
        ///
        /// ## Example
        /// ```zig
        /// const reader = channel.getReader();
        ///
        /// // Read messages until channel is completed
        /// while (reader.read()) |data| {
        ///     std.debug.print("Received: {}\n", .{data});
        /// }
        /// std.debug.print("Channel completed\n");
        /// ```
        ///
        /// @param self The reader instance
        /// @return The next message from the channel, or null if completed
        pub fn read(self: Self) ?T {
            self.channel.mutex.lock();
            defer self.channel.mutex.unlock();

            while (self.channel.data.len == 0) {
                if (self.channel.completed)
                    return null;

                self.channel.signal.wait(&self.channel.mutex);
            }

            const node = self.channel.data.popFirst().?;
            defer self.channel.allocator.destroy(node);

            return node.data;
        }
    };
}

// Tests
const testing = std.testing;

test "Channel init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel(i32).init(allocator);
    defer channel.deinit();

    try testing.expect(channel.completed == false);
    try testing.expect(channel.data.len == 0);
}

test "Channel basic write and read" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel(i32).init(allocator);
    defer channel.deinit();

    const writer = channel.getWriter();
    const reader = channel.getReader();

    try writer.write(42);
    const data = reader.read();

    try testing.expect(data != null);
    try testing.expectEqual(@as(i32, 42), data.?);
}

test "Channel multiple writes and reads" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel(i32).init(allocator);
    defer channel.deinit();

    const writer = channel.getWriter();
    const reader = channel.getReader();

    // Write multiple values
    try writer.write(1);
    try writer.write(2);
    try writer.write(3);

    // Read them back in order (FIFO)
    try testing.expectEqual(@as(i32, 1), reader.read().?);
    try testing.expectEqual(@as(i32, 2), reader.read().?);
    try testing.expectEqual(@as(i32, 3), reader.read().?);
}

test "Channel completion" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel(i32).init(allocator);
    defer channel.deinit();

    const writer = channel.getWriter();
    const reader = channel.getReader();

    try writer.complete();
    const data = reader.read();

    try testing.expect(data == null);
    try testing.expect(channel.completed == true);
}

test "Write to completed channel returns error" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel(i32).init(allocator);
    defer channel.deinit();

    const writer = channel.getWriter();

    try writer.complete();

    const result = writer.write(42);
    try testing.expectError(ChannelError.ChannelClosed, result);
}

test "Complete already completed channel returns error" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel(i32).init(allocator);
    defer channel.deinit();

    const writer = channel.getWriter();

    try writer.complete();

    const result = writer.complete();
    try testing.expectError(ChannelError.ChannelClosed, result);
}

test "Channel with string data" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel([]const u8).init(allocator);
    defer channel.deinit();

    const writer = channel.getWriter();
    const reader = channel.getReader();

    try writer.write("hello");
    try writer.write("world");

    const data1 = reader.read();
    const data2 = reader.read();

    try testing.expect(data1 != null);
    try testing.expect(data2 != null);
    try testing.expectEqualStrings("hello", data1.?);
    try testing.expectEqualStrings("world", data2.?);
}

test "Channel read from completed channel with remaining data" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel(i32).init(allocator);
    defer channel.deinit();

    const writer = channel.getWriter();
    const reader = channel.getReader();

    // Write data first
    try writer.write(100);
    try writer.write(200);

    // Then complete the channel
    try writer.complete();

    // Should still be able to read existing data
    try testing.expectEqual(@as(i32, 100), reader.read().?);
    try testing.expectEqual(@as(i32, 200), reader.read().?);

    // After all data is consumed, should return null
    try testing.expect(reader.read() == null);
}

test "Channel with different data types" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test with bool
    {
        const channel = try Channel(bool).init(allocator);
        defer channel.deinit();

        const writer = channel.getWriter();
        const reader = channel.getReader();

        try writer.write(true);
        try testing.expectEqual(true, reader.read().?);
    }

    // Test with f64
    {
        const channel = try Channel(f64).init(allocator);
        defer channel.deinit();

        const writer = channel.getWriter();
        const reader = channel.getReader();

        try writer.write(3.14159);
        try testing.expectEqual(@as(f64, 3.14159), reader.read().?);
    }
}

test "Channel threaded producer consumer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel(i32).init(allocator);
    defer channel.deinit();

    const Context = struct {
        channel: *Channel(i32),
        sum: *i32,
        mutex: *Thread.Mutex,
    };

    var sum: i32 = 0;
    var sum_mutex = Thread.Mutex{};

    const context = Context{
        .channel = channel,
        .sum = &sum,
        .mutex = &sum_mutex,
    };

    const producer = try Thread.spawn(.{}, struct {
        fn run(ctx: Context) !void {
            const writer = ctx.channel.getWriter();
            var i: i32 = 1;
            while (i <= 10) : (i += 1) {
                try writer.write(i);
                std.time.sleep(1_000_000); // 1ms delay
            }
            try writer.complete();
        }
    }.run, .{context});

    const consumer = try Thread.spawn(.{}, struct {
        fn run(ctx: Context) void {
            const reader = ctx.channel.getReader();
            while (reader.read()) |data| {
                ctx.mutex.lock();
                ctx.sum.* += data;
                ctx.mutex.unlock();
            }
        }
    }.run, .{context});

    producer.join();
    consumer.join();

    try testing.expectEqual(@as(i32, 55), sum); // 1+2+...+10 = 55
}

test "Channel multiple producers single consumer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel(i32).init(allocator);
    defer channel.deinit();

    const Context = struct {
        channel: *Channel(i32),
        sum: *i32,
        mutex: *Thread.Mutex,
        producer_id: i32,
    };

    var sum: i32 = 0;
    var sum_mutex = Thread.Mutex{};

    const producer1_ctx = Context{
        .channel = channel,
        .sum = &sum,
        .mutex = &sum_mutex,
        .producer_id = 1,
    };

    const producer2_ctx = Context{
        .channel = channel,
        .sum = &sum,
        .mutex = &sum_mutex,
        .producer_id = 2,
    };

    const consumer_ctx = Context{
        .channel = channel,
        .sum = &sum,
        .mutex = &sum_mutex,
        .producer_id = 0,
    };

    const producer1 = try Thread.spawn(.{}, struct {
        fn run(ctx: Context) !void {
            const writer = ctx.channel.getWriter();
            var i: i32 = 1;
            while (i <= 5) : (i += 1) {
                try writer.write(ctx.producer_id * 10 + i); // 11, 12, 13, 14, 15
            }
        }
    }.run, .{producer1_ctx});

    const producer2 = try Thread.spawn(.{}, struct {
        fn run(ctx: Context) !void {
            const writer = ctx.channel.getWriter();
            var i: i32 = 1;
            while (i <= 5) : (i += 1) {
                try writer.write(ctx.producer_id * 10 + i); // 21, 22, 23, 24, 25
            }
        }
    }.run, .{producer2_ctx});

    const consumer = try Thread.spawn(.{}, struct {
        fn run(ctx: Context) void {
            const reader = ctx.channel.getReader();
            var count: i32 = 0;
            while (count < 10) : (count += 1) {
                if (reader.read()) |data| {
                    ctx.mutex.lock();
                    ctx.sum.* += data;
                    ctx.mutex.unlock();
                }
            }
        }
    }.run, .{consumer_ctx});

    producer1.join();
    producer2.join();

    // Complete the channel after producers finish
    try channel.getWriter().complete();

    consumer.join();

    // Sum should be (11+12+13+14+15) + (21+22+23+24+25) = 65 + 115 = 180
    try testing.expectEqual(@as(i32, 180), sum);
}
