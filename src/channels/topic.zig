const std = @import("std");
const ChannelError = @import("./common.zig").ChannelError;
const Thread = std.Thread;
const ArrayList = std.ArrayList;
const ArrayHashMap = std.AutoArrayHashMap;
const DoublyLinkedList = std.DoublyLinkedList;
const Allocator = std.mem.Allocator;

/// Creates a thread-safe publish-subscribe communication topic for type T.
///
/// A Topic provides one-to-many message broadcasting between threads.
/// Messages published by writers are delivered to ALL subscribers (readers)
/// in FIFO order. Each subscriber receives their own copy of every message.
///
/// Unlike channels which provide point-to-point communication, topics implement
/// the publish-subscribe pattern where one message reaches multiple recipients.
///
/// The topic uses a mutex and condition variable for thread-safe operations
/// and efficient blocking when no data is available.
///
/// ## Example
/// ```zig
/// const topic = try Topic(i32).init(allocator);
/// defer topic.deinit();
///
/// const reader1 = try topic.createReader();
/// const reader2 = try topic.createReader();
/// defer reader1.deinit();
/// defer reader2.deinit();
///
/// const writer = topic.createWriter();
/// try writer.write(42); // Both readers receive 42
/// ```
///
/// @param T The type of data that will be broadcast through the topic
/// @return A topic type that can be instantiated with init()
pub fn Topic(comptime T: type) type {
    return struct {
        readers: ArrayHashMap(usize, *Reader(T)),
        allocator: Allocator,
        mutex: Thread.Mutex,
        condition: Thread.Condition,
        completed: bool,
        readerIndex: usize,

        const Self = @This();

        /// Initializes a new topic instance.
        ///
        /// Creates and allocates memory for a new topic that can be used for
        /// thread-safe publish-subscribe communication between publishers and subscribers.
        ///
        /// The topic starts in an uncompleted state and is ready to accept subscribers
        /// and publish messages. You must call deinit() when done to prevent memory leaks.
        ///
        /// ## Example
        /// ```zig
        /// var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        /// const allocator = gpa.allocator();
        /// defer _ = gpa.deinit();
        ///
        /// const topic = try Topic(i32).init(allocator);
        /// defer topic.deinit();
        /// ```
        ///
        /// @param allocator The allocator to use for internal memory management
        /// @return A pointer to the newly created topic
        /// @error OutOfMemory if memory allocation fails
        pub fn init(allocator: Allocator) ChannelError!*Self {
            const topic = allocator.create(Self) catch |err| switch (err) {
                error.OutOfMemory => return ChannelError.OutOfMemory,
                else => unreachable,
            };

            topic.* = .{
                .allocator = allocator,
                .readers = ArrayHashMap(usize, *Reader(T)).init(allocator),
                .mutex = Thread.Mutex{},
                .completed = false,
                .readerIndex = 0,
                .condition = Thread.Condition{},
            };

            return topic;
        }

        /// Creates a new subscriber reader for this topic.
        ///
        /// Creates a new reader that will receive ALL messages published to this topic.
        /// Each reader has its own message queue and receives a copy of every message
        /// published after subscription begins.
        ///
        /// Readers created before messages are published will receive all messages.
        /// Each reader operates independently and can consume messages at its own pace.
        ///
        /// The reader must be cleaned up by calling its deinit() method when no longer needed.
        ///
        /// ## Behavior
        /// - Each reader gets its own unique ID and message queue
        /// - All readers receive every message published to the topic
        /// - Readers can be created and destroyed dynamically
        /// - Multiple readers can read concurrently without affecting each other
        ///
        /// ## Example
        /// ```zig
        /// const reader1 = try topic.createReader();
        /// const reader2 = try topic.createReader();
        /// defer reader1.deinit();
        /// defer reader2.deinit();
        ///
        /// // Both readers will receive the same messages
        /// ```
        ///
        /// @param self Pointer to the topic instance
        /// @return A pointer to the newly created reader
        /// @error OutOfMemory if memory allocation fails
        pub fn createReader(self: *Self) ChannelError!*Reader(T) {
            self.mutex.lock();
            defer self.mutex.unlock();
            const id = self.readerIndex;
            self.readerIndex += 1;

            const reader = try Reader(T).init(id, self);
            self.readers.put(id, reader) catch |err| switch (err) {
                error.OutOfMemory => return ChannelError.OutOfMemory,
                else => unreachable,
            };

            return reader;
        }

        /// Creates a writer interface for publishing data to all subscribers.
        ///
        /// Returns a Writer instance that can be used to broadcast messages to all
        /// subscribers of this topic. The writer is lightweight and can be copied freely.
        ///
        /// Multiple writers can publish to the same topic safely. Each message
        /// will be delivered to all current subscribers.
        ///
        /// ## Example
        /// ```zig
        /// const writer = topic.createWriter();
        /// try writer.write(42); // Broadcast to all subscribers
        /// try writer.complete(); // Signal end of publishing
        /// ```
        ///
        /// @param self Pointer to the topic instance
        /// @return A Writer instance for this topic
        pub fn createWriter(self: *Self) Writer(T) {
            return .{ .topic = self };
        }

        fn removeReader(self: *Self, id: usize) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            _ = self.readers.swapRemove(id);
        }

        /// Cleans up topic resources and all associated readers.
        ///
        /// Destroys all subscriber readers and their message queues, then deallocates
        /// the topic itself. This must be called when the topic is no longer needed
        /// to prevent memory leaks.
        ///
        /// All associated readers will be automatically cleaned up, so you should not
        /// call deinit() on individual readers after calling topic.deinit().
        ///
        /// After calling deinit(), the topic pointer becomes invalid and should
        /// not be used.
        ///
        /// ## Example
        /// ```zig
        /// const topic = try Topic(i32).init(allocator);
        /// defer topic.deinit(); // Recommended pattern
        ///
        /// const reader = try topic.createReader();
        /// // reader.deinit() is NOT needed - topic.deinit() handles it
        /// ```
        ///
        /// @param self Pointer to the topic instance
        pub fn deinit(self: *Self) void {
            var iterator = self.readers.iterator();

            while (iterator.next()) |entry| {
                const reader = entry.value_ptr.*;
                reader.deinitFromTopic();
            }

            self.readers.deinit();
            self.allocator.destroy(self);
        }
    };
}

