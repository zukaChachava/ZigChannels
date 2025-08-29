# ZigChannels

A comprehensive thread-safe communication library for Zig, providing both **point-to-point channels** and **publish-subscribe topics** for inter-thread communication using condition variables and mutexes.

## Features

- **Two Communication Patterns**:
  - **Channels**: Point-to-point communication (one-to-one)
  - **Topics**: Publish-subscribe communication (one-to-many broadcast)
- **Thread-safe**: Uses mutex and condition variables for proper synchronization
- **Generic**: Works with any type `T` using Zig's compile-time generics
- **Completion handling**: Both channels and topics can be marked as completed to signal end of data
- **Efficient**: Uses condition variables to avoid busy-waiting, threads block until data is available
- **Memory managed**: Automatic allocation and deallocation using provided allocator
- **Error handling**: Proper error types for all operations (OutOfMemory, ChannelClosed)
- **FIFO ordering**: Messages are delivered in first-in-first-out order
- **Simple API**: Clean reader/writer pattern with minimal complexity

## Quick Start

### Channel Example (Point-to-Point)

```zig
const std = @import("std");
const channels = @import("channels");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Create a channel for i32 values
    const channel = try channels.Channel(i32).init(allocator);
    defer channel.deinit();

    // Spawn producer and consumer threads
    const writerThread = try std.Thread.spawn(.{}, writer, .{channel});
    const readerThread = try std.Thread.spawn(.{}, reader, .{channel});

    // Wait for completion
    writerThread.join();
    readerThread.join();
}

fn writer(channel: *channels.Channel(i32)) !void {
    const writerChannel = channel.getWriter();
    
    // Send some data
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        try writerChannel.write(i);
    }
    
    // Signal completion
    try writerChannel.complete();
}

fn reader(channel: *channels.Channel(i32)) void {
    const readerChannel = channel.getReader();
    
    // Read until channel is completed
    while (readerChannel.read()) |data| {
        std.debug.print("Received: {}\n", .{data});
    }
    
    std.debug.print("Reading completed\n", .{});
}
```

### Topic Example (Publish-Subscribe)

```zig
const std = @import("std");
const channels = @import("channels");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Create a topic for broadcasting i32 values
    const topic = try channels.Topic(i32).init(allocator);
    defer topic.deinit();

    // Create multiple subscribers
    const reader1 = try topic.createReader();
    const reader2 = try topic.createReader();
    const reader3 = try topic.createReader();
    defer reader1.deinit();
    defer reader2.deinit();
    defer reader3.deinit();

    // Spawn publisher and subscriber threads
    const publisherThread = try std.Thread.spawn(.{}, publisher, .{topic});
    const subscriber1Thread = try std.Thread.spawn(.{}, subscriber, .{reader1, "Sub1"});
    const subscriber2Thread = try std.Thread.spawn(.{}, subscriber, .{reader2, "Sub2"});
    const subscriber3Thread = try std.Thread.spawn(.{}, subscriber, .{reader3, "Sub3"});

    // Wait for completion
    publisherThread.join();
    subscriber1Thread.join();
    subscriber2Thread.join();
    subscriber3Thread.join();
}

fn publisher(topic: *channels.Topic(i32)) !void {
    const writer = topic.createWriter();
    
    // Broadcast messages to all subscribers
    var i: i32 = 1;
    while (i <= 5) : (i += 1) {
        try writer.write(i);
        std.debug.print("Published: {}\n", .{i});
    }
    
    // Signal completion
    try writer.complete();
}

fn subscriber(reader: *channels.TopicReader(i32), name: []const u8) void {
    // Each subscriber receives ALL messages
    while (reader.read()) |data| {
        std.debug.print("{s} received: {}\n", .{name, data});
    }
    std.debug.print("{s} completed\n", .{name});
}
```

## Installation

### Using Zig Package Manager

#### Method 1: Using build.zig.zon

