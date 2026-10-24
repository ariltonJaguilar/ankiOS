from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import sys

package_path = Path(sys.argv[1]).resolve()
port_file = Path(sys.argv[3])


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            body = b"<!doctype html><html><body><a href='/Hiragana_and_Katakana.apkg'>Download shared deck</a></body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/Hiragana_and_Katakana.apkg":
            size = package_path.stat().st_size
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="Hiragana_and_Katakana.apkg"')
            self.send_header("Content-Length", str(size))
            self.end_headers()
            with package_path.open("rb") as package_file:
                shutil.copyfileobj(package_file, self.wfile)
            return
        self.send_error(404)

    def log_message(self, format, *args):
        pass


class LocalFixtureServer(ThreadingHTTPServer):
    def server_bind(self):
        self.socket.bind(self.server_address)
        self.server_address = self.socket.getsockname()
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


server = LocalFixtureServer(("127.0.0.1", int(sys.argv[2])), Handler)
port_file.write_text(f"{server.server_address[1]}\n")
server.serve_forever()