/// Writer interface for publishing data to all subscribers of a topic.
///
/// A Writer provides a thread-safe interface for broadcasting messages to all
/// subscribers of a topic. Writers are lightweight handles that contain only
/// a pointer to the topic, making them cheap to copy and pass around.
///
/// Multiple writers can safely publish to the same topic concurrently.
/// Each message published will be delivered to ALL current subscribers.
///
/// ## Thread Safety
/// All Writer operations are thread-safe and can be called from multiple
/// threads simultaneously.
///
/// ## Broadcasting Behavior
/// When a message is written, it is copied to every subscriber's personal queue.
/// This means the topic uses more memory than channels (O(n) where n is the number
/// of subscribers), but provides true broadcast semantics.
///
/// @param T The type of data that can be published to the topic
pub fn Writer(comptime T: type) type {
    return struct {
        topic: *Topic(T),

        const Self = @This();

        fn init(topic: *Topic(T)) Self {
            return .{ .topic = topic };
        }

        /// Publishes a message to all subscribers of the topic.
        ///
        /// Broadcasts data to all current subscribers of the topic. Each subscriber
        /// will receive their own copy of the message in their personal queue.
        /// If the topic has been completed (via complete()), this operation will
        /// return an error.
        ///
        /// The operation is atomic and thread-safe. The message is copied to all
        /// subscriber queues before any subscriber is notified, ensuring consistent
        /// delivery.
        ///
        /// ## Behavior
        /// - Message is copied to every current subscriber's queue
        /// - All waiting subscribers are notified via broadcast signal
        /// - If no subscribers exist, the message is effectively discarded
        /// - Messages are delivered to each subscriber in FIFO order
        /// - Performance is O(n) where n is the number of subscribers
        ///
        /// ## Example
        /// ```zig
        /// const writer = topic.createWriter();
        /// try writer.write(42);        // All subscribers receive 42
        /// try writer.write("hello");   // All subscribers receive "hello"
        /// ```
        ///
        /// @param self The writer instance
        /// @param item The data to broadcast to all subscribers
        /// @error ChannelClosed if the topic has been completed
        /// @error OutOfMemory if memory allocation for any subscriber's copy fails
        pub fn write(self: Self, item: T) ChannelError!void {
            self.topic.mutex.lock();
            defer self.topic.mutex.unlock();

            if (self.topic.completed)
                return ChannelError.ChannelClosed;

            var iterator = self.topic.readers.iterator();

            while (iterator.next()) |entry| {
                const reader = entry.value_ptr.*;

                var node = self.topic.allocator.create(DoublyLinkedList(T).Node) catch |err| switch (err) {
                    error.OutOfMemory => return ChannelError.OutOfMemory,
                    else => unreachable,
                };

                node.data = item;
                reader.data.append(node);
            }

            self.topic.condition.broadcast();
        }

        /// Completes the topic, preventing further message publication.
        ///
        /// Marks the topic as completed and signals all current and future
        /// subscribers that no more messages will be published. Any subscribers
        /// currently waiting for messages will be notified immediately.
        ///
        /// After completion:
        /// - All write() operations will return ChannelClosed error
        /// - Existing messages in subscriber queues remain available
        /// - New subscribers will immediately receive ChannelClosed on read()
        /// - Existing subscribers will receive ChannelClosed after consuming their queues
        ///
        /// ## Thread Safety
        /// This operation is atomic and thread-safe. Once completed, the topic
        /// state is permanent and cannot be reversed.
        ///
        /// ## Error Handling
        /// Returns ChannelClosed if the topic has already been completed.
        /// This prevents double-completion which could lead to inconsistent state.
        ///
        /// ## Example
        /// ```zig
        /// const writer = topic.createWriter();
        /// try writer.write(1);
        /// try writer.write(2);
        /// try writer.complete();      // Signal completion
        /// // writer.write(3);         // Would return ChannelClosed error
        /// // writer.complete();       // Would also return ChannelClosed error
        /// ```
        ///
        /// @param self The writer instance
        /// @error ChannelClosed if the topic has already been completed
        pub fn complete(self: Self) ChannelError!void {
            self.topic.mutex.lock();
            defer self.topic.mutex.unlock();

            if (self.topic.completed)
                return ChannelError.ChannelClosed;

            self.topic.completed = true;
            self.topic.condition.broadcast();
        }
    };
}