Add to your `build.zig.zon`:

```zig
.{
    .name = "your-project",
    .version = "0.1.0",
    .dependencies = .{
        .zigChannels = .{
            .url = "https://github.com/zukaChachava/ZigChannels/archive/main.tar.gz",
            .hash = "...", // Will be filled automatically
        },
    },
}
```

Then in your `build.zig`:

```zig
const zigChannels = b.dependency("zigChannels", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("channels", zigChannels.module("channels"));
```

#### Method 2: Using zig fetch

You can also use `zig fetch` to add ZigChannels to your project:

```bash
# From your project directory
zig fetch --save https://github.com/zukaChachava/ZigChannels/archive/main.tar.gz
```

This will automatically update your `build.zig.zon` with the dependency. Then in your `build.zig`, add:

```zig
const zigChannels = b.dependency("zigChannels", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("channels", zigChannels.module("channels"));
```

## API Reference

### ChannelError

Error types that can be returned by channel and topic operations:

```zig
pub const ChannelError = error{
    OutOfMemory,     // Memory allocation failed
    ChannelClosed,   // Attempted to write to or complete a closed channel/topic
};
```

## Channel API (Point-to-Point Communication)

### Channel(T)

The main channel type that provides thread-safe point-to-point communication.

#### Methods

**`init(allocator: Allocator) ChannelError!*Channel(T)`**
- Creates a new channel instance
- Requires an allocator for internal memory management
- Returns a pointer to the channel or `ChannelError.OutOfMemory`

**`deinit(self: *Self) void`**
- Cleans up channel resources
- Destroys all remaining nodes in the queue
- Must be called to prevent memory leaks

**`getWriter(self: *Self) Writer(T)`**
- Returns a writer interface for sending data to the channel

**`getReader(self: *Self) Reader(T)`**
- Returns a reader interface for receiving data from the channel

### Writer(T)

Interface for sending data to a channel.

**`write(self: Self, data: T) ChannelError!void`**
- Sends data to the channel
- Thread-safe operation
- Wakes up waiting readers
- Returns `ChannelError.ChannelClosed` if channel is completed
- Returns `ChannelError.OutOfMemory` if allocation fails

**`complete(self: Self) ChannelError!void`**
- Marks the channel as completed
- Wakes up all waiting readers using `broadcast()`
- No more data can be sent after completion
- Returns `ChannelError.ChannelClosed` if already completed

### Reader(T)

Interface for receiving data from a channel.

**`read(self: Self) ?T`**
- Reads data from the channel
- Blocks if no data is available and channel is not completed
- Returns `null` if channel is completed and no more data
- Thread-safe operation
- Uses condition variables for efficient waiting

## Topic API (Publish-Subscribe Communication)

### Topic(T)

The main topic type that provides thread-safe publish-subscribe communication.

#### Methods

**`init(allocator: Allocator) ChannelError!*Topic(T)`**
- Creates a new topic instance
- Requires an allocator for internal memory management
- Returns a pointer to the topic or `ChannelError.OutOfMemory`

**`deinit(self: *Self) void`**
- Cleans up topic resources and all associated readers
- Destroys all remaining nodes in all reader queues
- Must be called to prevent memory leaks

**`createReader(self: *Self) ChannelError!*TopicReader(T)`**
- Creates a new subscriber reader
- Each reader has a unique ID and receives all published messages
- Returns a pointer to the reader or `ChannelError.OutOfMemory`

**`createWriter(self: *Self) TopicWriter(T)`**
- Returns a writer interface for publishing data to all subscribers

### TopicWriter(T)

Interface for publishing data to all subscribers of a topic.

**`write(self: Self, data: T) ChannelError!void`**
- Broadcasts data to ALL subscribers
- Thread-safe operation
- Wakes up all waiting readers
- Returns `ChannelError.ChannelClosed` if topic is completed
- Returns `ChannelError.OutOfMemory` if allocation fails

