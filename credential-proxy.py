from http.server import BaseHTTPRequestHandler, HTTPServer
import urllib.request

TARGET = "http://consumer-identityhub:7082"

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        req = urllib.request.Request(
            TARGET + self.path,
            data=body,
            method="POST",
            headers={
                "Authorization": self.headers.get("Authorization", ""),
                "Content-Type": self.headers.get("Content-Type", "application/json")
            }
        )
        try:
            with urllib.request.urlopen(req) as r:
                resp = r.read()
                open("/tmp/presentation-response.json", "wb").write(resp)
                print("PATH:", self.path, flush=True)
                print("RESP_STATUS:", r.status, flush=True)
                self.send_response(r.status)
                self.send_header("Content-Type", r.headers.get("Content-Type", "application/json"))
                self.end_headers()
                self.wfile.write(resp)
        except Exception as e:
            print("PROXY_ERROR:", repr(e), flush=True)
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode())

HTTPServer(("0.0.0.0", 9999), Handler).serve_forever()
