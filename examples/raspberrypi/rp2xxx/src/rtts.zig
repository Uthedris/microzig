const std = @import("std");
const microzig = @import("microzig");

const rtts = @import("rtts/rtts.zig");

const hal = microzig.hal;

const time = hal.time;
const gpio = hal.gpio;
const uart = hal.uart;
const usb = hal.usb;
const watchdog = hal.watchdog;
const i2c = hal.i2c;

const uart0 = uart.instance.num(0);

const Pin = gpio.Pin;
const usb_dev = usb.Usb(.{});

const scheduler = rtts.scheduler(
    .{
        .use_cores = 0xFF,
        .event_flags_count = 8,
    },
    &.{
        rtts.Task.init("alpha", loopA, 256, 0x01),
        rtts.Task.init("beta", loopB, 512, 0),
        rtts.Task.init("gamma", loopC, 256, 0),
    },
);

// -----------------------------------------------------------------------------
//  Local Types
// -----------------------------------------------------------------------------

//const allocator = microzig.allocator;

const Allocator = microzig.core.Allocator;

var heap_allocator: Allocator = undefined;

// -----------------------------------------------------------------------------
//  Local Constants
// -----------------------------------------------------------------------------

// --- GPIO pins --------------------------------

const pin_config = hal.pins.GlobalConfiguration{
    .GPIO0 = .{ .name = "uart0_tx", .function = .UART0_TX },
    .GPIO1 = .{
        .name = "uart0_rx",
        .function = .UART0_RX,
    },
    .GPIO2 = .{
        .name = "led_a",
        .function = .SIO,
        .direction = .out,
    },
    .GPIO3 = .{
        .name = "led_b",
        .function = .SIO,
        .direction = .out,
    },
};

// ---- UART Configuration --------------------------------

const baud_rate = 115200;

// ---- I2C1 Configuration --------------------------------

const i2c1 = i2c.instance(.I2C1);
const i2c_addr: i2c.Address = @enumFromInt(0x42);

// ---- MicroZig Options --------------------------------

pub const microzig_options = microzig.Options{
    .log_level = .debug,
    .logFn = hal.uart.logFnThreadsafe,
    // .interrupts = .{ .SVCall          = .{ .c = RTTS.Platform.svc_ISR },
    //                  .PendSV          = .{ .c = RTTS.Platform.pendsv_ISR },
    //                  .SIO_IRQ_FIFO    = .{ .c = RTTS.Platform.fifo_ISR },
    //                  .SIO_IRQ_FIFO_NS = .{ .c = RTTS.Platform.fifo_ISR } },
    .cpu = .{ .ram_vectors = true },
};

// -----------------------------------------------------------------------------
//  Function: main
// -----------------------------------------------------------------------------

pub fn main() !void {
    heap_allocator = Allocator.init_with_heap(0);
    const allocator = heap_allocator.allocator();

    _ = @TypeOf(allocator);

    // --- Set up GPIO -------------------------------

    pin_config.apply();

    // --- Set up UART -------------------------------

    uart0.apply(.{
        .baud_rate = baud_rate,
        .clock_config = hal.clock_config,
    });

    // --- Set up Logger -----------------------------

    hal.uart.init_logger(uart0);

    std.log.info("Hello, World!", .{});

    // --- Set up I2C communication --------------------

    // Note: at the time of writing, the microzig SDK does not support I2C slave mode.
    //       This is why we configure the I2C register manually.

    // i2c1.configure(.{
    //   .mode = .slave,
    //   .address = i2c_addr,
    //   .sda = .{ .pin = 26 },
    //   .scl = .{ .pin = 27 },
    // });

    // Set up I2C ISR

    //i2c1.set_isr( .{ .callback = i2cCallback, .param = null } );

    // --- Run RTTS tasks ------------------------------

    try scheduler.run();
}

fn loopA(Sched: type) void {
    std.log.debug("{s}TaskA -- Top of loop -- waiting for event", .{Sched.Platform.debug_core()});
    Sched.wait_for_event(0x01, true);
}

fn loopB(Sched: type) void {
    std.log.debug("{s}TaskB -- Signaling task alpha", .{Sched.Platform.debug_core()});
    Sched.signal_event(0x01, Sched.taskNamed("alpha"));

    std.log.debug("{s}TaskB -- Yielding", .{Sched.Platform.debug_core()});
    Sched.yield();
}

fn loopC(Sched: type) void {
    std.log.debug("{s}TaskC -- Sleeping", .{Sched.Platform.debug_core()});
    time.sleep_ms(1000);
    std.log.debug("{s}TaskC -- Posting significant event", .{Sched.Platform.debug_core()});
    Sched.significant_event();
}
