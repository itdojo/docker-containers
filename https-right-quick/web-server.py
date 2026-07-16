#!/usr/bin/env python3 

import http.server
import ssl
import base64
from urllib.parse import urlparse
from dotenv import load_dotenv
import os

load_dotenv()

USERNAME = os.getenv("USERNAME", "default_user")
PASSWORD = os.getenv("PASSWORD", "default_password")

class AuthHandler(http.server.SimpleHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(200)
        self.end_headers()

    def do_AUTHHEAD(self):
        self.send_response(401)
        self.send_header('WWW-Authenticate', 'Basic realm="Secure Area"')
        self.send_header('Content-type', 'text/html')
        self.end_headers()

    def do_GET(self):
        # Basic authentication logic
        auth_header = self.headers.get('Authorization')
        if auth_header is None:
            self.do_AUTHHEAD()
            self.wfile.write(b'Unauthorized: Authentication Required')
            return

        auth_type, encoded_creds = auth_header.split(' ', 1)
        if auth_type != 'Basic' or base64.b64decode(encoded_creds).decode() != f"{USERNAME}:{PASSWORD}":
            self.do_AUTHHEAD()
            self.wfile.write(b'Unauthorized: Invalid Credentials')
            return

        # Serve the request if authentication succeeds
        super().do_GET()

if __name__ == "__main__":
    server_address = ('', 443)  # Bind to all interfaces on port 443
    httpd = http.server.HTTPServer(server_address, AuthHandler)

    # Load SSL certificate and key
    httpd.socket = ssl.wrap_socket(
        httpd.socket,
        certfile="/cert/cert.pem",
        keyfile="/cert/key.pem",
        server_side=True
    )

    print("Starting HTTPS server...")
    httpd.serve_forever()
