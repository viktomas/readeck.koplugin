#!/usr/bin/env python3
"""Reverse proxy to a local Readeck that breaks EPUB downloads mid-body.

    truncating_proxy.py --port 18902 --target http://127.0.0.1:18900 [--pidfile F]

Everything is forwarded unchanged, except GET .../article.epub: the proxy sends
the real status and headers (including the full Content-Length), then only the
first half of the body, then closes the connection. That is what a Wi-Fi drop
in the middle of a download looks like to the client.
"""

import argparse
import http.client
import http.server
import os
import socketserver
import urllib.parse

HOP_BY_HOP = {"connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade"}


def make_handler(target):
    parsed = urllib.parse.urlsplit(target)

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def forward(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else None
            headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP and k.lower() != "host"}
            conn = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=30)
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
            conn.close()

            truncate = self.command == "GET" and self.path.split("?")[0].endswith("/article.epub") and resp.status == 200
            self.send_response(resp.status, resp.reason)
            for key, value in resp.getheaders():
                if key.lower() in HOP_BY_HOP or key.lower() == "content-length":
                    continue
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data[: len(data) // 2] if truncate else data)
            self.wfile.flush()
            self.close_connection = True

        do_GET = do_POST = do_PATCH = do_DELETE = do_PUT = forward

    return Handler


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--pidfile")
    args = parser.parse_args()
    server = Server(("127.0.0.1", args.port), make_handler(args.target))
    if args.pidfile:
        with open(args.pidfile, "w") as fh:
            fh.write(str(os.getpid()))
    server.serve_forever()


if __name__ == "__main__":
    main()
