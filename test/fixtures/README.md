# Test fixtures

Tiny ISOBMFF files used for round-trip tests. Regenerate with:

    ffmpeg -y -f lavfi -i testsrc=duration=1:size=128x96:rate=10 -pix_fmt yuv420p sample.mp4
    ffmpeg -y -f lavfi -i sine=frequency=440:duration=1 -c:a aac sample.m4a
