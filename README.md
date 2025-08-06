# ZigChannels

A thread-safe channel implementation for Zig, providing Go-style communication between threads using condition variables and mutexes. This library enables safe communication between threads using channels that can be closed and handle completion gracefully.

## Features

- **Thread-safe**: Uses mutex and condition variables for proper synchronization
- **Generic**: Works with any type `T` using Zig's compile-time generics
- **Completion handling**: Channels can be marked as completed to signal end of data
- **Efficient**: Uses condition variables to avoid busy-waiting, threads block until data is available
- **Memory managed**: Automatic allocation and deallocation of channel nodes using provided allocator
- **Error handling**: Proper error types for channel operations (OutOfMemory, ChannelClosed)
- **FIFO ordering**: Messages are delivered in first-in-first-out order
- **Simple API**: Clean reader/writer pattern with minimal complexity

## Quick Start

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

## Installation

### Using Zig Package Manager

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

exe.root_module.addImport("channels", zigChannels.module("zigChannels"));
```

## API Reference

### ChannelError

Error types that can be returned by channel operations:

```zig
pub const ChannelError = error{
    OutOfMemory,     // Memory allocation failed
    ChannelClosed,   // Attempted to write to or complete a closed channel
};
```

### Channel(T)

The main channel type that provides thread-safe communication.

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

## Usage Patterns

### Basic Producer-Consumer

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
    writer.complete();
    
    // Consumer processes messages
    const reader = channel.getReader();
    while (reader.read()) |msg| {
        std.debug.print("Message {}: {s} at {}\n", .{ msg.id, msg.content, msg.timestamp });
    }
}
```

## Implementation Details

### Thread Safety

- **Mutex Protection**: All channel operations are protected by a single mutex
- **Condition Variables**: Used for efficient blocking/waking of threads
- **Atomic Operations**: Channel completion state is protected by mutex
- **Memory Safety**: Proper allocation/deallocation prevents memory leaks

### Synchronization Flow

1. **Writer**: 
   - Acquires mutex → checks if completed → allocates node → adds to queue → signals condition → releases mutex
   - Uses `signal()` to wake up one waiting reader
   - Uses `broadcast()` on completion to wake up all waiting readers

2. **Reader**: 
   - Acquires mutex → checks queue and completion state → if empty and not completed, waits on condition → when woken, re-checks → removes data → releases mutex

### Performance Characteristics

- **Blocking Reads**: Readers block when no data is available using condition variables
- **Non-blocking Writes**: Writers add data and immediately signal readers
- **O(1) Operations**: Both read and write operations are constant time
- **Memory Overhead**: Each message requires one doubly-linked list node
- **No Busy-Waiting**: Uses condition variables instead of polling

### Memory Management

- Uses provided allocator for all internal allocations
- Nodes are allocated per message and freed when consumed
- Channel cleanup destroys all remaining nodes
- No memory leaks when properly using `defer channel.deinit()`
- Allocation only fails with `OutOfMemory` error

### Error Handling

The library uses Zig's error handling:
- `try` for propagating errors
- `catch` for handling specific errors
- `orelse` for handling optional values (null from completed channels)

## Project Structure

```
src/
├── channels/
│   ├── root.zig       # Main export file
│   ├── channel.zig    # Channel implementation with tests
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

# Run tests for specific file
zig test src/channels/channel.zig
```

The test suite includes:
- Basic read/write operations
- Channel completion behavior
- Error handling scenarios
- Multi-threaded producer/consumer patterns
- Memory leak detection
- Different data types

## Requirements

- **Zig 0.13.0** or later
- **Windows/Linux/macOS** - cross-platform compatible

## Examples

See `src/main.zig` for a complete working example demonstrating:
- Channel creation and cleanup
- Producer and consumer threads
- Proper completion handling
- Error handling patterns

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
