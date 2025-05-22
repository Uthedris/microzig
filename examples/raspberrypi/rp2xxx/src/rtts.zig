const std = @import("std");
const microzig = @import("microzig");

const hal = microzig.hal;
const drivers = microzig.drivers;
const rtts = microzig.rtts;

const time = hal.time;
const uart = hal.uart;

const uart0 = uart.instance.num(0);

const sched_config = rtts.Config{
    .use_cores = 0xFF,
    .event_flags_count = 8,
};

const tasks = [_]rtts.Task{
    .{ .name = "alpha", .func = taskA, .stack_size = 256, .event_mask = 0x01 },
    .{
        .name = "bravo",
        .func = taskB,
        .stack_size = 512,
    },
    .{
        .name = "charlie",
        .func = taskC,
        .stack_size = 256,
    },
};

const scheduler = rtts.scheduler(sched_config, &tasks);

// -----------------------------------------------------------------------------
//  Local Types
// -----------------------------------------------------------------------------

//const allocator = microzig.allocator;

const Allocator = microzig.Allocator;

var heap_allocator: Allocator = undefined;

// -----------------------------------------------------------------------------
//  Local Constants
// -----------------------------------------------------------------------------

// --- GPIO pins --------------------------------

const pin_config = hal.pins.GlobalConfiguration{
    .GPIO0 = .{ .name = "uart0_tx", .function = .UART0_TX },
};

// ---- UART Configuration --------------------------------

const baud_rate = 115200;

// ---- MicroZig Options --------------------------------

pub const microzig_options = microzig.Options{
    .log_level = .debug,
    .logFn = hal.uart.logFnThreadsafe,
    // .interrupts = .{ .SVCall          = .{ .c = RTTS.hal.rtts.svc_ISR },
    //                  .PendSV          = .{ .c = RTTS.hal.rtts.pendsv_ISR },
    //                  .SIO_IRQ_FIFO    = .{ .c = RTTS.hal.rtts.fifo_ISR },
    //                  .SIO_IRQ_FIFO_NS = .{ .c = RTTS.hal.rtts.fifo_ISR } },
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

    // --- Run RTTS tasks ------------------------------

    try scheduler.run(&tasks);
}

fn taskA() noreturn {
    while (true) {
        std.log.debug("{s}TaskA -- Top of loop -- waiting for event", .{scheduler.platform.debug_core()});
        scheduler.wait_for_event(0x01, true);
    }
}

fn taskB() noreturn {
    while (true) {
        std.log.debug("{s}TaskB -- Signaling task alpha", .{scheduler.platform.debug_core()});
        scheduler.signal_event(.alpha, 0x01);

        std.log.debug("{s}TaskB -- Yielding", .{scheduler.platform.debug_core()});
        scheduler.yield();
    }
}

fn taskC() noreturn {
    while (true) {
        std.log.debug("{s}TaskC -- Sleeping", .{scheduler.platform.debug_core()});
        time.sleep_ms(1000);
        std.log.debug("{s}TaskC -- Posting significant event", .{scheduler.platform.debug_core()});
        scheduler.significant_event();
    }
}