/// Creates a subscriber reader type for a topic-based communication channel.
///
/// A Reader represents a subscriber in the publish-subscribe pattern. Each reader
/// maintains its own independent message queue and receives copies of all messages
/// published to the topic after the reader was created. Messages are delivered
/// in FIFO order and each reader processes messages independently.
///
/// ## Key Characteristics
/// - Each reader has a unique ID within the topic
/// - Independent message queue per reader (no message sharing)
/// - FIFO message delivery per subscriber
/// - Thread-safe read operations with blocking support
/// - Automatic cleanup when reader is destroyed
/// - Receives all messages published after reader creation
///
/// ## Memory Management
/// Readers are heap-allocated and must be properly deallocated using deinit().
/// Each reader maintains its own copy of published messages, so memory usage
/// scales with (number of readers × number of unread messages).
///
/// ## Thread Safety
/// Multiple readers can safely operate concurrently. Each reader's queue
/// is independent and protected by the topic's shared mutex.
///
/// @param T The type of data that will be published and received
/// @return A type that can be instantiated to create topic subscribers
pub fn Reader(comptime T: type) type {
    return struct {
        id: usize,
        allocator: Allocator,
        data: DoublyLinkedList(T),
        topic: *Topic(T),

        const Self = @This();

        fn init(id: usize, topic: *Topic(T)) ChannelError!*Self {
            const reader = topic.allocator.create(Self) catch |err| switch (err) {
                error.OutOfMemory => return ChannelError.OutOfMemory,
                else => unreachable,
            };

            reader.* = .{
                .id = id,
                .allocator = topic.allocator,
                .data = DoublyLinkedList(T){},
                .topic = topic,
            };

            return reader;
        }

        /// Reads the next message from this subscriber's queue.
        ///
        /// Retrieves the oldest unread message from this reader's personal queue.
        /// If no messages are available, the calling thread will block until either:
        /// - A new message is published (and copied to this reader's queue)
        /// - The topic is completed by a writer
        ///
        /// ## Blocking Behavior
        /// This operation blocks the calling thread when the queue is empty and
        /// the topic is still active. The thread will be awakened when:
        /// - A writer publishes a new message (via write())
        /// - A writer completes the topic (via complete())
        ///
        /// ## Message Ordering
        /// Messages are delivered in FIFO order per subscriber. Each reader
        /// receives messages independently - reading from one reader does not
        /// affect other readers' queues.
        ///
        /// ## Completion Handling
        /// When the topic is completed and this reader's queue is empty,
        /// read() returns null to indicate no more messages will arrive.
        /// Any remaining messages in the queue can still be read normally.
        ///
        /// ## Thread Safety
        /// Safe to call from multiple threads, though typically each reader
        /// is used by a single consumer thread for message processing.
        ///
        /// ## Example
        /// ```zig
        /// const reader = try topic.createReader();
        /// defer reader.deinit();
        ///
        /// while (reader.read()) |message| {
        ///     std.debug.print("Received: {}\n", .{message});
        /// }
        /// std.debug.print("Topic completed, no more messages\n");
        /// ```
        ///
        /// @param self Pointer to the reader instance
        /// @return The next message, or null if topic is completed and queue is empty
        pub fn read(self: *Self) ?T {
            self.topic.mutex.lock();
            defer self.topic.mutex.unlock();

            while (self.data.len == 0) {
                if (self.topic.completed)
                    return null;

                self.topic.condition.wait(&self.topic.mutex);
            }

            const node = self.data.popFirst().?;
            defer self.topic.allocator.destroy(node);
            return node.data;
        }

        // Info: just destroys object, the pointer to this object still remains in topic
        fn deinitFromTopic(self: *Self) void {
            while (self.data.popFirst()) |node| {
                self.allocator.destroy(node);
            }

            self.allocator.destroy(self);
        }

        /// Destroys the reader and cleans up all associated resources.
        ///
        /// Properly deallocates the reader and removes it from the topic's
        /// subscriber list. This includes:
        /// - Draining and freeing all unread messages in the reader's queue
        /// - Removing the reader from the topic's subscriber registry
        /// - Deallocating the reader instance itself
        ///
        /// ## Thread Safety
        /// This operation is thread-safe and can be called while other readers
        /// or writers are active. The removal from the topic is atomic.
        ///
        /// ## Important Notes
        /// - Must be called for every reader created via createReader()
        /// - After calling deinit(), the reader pointer becomes invalid
        /// - Unread messages in the queue are permanently lost
        /// - This does NOT affect other readers or the topic itself
        ///
        /// ## Memory Management
        /// Failure to call deinit() will result in memory leaks, as each reader
        /// maintains its own message queue and allocates memory for received messages.
        ///
        /// ## Example
        /// ```zig
        /// const reader = try topic.createReader();
        ///
        /// // Use the reader...
        /// while (reader.read()) |message| {
        ///     // Process message
        /// }
        ///
        /// reader.deinit(); // Clean up - required!
        /// // reader is now invalid and cannot be used
        /// ```
        ///
        /// @param self Pointer to the reader instance to destroy
        // Info: removes reader from topic and destroys object
        pub fn deinit(self: *Self) void {
            while (self.data.popFirst()) |node| {
                self.allocator.destroy(node);
            }

            self.topic.removeReader(self.id); // Info: lock is used inside function
            self.allocator.destroy(self);
        }
    };
}

