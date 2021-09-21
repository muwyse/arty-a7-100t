#!/usr/bin/env python3

import sys
import argparse

from enum import Enum
from typing import Optional

import serial
from tqdm import tqdm

from nbf import NBF_COMMAND_LENGTH_BYTES, NbfCommand, NbfFile, ADDRESS_CSR_FREEZE
from nbf import ADDRESS_CSR_ICACHE_MODE, ADDRESS_CSR_DCACHE_MODE, ADDRESS_CSR_CCE_MODE
from nbf import OPCODE_FENCE, OPCODE_FINISH, OPCODE_READ_4, OPCODE_READ_8, OPCODE_WRITE_4, OPCODE_WRITE_8
from nbf import OPCODE_PUTCH, OPCODE_CORE_DONE, OPCODE_ERROR
from nbf import OPCODE_CTRL_SET, OPCODE_CTRL_CLEAR, OPCODE_CTRL_WRITE, OPCODE_CTRL_READ
from nbf import CTRL_BIT_READ_ERROR, CTRL_BIT_WRITE_ERROR, CTRL_BIT_WRITE_RESP

DRAM_REGION_START = 0x00_8000_0000
DRAM_REGION_END = 0x10_0000_0000

def _debug_format_message(command: NbfCommand) -> str:
    if command.opcode == OPCODE_PUTCH:
        return str(command) + f" (putch {repr(command.data[0:1].decode('utf-8'))})"
    else:
        return str(command)

class LogDomain(Enum):
    # meta info on requested commands
    COMMAND = 'command'
    # sent messages
    TRANSMIT = 'transmit'
    # received messages out-of-turn
    RECEIVE = 'receive'
    # received messages in response to a transmitted command
    REPLY = 'reply'

    @property
    def message_prefix(self):
        if self == LogDomain.COMMAND:
            return "[CMD  ]"
        elif self == LogDomain.TRANSMIT:
            return "[TX   ]"
        elif self == LogDomain.RECEIVE:
            return "[RX   ]"
        elif self == LogDomain.REPLY:
            return "[REPLY]"
        else:
            raise ValueError(f"unknown log domain '{self}'")

def _log(domain: LogDomain, message: str):
    tqdm.write(domain.message_prefix + " " + message)

