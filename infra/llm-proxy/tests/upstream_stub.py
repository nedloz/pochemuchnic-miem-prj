"""Заглушка upstream для proxy_e2e.sh: вместо роутера и Ollama.

На POST отвечает JSON с тем, что дошло до неё: путь, Host, заголовки и тело. Если в теле
"stream": true — отдаёт SSE из трёх событий с паузой в секунду между ними, чтобы было видно,
приходит ли ответ через прокси порциями или целиком в конце.
"""

import http.server
import json
import time


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8")
        body = json.loads(raw)
        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for i in range(3):
                event = f"data: {json.dumps({'i': i, 'model': body.get('model')})}\n\n".encode()
                self.wfile.write(b"%x\r\n%s\r\n" % (len(event), event))
                self.wfile.flush()
                if i < 2:
                    time.sleep(1)
            self.wfile.write(b"0\r\n\r\n")
            return
        out = json.dumps({
            "path": self.path,
            "host": self.headers.get("Host"),
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "body": body,
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


http.server.ThreadingHTTPServer(("0.0.0.0", 9000), Handler).serve_forever()
