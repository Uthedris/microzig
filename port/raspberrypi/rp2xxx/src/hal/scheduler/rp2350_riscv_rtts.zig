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
};

const FIFOCommand = enum(u8) {
    dispatch,
    block,
    _,
};

const riscv_calling_convention: std.builtin.CallingConvention = .{ .riscv32_interrupt = .{ .mode = .machine } };

pub fn configure(comptime RTTS: type) type {
    return struct {
        const Platform = @This();

        pub const cores_available = 0x03;

        //==============================================================================
        // RTTS Platform Function
        //==============================================================================
        // These function are called from the common RTTS code and implement the
        // platform specific functionality.

        //------------------------------------------------------------------------------
        /// Get the ID of the current core
        ///
        pub fn core_id() u8 {
            return @intCast(hal.get_cpu_id());
        }

        pub fn debug_core() []const u8 {
            return if (core_id() == 0) "Core 0 " else "Core 1                                       ";
        }

        //------------------------------------------------------------------------------
        /// Initialize the stack for a task as though it had been swapped out
        ///
        pub fn initialize_stack(in_stack: [*]usize, in_pc: *const fn () void) [*]usize {

            // We want to duplicate what the stack looks like when a task is swapped out

            //      +------------+
            //      |  MEPC      | <- Stack pointer
            //      |  MSTATUS   | +   1
            //      |  gp        | +   2
            //      |  tp        | +   3
            //      |  t0        | +   4
            //      |  t1        | +   5
            //      |  t2        | +   6
            //      |  t3        | +   7
            //      |  t4        | +   8
            //      |  t5        | +   9
            //      |  t6        | +  10
            //      |  a0        | +  11
            //      |  a1        | +  12
            //      |  a2        | +  13
            //      |  a3        | +  14
            //      |  a4        | +  15
            //      |  a5        | +  16
            //      |  a6        | +  17
            //      |  a7        | +  18
            //      |  s11       | +  19
            //      |  s10       | +  20
            //      |  s9        | +  21
            //      |  s8        | +  22
            //      |  s7        | +  23
            //      |  s6        | +  24
            //      |  s5        | +  25
            //      |  s4        | +  26
            //      |  s3        | +  27
            //      |  s2        | +  28
            //      |  s1        | +  29
            //      |  s0        | +  30
            //      |  ra        | +  31
            //      +------------+

            var sp = in_stack - 32;

            for (sp[2..32]) |*reg| {
                reg.* = 0xface_fade; // so we can spot bad values
            }

            sp[0] = @intFromPtr(in_pc);
            sp[1] = 0x0000_0340;

            return sp;
        }

        //------------------------------------------------------------------------------
        /// Initialize the cores
        ///
        pub fn start_cores() noreturn {
            // Set the priority of the PendSV exception to the lowest possible value

            if (compatibility.chip == .RP2040) {
                PPB.SHPR3.modify(.{ .PRI_14 = 0, .PRI_15 = 0 });
            } else {
                PPB.SHPR3.modify(.{ .PRI_14_3 = 0, .PRI_15_3 = 0 });
            }

            // ### TODO ### uncomment below when we allow these to be set at runtime
            // _ = cpu.interrupt.exception.set_handler(.Exception, .{ .riscv = machine_exception_ISR });
            // _ = cpu.interrupt.exception.set_handler(.MachineSoftware, .{ .riscv = machine_software_exception_ISR });

            if (RTTS.core_mask & 0x02 != 0) {
                if (compatibility.chip == .RP2040) {
                    _ = hal.irq.set_handler(.SIO_IRQ_PROC0, .{ .c = fifo_ISR });
                    _ = hal.irq.set_handler(.SIO_IRQ_PROC1, .{ .c = fifo_ISR });
                } else {
                    _ = hal.irq.set_handler(.SIO_IRQ_FIFO, .{ .c = fifo_ISR });
                }
                // Note: We don't enable these interrupts until after the other core is
                // launched, so we don't mess with the launch sequence.
            }

            // Set up null task stack

            null_task_stack[null_task_stack_len - 2] = @intFromPtr(&null_task_loop);
            null_task_stack[null_task_stack_len - 1] = 0x01000000;

            null_task_stack_pointer = @intFromPtr(&null_task_stack[null_task_stack_len - 16]);

            // Launch the other core

            if (RTTS.core_mask & 0x02 != 0) {
                multicore.launch_core1(blk: {
                    const s = struct {
                        fn core1_init() noreturn {
                            run_first_task();
                        }
                    };

                    break :blk s.core1_init;
                });
            }

            run_first_task();
        }

        //------------------------------------------------------------------------------
        /// Send the yield SVC
        ///
        pub fn yield() void {
            asm volatile (
                \\ li    a0, 0
                \\ ecall
            );
        }

        //------------------------------------------------------------------------------
        /// Post a significant event
        ///
        pub fn significant_event() void {
            asm volatile (
                \\ li    a0, 1
                \\ ecall
            );
        }

        //------------------------------------------------------------------------------
        /// Send the wait SVC
        ///
        pub fn wait() void {
            asm volatile (
                \\ li    a0, 2
                \\ ecall
            );

            //   else
            //   {
            //     if (RTTS.current_task[core_id()]) |task|
            //     {
            //       // We need to wait if we have a mask and no
            //       // mask bit has a corresponding event flag set.
            //       if (    task.event_mask != 0
            //           and task.event_mask & task.event_flags == 0)
            //       {
            //         task.state = .waiting;
            //         scb.ICSR.modify( .{ .PENDSVSET = 1 });
            //         asm volatile ( "isb" );
            //       }
            //     }

        }

        //==============================================================================
        // Interrupt service routines
        //==============================================================================
        // There are three ISR's that need to be registered.The
        //  1. me_ISR   - (Exception)
        //  2. ms_ISR   - (Machine Software) The pendsv interrupt service routine
        //  3. fifo_ISR - (???) The inter-core communication interrupt service routine
        //
        //  4. mt_ISR   - (Machine Timer) The sysTick interrupt service routine

        //------------------------------------------------------------------------------
        /// machine_exception interrupt service routine
        ///
        pub export fn machine_exception_ISR() callconv(.naked) noreturn {
            asm volatile (
                \\     cm.push {ra,s0-s11},-64   // Save x1, x8, x9 and x18-x27
                \\     addi    sp, sp, -64
                \\     csrr    ra,  MEPC
                \\     sw      ra,  0(sp)
                \\     csrr    ra,  MSTATUS
                \\     sw      ra,  4(sp)
                \\     sw      gp,  8(sp)
                \\     sw      tp,  12(sp)
                \\     sw      t0,  16(sp)
                \\     sw      t1,  20(sp)
                \\     sw      t2,  24(sp)
                \\     sw      t3,  28(sp)
                \\     sw      t4,  32(sp)
                \\     sw      t5,  36(sp)
                \\     sw      t6,  40(sp)
                \\     sw      a0,  44(sp)
                \\     sw      a1,  48(sp)
                \\     sw      a2,  52(sp)
                \\     sw      a3,  56(sp)
                \\     sw      a4,  60(sp)
                \\     sw      a5,  64(sp)
                \\     sw      a6,  68(sp)
                \\     sw      a7,  72(sp)
                \\     mv      a1, sp
                \\     call    %[meh]
                \\     mv      sp, a0
                \\     lw      ra, 0(sp)
                \\     csrw    MEPC, ra
                \\     lw      ra, 4(sp)
                \\     csrw    MSTATUS, ra
                \\     lw      gp,  8(sp)
                \\     lw      tp,  12(sp)
                \\     lw      t0,  16(sp)
                \\     lw      t1,  20(sp)
                \\     lw      t2,  24(sp)
                \\     lw      t3,  28(sp)
                \\     lw      t4,  32(sp)
                \\     lw      t5,  36(sp)
                \\     lw      t6,  40(sp)
                \\     lw      a0,  44(sp)
                \\     lw      a1,  48(sp)
                \\     lw      a2,  52(sp)
                \\     lw      a3,  56(sp)
                \\     lw      a4,  60(sp)
                \\     lw      a5,  64(sp)
                \\     lw      a6,  68(sp)
                \\     lw      a7,  72(sp)
                \\     addi    sp,  sp, 64
                \\     cm.pop {ra,s0-s11},64   // Restore x1, x8, x9 and x18-x27
                \\     mret
                :
                : [meh] "i" (meh),
            );
        }

        export fn meh(in_code: u32, sp: [*]usize) callconv(.c) [*]usize {
            if (RTTS.current_task[core_id()]) |task| {
                task.stack_pointer = sp;
            } else {
                // no need to save null task stack pointer
            }

            switch (in_code) {
                0 => // yield
                {
                    return @ptrFromInt(RTTS.find_next_task_sp(@intFromPtr(sp)));
                },
                1 => // significant_event
                {
                    for (&RTTS.sig_event) |*sig_event| {
                        sig_event.* = true;
                    }
                    return @ptrFromInt(RTTS.find_next_task_sp(@intFromPtr(sp)));
                },
                2 => // wait
                {
                    if (RTTS.current_task[core_id()]) |task| {
                        // We need to wait if we have a mask and no
                        // mask bit has a corresponding event flag set.
                        if (task.event_mask != 0 and task.event_mask & task.event_flags == 0) {
                            task.state = .waiting;
                            return @ptrFromInt(RTTS.find_next_task_sp(@intFromPtr(sp)));
                        }
                    }
                },
                else => {
                    @panic("Unhandled machine exception code");
                },
            }

            return sp;
        }

        //------------------------------------------------------------------------------
        /// machine_exception interrupt service routine
        ///
        pub export fn machine_software_exception_ISR() callconv(riscv_calling_convention) void {}

        //------------------------------------------------------------------------------
        /// FIFO interrupt service routine
        ///
        pub fn fifo_ISR() callconv(.c) void {
            var theParam: u32 = 0;
            var theTask: ?*RTTS.TaskItem = null;

            std.log.debug("{s}FIFO ISR   FIFO_ST: 0x{x:08}", .{ debug_core(), SIO.FIFO_ST.raw });

            SIO.FIFO_ST.raw = 0;

            while (multicore.fifo.read()) |first_word| {
                // The high order eight bits of the first word of
                // a transfer are always 0x80.
                if ((first_word & 0xFF000000) != 0x80000000) {
                    std.log.debug("{s}   bad command 0x{x:08}", .{ debug_core(), first_word });
                    continue;
                }

                // And the next eight bits are the size of the transfer.
                const count = (first_word >> 16) & 0xFF;

                //This will always be either 1, 2, or 3.
                if (count < 1 or count > 3) {
                    std.log.debug("{s}   bad command 0x{x:08}  count: {d}", .{ debug_core(), first_word, count });
                    continue;
                }

                if (count >= 2) {
                    theTask = @ptrFromInt(multicore.fifo.read_blocking());
                }

                if (count == 3) {
                    theParam = multicore.fifo.read_blocking();
                }

                const command: FIFOCommand = @enumFromInt(first_word & 0xFF);

                if (theTask) |task| {
                    std.log.debug("{s}   dispatch: {} {s} {d}", .{ debug_core(), @intFromEnum(command), @tagName(task.tag), theParam });
                } else {
                    std.log.debug("{s}   dispatch: {} null {d}", .{ debug_core(), @intFromEnum(command), theParam });
                }

                switch (command) {
                    .dispatch => {
                        // ---------- Trigger a dispatch ---------
                        // scb.ICSR.modify( .{ .PENDSVSET = 1 });
                        // asm volatile ( "isb" );
                    },
                    .block => {},
                    else => {
                        std.log.debug("Unknown command: 0x{x:08}", .{@intFromEnum(command)});
                    },
                }
            }

            std.log.debug("{s}   done", .{debug_core()});
        }
        //==============================================================================
        // Local thread mode functions
        //==============================================================================

        //------------------------------------------------------------------------------
        /// Run the first task on this core
        fn run_first_task() noreturn {
            // Enable the FIFO interrupt

            if (RTTS.core_mask & 0x02 != 0) {
                multicore.fifo.drain();
                SIO.FIFO_ST.raw = 0;

                // ### TODO ### Enable specific interrupts
                // if (compatibility.chip == .RP2040) {
                //     if (core_id() == 0) {
                //         hal.irq.enable(.SIO_IRQ_PROC0);
                //     } else {
                //         hal.irq.enable(.SIO_IRQ_PROC1);
                //     }
                // } else {
                //     hal.irq.enable(.SIO_IRQ_FIFO);
                // }

                cpu.interrupt.enable_interrupts();
            }

            // Switch to the highest priority task

            std.log.debug("{s}Entered run_first_task", .{debug_core()});

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
                        // the initalized stack then clear the stack.

                        target_pc = a_task.stack_pointer[14];
                        target_sp = a_task.stack_pointer + 16;

                        std.log.debug("{s}   Starting task {s}", .{ debug_core(), @tagName(a_task.tag) });
                        break;
                    }
                }
            }

            asm volatile (
                \\    mv    sp, %[sp]       // Set the process stack pointer
                \\    li    t0, 0x00000000  // Set the MSTATUS register to enable interrupts
                \\    csrs  MSTATUS, t0
                \\    csrs  MEPC, %[pc]     // Set the MEPC register to the target PC
                \\    mret
                :
                : [sp] "r" (target_sp),
                  [pc] "r" (target_pc),
                : "t0"
            );

            unreachable;
        }

        //------------------------------------------------------------------------------
        /// Core1 initialization
        fn core1_init() noreturn {
            std.log.debug("{s}Init", .{debug_core()});
            run_first_task();
        }
        //==============================================================================
        // Local handler mode functions
        //==============================================================================

        //------------------------------------------------------------------------------
        /// Swap the context
        ///
        fn swap_context(in_new_task: *RTTS.TaskItem) void {
            const task = RTTS.current_task[core_id()];

            if (task) |old_task| {
                if (old_task != in_new_task) {
                    old_task.state = .runnable;
                    in_new_task.state = .running;
                    RTTS.current_task[core_id()] = in_new_task;
                }
            }
        }

        //==============================================================================
        // Null Task
        //==============================================================================

        const null_task_stack_len = 33;

        var null_task_stack: [null_task_stack_len]usize = undefined;
        pub var null_task_stack_pointer: usize = undefined;

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