class HostApp:
    def __init__(self, serial_port_name: str, serial_port_baud: int, timeout: float = 3.0):
        self.port = serial.Serial(
            port=serial_port_name,
            baudrate=serial_port_baud,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            # Without a timeout, SIGINT can't end the process while we are blocking on a read.
            timeout=timeout
        )
        self.commands_sent = 0
        self.commands_received = 0
        self.reply_violations = 0
        # default behavior is writes do not send replies
        # this can be enabled by setting the
        self.opcodes_expecting_replies = [
            OPCODE_READ_4,
            OPCODE_READ_8,
            OPCODE_FENCE,
            OPCODE_FINISH,
            OPCODE_CTRL_READ,
        ]

    def close_port(self):
        if self.port.is_open:
            self.port.close()

    def _send_message(self, command: NbfCommand):
        self.port.write(command.to_bytes())
        self.port.flush()
        self.commands_sent += 1

    def _receive_message(self, block=True) -> Optional[NbfCommand]:
        if block or self.port.in_waiting >= NBF_COMMAND_LENGTH_BYTES:
            buffer = self.port.read(NBF_COMMAND_LENGTH_BYTES)

            if len(buffer) != NBF_COMMAND_LENGTH_BYTES:
                raise ValueError(f"serial port returned {len(buffer)} bytes, but {NBF_COMMAND_LENGTH_BYTES} requested")

            self.commands_received += 1
            return NbfCommand.from_bytes(buffer)
        else:
            return None

    def _receive_until_opcode(self, opcode: int, block=True) -> Optional[NbfCommand]:
        message = self._receive_message(block=block)
        while message is not None and message.opcode != opcode:
            _log(LogDomain.RECEIVE, _debug_format_message(message))
            message = self._receive_message()

        return message

    def print_summary_statistics(self):
        _log(LogDomain.COMMAND, f" Sent:     {self.commands_sent} commands")
        _log(LogDomain.COMMAND, f" Received: {self.commands_received} commands")
        if self.reply_violations > 0:
            _log(LogDomain.COMMAND, f" Reply violations: {self.reply_violations} commands")

    def _nbf_expects_reply(self, command: NbfCommand):
        """
        Returns True if this command is known to expect a reply. Replies will have the
        same opcode as this command. False otherwise.
        """
        return command.opcode in self.opcodes_expecting_replies

    def _nbf_correct_reply(self, command: NbfCommand, reply: NbfCommand):
        """
        Checks whether the given command is a valid, correct reply for the
        current command. Returns True if correct, and False otherwise.
        """
        if not self._nbf_expects_reply(command):
            return False

        if command.opcode == OPCODE_WRITE_4:
            return reply.matches(OPCODE_WRITE_4, command.address_int, 0)
        if command.opcode == OPCODE_WRITE_8:
            return reply.matches(OPCODE_WRITE_8, command.address_int, 0)
        elif command.opcode == OPCODE_READ_4:
            return reply.matches(OPCODE_READ_4, command.address_int, command.data_int)
        elif command.opcode == OPCODE_READ_8:
            return reply.matches(OPCODE_READ_8, command.address_int, command.data_int)
        elif command.opcode == OPCODE_FENCE:
            return reply.matches(OPCODE_FENCE, 0, 0)
        elif command.opcode == OPCODE_FINISH:
            return reply.matches(OPCODE_FINISH, 0, 0)
        elif command.opcode == OPCODE_CTRL_READ:
            return reply.matches(OPCODE_CTRL_READ, None)
        else:
            return False

    def _validate_reply(self, command: NbfCommand, reply: NbfCommand) -> bool:
        if not self._nbf_correct_reply(command, reply):
            self.reply_violations += 1
            _log(LogDomain.REPLY, f'Unexpected reply: {command} -> {reply}')
            # TODO: abort on invalid reply?
            return False
        return True

    def _validate_outstanding_replies(self, command_queue_expecting_replies: list, sliding_window_num_commands: int, log_all_rx: bool = False):
        """
        Reads replies from the incoming data stream, matching them with the provided command queue
        in-order and validating each. If more than "sliding_window_num_commands" commands are in the
        queue, blocks waiting for an incoming command. Pops all validated commands from the front of
        the queue, in-place.
        """
        while len(command_queue_expecting_replies) > 0:
            sent_command = command_queue_expecting_replies[0]

            is_window_full = len(command_queue_expecting_replies) > sliding_window_num_commands
            reply = self._receive_until_opcode(
                sent_command.opcode,
                block=is_window_full
            )
            if reply is None:
                # all queued packets have been processed
                break

            if log_all_rx:
                # TODO: indicate this is an expected reply
                _log(LogDomain.RECEIVE, _debug_format_message(reply))

            # TODO: verbose/echo mode
            was_valid = self._validate_reply(sent_command, reply)
            if was_valid:
                # TODO: consider aborting on invalid reply
                command_queue_expecting_replies.pop(0)

    def test_memory(self, verbose: bool = False, sliding_window_num_commands: int = 0, write_responses: bool = False, words: int = 1):
        command: NbfCommand
        # configure the system/processor
        self._send_message(NbfCommand.with_values(OPCODE_WRITE_8, ADDRESS_CSR_FREEZE, 1))
        self._send_message(NbfCommand.with_values(OPCODE_FENCE, 0, 0))
        reply = self._receive_message(block=True)
        self._send_message(NbfCommand.with_values(OPCODE_WRITE_8, ADDRESS_CSR_ICACHE_MODE, 1))
        self._send_message(NbfCommand.with_values(OPCODE_WRITE_8, ADDRESS_CSR_DCACHE_MODE, 1))
        self._send_message(NbfCommand.with_values(OPCODE_WRITE_8, ADDRESS_CSR_CCE_MODE, 1))
        self._send_message(NbfCommand.with_values(OPCODE_FENCE, 0, 0))
        reply = self._receive_message(block=True)

        if write_responses:
          self.opcodes_expecting_replies.extend([OPCODE_WRITE_4, OPCODE_WRITE_8])
          self._send_message(NbfCommand.with_values(OPCODE_CTRL_SET, CTRL_BIT_WRITE_RESP, 1))

        outstanding_commands_expecting_replies = []

        for i in tqdm(range(int(words)), total=words, desc="writing memory"):
            addr = DRAM_REGION_START + i*8
            command = NbfCommand.with_values(OPCODE_WRITE_8, addr, i)
            self._send_message(command)
            if self._nbf_expects_reply(command):
                outstanding_commands_expecting_replies.append(command)
            if verbose:
                _log(LogDomain.TRANSMIT, _debug_format_message(command))

        for i in tqdm(range(int(words)), total=words, desc="reading memory"):
            addr = DRAM_REGION_START + i*8
            command = NbfCommand.with_values(OPCODE_READ_8, addr, i)
            self._send_message(command)
            if self._nbf_expects_reply(command):
                outstanding_commands_expecting_replies.append(command)
            #reply = self._receive_until_opcode(OPCODE_READ_8)
            #self._validate_reply(command, reply)

            self._validate_outstanding_replies(outstanding_commands_expecting_replies, sliding_window_num_commands, log_all_rx=verbose)

        self._validate_outstanding_replies(outstanding_commands_expecting_replies, 0, log_all_rx=verbose)


    def load_file(self, source_file: str, ignore_unfreezes: bool = False, sliding_window_num_commands: int = 0, log_all_messages: bool = False, write_responses: bool = False):
        if write_responses:
          self.opcodes_expecting_replies.extend([OPCODE_WRITE_4, OPCODE_WRITE_8])
          self._send_message(NbfCommand.with_values(OPCODE_CTRL_SET, CTRL_BIT_WRITE_RESP, 1))

        file = NbfFile(source_file)

        outstanding_commands_expecting_replies = []

        command: NbfCommand
        for command in tqdm(file, total=file.peek_length(), desc="loading nbf"):
            if ignore_unfreezes and command.matches(OPCODE_WRITE_8, ADDRESS_CSR_FREEZE, 0):
                continue

            if log_all_messages:
                _log(LogDomain.TRANSMIT, _debug_format_message(command))

            self._send_message(command)
            if self._nbf_expects_reply(command):
                outstanding_commands_expecting_replies.append(command)

            self._validate_outstanding_replies(outstanding_commands_expecting_replies, sliding_window_num_commands, log_all_rx=log_all_messages)

        self._validate_outstanding_replies(outstanding_commands_expecting_replies, 0, log_all_rx=log_all_messages)
        _log(LogDomain.COMMAND, "Load complete")

    def unfreeze(self):
        unfreeze_command = NbfCommand.with_values(OPCODE_WRITE_8, ADDRESS_CSR_FREEZE, 0)
        self._send_message(unfreeze_command)

        reply = self._receive_until_opcode(unfreeze_command.opcode)
        self._validate_reply(unfreeze_command, reply)

    def listen_perpetually(self, verbose: bool):
        _log(LogDomain.COMMAND, "Listening for incoming messages...")
        while message := self._receive_message():
            # in "verbose" mode, we'll always print the full message, even for putchar
            if not verbose and message.opcode == OPCODE_PUTCH:
                print(chr(message.data[0]), end = '')
                continue

            _log(LogDomain.RECEIVE, _debug_format_message(message))

            if message.opcode == OPCODE_CORE_DONE:
                status = f"FAIL, code {message.data_int}" if message.data_int else "PASS"
                print(f"FINISH: core {message.address_int} {status}")
                # TODO: this assumes unicore
                return

    def verify(self, reference_file: str):
        file = NbfFile(reference_file)

        writes_checked = 0
        writes_corrupted = 0

        command: NbfCommand
        for command in tqdm(file, total=file.peek_length(), desc="verifying nbf"):
            if command.opcode != OPCODE_WRITE_8:
                continue

            if command.address_int < DRAM_REGION_START or command.address_int > DRAM_REGION_END - 8:
                continue

            read_message = NbfCommand.with_values(OPCODE_READ_8, command.address_int, 0)
            self._send_message(read_message)
            reply = self._receive_until_opcode(OPCODE_READ_8)
            self._validate_reply(read_message, reply)

            writes_checked += 1

            if reply.data != command.data:
                writes_corrupted += 1
                _log(LogDomain.COMMAND, f"Corruption detected at address 0x{command.address_hex_str}")
                _log(LogDomain.COMMAND, f" Expected: 0x{command.data_hex_str}")
                _log(LogDomain.COMMAND, f" Actual:   0x{reply.data_hex_str}")

        _log(LogDomain.COMMAND, "Verify complete")
        _log(LogDomain.COMMAND, f" Writes checked:       {writes_checked}")
        _log(LogDomain.COMMAND, f" Corrupt writes found: {writes_corrupted}")
        if writes_corrupted > 0:
            _log(LogDomain.COMMAND, "== CORRUPTION DETECTED ==")

