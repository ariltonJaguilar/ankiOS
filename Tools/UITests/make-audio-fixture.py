import math
import struct
import sys
import wave


sample_rate = 22050
sample_count = sample_rate // 5
with wave.open(sys.argv[1], "wb") as fixture:
    fixture.setnchannels(1)
    fixture.setsampwidth(2)
    fixture.setframerate(sample_rate)
    frames = bytearray()
    for index in range(sample_count):
        sample = int(12000 * math.sin(2 * math.pi * 440 * index / sample_rate))
        frames.extend(struct.pack("<h", sample))
    fixture.writeframes(frames)