// Tests
const testing = std.testing;

test "Topic init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    try testing.expect(topic.completed == false);
    try testing.expect(topic.readerIndex == 0);
}

test "Topic create single reader" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const reader = try topic.createReader();
    defer reader.deinit();

    try testing.expect(reader.id == 0);
    try testing.expect(topic.readerIndex == 1);
}

test "Topic create multiple readers" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const reader1 = try topic.createReader();
    const reader2 = try topic.createReader();
    const reader3 = try topic.createReader();

    defer reader1.deinit();
    defer reader2.deinit();
    defer reader3.deinit();

    try testing.expect(reader1.id == 0);
    try testing.expect(reader2.id == 1);
    try testing.expect(reader3.id == 2);
    try testing.expect(topic.readerIndex == 3);
}

test "Topic writer write and reader read" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const writer = topic.createWriter();
    const reader = try topic.createReader();
    defer reader.deinit();

    try writer.write(42);

    const data = reader.read();
    try testing.expect(data != null);
    try testing.expectEqual(@as(i32, 42), data.?);
}

test "Topic broadcast to multiple readers" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const writer = topic.createWriter();
    const reader1 = try topic.createReader();
    const reader2 = try topic.createReader();
    const reader3 = try topic.createReader();

    defer reader1.deinit();
    defer reader2.deinit();
    defer reader3.deinit();

    // Write one message - all readers should receive it
    try writer.write(100);

    // All readers should get the same message
    try testing.expectEqual(@as(i32, 100), reader1.read().?);
    try testing.expectEqual(@as(i32, 100), reader2.read().?);
    try testing.expectEqual(@as(i32, 100), reader3.read().?);
}

