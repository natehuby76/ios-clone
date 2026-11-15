"""Unmodified pinned Dom protocol server; test-only certificates and media."""
import base64
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
    session.fragment_acks = sys.argv[1] == 'fragment'
    session.authenticate()
    mode = session.start('Unmodified Dom integration fixture', 'comma.ai')
    assert (mode.width, mode.height, mode.codec) == (1280, 720, 1), mode
    deadline = time.monotonic() + 10
    def pump_until(predicate):
        while not predicate():
            assert time.monotonic() < deadline, 'Protocol did not advance'
            session.pump(.01)
    pump_until(lambda: session.focused)
    # Large deterministic fake IDR/P slices exercise TLS and fragment ACKs.
    # Decoder correctness is separately tested using saved real H264 material.
    for number in range(10):
        pump_until(session.can_send)
        payload = b'\x00\x00\x00\x01' + bytes([0x65 if number == 0 else 0x41]) + bytes([17 + number]) * 48000
        session.send_frame(payload, number * 33333, keyframe=number == 0)
    pump_until(lambda: session.acked == 10)
    session.shutdown()
    print(json.dumps({'frames': 10, 'acked': session.acked, 'authenticated': session.authenticated}), flush=True)
    peer.close()
    listener.close()
