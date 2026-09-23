#!/usr/bin/env python3
"""Fixture web site that the local Readeck bookmarks during e2e runs.

    server.py PORT

Serves e2e/fixtures/site/* as static files, plus:

  /gen/<slug>.html   a generated article titled from the slug (or ?title=...),
                     so a test can create many bookmarks with distinct titles;
  ?delay=SECONDS     on any path, sleep before answering. Readeck keeps the
                     bookmark in state=2 (loading) until the page arrives,
                     which is how tests get a deterministic "still loading"
                     bookmark;
  ?copy=N            ignored, only makes the URL distinct.

Standard library only, so it runs on a bare CI image.
"""

import html
import http.server
import os
import sys
import threading
import time
import urllib.parse

SITE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "site")

PARAGRAPHS = [
    "The morning train left the valley station a few minutes late, as it did on most days of the year.",
    "Passengers folded their newspapers and watched the orchards give way to pine forest and then to rock.",
    "At the summit the air was thin and cold, and the conductor walked the length of the carriages twice.",
    "Nobody remembered who had first painted the benches on the platform a cheerful shade of yellow.",
    "On the way down the light changed quickly, and the lake appeared all at once between two ridges.",
]


def generated_article(slug, title):
    title = title or slug.replace("-", " ").replace("_", " ").strip().title()
    # Three rounds of paragraphs: long enough (~300 words) for Readeck to
    # report a reading_time, which the plugin stores as a keyword.
    body = "\n".join("<p>%s %s</p>" % (html.escape(title), html.escape(p)) for p in PARAGRAPHS * 3)
    return (
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
        "<title>%s</title><meta name=\"author\" content=\"E2E Fixture\">"
        "<meta name=\"description\" content=\"Generated fixture article.\"></head>"
        "<body><article><h1>%s</h1>\n%s\n</article></body></html>"
    ) % (html.escape(title), html.escape(title), body)


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=SITE, **kwargs)

    def log_message(self, fmt, *args):
        sys.stderr.write("[fixtures] %s\n" % (fmt % args))

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        delay = float(query.get("delay", ["0"])[0] or 0)
        if delay > 0:
            time.sleep(min(delay, 60))
        if parsed.path.startswith("/gen/"):
            slug = parsed.path[len("/gen/") :].rsplit(".", 1)[0]
            payload = generated_article(slug, query.get("title", [""])[0]).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.path = parsed.path
        return super().do_GET()


def main():
    port = int(sys.argv[1])
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    threading.current_thread().name = "fixtures"
    server.serve_forever()


if __name__ == "__main__":
    main()
