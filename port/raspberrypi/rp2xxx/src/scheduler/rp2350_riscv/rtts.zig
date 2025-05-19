// zig fmt: off

const std           = @import( "std" );
const microzig      = @import( "microzig" );

const hal           = microzig.hal;
const cpu           = microzig.cpu;
const chip          = microzig.chip;

const irq           = hal.irq;
const multicore     = hal.multicore;
const time          = hal.time;
const compatibility = hal.compatibility;

const peripherals   = chip.peripherals;

const PPB           = peripherals.PPB;
const SIO           = peripherals.SIO;

const csr           = cpu.csr;

pub const SvcID = enum(u8)
{
  yield             = 0x00,
  significant_event = 0x01,
  wait              = 0x02,
};

const FIFOCommand = enum(u8)
{
  dispatch,
  block,
  _,
};

const riscv_calling_convention: std.builtin.CallingConvention = .{ .riscv32_interrupt = .{ .mode = .machine } };

pub fn Configure( comptime RTTS : type ) type
{
  return struct
  {
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
    pub fn coreID() u8
    {
      return @intCast( hal.get_cpu_id() );
    }

    pub fn debugCore() []const u8
    {
      return if (coreID() == 0) "Core 0 " else "Core 1                                       ";
    }

    //------------------------------------------------------------------------------
    /// Initialize the stack for a task as though it had been swapped out
    ///
    pub fn initializeStack( in_stack : [*]usize,
                            in_pc    : *const fn() void ) [*]usize
    {
      _ = in_pc;
      return in_stack;
    }


    //------------------------------------------------------------------------------
    /// Initialize the cores
    ///
    pub fn startCores() noreturn
    {
      while (true) {}
    }

    //------------------------------------------------------------------------------
    /// Send the yield SVC
    ///
    pub fn yield() void
    {
        asm volatile (
        \\ li    a0, 0
        \\ ecall
        );
    }

    //------------------------------------------------------------------------------
    /// Post a significant event
    ///
    pub fn significantEvent() void
    {
          asm volatile (
        \\ li    a0, 1
        \\ ecall
        );
    }

    //------------------------------------------------------------------------------
    /// Send the wait SVC
    ///
    pub fn wait() void
    {
      asm volatile (
        \\ li    a0, 2
        \\ ecall
        );

    //   else
    //   {
    //     if (RTTS.current_task[coreID()]) |task|
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
    pub export fn machine_exception_ISR() callconv(riscv_calling_convention) void
    {
      switch (csr.mcause.read().code)
      {
        0x8 => // ecall in User mode
        {
        },
        0xb => // ecall in Machine mode
        {
        },
        else =>
        {
          @panic( "Unhandled machine exception" );
        },
      }
    }

    //------------------------------------------------------------------------------
    /// machine_exception interrupt service routine
    ///
    pub export fn machine_software_exception_ISR() callconv(riscv_calling_convention) void
    {
      // Handle an interrupt from the other core.
    }

    //------------------------------------------------------------------------------
    /// FIFO interrupt service routine
    ///
    pub fn fifo_ISR() callconv( .c ) void
    {
      var theParam : u32 = 0;
      var theTask  : ?*RTTS.TaskItem = null;

      std.log.debug( "{s}FIFO ISR   FIFO_ST: 0x{x:08}", .{debugCore(), SIO.FIFO_ST.raw} );

      SIO.FIFO_ST.raw = 0;

      while (multicore.fifo.read()) |first_word|
      {
        // The high order eight bits of the first word of
        // a transfer are always 0x80.
        if ((first_word & 0xFF000000) != 0x80000000)
        {
          std.log.debug( "{s}   bad command 0x{x:08}", .{debugCore(), first_word });
          continue;
        }

        // And the next eight bits are the size of the transfer.
        const count = (first_word >> 16) & 0xFF;

        //This will always be either 1, 2, or 3.
        if (count < 1  or  count > 3)
        {
          std.log.debug( "{s}   bad command 0x{x:08}  count: {d}", .{debugCore(), first_word, count });
          continue;
        }

        if (count >= 2)
        {
          theTask = @ptrFromInt( multicore.fifo.read_blocking() );
        }

        if (count == 3)
        {
          theParam = multicore.fifo.read_blocking();
        }

        const command : FIFOCommand = @enumFromInt( first_word & 0xFF );

        if (theTask) |task|
        {
          std.log.debug( "{s}   dispatch: {} {s} {d}", .{debugCore(), @intFromEnum( command ), task.name, theParam });
        }
        else
        {
          std.log.debug( "{s}   dispatch: {} null {d}", .{debugCore(), @intFromEnum( command ), theParam });
        }

        switch (command)
        {
          .dispatch =>
          {
            // ---------- Trigger a dispatch ---------
            // scb.ICSR.modify( .{ .PENDSVSET = 1 });
            // asm volatile ( "isb" );
          },
          .block =>
          {

          },
          else =>
          {
            std.log.debug( "Unknown command: 0x{x:08}", .{@intFromEnum( command )} );
          },
        }
      }

      std.log.debug( "{s}   done", .{debugCore()} );
    }
  };
}