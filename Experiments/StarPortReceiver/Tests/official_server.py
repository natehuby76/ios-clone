"""Unmodified pinned Dom protocol server; test-only certificates and media."""
import base64
from fractions import Fraction
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import time
sys.path.insert(0, os.environ['STARPORT_OFFICIAL_SOURCE'])
from openpilot.starpilot.system.starport.session import ProjectionSession
from openpilot.starpilot.system.starport.tests.fake_head_unit import make_identity
from cryptography import x509
from cryptography.hazmat.primitives.serialization import Encoding

if sys.argv[1] == 'decode':
    import av
    with av.open(sys.argv[2], format='h264') as stream:
        frames = list(stream.decode(video=0))
    assert len(frames) == 10, len(frames)
    for index, frame in enumerate(frames):
        assert (frame.width, frame.height) == (1280, 720)
        assert abs(bytes(frame.planes[0])[0] - (80 + index * 4)) <= 3
    print(json.dumps({'decoded': len(frames), 'resolution': [1280, 720], 'pixelsVerified': True}), flush=True)
    raise SystemExit(0)

with tempfile.TemporaryDirectory() as directory:
    identity = make_identity(Path(directory))
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    listener.settimeout(15)
    certificate = x509.load_pem_x509_certificate(identity['phone_cert'].read_bytes()).public_bytes(Encoding.DER)
    print(json.dumps({'port': listener.getsockname()[1], 'certificate': base64.b64encode(certificate).decode()}), flush=True)
    peer, _ = listener.accept()
    peer.settimeout(15)
    session = ProjectionSession(peer, str(identity['phone_cert']), str(identity['phone_key']))
    real_media = sys.argv[1] == 'media'
    session.fragment_acks = sys.argv[1] in ('fragment', 'media')
    session.authenticate()
    mode = session.start('Unmodified Dom integration fixture', 'comma.ai')
    assert (mode.width, mode.height, mode.codec) == (1280, 720, 3), mode
    deadline = time.monotonic() + 10
    def pump_until(predicate):
        while not predicate():
            assert time.monotonic() < deadline, 'Protocol did not advance'
            session.pump(.01)
    pump_until(lambda: session.focused)
    if real_media:
        import av
        encoder = av.CodecContext.create('libx264', 'w')
        encoder.width, encoder.height = mode.width, mode.height
        encoder.pix_fmt = 'yuv420p'
        encoder.time_base, encoder.framerate = Fraction(1, 30), Fraction(30, 1)
        encoder.options = {'preset': 'ultrafast', 'tune': 'zerolatency', 'profile': 'baseline', 'crf': '25', 'bf': '0'}
        packets = []
        for number in range(10):
            frame = av.VideoFrame(mode.width, mode.height, 'yuv420p')
            frame.pts = number
            for plane, value in zip(frame.planes, (80 + number * 4, 90, 166)):
                plane.update(bytes([value]) * plane.buffer_size)
            packets.extend(encoder.encode(frame))
        packets.extend(encoder.encode(None))
        assert len(packets) == 10
        media = [(bytes(packet), packet.is_keyframe) for packet in packets]
    else:
        # Large deterministic fake slices test TLS/fragment boundaries even
        # when the real low-complexity sample compresses into small packets.
        media = [(b'\x00\x00\x00\x01' + bytes([0x65 if number == 0 else 0x41]) +
                  bytes([17 + number]) * 48000, number == 0) for number in range(10)]
    for number, (payload, keyframe) in enumerate(media):
        pump_until(session.can_send)
        session.send_frame(payload, number * 33333, keyframe=keyframe)
    pump_until(lambda: session.acked == 10)
    session.shutdown()
    print(json.dumps({'frames': 10, 'acked': session.acked, 'authenticated': session.authenticated}), flush=True)
    peer.close()
    listener.close()
