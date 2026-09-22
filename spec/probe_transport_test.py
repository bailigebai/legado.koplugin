"""Check the desktop probe's total response deadline with a slow local peer."""

import http.client
from pathlib import Path
import socket
import sys
import threading
import time
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from probe_sources import read_response, successful_probe


def check_deadline():
    client, server = socket.socketpair()

    def send():
        try:
            server.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\n")
            for _ in range(20):
                time.sleep(0.03)
                server.sendall(b"x")
        except OSError:
            pass
        finally:
            server.close()

    sender = threading.Thread(target=send)
    sender.start()
    try:
        response = http.client.HTTPResponse(client)
        response.begin()
        started = time.monotonic()
        try:
            read_response(response, lambda chunk: True, started + 0.1)
        except TimeoutError:
            pass
        else:
            raise AssertionError("slow response exceeded its total deadline")
        assert time.monotonic() - started < 0.4, "deadline was applied per packet instead of overall"
        response.close()
    finally:
        client.close()
        sender.join(timeout=1)
    print("PASS: slow response stops at its total deadline")


def check_redirect():
    client, server = socket.socketpair()
    try:
        server.sendall(b"HTTP/1.1 302 Found\r\nContent-Length: 0\r\nLocation: /next\r\n\r\n")
        response = http.client.HTTPResponse(client)
        response.begin()
        wrapped = urllib.error.HTTPError("https://example.test", 302, "Found", response.headers, response)
        assert read_response(wrapped, lambda chunk: True, time.monotonic() + 0.1)
        wrapped.close()
    finally:
        client.close()
        server.close()
    print("PASS: urllib redirect wrapper preserves the HTTP response")


def check_complete_body():
    client, server = socket.socketpair()
    try:
        server.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx")
        response = http.client.HTTPResponse(client)
        response.begin()
        client.close()
        chunks = []
        assert read_response(response, lambda chunk: chunks.append(chunk) or True, time.monotonic() + 0.1)
        assert b"".join(chunks) == b"x"
        response.close()
    finally:
        client.close()
        server.close()
    print("PASS: a completed body does not touch its closed socket")


if __name__ == "__main__":
    assert successful_probe({'status':'completed'})
    assert successful_probe({'status':'completed','steps':[{'status':'success'}]})
    assert successful_probe({'status':'completed','steps':[{'status':'passed'}]})
    assert not successful_probe({'status':'no_categories'})
    assert not successful_probe({'status':'completed','steps':[{'status':'failed'}]})
    assert not successful_probe({'status':'completed'}, reader_required=True)
    assert not successful_probe({'status':'completed','sample':{'reader_document':{'status':'failed'}}}, reader_required=True)
    assert successful_probe({'status':'completed','sample':{'reader_document':{
        'status':'passed','format':'html','reader_entry':True}}}, reader_required=True)
    assert not successful_probe({'status':'completed','detail_intro_bytes':0}, discovery=True)
    assert not successful_probe({'status':'completed','detail_intro_bytes':3,'detail_has_cover':True}, discovery=True)
    assert successful_probe({'status':'completed','detail_intro_bytes':3,'detail_has_cover':True,
                             'cover_image_signature':True}, discovery=True)
    print('PASS: success requires every requested probe stage')
    check_deadline()
    check_redirect()
    check_complete_body()
