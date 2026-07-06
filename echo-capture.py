from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        print("PATH:", self.path, flush=True)
        print("AUTH:", self.headers.get("Authorization"), flush=True)
        length = int(self.headers.get("Content-Length", 0))
        print("BODY:", self.rfile.read(length).decode("utf-8", errors="replace"), flush=True)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

HTTPServer(("0.0.0.0", 9999), H).serve_forever()
