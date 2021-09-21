from typing import Optional

# host -> device
# TODO: 4-byte versions omitted
OPCODE_WRITE_4 = 0x02
OPCODE_WRITE_8 = 0x03
OPCODE_READ_4 = 0x12
OPCODE_READ_8 = 0x13
OPCODE_FENCE = 0xfe
OPCODE_FINISH = 0xff
OPCODE_CTRL_SET = 0x40
OPCODE_CTRL_CLEAR = 0x41
OPCODE_CTRL_WRITE = 0x42
OPCODE_CTRL_READ = 0x43

CTRL_BIT_READ_ERROR = 0x0
CTRL_BIT_WRITE_ERROR = 0x1
CTRL_BIT_WRITE_RESP = 0x2

# device -> host
OPCODE_CORE_DONE = 0x80
OPCODE_ERROR = 0x81
OPCODE_PUTCH = 0x82

# CSR addresses
ADDRESS_CSR_FREEZE = 0x0000200008
ADDRESS_CSR_ICACHE_MODE = 0x0000200204
ADDRESS_CSR_DCACHE_MODE = 0x0000200404
ADDRESS_CSR_CCE_MODE = 0x0000200604

# addresses are 40-bit by default
ADDRESS_LENGTH_BYTES = 5
DATA_LENGTH_BYTES = 8

NBF_COMMAND_LENGTH_BYTES = 1 + ADDRESS_LENGTH_BYTES + DATA_LENGTH_BYTES

class NbfParseError(RuntimeError):
    def __init__(self, message: str):
        super(NbfParseError, self).__init__(message)

def reverse_bytes(b: bytes) -> bytes:
    return bytes(reversed(b))

class NbfCommand:
    opcode: int
    address: bytes
    data: bytes

    def __init__(self, opcode, address, data):
        if len(address) != ADDRESS_LENGTH_BYTES:
            raise ValueError(f"invalid address length, must be exactly {ADDRESS_LENGTH_BYTES} bytes")

        if len(data) != DATA_LENGTH_BYTES:
            raise ValueError(f"invalid data length, must be exactly {DATA_LENGTH_BYTES} bytes")

        self.opcode = opcode
        self.address = address
        self.data = data

    @staticmethod
    def with_values(opcode: int, address_int: int, data_int: int) -> 'NbfCommand':
        """
        Creates an NbfCommand from integer values of address and data, rather than byte buffers.
        """
        return NbfCommand(
            opcode,
            address_int.to_bytes(ADDRESS_LENGTH_BYTES, 'little'),
            data_int.to_bytes(DATA_LENGTH_BYTES, 'little')
        )

    @staticmethod
    def parse(string: str) -> 'NbfCommand':
        """
        Parses a textual nbf command, of the form "03_0080000008_ff81011301000117"
        """
        part_strs = string.split('_')
        if len(part_strs) != 3:
            raise NbfParseError(f"nbf command \"{string}\" malformed, should have exactly three parts")

        opcode_str, addr_str, data_str = part_strs
        try:
            opcode = int(opcode_str, 16)
            addr = reverse_bytes(bytes.fromhex(addr_str))
            data = reverse_bytes(bytes.fromhex(data_str))
        except ValueError:
            raise NbfParseError(f"nbf command \"{string}\" malformed, contains invalid hex bytes")

        if len(addr) != ADDRESS_LENGTH_BYTES:
            raise NbfParseError(f"nbf command \"{string}\" malformed, address must be exactly {ADDRESS_LENGTH_BYTES} bytes")

        if len(data) != DATA_LENGTH_BYTES:
            raise NbfParseError(f"nbf command \"{string}\" malformed, data must be exactly {DATA_LENGTH_BYTES} bytes")

        return NbfCommand(opcode, addr, data)

    def matches(self, opcode: int, address_int: int, data_int: Optional[int]) -> bool:
        """
        Checks whether the current command has the given opcode, address and data.
        If "data" is None, checks only opcode and address.
        """
        return self.opcode == opcode \
            and self.address_int == address_int \
            and (data_int is None or self.data_int == data_int)

    def __str__(self):
        """
        Stringifies to textual nbf format.
        """
        return f"{self.opcode:02x}_{self.address_hex_str}_{reverse_bytes(self.data).hex()}"

    @property
    def address_hex_str(self) -> str:
        return reverse_bytes(self.address).hex()

    @property
    def address_int(self) -> int:
        return int.from_bytes(self.address, 'little')

    @property
    def data_hex_str(self) -> str:
        return reverse_bytes(self.data).hex()

    @property
    def data_int(self) -> int:
        return int.from_bytes(self.data, 'little')

    def to_bytes(self) -> bytes:
        return self.opcode.to_bytes(1, 'little') + self.address + self.data

    @staticmethod
    def from_bytes(b: bytes) -> 'NbfCommand':
        return NbfCommand(
            int.from_bytes(b[0:1], 'little'),
            b[1:1+ADDRESS_LENGTH_BYTES],
            b[1+ADDRESS_LENGTH_BYTES:1+ADDRESS_LENGTH_BYTES+DATA_LENGTH_BYTES],
        )

