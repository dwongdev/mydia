#!/usr/bin/env python3
"""
Simple HTTP server with live reload support for Flutter web development.
Serves files from build/web/ and provides an SSE endpoint for browser refresh.
"""

import http.server
import socketserver
import os
import time

RELOAD_TRIGGER = '/tmp/reload_trigger'
WEB_DIR = 'build/web'

class ReloadHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEB_DIR, **kwargs)

    def do_GET(self):
        if self.path == '/livereload':
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Cache-Control', 'no-cache')
            self.send_header('Connection', 'keep-alive')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            try:
                last_mtime = os.path.getmtime(RELOAD_TRIGGER) if os.path.exists(RELOAD_TRIGGER) else 0
                while True:
                    time.sleep(0.5)
                    if os.path.exists(RELOAD_TRIGGER):
                        current_mtime = os.path.getmtime(RELOAD_TRIGGER)
                        if current_mtime > last_mtime:
                            self.wfile.write(b'data: reload\n\n')
                            self.wfile.flush()
                            last_mtime = current_mtime
            except:
                pass
        else:
            super().do_GET()

    def log_message(self, format, *args):
        pass  # Suppress logging

class ThreadedServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True

if __name__ == '__main__':
    print('Serving on port 3000 with live reload...')
    with ThreadedServer(('0.0.0.0', 3000), ReloadHandler) as httpd:
        httpd.serve_forever()
