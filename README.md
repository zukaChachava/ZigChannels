# ZigChannels

A thread-safe channel implementation for Zig, providing Go-style communication between threads using condition variables and mutexes. This library enables safe communication between threads using channels that can be closed and handle completion gracefully.

## Features

- **Thread-safe**: Uses mutex and condition variables for proper synchronization
- **Generic**: Works with any type `T` using Zig's compile-time generics
- **Completion handling**: Channels can be marked as completed to signal end of data
- **Efficient**: Uses condition variables to avoid busy-waiting, threads block until data is available
- **Memory managed**: Automatic allocation and deallocation of channel nodes using provided allocator
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
    writerChannel.complete();
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

## API Reference

### Channel(T)

The main channel type that provides thread-safe communication.

#### Methods

**`init(allocator: Allocator) !*Channel(T)`**
- Creates a new channel instance
- Requires an allocator for internal memory management
- Returns a pointer to the channel

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

**`write(self: Self, data: T) !void`**
- Sends data to the channel
- Thread-safe operation
- Wakes up waiting readers
- Returns immediately if channel is not completed

**`complete(self: Self) void`**
- Marks the channel as completed
- Wakes up all waiting readers
- No more data can be sent after completion

### Reader(T)

Interface for receiving data from a channel.

**`read(self: Self) ?T`**
- Reads data from the channel
- Blocks if no data is available and channel is not completed
- Returns `null` if channel is completed and no more data
- Thread-safe operation

## Usage Patterns

### Basic Producer-Consumer

```zig
fn producer(channel: *channels.Channel([]const u8)) !void {
    const writer = channel.getWriter();
    
    try writer.write("Hello");
    try writer.write("World");
    writer.complete();
}

fn consumer(channel: *channels.Channel([]const u8)) void {
    const reader = channel.getReader();
    
    while (reader.read()) |message| {
        std.debug.print("Got: {s}\n", .{message});
    }
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
    const producer1 = try std.Thread.spawn(.{}, producer, .{channel, 0, 5});
    const producer2 = try std.Thread.spawn(.{}, producer, .{channel, 10, 15});
    const consumer = try std.Thread.spawn(.{}, consumer, .{channel});
    
    producer1.join();
    producer2.join();
    
    // Complete the channel when all producers are done
    channel.getWriter().complete();
    consumer.join();
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

- **Mutex Protection**: All channel operations are protected by a mutex
- **Condition Variables**: Used for efficient blocking/waking of threads
- **Memory Safety**: Proper allocation/deallocation prevents memory leaks

### Performance Characteristics

- **Blocking Reads**: Readers block when no data is available
- **Non-blocking Writes**: Writers add data and immediately signal readers
- **O(1) Operations**: Both read and write operations are constant time
- **Memory Overhead**: Each message requires one doubly-linked list node

### Memory Management

- Uses provided allocator for all internal allocations
- Nodes are allocated per message and freed when consumed
- Channel cleanup destroys all remaining nodes
- No memory leaks when properly using `defer channel.deinit()`

## Building and Testing

### Build

```bash
zig build
```

### Run Example

```bash
zig build run
```

### Debug Build

```bash
zig build -Doptimize=Debug
```

### Testing

```bash
zig build test
```

## VS Code Development

This project includes VS Code configuration for debugging:

- **Debug configurations** in `.vscode/launch.json`
- **Build tasks** in `.vscode/tasks.json`
- **Recommended extensions** for Zig development

Press `F5` to start debugging the example application.

## Requirements

- **Zig 0.14.0** or later
- **Windows/Linux/macOS** - cross-platform compatible

## License

MIT License - see LICENSE file for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## Examples

See `src/main.zig` for a complete working example of the channel system in action.

fn consumer(channel: *zigChannels.Channel(i32)) void {
    var reader = channel.getReader();
    
    for (0..10) |_| {
        const value = reader.read();
        std.debug.print("Consumed: {}\n", .{value});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var channel = zigChannels.Channel(i32).init(allocator);
    
    var worker_data = WorkerData{
        .channel = &channel,
        .start = 1,
        .end = 11,
    };

    // Start producer thread
    const producer_thread = try Thread.spawn(.{}, producer, .{&worker_data});
    
    // Start consumer thread  
    const consumer_thread = try Thread.spawn(.{}, consumer, .{&channel});

    // Wait for threads to complete
    producer_thread.join();
    consumer_thread.join();
}
```

## API Reference

### Channel(T)

Generic channel type for values of type `T`.

#### Methods

##### `init(allocator: Allocator) Self`

Creates a new channel with the given allocator.

**Parameters:**
- `allocator`: Memory allocator for internal data structures

**Returns:** New channel instance

##### `getReader(self: *Self) Reader(T)`

Creates a reader for this channel.

**Returns:** Reader instance

##### `getWriter(self: *Self) Writer(T)`

Creates a writer for this channel.

**Returns:** Writer instance

### Writer(T)

Writer handle for sending data to a channel.

#### Methods

##### `write(self: *Self, data: T) !void`

Writes data to the channel. This operation is thread-safe and will wake up any waiting readers.

**Parameters:**
- `data`: Value to write to the channel

**Errors:**
- `OutOfMemory`: If allocation fails

### Reader(T)

Reader handle for receiving data from a channel.

#### Methods

##### `read(self: *Self) T`

Reads data from the channel. Blocks until data is available.

**Returns:** Value read from the channel

## How It Works

The channel implementation uses:

1. **DoublyLinkedList**: For storing queued messages
2. **Mutex**: For thread-safe access to the queue
3. **Condition Variable**: For efficient blocking when no data is available

### Synchronization Flow

1. **Writer**: Acquires mutex → adds data to queue → signals condition → releases mutex
2. **Reader**: Acquires mutex → checks if data available → if not, waits on condition → when woken, removes data → releases mutex

This avoids busy-waiting and provides efficient thread coordination.

## Building

```bash
# Build the library
zig build

# Run tests (if available)
zig build test

# Build in release mode
zig build -Doptimize=ReleaseFast
```

## Requirements

- Zig 0.14.0 or later

## Thread Safety

All operations are thread-safe:
- Multiple readers can safely read from the same channel
- Multiple writers can safely write to the same channel  
- Readers and writers can operate concurrently

## Memory Management

- Channel nodes are allocated using the provided allocator
- Memory is automatically freed when messages are consumed
- No manual cleanup required for messages

## Performance Considerations

- Uses condition variables for efficient blocking (no busy-waiting)
- Minimal lock contention with proper mutex usage
- Memory allocation only occurs when writing to the channel

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Similar Projects

- Go channels (inspiration)
- Rust's `std::sync::mpsc`
- C++ condition variables

## Acknowledgments

Inspired by Go's channel implementation and built using modern Zig threading primitives.
