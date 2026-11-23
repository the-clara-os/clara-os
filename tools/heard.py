#!/usr/bin/env python3
"""What a machine played, from the file that QEMU wrote of it.

usage: tools/heard.py build/sound-<name>.wav
       tools/heard.py --about "1000 ms, 440 turns, 8192 left, 8192 right" build/sound-<name>.wav

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

That holds for virtio's card, which plays what it is handed and waits for
more. Intel's card goes by the clock: it takes the next numbers out of the
machine's memory when their time has come, whether the machine has put
them there or not, and QEMU, for its part, throws away what its codec
holds when it has fallen behind its own clock (hw/audio/hda-codec.c,
"drop buffer"). So a machine with that card that was late for a moment
has a gap in what it played, and the file may lack a few hundredths of a
second: frame for frame is more than can be asked of it. With --about, the file is held
against one line of the kind above, for the one sound that such a session
plays, all its stretches taken together: at least half as long, and no
longer; as many turns to the second, to a part in twenty-five; as far out
on each side, to a part in a hundred. When it is like that, the line comes
back with "about" before it, and otherwise the file is described as
always.
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


def turns_of(frames, start, end):
    """How often a stretch turns: with the frame after it, where the last turn ends."""
    turns, below = 0, False
    for left, right in frames[start:end + 1]:
        both = left + right
        if both < 0:
            below = True
        elif below:
            below = False
            turns += 1
    return turns


def like(frames, rate, line):
    """Is what the file holds like the one sound that the line describes?"""
    words = line.replace(",", " ").split()
    try:
        length, turns, left, right = int(words[0]), int(words[2]), int(words[4]), int(words[6])
    except (IndexError, ValueError):
        sys.exit(f'tools/heard.py: "{line}" is not a line like "1000 ms, 440 turns, 8192 left, 8192 right"')
    found = stretches(frames, rate)
    if not found:
        return False
    heard = sum(end - start for start, end in found) * 1000 / rate
    turned = sum(turns_of(frames, start, end) for start, end in found)
    far_left = max(abs(a) for start, end in found for a, _ in frames[start:end])
    far_right = max(abs(b) for start, end in found for _, b in frames[start:end])
    return (length / 2 <= heard <= length + 10
            and abs(turned * length - turns * heard) * 25 <= turns * heard
            and abs(far_left - left) * 100 <= max(left, 100)
            and abs(far_right - right) * 100 <= max(right, 100))


def main():
    about = None
    if len(sys.argv) == 4 and sys.argv[1] == "--about":
        about = sys.argv[2]
    elif len(sys.argv) != 2:
        sys.exit(__doc__)
    frames, rate = frames_of(sys.argv[-1])
    if about is not None and like(frames, rate, about):
        print(f"about {about}")
        return
    before = None
    for start, end in stretches(frames, rate):
        if before is not None and (start - before) * 20 >= rate:
            print(f"{round((start - before) * 1000 / rate)} ms of nothing")
        print(f"{round((end - start) * 1000 / rate)} ms, {turns_of(frames, start, end)} turns, "
              f"{max(abs(left) for left, _ in frames[start:end])} left, "
              f"{max(abs(right) for _, right in frames[start:end])} right")
        before = end


if __name__ == "__main__":
    main()
