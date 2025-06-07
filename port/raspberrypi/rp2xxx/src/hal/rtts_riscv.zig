//! This is the platform specific code for the RTTS scheduler for the
//! RP2350 dual core risc-v processor.
//!
//! To use dual processor mode, RTTS must be started on core 0.
//!
//! System resources used:
//!   - Exception handler (Machine Exception) for `ecall` instruction dispatch.
//!   - Machine Software interrupt for inter-core communication (when configured for both cores).

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
        /// Get the ID of the current core [0..RTTS.core_count]
        ///
        pub fn core_id() u8 {
            return @intCast(hal.get_cpu_id());
        }

        /// Get a string that can be used to identify the current core for debug messages.
        ///
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
            sp[1] = if (config.run_unprivileged) 0x0000_0080 else 0x0000_1880;

            return sp;
        }

        //------------------------------------------------------------------------------
        /// Initialize the cores
        ///
        pub fn start_cores() noreturn {

            // ### TODO ### uncomment below when we allow these to be set at runtime
            // _ = cpu.interrupt.core.set_handler(.MachineSoftware, .{ .naked = machine_software_ISR });

            std.log.debug("{s}Entered start_cores  core_mask: 0x{x:02}", .{ debug_core(), RTTS.core_mask });

            // Setup for multiple cores if configured.

            if (RTTS.core_count > 1) {
                multicore.launch_core1(run_first_task);
            }

            // Configure the machine timer

            disable_timer();

            SIO.MTIME_CTRL.modify(.{ .EN = 0 });

            SIO.MTIME.write_raw(0);
            SIO.MTIMEH.write_raw(0);
                
            const initial_timer_value = 1_000_000 / config.resolution;

            // Note: If the timer expires too soon, it will cause a machine exception.
            //       If debug logging is added to run_first_task, the initial timer
            //       value should be set to a larger value to allow time for the
            //       first task to run before the timer expires.
            
            SIO.MTIMECMPH.write_raw(0);
            SIO.MTIMECMP.write_raw(initial_timer_value);            

            SIO.MTIME_CTRL.modify(.{ .EN = 1 });

            if (RTTS.first_timer != null) {
                cpu.interrupt.core.enable(.MachineTimer);
            }

            run_first_task();
        }


        //------------------------------------------------------------------------------
        /// Perform a reschedule (this core)
        ///
        pub fn reschedule() void {
            // Trigger the softirq for this core
            SIO.RISCV_SOFTIRQ.write_raw(if (core_id() == 0) 0x01 else 0x02);
        }

        //------------------------------------------------------------------------------
        /// Perform a reschedule (all cores)
        ///
        pub fn reschedule_all_cores() void {
            if (RTTS.core_count > 1) {
                // Trigger the softirq for the other core
                SIO.RISCV_SOFTIRQ.write_raw(if (core_id() == 0) 0x02 else 0x01);

                microzig.cpu.sev();
            }

            // Trigger the softirq for this core
            SIO.RISCV_SOFTIRQ.write_raw(if (core_id() == 0) 0x01 else 0x02);
        }

        //------------------------------------------------------------------------------
        /// Perfom a reschedule_all_cores from an ISR.
        /// For the RP2xxx this is the same as the normal reschedule_all_cores.
        ///
        pub fn reschedule_all_cores_isr() void {
            reschedule_all_cores();
        }

        //----------------------------------------------------------------------------
        /// Switch to the null task.
        pub fn switch_to_null_task() [*]usize {

            const null_task_stack_pointer: [*]usize = @ptrCast(&null_task_stack[core_id()][null_task_stack_len - 32]);

            null_task_stack_pointer[0] = @intFromPtr(&null_task_loop);
            null_task_stack_pointer[1] = if (config.run_unprivileged) 0x0000_0080 else 0x0000_1880;

            return null_task_stack_pointer;
        }

        //------------------------------------------------------------------------------
        /// Enable the timer interrupt
        pub fn enable_timer() void {
            var new_time: u64 = SIO.MTIMEH.raw;
            new_time <<= 32; 
            new_time += SIO.MTIME.raw;

            new_time += 1_000_000 / config.resolution;
            
            SIO.MTIMECMPH.write_raw(@intCast(new_time >> 32));
            SIO.MTIMECMP.write_raw(@truncate(new_time));            

            cpu.interrupt.core.enable(.MachineTimer);
        }

        //------------------------------------------------------------------------------
        /// Disable the timer interrupt
        pub fn disable_timer() void {
            cpu.interrupt.core.disable(.MachineTimer);
        }

        //==============================================================================
        // Local thread mode functions
        //==============================================================================

        //------------------------------------------------------------------------------
        /// Run the first task on this core
        fn run_first_task() noreturn {
            if (RTTS.core_count > 1) {
                irq.globally_enable();
                cpu.interrupt.core.enable(.MachineSoftware);
            }

            // Find the highest priority task.  If launched on multiple
            // cores, each will pick a different task.

            var target_sp: [*]usize = switch_to_null_task();
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
                        RTTS.next_task = a_task.next;
                        break;
                    }
                }
            }

            if (core_id() == 0) {
                irq.globally_enable();
                cpu.interrupt.core.enable(.MachineSoftware);
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
        //  - ms_ISR   - (Machine Software) The reschedule interrupt service routine
        //
        //  For time functions?
        //  - mt_ISR   - (Machine Timer) The sysTick interrupt service routine

        //------------------------------------------------------------------------------
        /// Machine_software interrupt service routine
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

        pub fn machine_software_ISR() callconv(.naked) noreturn {
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
                \\     mv      a0, sp
                \\     call    %[next]
                \\     mv      sp, a0
                \\
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
                : [next] "i" (next_task),
            );
        }

        /// This function is called from the machine_software_ISR.
        export fn next_task(sp: [*]usize) callconv(.c) [*]usize {
            // std.log.debug("{s}  ### Software ISR ###", .{debug_core()});

            // Clear the softirq for this core
            SIO.RISCV_SOFTIRQ.write_raw(if (core_id() == 0) 0x100 else 0x200);

            return RTTS.find_next_task_sp(sp);
        }

        //------------------------------------------------------------------------------
        /// machine timer interrupt service routine
        ///
        pub fn machine_timer_ISR() callconv(riscv_calling_convention) void {

            var new_time: u64 = SIO.MTIMECMPH.raw;
            new_time <<= 32; 
            new_time += SIO.MTIMECMP.raw;

            new_time += 1_000_000 / config.resolution;
            
            SIO.MTIMECMPH.write_raw(@intCast(new_time >> 32));
            SIO.MTIMECMP.write_raw(@truncate(new_time));            
 
            RTTS.Timer.tick();
        }

        //==============================================================================
        // Null Task
        //==============================================================================

        const null_task_stack_len = 128;

        var null_task_stack: [RTTS.core_count][null_task_stack_len]usize = undefined;

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
