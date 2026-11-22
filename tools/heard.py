#!/usr/bin/env python3
"""What a machine played, from the file that QEMU wrote of it.

usage: tools/heard.py build/sound-<name>.wav

tools/boottest.sh gives every machine a sound card whose sound goes into a
file (`-audiodev wav`), frame for frame as the machine sent it. This says
what is in such a file in a way that can be read and held against a
session: a line for every stretch of sound, with how long it is, how often
it turns, and how far it goes on each side.

    500 ms, 220 turns, 8192 left, 8192 right

A turn is counted wherever the two sides together come up through
nothing, so a tone of 440 turns a second has 220 of them in half a second,
and several notes one after the other have the sum of theirs. How far is
the largest number of the stretch, of the 32767 that a number of 16 bits
goes to. A stretch ends where nothing is played for five thousandths of a
second; a silence of a twentieth of a second or more between two stretches
has a line of its own, "100 ms of nothing", and a shorter one has none:
the machine ends whatever it plays with a hundredth of a second of
nothing.

All of it is counting in whole numbers, so the same file gives the same
lines on every computer. The lengths that the file's own header gives are
not gone by: QEMU writes them when it ends, and not when it is stopped.
"""
import struct
import sys


def frames_of(path):
    """The frames of a file, as pairs of numbers, and how many there are to the second."""
    with open(path, "rb") as file:
        data = file.read()
    if data[:4] != b"RIFF" or data[8:16] != b"WAVEfmt " or data[36:40] != b"data":
        sys.exit(f"{path} is not a file of sound as QEMU writes it")
    kind, sides, rate, _, _, bits = struct.unpack("<HHIIHH", data[20:36])
    if (kind, sides, bits) != (1, 2, 16):
        sys.exit(f"{path} is not 16 bits on two sides: kind {kind}, {sides} sides, {bits} bits")
    count = (len(data) - 44) // 4
    numbers = struct.unpack(f"<{2 * count}h", data[44:44 + 4 * count])
    return list(zip(numbers[0::2], numbers[1::2])), rate


def stretches(frames, rate):
    """The stretches of sound: (first frame, one past the last), with nothing for 5 ms between two."""
    found, start, last = [], None, None
    for at, (left, right) in enumerate(frames):
        if left or right:
            if start is None:
                start = at
            elif at - last > rate // 200:
                found.append((start, last + 1))
                start = at
            last = at
    if start is not None:
        found.append((start, last + 1))
    return found


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    frames, rate = frames_of(sys.argv[1])
    before = None
    for start, end in stretches(frames, rate):
        if before is not None and (start - before) * 20 >= rate:
            print(f"{round((start - before) * 1000 / rate)} ms of nothing")
        turns, below = 0, False
        for left, right in frames[start:end + 1]:   # with the frame after it, where the last turn ends
            both = left + right
            if both < 0:
                below = True
            elif below:
                below = False
                turns += 1
        print(f"{round((end - start) * 1000 / rate)} ms, {turns} turns, "
              f"{max(abs(left) for left, _ in frames[start:end])} left, "
              f"{max(abs(right) for _, right in frames[start:end])} right")
        before = end


if __name__ == "__main__":
    main()