class NbfFile:
    def __init__(self, path: str):
        self.path = path

    def __iter__(self):
        with open(self.path, mode='r') as f:
            for cmd in map(NbfCommand.parse, f):
                yield cmd

    def peek_length(self) -> Optional[int]:
        """
        Reads the file to compute the total expected number of entries.
        """
        LINE_CUTOFF = 10_000
        count = 0
        with open(self.path, mode='r') as f:
            for _ in f:
                count += 1

        return count

if __name__ == '__main__':
    import unittest
    class TestNbf(unittest.TestCase):
        def test_parse(self):
            command = NbfCommand.parse("03_00800009e0_0000000080000790")
            self.assertEqual(command.opcode, 0x03)
            self.assertEqual(command.address, bytes([0xe0, 0x09, 0x00, 0x80, 0x00]))
            self.assertEqual(command.data, bytes([0x90, 0x07, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00]))

        def test_str(self):
            command = NbfCommand(
                0x03,
                bytes([0xe0, 0x09, 0x00, 0x80, 0x00]),
                bytes([0x90, 0x07, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00])
            )
            stringified = str(command)
            self.assertEqual(stringified, "03_00800009e0_0000000080000790")

        def test_fields_to_int(self):
            command = NbfCommand(
                0,
                bytes([0xe0, 0x09, 0x00, 0x80, 0x00]),
                bytes([0x90, 0x07, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00])
            )
            self.assertEqual(command.address_int, 0x800009e0)
            self.assertEqual(command.data_int, 0x80000790)

        def test_fields_to_str(self):
            command = NbfCommand(
                0,
                bytes([0xe0, 0x09, 0x00, 0x80, 0x00]),
                bytes([0x90, 0x07, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00])
            )
            self.assertEqual(command.address_hex_str, "00800009e0")
            self.assertEqual(command.data_hex_str, "0000000080000790")

        def test_to_bytes(self):
            command = NbfCommand(
                0x03,
                bytes([0xe0, 0x09, 0x00, 0x80, 0x00]),
                bytes([0x90, 0x07, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00])
            )
            byte_buffer = command.to_bytes()
            self.assertEqual(byte_buffer, bytes(
                    [0x03]
                    + [0xe0, 0x09, 0x00, 0x80, 0x00]
                    + [0x90, 0x07, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00]
                )
            )

        def test_from_bytes(self):
            byte_buffer = bytes(
                [0x03]
                + [0xe0, 0x09, 0x00, 0x80, 0x00]
                + [0x90, 0x07, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00]
            )
            command = NbfCommand.from_bytes(byte_buffer)
            self.assertEqual(command.opcode, 0x03)
            self.assertEqual(command.address, bytes([0xe0, 0x09, 0x00, 0x80, 0x00]))
            self.assertEqual(command.data, bytes([0x90, 0x07, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00]))

    unittest.main()