def _load_command(app: HostApp, args):
    app.load_file(
        args.file,
        ignore_unfreezes=args.no_unfreeze,
        sliding_window_num_commands=args.window_size,
        log_all_messages=args.verbose,
        write_responses=args.write_responses
    )
    app.print_summary_statistics()

    if args.listen:
        app.listen_perpetually(verbose=args.verbose)

def _unfreeze_command(app: HostApp, args):
    app.unfreeze()

    if args.listen:
        app.listen_perpetually(verbose=False)

def _verify_command(app: HostApp, args):
    app.verify(args.file)
    app.print_summary_statistics()

def _listen_command(app: HostApp, args):
    app.listen_perpetually(verbose=False)

def _test_command(app: HostApp, args):
    app.test_memory(
            verbose=args.verbose,
            sliding_window_num_commands=args.window_size,
            write_responses=args.write_responses,
            words=args.words
    )
    app.print_summary_statistics()

if __name__ == "__main__":
    root_parser = argparse.ArgumentParser()
    root_parser.add_argument('-p', '--port', dest='port', type=str, default='COM4', help='Serial port (full path or name)')
    root_parser.add_argument('-b', '--baud', dest='baud_rate', type=int, default=500000, help='Serial port baud rate')
    root_parser.add_argument('-t', '--timeout', dest='timeout', type=float, default=3.0, help='Timeout in seconds')

    command_parsers = root_parser.add_subparsers(dest="command")
    command_parsers.required = True

    load_parser = command_parsers.add_parser("load", help="Stream a file of NBF commands to the target")
    load_parser.add_argument('file', help="NBF-formatted file to load")
    load_parser.add_argument('--no-unfreeze', action='store_true', dest='no_unfreeze', help='Suppress any "unfreeze" commands in the input file')
    load_parser.add_argument('--listen', action='store_true', dest='listen', help='Continue listening for incoming messages until program is aborted')
    load_parser.add_argument('--window-size', type=int, default=256, dest='window_size', help='Specifies the maximum number of outstanding replies to allow before blocking')
    load_parser.add_argument('--verbose', action='store_true', dest='verbose', help='Log all send and received commands, even if valid')
    load_parser.add_argument('--write-responses', action='store_true', dest='write_responses', help='Enable write responses in FPGA Host')
    # TODO: add --verify which automatically implies --no-unfreeze then manually unfreezes after
    # TODO: add --verbose which prints all sent and received commands
    load_parser.set_defaults(handler=_load_command)

    unfreeze_parser = command_parsers.add_parser("unfreeze", help="Send an \"unfreeze\" command to the target")
    unfreeze_parser.add_argument('--listen', action='store_true', dest='listen', help='Continue listening for incoming messages until program is aborted')
    unfreeze_parser.set_defaults(handler=_unfreeze_command)

    verify_parser = command_parsers.add_parser("verify", help="Read back the results of an NBF file's memory writes and confirm that their values match the original file")
    verify_parser.add_argument('file', help="NBF-formatted file to load")
    verify_parser.set_defaults(handler=_verify_command)

    listen_parser = command_parsers.add_parser("listen", help="Watch for incoming messages and print the received data")
    listen_parser.set_defaults(handler=_listen_command)

    test_parser = command_parsers.add_parser("test", help="full memory test")
    test_parser.add_argument('--window-size', type=int, default=256, dest='window_size', help='Specifies the maximum number of outstanding replies to allow before blocking')
    test_parser.add_argument('--verbose', action='store_true', dest='verbose', help='Log all send and received commands, even if valid')
    test_parser.add_argument('--write-responses', action='store_true', dest='write_responses', help='Enable write responses in FPGA Host')
    test_parser.add_argument('--words', type=int, default=8192, dest='words', help='Number of words to write and read from memory')
    test_parser.set_defaults(handler=_test_command)

    args = root_parser.parse_args()

    app = HostApp(serial_port_name=args.port, serial_port_baud=args.baud_rate, timeout=args.timeout)
    try:
        args.handler(app, args)
        app.close_port()
    except KeyboardInterrupt:
        app.close_port()
        print("Aborted")
        sys.exit(1)
