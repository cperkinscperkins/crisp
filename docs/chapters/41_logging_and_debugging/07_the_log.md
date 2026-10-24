# The Log 📝


Under `--logging-output` a kernel that logs gets one more implicit side-channel argument: the
log, a `(vector ulong :align :compact :address-space :global)` allocated by the host.  Like scratch,
it is passed down to every function that logs, and the metadata says where it sits in the
kernel's argument list.  Kernels that never log don't get it.

The log is a small header followed by messages:

| header field | meaning |
|---|---|
| `cursor` | next free word.  Advanced atomically by each message. |
| `capacity` | words available for messages |
| `dropped` | messages that did not fit |

Each message is a packet in the [Runtime Strings](#runtime-strings) format,
`[IDENTIFIER][LENGTH][x1]..[xN]`, plus the group and local id of the thread that wrote it.  The
writer claims the whole packet with one atomic add on `cursor`.  If the packet would go past
`capacity`, the writer bumps `dropped` instead and writes nothing.  The log is therefore always
the first N messages to arrive, and the host knows how many were lost.

The host side (the hoisting code):
1. allocates the log and zeroes it;
2. passes it in the position the metadata gives;
3. after the kernel finishes, decodes the messages using the metadata's string table, prints the
   die record first if there is one, and then the `dropped` count.

The hoist chooses the log size, with a default that can be overridden.