test "Topic multiple messages to multiple readers" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const writer = topic.createWriter();
    const reader1 = try topic.createReader();
    const reader2 = try topic.createReader();

    defer reader1.deinit();
    defer reader2.deinit();

    // Write multiple messages
    try writer.write(1);
    try writer.write(2);
    try writer.write(3);

    // Reader1 should receive all messages in order
    try testing.expectEqual(@as(i32, 1), reader1.read().?);
    try testing.expectEqual(@as(i32, 2), reader1.read().?);
    try testing.expectEqual(@as(i32, 3), reader1.read().?);

    // Reader2 should also receive all messages in order
    try testing.expectEqual(@as(i32, 1), reader2.read().?);
    try testing.expectEqual(@as(i32, 2), reader2.read().?);
    try testing.expectEqual(@as(i32, 3), reader2.read().?);
}

test "Topic completion" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const writer = topic.createWriter();
    const reader = try topic.createReader();
    defer reader.deinit();

    try writer.complete();

    try testing.expect(topic.completed == true);

    // Reading from completed topic should return null
    const data = reader.read();
    try testing.expect(data == null);
}

test "Write to completed topic returns error" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const writer = topic.createWriter();

    try writer.complete();

    const result = writer.write(42);
    try testing.expectError(ChannelError.ChannelClosed, result);
}

test "Complete already completed topic returns error" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const writer = topic.createWriter();

    try writer.complete();

    const result = writer.complete();
    try testing.expectError(ChannelError.ChannelClosed, result);
}

