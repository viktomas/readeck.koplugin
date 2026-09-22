#!/usr/bin/env python3
import argparse
import json
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


# Real Readeck seeds a single "created by test fixtures" bookmark for the
# read-only network smoke test (spec/koreader_network_probe.lua asserts on it
# by ID and expects exactly one bookmark back from a plain, unfiltered list).
# Bookmarks created through POST /api/bookmarks (used by the opt-in write-mode
# probe, spec/koreader_live_probe.lua with READECK_LIVE_WRITE=1) are appended
# to the same list and can be deleted again via DELETE /api/bookmarks/{id}.
ARTICLE_ID = "A1b2C3d4E5f6G7h8I9"

# How long a freshly POSTed bookmark stays "loading" before article.epub and
# has_article/loaded/state flip to ready. Mirrors (in miniature) the real
# server extracting the article asynchronously after accepting the POST.
LOAD_DELAY_SECONDS = 0.6

BOOKMARK_ID_RE = re.compile(r"^/api/bookmarks/([^/]+)$")
BOOKMARK_ARTICLE_RE = re.compile(r"^/api/bookmarks/([^/]+)/article\.epub$")
BOOKMARK_ANNOTATIONS_RE = re.compile(r"^/api/bookmarks/([^/]+)/annotations$")
BOOKMARK_ANNOTATION_RE = re.compile(r"^/api/bookmarks/([^/]+)/annotations/([^/]+)$")


def new_state():
    return {
        "bookmarks": [
            {
                "id": ARTICLE_ID,
                "title": "Runtime Probe Article",
                "type": "article",
                "url": "https://example.com/mock-seed-article",
                "created": "2026-05-06T00:00:00Z",
                "read_progress": 37,
                "labels": [],
                "is_archived": False,
                # Already "loaded" - the seeded bookmark is used by read-only
                # tests that expect the epub/annotations to be available
                # immediately.
                "ready_at": 0.0,
                "annotations": [
                    {
                        "id": "remote-existing",
                        "text": "remote text",
                        "note": "remote note",
                        "color": "yellow",
                        "start_selector": "section/p[1]",
                        "start_offset": 0,
                        "end_selector": "section/p[1]",
                        "end_offset": 11,
                        "created": "2026-05-06T17:47:45Z",
                    }
                ],
            }
        ],
        # Kept as flat, cross-bookmark logs so existing assertions in
        # spec/koreader_network_probe.lua (which only ever touches the single
        # seeded bookmark) keep working unchanged.
        "annotation_posts": [],
        "annotation_patches": [],
        "oauth_clients": [],
        "oauth_token_requests": 0,
        "next_bookmark_seq": 1,
        "next_annotation_seq": 1,
    }


STATE = new_state()

CONFIG = {
    "version": "0.22.2",
    "features": ["oauth"],
}


def parse_version(version):
    parts = []
    for part in str(version or "").split("."):
        digits = ""
        for char in part:
            if char.isdigit():
                digits += char
            else:
                break
        if digits == "":
            break
        parts.append(int(digits))
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


def version_at_least(target):
    return parse_version(CONFIG["version"]) >= parse_version(target)


def annotation_notes_supported():
    return "annotation_notes" in CONFIG["features"] or version_at_least("0.22.2")


def annotation_none_color_supported():
    return "annotation_none_color" in CONFIG["features"] or version_at_least("0.22.2")


def write_json(handler, payload, status=200, extra_headers=None):
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    for key, value in (extra_headers or {}).items():
        handler.send_header(key, value)
    handler.end_headers()
    handler.wfile.write(body)


def read_body(handler):
    length = int(handler.headers.get("Content-Length", "0") or "0")
    return handler.rfile.read(length) if length > 0 else b""


def request_payload(handler):
    body = read_body(handler)
    content_type = handler.headers.get("Content-Type", "")
    if "application/json" in content_type:
        return json.loads(body.decode("utf-8") or "{}")

    if "application/x-www-form-urlencoded" in content_type:
        form = parse_qs(body.decode("utf-8"), keep_blank_values=True)
        return {key: values[-1] if len(values) == 1 else values for key, values in form.items()}

    return {}


def list_value(value):
    if isinstance(value, list):
        return value
    if value is None:
        return []
    return [value]


def form_error(field, message):
    return {"is_valid": False, "errors": {field: [message]}}


def validate_oauth_client(payload):
    required = ["client_name", "client_uri", "software_id", "software_version", "grant_types"]
    for field in required:
        value = payload.get(field)
        if value is None or value == "" or value == []:
            return form_error(field, "required")

    if len(str(payload["software_version"])) > 64:
        return form_error("software_version", "max length is 64")

    if "urn:ietf:params:oauth:grant-type:device_code" not in list_value(payload.get("grant_types")):
        return form_error("grant_types", "unsupported grant type")

    return None


def normalize_annotation(annotation):
    item = dict(annotation)
    if not annotation_notes_supported():
        item.pop("note", None)
    if item.get("color") == "none" and not annotation_none_color_supported():
        item["color"] = "yellow"
    return item


