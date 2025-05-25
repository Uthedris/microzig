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
            var sp = in_stack - 32;

            for (sp[2..32]) |*reg| {
                reg.* = 0xface_fade; // so we can spot bad values
            }

            sp[0] = @intFromPtr(in_pc);
            sp[1] = if (config.run_unprivileged) 0x0000_0080 else 0x0000_1880;

            return sp;
        }

        //------------------------------------------------------------------------------
        /// Initialize the cores
        ///
        pub fn start_cores() noreturn {

            // Set up null task stack

            null_task_stack_pointer = @ptrCast(&null_task_stack[null_task_stack_len - 32]);

            null_task_stack[0] = @intFromPtr(&null_task_loop);
            null_task_stack[1] = if (config.run_unprivileged) 0x0000_0080 else 0x0000_1880;

            // ### TODO ### uncomment below when we allow these to be set at runtime
            // _ = cpu.interrupt.core.set_handler(.Exception, .{ .riscv = machine_exception_ISR });

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

                        target_pc = a_task.stack_pointer[0];
                        target_sp = a_task.stack_pointer + 32;

                        std.log.debug("Starting task {s} pc: 0x{x:08} sp: 0x{x:08}", .{ @tagName(a_task.tag), target_pc, @intFromPtr(target_sp) });
                        break;
                    }
                }
            }

            if (config.run_unprivileged) {
                asm volatile (
                    \\    mv    sp, %[sp]        // Set the process stack pointer
                    \\    li    t0, 0x00000080   // Set the MSTATUS register
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
                    \\    li    t0, 0x00001880   // Set the MSTATUS register
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
        /// This ISR is registered as a naked function, so we can save the registers
        /// and restore the registers in a predicable way. This function calls
        /// "do_machine_exception" that does the actual dispatch in Zig.

        // The riscv does not push anything when a trap happens.  After the save
        // the stack (pointed to by sp) looks like this:
        //
       //      +------------+
        //      |  MEPC      | <- Stack pointer
        //      |  MSTATUS   | +    4  ( 1)
        //      |  gp        | +    8  ( 2)
        //      |  tp        | +   12  ( 3)
        //      |  t6        | +   16  ( 4)
        //      |  t5        | +   20  ( 5)
        //      |  t4        | +   24  ( 6)
        //      |  t3        | +   28  ( 7)
        //      |  t2        | +   32  ( 8)
        //      |  t1        | +   36  ( 9)
        //      |  t0        | +   40  (10)
        //      |  a7        | +   44  (11)
        //      |  a6        | +   48  (12)
        //      |  a5        | +   52  (13)
        //      |  a4        | +   56  (14)
        //      |  a3        | +   60  (15)
        //      |  a2        | +   64  (16)
        //      |  a1        | +   68  (17)
        //      |  a0        | +   72  (18)
        //      |  s11       | +   76  (19)
        //      |  s10       | +   80  (20)
        //      |  s9        | +   84  (21)
        //      |  s8        | +   88  (22)
        //      |  s7        | +   92  (23)
        //      |  s6        | +   96  (24)
        //      |  s5        | +  100  (25)
        //      |  s4        | +  104  (26)
        //      |  s3        | +  108  (27)
        //      |  s2        | +  112  (28)
        //      |  s1        | +  116  (29)
        //      |  s0        | +  120  (30)
        //      |  ra        | +  124  (31)
        //      +------------+


        pub fn machine_exception_ISR() callconv(.naked) noreturn {
            asm volatile (
                \\     addi    sp, sp, -128
                \\     sw      ra,  124(sp)
                \\     sw      s0,  120(sp)
                \\     sw      s1,  116(sp)
                \\     sw      s2,  112(sp)
                \\     sw      s3,  108(sp)
                \\     sw      s4,  104(sp)
                \\     sw      s5,  100(sp)
                \\     sw      s6,  96(sp)
                \\     sw      s7,  92(sp)
                \\     sw      s8,  88(sp)
                \\     sw      s9,  84(sp)
                \\     sw      s10, 80(sp)
                \\     sw      s11, 76(sp)
                \\     sw      a0,  72(sp)
                \\     sw      a1,  68(sp)
                \\     sw      a2,  64(sp)
                \\     sw      a3,  60(sp)
                \\     sw      a4,  56(sp)
                \\     sw      a5,  52(sp)
                \\     sw      a6,  48(sp)
                \\     sw      a7,  44(sp)
                \\     sw      t0,  40(sp)
                \\     sw      t1,  36(sp)
                \\     sw      t2,  32(sp)
                \\     sw      t3,  28(sp)
                \\     sw      t4,  24(sp)
                \\     sw      t5,  20(sp)
                \\     sw      t6,  16(sp)
                \\     sw      tp,  12(sp)
                \\     sw      gp,  8(sp)
                \\     csrr    ra,  MSTATUS
                \\     sw      ra,  4(sp)
                \\     csrr    ra,  MEPC
                \\     sw      ra,  0(sp)
                \\
                \\     mv      a1, sp
                \\     call    %[meh]
                \\     mv      sp, a0
                \\
                \\     lw      ra, 0(sp)
                \\     csrw    MEPC, ra
                \\     lw      ra, 4(sp)
                \\     csrw    MSTATUS, ra
                \\     lw      gp,  8(sp)
                \\     lw      tp,  12(sp)
                \\     lw      t6,  16(sp)
                \\     lw      t5,  20(sp)
                \\     lw      t4,  24(sp)
                \\     lw      t3,  28(sp)
                \\     lw      t2,  32(sp)
                \\     lw      t1,  36(sp)
                \\     lw      t0,  40(sp)
                \\     lw      a7,  44(sp)
                \\     lw      a6,  48(sp)
                \\     lw      a5,  52(sp)
                \\     lw      a4,  56(sp)
                \\     lw      a3,  60(sp)
                \\     lw      a2,  64(sp)
                \\     lw      a1,  68(sp)
                \\     lw      a0,  72(sp)
                \\     lw      s11, 76(sp)
                \\     lw      s10, 80(sp)
                \\     lw      s9,  84(sp)
                \\     lw      s8,  88(sp)
                \\     lw      s7,  92(sp)
                \\     lw      s6,  96(sp)
                \\     lw      s5,  100(sp)
                \\     lw      s4,  104(sp)
                \\     lw      s3,  108(sp)
                \\     lw      s2,  112(sp)
                \\     lw      s1,  116(sp)
                \\     lw      s0,  120(sp)
                \\     lw      ra,  124(sp)
                \\     addi    sp,  sp, 128
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
                        if (RTTS.current_task[0]) |task| {
                            task.state = .yielded;
                            ret_sp = RTTS.find_next_task_sp(sp);
                        }
                    },
                    1 => // significant_event
                    {
                        for (&RTTS.sig_event) |*sig_event| {
                            sig_event.* = true;
                        }
                        ret_sp = RTTS.find_next_task_sp(sp);
                    },
                    2 => // wait
                    {
                        if (RTTS.current_task[0]) |task| {
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
