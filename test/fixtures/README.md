# Test fixtures

Tiny ISOBMFF files used for round-trip tests. Regenerate with:

    ffmpeg -y -f lavfi -i testsrc=duration=1:size=128x96:rate=10 -pix_fmt yuv420p sample.mp4
    ffmpeg -y -f lavfi -i sine=frequency=440:duration=1 -c:a aac sample.m4a

    # Two-track (video + audio) fixture for track extraction:
    ffmpeg -y -f lavfi -i testsrc=duration=1:size=128x96:rate=10 \
      -f lavfi -i sine=frequency=440:duration=1 \
      -pix_fmt yuv420p -c:a aac -shortest sample_av.mp4

    # Multi-fragment fMP4 fixture for Phase 9 indexing/defragment.
    # 2s + forced 0.5s fragment duration -> multiple moof/mdat pairs, so the
    # inter-fragment dts realignment is genuinely exercised. default_base_moof
    # gives modern moof-relative sample addressing.
    ffmpeg -y -f lavfi -i testsrc=duration=2:size=128x96:rate=10 \
      -f lavfi -i sine=frequency=440:duration=2 \
      -pix_fmt yuv420p -c:a aac -shortest \
      -movflags frag_keyframe+empty_moov+default_base_moof -frag_duration 500000 sample_frag.mp4