def validate_annotation(payload):
    required = ["start_selector", "start_offset", "end_selector", "end_offset", "color"]
    for field in required:
        value = payload.get(field)
        if value is None or value == "":
            return form_error(field, "required")

    for field in ["start_selector", "end_selector"]:
        if len(str(payload[field])) > 256:
            return form_error(field, "max length is 256")

    for field in ["start_offset", "end_offset"]:
        try:
            value = int(payload[field])
        except (TypeError, ValueError):
            return form_error(field, "must be an integer")
        if value < 0:
            return form_error(field, "must be greater than or equal to 0")

    color = str(payload["color"])
    if len(color) > 32:
        return form_error("color", "max length is 32")
    if color == "none" and not annotation_none_color_supported():
        return form_error("color", "unsupported before Readeck 0.22.2")

    if "note" in payload:
        if not annotation_notes_supported():
            return form_error("note", "unsupported before Readeck 0.22.2")
        if len(str(payload["note"])) > 1024:
            return form_error("note", "max length is 1024")

    return None


def validate_annotation_update(payload):
    if payload.get("color") is None or payload.get("color") == "":
        return form_error("color", "required")

    color = str(payload["color"])
    if len(color) > 32:
        return form_error("color", "max length is 32")
    if color == "none" and not annotation_none_color_supported():
        return form_error("color", "unsupported before Readeck 0.22.2")

    if "note" in payload:
        if not annotation_notes_supported():
            return form_error("note", "unsupported before Readeck 0.22.2")
        if len(str(payload["note"])) > 1024:
            return form_error("note", "max length is 1024")

    return None


def find_bookmark(bookmark_id):
    for bookmark in STATE["bookmarks"]:
        if bookmark["id"] == bookmark_id:
            return bookmark
    return None


def bookmark_is_ready(bookmark):
    return time.time() >= bookmark.get("ready_at", 0.0)


def bookmark_public_view(bookmark):
    ready = bookmark_is_ready(bookmark)
    return {
        "id": bookmark["id"],
        "title": bookmark["title"],
        "type": bookmark["type"],
        "url": bookmark.get("url"),
        "created": bookmark["created"],
        "read_progress": bookmark.get("read_progress", 0),
        "labels": bookmark.get("labels", []),
        "is_archived": bookmark.get("is_archived", False),
        # Mirrors the real bookmarkInfo shape (see internal/bookmarks/dataset
        # in the Readeck source): state 0 = loaded, 1 = error, 2 = loading;
        # loaded only means "no longer in progress", has_article means the
        # article file itself is ready to download.
        "state": 0 if ready else 2,
        "loaded": ready,
        "has_article": ready,
    }


def validate_create_bookmark(payload):
    if not payload.get("url"):
        return form_error("url", "required")
    return None


