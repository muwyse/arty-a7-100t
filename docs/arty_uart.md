# UART testing on Arty A7 100T

This document describes how to create a design on the Arty A7 that instantiates a UART transceiver.

## Requirements

In addition to the requirements described in the [README](../README.md) for the memory-only design,
this project requires `python 3.8` to execute the Host PC python script that communicates to the
on-board UART instantiated by the design.

## Setup

This project relies on code from Basejump STL, an open-source library of hardware modules that is
included as a submodule within the BlackParrot RTL code.
After checking out this repo, run the following commands from the top-level directory to
fetch the required code:

```
git submodule update --init --checkout blackparrot/rtl
cd blackparrot/rtl
git submodule update --init --checkout --recursive external/basejump_stl
```

To generate the project:
`vivado -mode batch -source tcl/arty-uart.tcl`

To run synthesis, implementation, and generate bitsream:
`vivado -mode batch -source tcl/generate_bitstream.tcl --project_name arty-uart`

## Quick Start

After compiling the bitstream for this project, remove `JP2` on the Arty A7 board. This disconnects
a reset signal originating from the on-board UART chip that can cause spurious reset signals to be
generated by the on-board UART chip.

Program the FPGA using the Vivado GUI and then the design is ready to be tested by sending
bytes from the host PC to the Arty A7 and back. To do this, invoke the `uart.py` script from the top
directory of this repository as follow:

`python py\host.py -p <serial port> -m test --iters 10 --burst 256`

After executing the above command you should see a progress bar fill and a printout reporting
PASS with an achieved throughput of data transfer. The command above runs 10 iterations with each
sending 256 bytes of data and then waiting for responses from the Arty design.

Informal testing has shown that at the pre-configured baud rate of 1,000,000 Baud the board is
capable of performing bursts up to 4096 bytes. It may be possible to perform larger bursts or to
further increase the baud rate of the uart communication. Be careful when doing so because uart
communication does not implement flow control and any overflow of send or receive buffers will
result in dropped packets.

