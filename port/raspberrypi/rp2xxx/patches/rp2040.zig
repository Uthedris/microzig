const Patch = @import("microzig/build-internals").Patch;

pub const patches: []const Patch = &.{
    .{
        .add_enum = .{
            .parent = "types.peripherals.PADS_BANK0",
            .@"enum" = .{
                .name = "DriveStrength",
                .bitsize = 2,
                .fields = &.{
                    .{ .value = 0x0, .name = "2mA" },
                    .{ .value = 0x1, .name = "4mA" },
                    .{ .value = 0x2, .name = "8mA" },
                    .{ .value = 0x3, .name = "12mA" },
                },
            },
        },
    },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO0.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO1.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO2.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO3.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO4.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO5.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO6.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO7.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO8.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO9.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO10.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO11.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO12.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO13.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO14.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO15.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO16.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO17.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO18.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO19.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO20.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO21.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO22.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO23.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO24.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO25.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO26.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO27.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO28.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.PADS_BANK0.GPIO29.DRIVE", .to = "types.peripherals.PADS_BANK0.DriveStrength" } },
    .{
        .add_enum = .{
            .parent = "types.peripherals.USB_DPRAM",
            .@"enum" = .{
                .name = "EndpointType",
                .bitsize = 2,
                .fields = &.{
                    .{ .value = 0x0, .name = "control" },
                    .{ .value = 0x1, .name = "isochronous" },
                    .{ .value = 0x2, .name = "bulk" },
                    .{ .value = 0x3, .name = "interrupt" },
                },
            },
        },
    },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP1_IN_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP1_OUT_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP2_IN_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP2_OUT_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP3_IN_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP3_OUT_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP4_IN_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP4_OUT_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP5_IN_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP5_OUT_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP6_IN_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP6_OUT_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP7_IN_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP7_OUT_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP8_IN_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP8_OUT_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP9_IN_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP9_OUT_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP10_IN_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP10_OUT_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP11_IN_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP11_OUT_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP12_IN_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP12_OUT_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP13_IN_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP13_OUT_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP14_IN_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP14_OUT_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP15_IN_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.USB_DPRAM.EP15_OUT_CONTROL.ENDPOINT_TYPE", .to = "types.peripherals.USB_DPRAM.EndpointType" } },
    .{
        .add_enum = .{
            .parent = "types.peripherals.DMA",
            .@"enum" = .{
                .name = "DataSize",
                .bitsize = 2,
                .fields = &.{
                    .{ .value = 0x0, .name = "size_8" },
                    .{ .value = 0x1, .name = "size_16" },
                    .{ .value = 0x2, .name = "size_32" },
                },
            },
        },
    },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH0_CTRL_TRIG.DATA_SIZE", .to = "types.peripherals.DMA.DataSize" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH1_CTRL_TRIG.DATA_SIZE", .to = "types.peripherals.DMA.DataSize" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH2_CTRL_TRIG.DATA_SIZE", .to = "types.peripherals.DMA.DataSize" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH3_CTRL_TRIG.DATA_SIZE", .to = "types.peripherals.DMA.DataSize" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH4_CTRL_TRIG.DATA_SIZE", .to = "types.peripherals.DMA.DataSize" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH5_CTRL_TRIG.DATA_SIZE", .to = "types.peripherals.DMA.DataSize" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH6_CTRL_TRIG.DATA_SIZE", .to = "types.peripherals.DMA.DataSize" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH7_CTRL_TRIG.DATA_SIZE", .to = "types.peripherals.DMA.DataSize" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH8_CTRL_TRIG.DATA_SIZE", .to = "types.peripherals.DMA.DataSize" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH9_CTRL_TRIG.DATA_SIZE", .to = "types.peripherals.DMA.DataSize" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH10_CTRL_TRIG.DATA_SIZE", .to = "types.peripherals.DMA.DataSize" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH11_CTRL_TRIG.DATA_SIZE", .to = "types.peripherals.DMA.DataSize" } },
    .{
        .add_enum = .{
            .parent = "types.peripherals.DMA",
            .@"enum" = .{
                .name = "Dreq",
                .bitsize = 6,
                .fields = &.{
                    .{ .value = 0, .name = "pio0_tx0" },
                    .{ .value = 1, .name = "pio0_tx1" },
                    .{ .value = 2, .name = "pio0_tx2" },
                    .{ .value = 3, .name = "pio0_tx3" },
                    .{ .value = 4, .name = "pio0_rx0" },
                    .{ .value = 5, .name = "pio0_rx1" },
                    .{ .value = 6, .name = "pio0_rx2" },
                    .{ .value = 7, .name = "pio0_rx3" },
                    .{ .value = 8, .name = "pio1_tx0" },
                    .{ .value = 9, .name = "pio1_tx1" },
                    .{ .value = 10, .name = "pio1_tx2" },
                    .{ .value = 11, .name = "pio1_tx3" },
                    .{ .value = 12, .name = "pio1_rx0" },
                    .{ .value = 13, .name = "pio1_rx1" },
                    .{ .value = 14, .name = "pio1_rx2" },
                    .{ .value = 15, .name = "pio1_rx3" },
                    .{ .value = 16, .name = "spi0_tx" },
                    .{ .value = 17, .name = "spi0_rx" },
                    .{ .value = 18, .name = "spi1_tx" },
                    .{ .value = 19, .name = "spi1_rx" },
                    .{ .value = 20, .name = "uart0_tx" },
                    .{ .value = 21, .name = "uart0_rx" },
                    .{ .value = 22, .name = "uart1_tx" },
                    .{ .value = 23, .name = "uart1_rx" },
                    .{ .value = 24, .name = "pwm_wrap0" },
                    .{ .value = 25, .name = "pwm_wrap1" },
                    .{ .value = 26, .name = "pwm_wrap2" },
                    .{ .value = 27, .name = "pwm_wrap3" },
                    .{ .value = 28, .name = "pwm_wrap4" },
                    .{ .value = 29, .name = "pwm_wrap5" },
                    .{ .value = 30, .name = "pwm_wrap6" },
                    .{ .value = 31, .name = "pwm_wrap7" },
                    .{ .value = 32, .name = "i2c0_tx" },
                    .{ .value = 33, .name = "i2c0_rx" },
                    .{ .value = 34, .name = "i2c1_tx" },
                    .{ .value = 35, .name = "i2c1_rx" },
                    .{ .value = 36, .name = "adc" },
                    .{ .value = 37, .name = "xip_stream" },
                    .{ .value = 38, .name = "xip_ssitx" },
                    .{ .value = 39, .name = "xip_ssirx" },
                    .{ .value = 59, .name = "timer0" },
                    .{ .value = 60, .name = "timer1" },
                    .{ .value = 61, .name = "timer2" },
                    .{ .value = 62, .name = "timer3" },
                    .{ .value = 63, .name = "permanent" },
                },
            },
        },
    },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH0_CTRL_TRIG.TREQ_SEL", .to = "types.peripherals.DMA.Dreq" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH1_CTRL_TRIG.TREQ_SEL", .to = "types.peripherals.DMA.Dreq" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH2_CTRL_TRIG.TREQ_SEL", .to = "types.peripherals.DMA.Dreq" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH3_CTRL_TRIG.TREQ_SEL", .to = "types.peripherals.DMA.Dreq" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH4_CTRL_TRIG.TREQ_SEL", .to = "types.peripherals.DMA.Dreq" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH5_CTRL_TRIG.TREQ_SEL", .to = "types.peripherals.DMA.Dreq" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH6_CTRL_TRIG.TREQ_SEL", .to = "types.peripherals.DMA.Dreq" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH7_CTRL_TRIG.TREQ_SEL", .to = "types.peripherals.DMA.Dreq" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH8_CTRL_TRIG.TREQ_SEL", .to = "types.peripherals.DMA.Dreq" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH9_CTRL_TRIG.TREQ_SEL", .to = "types.peripherals.DMA.Dreq" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH10_CTRL_TRIG.TREQ_SEL", .to = "types.peripherals.DMA.Dreq" } },
    .{ .set_enum_type = .{ .of = "types.peripherals.DMA.CH11_CTRL_TRIG.TREQ_SEL", .to = "types.peripherals.DMA.Dreq" } },
};