class MockReadeckHandler(BaseHTTPRequestHandler):
    server_version = "MockReadeck/0.1"

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/api/info":
            write_json(self, {"version": {"canonical": CONFIG["version"]}, "features": CONFIG["features"]})
            return
        if path == "/api/bookmarks":
            write_json(self, [bookmark_public_view(item) for item in STATE["bookmarks"]])
            return

        match = BOOKMARK_ID_RE.match(path)
        if match:
            bookmark = find_bookmark(match.group(1))
            if not bookmark:
                write_json(self, {"error": "not_found", "path": path}, 404)
                return
            write_json(self, bookmark_public_view(bookmark))
            return

        match = BOOKMARK_ARTICLE_RE.match(path)
        if match:
            bookmark = find_bookmark(match.group(1))
            if not bookmark:
                write_json(self, {"error": "not_found", "path": path}, 404)
                return
            if not bookmark_is_ready(bookmark):
                write_json(self, {"error": "not_ready", "path": path}, 404)
                return
            # Real EPUBs are ZIP files (magic bytes "PK\x03\x04"); the live
            # probe's read-only checks assert on that, so this fake payload
            # matches it too instead of being an arbitrary string.
            body = b"PK\x03\x04mock epub payload"
            self.send_response(200)
            self.send_header("Content-Type", "application/epub+zip")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        match = BOOKMARK_ANNOTATIONS_RE.match(path)
        if match:
            bookmark = find_bookmark(match.group(1))
            if not bookmark:
                write_json(self, {"error": "not_found", "path": path}, 404)
                return
            write_json(self, [normalize_annotation(item) for item in bookmark["annotations"]])
            return

        if path == "/__state":
            write_json(self, STATE)
            return
        write_json(self, {"error": "not_found", "path": path}, 404)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        payload = request_payload(self)

        if path == "/api/oauth/client":
            error = validate_oauth_client(payload)
            if error:
                write_json(self, error, 400)
                return
            STATE["oauth_clients"].append(payload)
            write_json(self, {"client_id": "mock-client"})
            return
        if path == "/api/oauth/device":
            write_json(
                self,
                {
                    "device_code": "mock-device",
                    "user_code": "ABCD1234",
                    "verification_uri": "http://127.0.0.1/device",
                    "verification_uri_complete": "http://127.0.0.1/device?user_code=ABCD1234",
                    "interval": 5,
                    "expires_in": 300,
                },
            )
            return
        if path == "/api/oauth/token":
            STATE["oauth_token_requests"] += 1
            write_json(self, {"access_token": "oauth-access", "refresh_token": "oauth-refresh", "expires_in": 3600})
            return

        if path == "/api/bookmarks":
            # Real Readeck: 202 Accepted, id comes back via the Bookmark-Id /
            # Location headers, NOT the JSON body (which is just a generic
            # {"status":202,"message":"Link submited"} message). Callers that
            # need the id right away have to discover it some other way (e.g.
            # list bookmarks and match by URL) - see spec/koreader_live_probe.lua.
            error = validate_create_bookmark(payload)
            if error:
                write_json(self, error, 422)
                return
            seq = STATE["next_bookmark_seq"]
            STATE["next_bookmark_seq"] += 1
            bookmark_id = "created-bookmark-%d" % seq
            bookmark = {
                "id": bookmark_id,
                "title": payload.get("title") or payload["url"],
                "type": "article",
                "url": payload["url"],
                "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "read_progress": 0,
                "labels": list_value(payload.get("labels")),
                "is_archived": False,
                "ready_at": time.time() + LOAD_DELAY_SECONDS,
                "annotations": [],
            }
            STATE["bookmarks"].append(bookmark)
            write_json(
                self,
                {"status": 202, "message": "Link submited"},
                202,
                extra_headers={
                    "Bookmark-Id": bookmark_id,
                    "Location": "/api/bookmarks/" + bookmark_id,
                },
            )
            return

        match = BOOKMARK_ANNOTATIONS_RE.match(path)
        if match:
            bookmark = find_bookmark(match.group(1))
            if not bookmark:
                write_json(self, {"error": "not_found", "path": path}, 404)
                return
            error = validate_annotation(payload)
            if error:
                write_json(self, error, 422)
                return
            annotation_id = "created-%d" % STATE["next_annotation_seq"]
            STATE["next_annotation_seq"] += 1
            payload = dict(payload)
            payload["id"] = annotation_id
            STATE["annotation_posts"].append(payload)
            bookmark["annotations"].append(normalize_annotation(payload))
            write_json(self, normalize_annotation(payload), 201)
            return

        write_json(self, {"error": "not_found", "path": path}, 404)

    def do_PATCH(self):
        parsed = urlparse(self.path)
        path = parsed.path
        payload = request_payload(self)

        match = BOOKMARK_ANNOTATION_RE.match(path)
        if match:
            bookmark_id, annotation_id = match.group(1), match.group(2)
            bookmark = find_bookmark(bookmark_id)
            if not bookmark:
                write_json(self, {"error": "not_found", "path": path}, 404)
                return
            error = validate_annotation_update(payload)
            if error:
                write_json(self, error, 422)
                return
            for index, item in enumerate(bookmark["annotations"]):
                if item.get("id") == annotation_id:
                    item = dict(item)
                    item["color"] = payload["color"]
                    if "note" in payload:
                        item["note"] = payload["note"]
                    bookmark["annotations"][index] = normalize_annotation(item)
                    patched = dict(payload)
                    patched["id"] = annotation_id
                    STATE["annotation_patches"].append(patched)
                    write_json(
                        self, {"annotations": [normalize_annotation(entry) for entry in bookmark["annotations"]]}
                    )
                    return
            write_json(self, {"error": "not_found", "path": path}, 404)
            return

        write_json(self, {"error": "not_found", "path": path}, 404)

    def do_DELETE(self):
        parsed = urlparse(self.path)
        path = parsed.path

        match = BOOKMARK_ID_RE.match(path)
        if match:
            bookmark = find_bookmark(match.group(1))
            if not bookmark:
                write_json(self, {"error": "not_found", "path": path}, 404)
                return
            STATE["bookmarks"].remove(bookmark)
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        write_json(self, {"error": "not_found", "path": path}, 404)


def main():
    global LOAD_DELAY_SECONDS
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18080)
    parser.add_argument("--version", default="0.22.2")
    parser.add_argument("--features", default="oauth")
    parser.add_argument(
        "--load-delay",
        type=float,
        default=LOAD_DELAY_SECONDS,
        help="seconds a POSTed bookmark stays in the 'loading' state before article.epub/has_article become ready",
    )
    args = parser.parse_args()
    CONFIG["version"] = args.version
    CONFIG["features"] = [item.strip() for item in args.features.split(",") if item.strip()]
    LOAD_DELAY_SECONDS = args.load_delay
    server = ThreadingHTTPServer((args.host, args.port), MockReadeckHandler)
    print("Mock Readeck listening on http://%s:%s" % (args.host, args.port), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
