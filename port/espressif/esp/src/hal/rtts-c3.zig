//! This is the platform specific code for the RTTS scheduler for a single
//! core risc-v processor.
//!
//! System resources used:
//!   - Exception handler (Machine Exception) for `ecall` instruction dispatch.
//!
//!
// ### TODO ###  Test calling "significant_event()" and "signal_event()" from an interrupt handler.

const std = @import("std");
const microzig = @import("microzig");

const hal = microzig.hal;
const cpu = microzig.cpu;
const chip = microzig.chip;

const irq = hal.irq;
const multicore = hal.multicore;
const time = hal.time;
const compatibility = hal.compatibility;

const peripherals = chip.peripherals;

const PPB = peripherals.PPB;
const SIO = peripherals.SIO;

const csr = cpu.csr;

pub const SvcID = enum(u8) {
    yield = 0x00,
    significant_event = 0x01,
    wait = 0x02,
    _,
};

pub fn configure(comptime RTTS: type, comptime config: RTTS.Configuration) type {
    return struct {
        const Platform = @This();

        pub const cores_available = 0x01;

        //==============================================================================
        // RTTS Platform Function
        //==============================================================================
        // These function are called from the common RTTS code and implement the
        // platform specific functionality.

        //------------------------------------------------------------------------------
        /// Get the ID of the current core.  We only have one so the id is always 0.
        ///
        pub fn core_id() u8 {
            return 0;
        }

        //------------------------------------------------------------------------------
        /// Get the name of the current core.  We only have one so it is always ""
        ///
        pub fn debug_core() []const u8 {
            return "";
        }

        //------------------------------------------------------------------------------
        /// Initialize the stack for a task as though it had been swapped out
        ///
        pub fn initialize_stack(in_stack: [*]usize, in_pc: *const fn () void) [*]usize {
            var sp = in_stack - 35;

            for (sp[0..35]) |*reg| {
                reg.* = 0xface_fade; // so we can spot bad values
            }

            sp[30] = @intFromPtr(in_stack);
            sp[31] = @intFromPtr(in_pc);
            sp[32] = if (config.run_unprivileged) 0x0000_0081 else 0x0000_1881;

            return sp;
        }

        //------------------------------------------------------------------------------
        /// Initialize the cores
        ///
        pub fn start_cores() noreturn {

            // Set up null task stack

            null_task_stack_pointer = @ptrCast(&null_task_stack[null_task_stack_len - 35]);

            null_task_stack_pointer[30] = @intFromPtr(&null_task_stack) + 4 * null_task_stack_len;
            null_task_stack_pointer[31] = @intFromPtr(&null_task_loop);
            null_task_stack_pointer[32] = if (config.run_unprivileged) 0x0000_0081 else 0x0000_1881;

            // ### TODO ### uncomment below when we allow these to be set at runtime
            // _ = cpu.interrupt.core.set_handler(.Exception, .{ .riscv = machine_exception_ISR });

            // Configure the tick timer

            // ### TODO ### configure the tick timer for esp32-c3

            run_first_task();
        }

        //------------------------------------------------------------------------------
        /// Perform a reschedule (this core)
        ///
        pub fn reschedule() void {
            // ### TODO ### Schedule task switch when not in interrupt handler
        }

        //------------------------------------------------------------------------------
        /// Perform a reschedule (all cores)
        ///
        pub fn reschedule_all_cores() void {
            reschedule();
        }

        //------------------------------------------------------------------------------
        /// Perfom a reschedule_all_cores from an ISR.
        /// For the RP2xxx this is the same as the normal reschedule_all_cores.
        ///
        pub fn reschedule_all_cores_isr() void {
            reschedule();
        }

        //==============================================================================
        // Local thread mode functions
        //==============================================================================

        //------------------------------------------------------------------------------
        /// Run the first task on this core
        fn run_first_task() noreturn {
            std.log.debug("{s}Entered run_first_task", .{debug_core()});

            // Find the highest priority task.  If launched on multiple
            // cores, each will pick a different task.

            var target_sp: [*]usize = &null_task_stack;
            var target_pc: usize = @intFromPtr(&null_task_loop);

            {
                RTTS.schedule_mutex.lock();
                defer RTTS.schedule_mutex.unlock();

                for (&RTTS.task_list) |*a_task| {
                    if (a_task.state == .runnable) {
                        RTTS.current_task[core_id()] = a_task;
                        a_task.state = .running;

                        // We found the task we want to run.  Get the initial PC from
                        // the initialized stack then clear the stack.

                        target_pc = a_task.stack_pointer[31];
                        target_sp = a_task.stack_pointer + 35;

                        std.log.debug("Starting task {s} pc: 0x{x:08} sp: 0x{x:08}", .{ @tagName(a_task.tag), target_pc, @intFromPtr(target_sp) });
                        break;
                    }
                }
            }

            if (config.run_unprivileged) {
                asm volatile (
                    \\    mv    sp, %[sp]        // Set the process stack pointer
                    \\    li    t0, 0x00000081   // Set the MSTATUS register
                    \\    csrs  MSTATUS, t0
                    \\    csrs  MEPC, %[pc]      // Set the MEPC register to the target PC
                    \\    mret
                    :
                    : [sp] "r" (target_sp),
                      [pc] "r" (target_pc),
                    : "t0"
                );
            } else {
                asm volatile (
                    \\    mv    sp, %[sp]        // Set the process stack pointer
                    \\    li    t0, 0x00001881   // Set the MSTATUS register
                    \\    csrs  MSTATUS, t0
                    \\    csrs  MEPC, %[pc]      // Set the MEPC register to the target PC
                    \\    mret
                    :
                    : [sp] "r" (target_sp),
                      [pc] "r" (target_pc),
                    : "t0"
                );
            }

            unreachable;
        }

        //==============================================================================
        // Interrupt service routines
        //==============================================================================
        // These ISR's  need to be registered.
        //  1. me_ISR   - (Exception)

        //------------------------------------------------------------------------------
        /// Machine_exception interrupt service routine
        ///
        /// This isr fires when machine exception is triggered.
        /// We use this to handle ecall instructions.
        ///
        //     // Upon Entry the TrapFrame is:
        //
        //      +------------+
        //      |  ra        | <--- TrapFrame pointer
        //      |  t0        |    +  4 ( 1)
        //      |  t1        |    +  8 ( 2)
        //      |  t2        |    + 12 ( 3)
        //      |  t3        |    + 16 ( 4)
        //      |  t4        |    + 20 ( 5)
        //      |  t5        |    + 24 ( 6)
        //      |  t6        |    + 28 ( 7)
        //      |  a0        |    + 32 ( 8)
        //      |  a1        |    + 36 ( 9)
        //      |  a2        |    + 40 (10)
        //      |  a3        |    + 44 (11)
        //      |  a4        |    + 48 (12)
        //      |  a5        |    + 52 (13)
        //      |  a6        |    + 56 (14)
        //      |  a7        |    + 60 (15)
        //      |  s0        |    + 64 (16)
        //      |  s1        |    + 68 (17)
        //      |  s2        |    + 72 (18)
        //      |  s3        |    + 76 (19)
        //      |  s4        |    + 80 (20)
        //      |  s5        |    + 84 (21)
        //      |  s6        |    + 88 (22)
        //      |  s7        |    + 92 (23)
        //      |  s8        |    + 96 (24)
        //      |  s9        |    +100 (25)
        //      |  s10       |    +104 (26)
        //      |  s11       |    +108 (27)
        //      |  gp        |    +112 (28)
        //      |  tp        |    +116 (29)
        //      |  sp        |    +120 (30)
        //      |  pc        |    +124 (31)
        //      |  mstatus   |    +128 (32)
        //      |  mcause    |    +132 (33)
        //      |  mtval     |    +136 (34)
        //      +------------+

        fn _machine_exception_ISR(_: *cpu.TrapFrame) callconv(.naked) void {
            asm volatile (
                \\                   // the frame pointer is already in a0
                \\    mv    s0, ra   // save our return address
                \\    call  %[dme]   // call do_machine_exception
                \\    mv    sp, a0   // use the new stack pointer returned by do_machine_exception
                \\    jr    s0       // return
                :
                : [dme] "i" (do_machine_exception),
            );
        }

        // We have to cheat a bit here.  This function above is callconv (.naked) because we need
        // to be precise in our register usage, but the ISR is callconv(.c), so we need to cast it
        // to a callconv(.c) InterruptHandler function pointer.

        pub const machine_exception_ISR: cpu.InterruptHandler = @ptrCast(&_machine_exception_ISR);

        /// This function is called from the machine_exception_ISR
        ///
        /// It does the actual dispatching of the ecall instruction
        ///
        export fn do_machine_exception(in_frame: *cpu.TrapFrame) callconv(.c) [*]usize {
            var sp: [*]usize = @ptrCast(in_frame);

            //           std.log.debug("MEH: frame: 0x{x:08} sp: 0x{x:08} pc: 0x{x:08}", .{ @intFromPtr(in_frame), @intFromPtr(sp), in_frame.pc });

            if (in_frame.mcause == 0x08 or in_frame.mcause == 0x0b) {
                // We got here due to an ecall instruction.  The what that works
                // leaves the PC pointing to the ecall instruction itself.  We
                // must bump it by four bytes to point to the next instruction.

                const in_code: SvcID = @enumFromInt(in_frame.a0);

                in_frame.pc += 4;

                // Dispatch the instruction. This may change the stack pointer.
                // if a new task is dispatched.

                switch (in_code) {
                    .yield => {
                        //                        std.log.debug("MEH: yield", .{});
                        if (RTTS.current_task[0]) |task| {
                            task.state = .yielded;
                            sp = RTTS.find_next_task_sp(sp);
                        }
                    },
                    .significant_event => {
                        //                        std.log.debug("MEH: significant_event", .{});
                        for (&RTTS.sig_event) |*sig_event| {
                            sig_event.* = true;
                        }
                        sp = RTTS.find_next_task_sp(sp);
                    },
                    .wait => {
                        //                        std.log.debug("MEH: wait", .{});
                        if (RTTS.current_task[0]) |task| {
                            // We need to wait if we have a mask and no
                            // mask bit has a corresponding event flag set.
                            if (task.event_mask != 0 and task.event_mask & task.event_flags == 0) {
                                task.state = .waiting;
                                sp = RTTS.find_next_task_sp(sp);
                            }
                        }
                    },
                    else => {
                        std.log.err("Unhandled machine exception code: {s}", .{@tagName(in_code)});
                    },
                }
            }

            //            for (0..44) |i| {
            //                std.log.debug("New: sp[{d:2}] frame[{d:2}]: 0x{x:08}", .{ i, if (i < 4) 0 else i-4, sp[i] });
            //            }

            return sp;
        }

        //==============================================================================
        // Null Task
        //==============================================================================

        const null_task_stack_len = 48;

        var null_task_stack: [null_task_stack_len]usize = undefined;
        pub var null_task_stack_pointer: [*]usize = undefined;

        // ------------------------------------------------------------------------
        // The null task just calls wait for interrupt in an infinite loop.
        // A user who want to "replace" the null task should just run the
        // replacement code as the lowest priority task.

        fn null_task_loop() callconv(.naked) noreturn {
            asm volatile (
                \\ null_loop:
                \\       slt zero, zero, x0
                \\       j null_loop
            );
        }
    };
}
