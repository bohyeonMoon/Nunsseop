#!/usr/bin/env python3
"""The update feed for scripts/e2e-update.sh, served the way GitHub serves a release's files: /appcast.xml redirects to
/files/appcast.xml, as releases/latest/download does, and files go out as application/octet-stream. Every request is
logged, one line each.

  feed.py <port> <folder> <log>
"""
import http.server
import os
import sys

PORT, FOLDER, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(LOG, "a") as log:
            log.write(f"GET {self.path}\n")
        if self.path == "/appcast.xml":
            self.send_response(302)
            self.send_header("Location", "/files/appcast.xml")
            self.end_headers()
            return
        name = self.path[len("/files/"):] if self.path.startswith("/files/") else ""
        path = os.path.join(FOLDER, os.path.basename(name))
        if not name or not os.path.isfile(path):
            self.send_error(404)
            return
        with open(path, "rb") as file:
            body = file.read()
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