test "Topic read from completed topic with remaining data" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const writer = topic.createWriter();
    const reader = try topic.createReader();
    defer reader.deinit();

    // Write data first
    try writer.write(100);
    try writer.write(200);

    // Then complete the topic
    try writer.complete();

    // Should still be able to read existing data
    try testing.expectEqual(@as(i32, 100), reader.read().?);
    try testing.expectEqual(@as(i32, 200), reader.read().?);

    // After all data is consumed, should return null
    try testing.expect(reader.read() == null);
}

test "Topic with different data types" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test with bool
    {
        const topic = try Topic(bool).init(allocator);
        defer topic.deinit();

        const writer = topic.createWriter();
        const reader = try topic.createReader();
        defer reader.deinit();

        try writer.write(true);
        try testing.expectEqual(true, reader.read().?);
    }

    // Test with f64
    {
        const topic = try Topic(f64).init(allocator);
        defer topic.deinit();

        const writer = topic.createWriter();
        const reader = try topic.createReader();
        defer reader.deinit();

        try writer.write(3.14159);
        try testing.expectEqual(@as(f64, 3.14159), reader.read().?);
    }

    // Test with strings
    {
        const topic = try Topic([]const u8).init(allocator);
        defer topic.deinit();

        const writer = topic.createWriter();
        const reader = try topic.createReader();
        defer reader.deinit();

        try writer.write("hello");
        try testing.expectEqualStrings("hello", reader.read().?);
    }
}

test "Topic reader removal" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const writer = topic.createWriter();
    const reader1 = try topic.createReader();
    const reader2 = try topic.createReader();

    // reader2 will be cleaned up manually
    defer reader1.deinit();

    // Write message to both readers
    try writer.write(42);

    // Both readers should receive the message
    try testing.expectEqual(@as(i32, 42), reader1.read().?);
    try testing.expectEqual(@as(i32, 42), reader2.read().?);

    // Remove reader2
    reader2.deinit();

    // Write another message - only reader1 should receive it
    try writer.write(100);
    try testing.expectEqual(@as(i32, 100), reader1.read().?);
}

test "Topic threaded producer consumer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const Context = struct {
        topic: *Topic(i32),
        sum: *i32,
        mutex: *std.Thread.Mutex,
        reader_id: u8,
    };

    var sum1: i32 = 0;
    var sum2: i32 = 0;
    var sum_mutex = std.Thread.Mutex{};

    const context1 = Context{
        .topic = topic,
        .sum = &sum1,
        .mutex = &sum_mutex,
        .reader_id = 1,
    };

    const context2 = Context{
        .topic = topic,
        .sum = &sum2,
        .mutex = &sum_mutex,
        .reader_id = 2,
    };

    const producer = try std.Thread.spawn(.{}, struct {
        fn run(ctx: Context) !void {
            const writer = ctx.topic.createWriter();
            var i: i32 = 1;
            while (i <= 5) : (i += 1) {
                try writer.write(i);
                std.time.sleep(1_000_000); // 1ms delay
            }
            try writer.complete();
        }
    }.run, .{context1});

    const consumer1 = try std.Thread.spawn(.{}, struct {
        fn run(ctx: Context) !void {
            const reader = try ctx.topic.createReader();
            defer reader.deinit();

            while (reader.read()) |data| {
                ctx.mutex.lock();
                ctx.sum.* += data;
                ctx.mutex.unlock();
            }
        }
    }.run, .{context1});

    const consumer2 = try std.Thread.spawn(.{}, struct {
        fn run(ctx: Context) !void {
            const reader = try ctx.topic.createReader();
            defer reader.deinit();

            while (reader.read()) |data| {
                ctx.mutex.lock();
                ctx.sum.* += data;
                ctx.mutex.unlock();
            }
        }
    }.run, .{context2});

    producer.join();
    consumer1.join();
    consumer2.join();

    // Both consumers should receive all messages: 1+2+3+4+5 = 15
    try testing.expectEqual(@as(i32, 15), sum1);
    try testing.expectEqual(@as(i32, 15), sum2);
}