**`complete(self: Self) ChannelError!void`**
- Marks the topic as completed
- Wakes up all waiting readers using `broadcast()`
- No more data can be published after completion
- Returns `ChannelError.ChannelClosed` if already completed

### TopicReader(T)

Interface for receiving data from a topic subscription.

**`read(self: *Self) ?T`**
- Reads data from the reader's personal queue
- Each reader has its own queue and receives ALL published messages
- Blocks if no data is available and topic is not completed
- Returns `null` if topic is completed and no more data
- Thread-safe operation
- Uses condition variables for efficient waiting

**`deinit(self: *Self) void`**
- Cleans up reader resources and removes it from the topic
- Destroys all remaining nodes in the reader's queue
- Must be called to prevent memory leaks

## Usage Patterns

### Channel Patterns (Point-to-Point)

#### Basic Producer-Consumer

```zig
fn producer(channel: *channels.Channel([]const u8)) !void {
    const writer = channel.getWriter();
    
    try writer.write("Hello");
    try writer.write("World");
    try writer.complete();
}

fn consumer(channel: *channels.Channel([]const u8)) void {
    const reader = channel.getReader();
    
    while (reader.read()) |message| {
        std.debug.print("Got: {s}\n", .{message});
    }
}
```

#### Multiple Producers, Single Consumer

```zig
fn multipleProducers() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const channel = try channels.Channel(i32).init(allocator);
    defer channel.deinit();
    
    // Spawn multiple producer threads
    const producer1 = try std.Thread.spawn(.{}, producerFunc, .{channel, 1, 5});
    const producer2 = try std.Thread.spawn(.{}, producerFunc, .{channel, 10, 15});
    const consumer_thread = try std.Thread.spawn(.{}, consumerFunc, .{channel});
    
    producer1.join();
    producer2.join();
    
    // Complete the channel when all producers are done
    try channel.getWriter().complete();
    consumer_thread.join();
}
```

### Topic Patterns (Publish-Subscribe)

#### Basic Publisher-Subscriber

```zig
fn basicPubSub() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const topic = try channels.Topic([]const u8).init(allocator);
    defer topic.deinit();
    
    // Create subscribers
    const sub1 = try topic.createReader();
    const sub2 = try topic.createReader();
    defer sub1.deinit();
    defer sub2.deinit();
    
    // Publisher broadcasts to all
    const writer = topic.createWriter();
    try writer.write("Breaking News!");
    try writer.write("Weather Update");
    try writer.complete();
    
    // All subscribers receive all messages
    while (sub1.read()) |msg| {
        std.debug.print("Subscriber 1: {s}\n", .{msg});
    }
    
    while (sub2.read()) |msg| {
        std.debug.print("Subscriber 2: {s}\n", .{msg});
    }
}
```

#### Event Broadcasting

```zig
const Event = struct {
    type: EventType,
    data: []const u8,
    timestamp: i64,
};

const EventType = enum { UserLogin, UserLogout, DataUpdate };

fn eventSystem() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const eventTopic = try channels.Topic(Event).init(allocator);
    defer eventTopic.deinit();
    
    // Different components subscribe to events
    const logger = try eventTopic.createReader();
    const analytics = try eventTopic.createReader();
    const notifications = try eventTopic.createReader();
    defer logger.deinit();
    defer analytics.deinit();
    defer notifications.deinit();
    
    // Event publisher
    const publisher = eventTopic.createWriter();
    
    try publisher.write(.{
        .type = .UserLogin,
        .data = "user123",
        .timestamp = std.time.timestamp(),
    });
    
    try publisher.write(.{
        .type = .DataUpdate,
        .data = "inventory_changed",
        .timestamp = std.time.timestamp(),
    });
    
    try publisher.complete();
}
```

### Error Handling

