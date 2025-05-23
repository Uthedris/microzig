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

pub fn configure(comptime RTTS: type, comptime config: RTTS.Configuration) type {
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

            var sp = in_stack - 32;

            for (sp[2..32]) |*reg| {
                reg.* = 0xface_fade; // so we can spot bad values
            }

            sp[0] = @intFromPtr(in_pc);
            sp[1] = if (config.run_unprivileged) 0x0000_0010 else 0x0000_1810;

            return sp;
        }

        //------------------------------------------------------------------------------
        /// Initialize the cores
        ///
        pub fn start_cores() noreturn {

            // ### TODO ### uncomment below when we allow these to be set at runtime
            // _ = irq.set_handler(.Exception, .{ .riscv = machine_exception_ISR });

            std.log.debug("{s}Entered start_cores  core_mask: 0x{x:02}", .{debug_core(), RTTS.core_mask});

            if (RTTS.core_mask & 0x02 != 0) {
                if (compatibility.chip == .RP2040) {
                    _ = irq.set_handler(.SIO_IRQ_PROC0, .{ .c = fifo_ISR });
                    _ = irq.set_handler(.SIO_IRQ_PROC1, .{ .c = fifo_ISR });
                } else {
                    _ = irq.set_handler(.SIO_IRQ_FIFO, .{ .c = fifo_ISR });
                }
                // Note: We don't enable these interrupts until after the other core is
                // launched, so we don't mess with the launch sequence.
            }

            // Set up null task stack

            null_task_stack_pointer = @ptrCast(&null_task_stack[null_task_stack_len - 32]);

            null_task_stack[0] = @intFromPtr(&null_task_loop);
            null_task_stack[1] = if (config.run_unprivileged) 0x0000_0010 else 0x0000_1810;

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
        // These ISR's  need to be registered.
        //  1. me_ISR   - (Exception)
        //  2. fifo_ISR    - (The inter-core communication interrupt service routine

        //  For time functions?
        //  3. mt_ISR   - (Machine Timer) The sysTick interrupt service routine
        //
        //  For intercore interrupt?
        //  4. ms_ISR   - (Machine Software) The inter-core interrupt service routine


        //------------------------------------------------------------------------------
        /// Machine_exception interrupt service routine
        ///
        /// This isr fires when machine exception is triggered.
        /// We use this to handle ecall instructions.
        ///
        /// This ISR is registered as a naked function, so we can save the registers
        /// and restore the registers in a predicable way. This function calls
        /// "do_machine_exception" that does the actual dispatch in Zig.

        // The riscv does not push anything when a trap happens.  After the save
        // the stack (pointed to by sp) looks like this:
        //
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

        pub fn machine_exception_ISR() callconv(.naked) noreturn {
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
                \\
                \\     mv      a1, sp
                \\     call    %[meh]
                \\
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
                : [meh] "i" (do_machine_exception),
            );
        }

        /// This function is called from the machine_exception_ISR
        ///
        /// It does the actual dispatching of the ecall instruction
        ///
        export fn do_machine_exception(in_code: u32, sp: [*]usize) callconv(.c) [*]usize {

            var ret_sp: [*]usize = sp;

            const cause = cpu.csr.mcause.read().code;

            if (cause == 0x08 or cause == 0x0b) {
                // We got here due to an ecall instruction.  The what that works
                // leaves the PC pointing to the ecall instruction itself.  We
                // must bump it by four bytes to point to the next instruction.

                sp[0] += 4;

                // Dispatch the instruction. This may change the stack pointer.
                // if a new task is dispatched.

                switch (in_code) {
                    0 => // yield
                    {
                        ret_sp = RTTS.find_next_task_sp(sp);
                    },
                    1 => // significant_event
                    {
                        for (&RTTS.sig_event) |*sig_event| {
                            sig_event.* = true;
                        }
                        ret_sp = RTTS.find_next_task_sp(sp);

                        send_fifo_command(.dispatch, null, null);
                    },
                    2 => // wait
                    {
                        if (RTTS.current_task[core_id()]) |task| {
                            // We need to wait if we have a mask and no
                            // mask bit has a corresponding event flag set.
                            if (task.event_mask != 0 and task.event_mask & task.event_flags == 0) {
                                task.state = .waiting;
                                ret_sp = RTTS.find_next_task_sp(sp);
                            }
                        }
                    },
                    else => {
                        std.log.err("Unhandled machine exception code: {d}", .{in_code});
                    },
                }
            }

            return ret_sp;
        }

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
            std.log.debug("{s}Entered run_first_task", .{debug_core()});

            // Enable the FIFO interrupt

            if (RTTS.core_mask & 0x02 != 0) {
                multicore.fifo.drain();
                SIO.FIFO_ST.raw = 0;

                if (compatibility.chip == .RP2040) {
                    if (core_id() == 0) {
                        irq.enable(.SIO_IRQ_PROC0);
                    } else {
                        irq.enable(.SIO_IRQ_PROC1);
                    }
                } else {
                    irq.enable(.SIO_IRQ_FIFO);

                    if (compatibility.arch == .riscv) {
                        cpu.interrupt.core.enable(cpu.CoreInterrupt.MachineExternal);
                    }
                }

                irq.globally_enable();
            }

            // Switch to the highest priority task

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

                        target_pc = a_task.stack_pointer[0];
                        target_sp = a_task.stack_pointer + 32;

                        std.log.debug("{s}   Starting task {s} pc: 0x{x:08} sp: 0x{x:08}", .{ debug_core(), @tagName(a_task.tag), target_pc, @intFromPtr(target_sp) });
                        break;
                    }
                }
            }

            asm volatile (
                \\    mv    sp, %[sp]        // Set the process stack pointer
                \\    li    t0, 0x00001810   // Set the MSTATUS register
                \\    csrs  MSTATUS, t0
                \\    csrs  MEPC, %[pc]      // Set the MEPC register to the target PC
                \\    mret
                :
                : [sp] "r" (target_sp),
                  [pc] "r" (target_pc),
                : "t0"
            );

            unreachable;
        }

        //==============================================================================
        // Local handler mode functions
        //==============================================================================
        // These functions are with the scheduler mutex locked
        // and must not be called from user mode.

        //------------------------------------------------------------------------------
        /// Send a command to the other core
        /// Parameters:
        ///   in_command - The command to send
        ///   in_task    - The task the command applies to
        ///   in_param   - The parameter to send
        fn send_fifo_command(in_command: FIFOCommand, in_task: ?*RTTS.TaskItem, in_param: ?u32) void {
            // If we're not using core1 then just return

            if (RTTS.core_mask & 0x02 == 0) return;

            // Compute and queue the command word:
            //
            // +---------+---------+---------+---------+
            // |  0x80   | msg len |  command number   |
            // +---------+---------+---------+---------+

            var msg_len: usize = 1;

            if (in_task != null) msg_len += 1;
            if (in_param != null) msg_len += 1;

            const command = 0x80000000 | (msg_len << 16) | @intFromEnum(in_command);

            // If the send fifo is full then we have to  wait until the
            // other core reads something off of the fifo so we can
            // send some data.

            // If the send fifo is full then ping the other core
            // so that it reads something off of the fifo.

            if (!multicore.fifo.is_write_ready()) cpu.sev();

            multicore.fifo.write_blocking(command);

            if (in_task) |task| {
                multicore.fifo.write_blocking(@intFromPtr(task));
            }

            if (in_param) |param| {
                multicore.fifo.write_blocking(param);
            }
        }

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