```zig
fn safeWriter(channel: *channels.Channel(i32)) void {
    const writer = channel.getWriter();
    
    // Handle write errors
    writer.write(42) catch |err| switch (err) {
        channels.ChannelError.ChannelClosed => {
            std.debug.print("Channel is closed\n");
        },
        channels.ChannelError.OutOfMemory => {
            std.debug.print("Out of memory\n");
        },
    };
    
    // Handle completion errors
    writer.complete() catch |err| switch (err) {
        channels.ChannelError.ChannelClosed => {
            std.debug.print("Channel already closed\n");
        },
        channels.ChannelError.OutOfMemory => unreachable, // complete() doesn't allocate
    };
}

fn safeReader(channel: *channels.Channel(i32)) void {
    const reader = channel.getReader();
    
    // Using if let pattern for null checking
    if (reader.read()) |data| {
        std.debug.print("Received: {}\n", .{data});
    } else {
        std.debug.print("Channel completed\n");
    }
    
    // Using orelse for default values
    const data = reader.read() orelse -1;
    std.debug.print("Data or default: {}\n", .{data});
}
```

### Multiple Producers

```zig
fn multipleProducers() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const channel = try channels.Channel(i32).init(allocator);
    defer channel.deinit();
    
    // Spawn multiple producer threads
    const producer1 = try std.Thread.spawn(.{}, producerFunc, .{channel, 1, 5});
    const producer2 = try std.Thread.spawn(.{}, producerFunc, .{channel, 10, 15});
    const consumer_thread = try std.Thread.spawn(.{}, consumerFunc, .{channel});
    
    producer1.join();
    producer2.join();
    
    // Complete the channel when all producers are done
    try channel.getWriter().complete();
    consumer_thread.join();
}

fn producerFunc(channel: *channels.Channel(i32), start: i32, end: i32) !void {
    const writer = channel.getWriter();
    var i = start;
    while (i <= end) : (i += 1) {
        try writer.write(i);
    }
}

fn consumerFunc(channel: *channels.Channel(i32)) void {
    const reader = channel.getReader();
    while (reader.read()) |data| {
        std.debug.print("Consumed: {}\n", .{data});
    }
}
```

### Working with Complex Types

```zig
const Message = struct {
    id: u32,
    content: []const u8,
    timestamp: i64,
};

fn processMessages() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const channel = try channels.Channel(Message).init(allocator);
    defer channel.deinit();
    
    // Producer sends structured messages
    const writer = channel.getWriter();
    try writer.write(.{
        .id = 1,
        .content = "Hello",
        .timestamp = std.time.timestamp(),
    });
    try writer.complete();
    
    // Consumer processes messages
    const reader = channel.getReader();
    while (reader.read()) |msg| {
        std.debug.print("Message {}: {s} at {}\n", .{ msg.id, msg.content, msg.timestamp });
    }
}
```

## When to Use Channels vs Topics

### Use Channels When:
- **Point-to-point communication** - One producer, one consumer
- **Work distribution** - Tasks need to be processed by exactly one worker
- **Pipeline processing** - Data flows through a series of processing stages
- **Load balancing** - Multiple workers sharing a queue of tasks

### Use Topics When:
- **Event broadcasting** - Multiple components need to react to the same event
- **Notifications** - All subscribers should receive the same message
- **Fan-out patterns** - One message needs to reach multiple recipients
- **Monitoring/Logging** - Multiple systems need to observe the same data stream

## Comparison

| Feature | Channel | Topic |
|---------|---------|-------|
| **Pattern** | Point-to-Point | Publish-Subscribe |
| **Consumers** | One message → One consumer | One message → All subscribers |
| **Use Case** | Work queues, pipelines | Events, notifications, broadcasting |
| **Message Delivery** | First available consumer gets it | All subscribers receive it |
| **Performance** | Lower memory usage | Higher memory usage (copies per subscriber) |

## Implementation Details

### Thread Safety

- **Mutex Protection**: All operations are protected by appropriate mutexes
  - **Channels**: Single mutex protects the shared queue
  - **Topics**: Single mutex protects reader management and broadcasting
- **Condition Variables**: Used for efficient blocking/waking of threads
- **Atomic Operations**: Completion states are protected by mutex
- **Memory Safety**: Proper allocation/deallocation prevents memory leaks

### Synchronization Flow

#### Channel Synchronization:
1. **Writer**: Acquires mutex → checks completion → allocates node → adds to queue → signals condition → releases mutex
2. **Reader**: Acquires mutex → checks queue/completion → waits if needed → removes data → releases mutex

#### Topic Synchronization:
1. **Writer**: Acquires mutex → checks completion → iterates readers → adds data to each reader queue → broadcasts to all → releases mutex  
2. **Reader**: Acquires mutex → checks own queue/completion → waits if needed → removes data → releases mutex

### Performance Characteristics

- **Blocking Operations**: All read operations block when no data is available
- **Non-blocking Writes**: Writers add data and immediately signal waiting readers
- **O(1) Channel Operations**: Both read and write operations are constant time
- **O(n) Topic Write**: Topic writes are O(n) where n is the number of subscribers
- **Memory Overhead**: 
  - Channels: One node per message
  - Topics: One node per message per subscriber
- **No Busy-Waiting**: Uses condition variables instead of polling

### Memory Management

- Uses provided allocator for all internal allocations
- **Channels**: Nodes allocated per message, freed when consumed by single reader
- **Topics**: Nodes allocated per message per subscriber, freed when consumed by each reader
- Channel/Topic cleanup destroys all remaining nodes
- Reader cleanup destroys personal queue and removes from topic
- No memory leaks when properly using `defer` cleanup
- Allocation only fails with `OutOfMemory` error

### Error Handling

The library uses Zig's error handling:
- `try` for propagating errors
- `catch` for handling specific errors  
- `orelse` for handling optional values (null from completed channels/topics)

## Project Structure

```
src/
├── channels/
│   ├── root.zig       # Main export file
│   ├── channel.zig    # Channel implementation with tests
│   ├── topic.zig      # Topic implementation with tests
│   └── common.zig     # Common types and errors
├── main.zig           # Example usage
└── root.zig           # Library root
```

## Building and Testing

### Build

```bash
# Build the library
zig build

# Build in release mode
zig build -Doptimize=ReleaseFast

# Build in debug mode
zig build -Doptimize=Debug
```

### Run Example

```bash
# Run the example in main.zig
zig build run
```

### Testing

```bash
# Run all tests
zig build test

# Run tests for specific implementations
zig test src/channels/channel.zig
zig test src/channels/topic.zig
```

The test suite includes:
- **Channel tests**: Basic read/write operations, completion behavior, error handling, multi-threaded patterns
- **Topic tests**: Publisher-subscriber patterns, broadcasting, reader management, completion behavior
- **Memory leak detection** and proper cleanup verification
- **Concurrency testing** with multiple threads
- **Error handling scenarios** for both channels and topics
- **Different data types** compatibility testing

## Requirements

- **Zig 0.13.0** or later
- **Windows/Linux/macOS** - cross-platform compatible

## Examples

See `src/main.zig` for complete working examples demonstrating:
- **Channel usage**: Point-to-point communication with producer/consumer threads
- **Topic usage**: Publish-subscribe with multiple subscribers receiving broadcast messages
- **Proper completion handling** for both patterns
- **Error handling patterns** and resource cleanup
- **Threading examples** with proper synchronization

Both communication patterns provide robust, thread-safe inter-thread communication suitable for various concurrent programming scenarios.

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass (`zig build test`)
6. Commit your changes (`git commit -m 'Add amazing feature'`)
7. Push to the branch (`git push origin feature/amazing-feature`)
8. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Inspired by Go's channel implementation
- Built using Zig's modern threading primitives
- Thanks to the Zig community for excellent documentation and examples
