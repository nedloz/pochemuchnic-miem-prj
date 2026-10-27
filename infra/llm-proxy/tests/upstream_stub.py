"""Заглушка upstream для proxy_e2e.sh: вместо роутера и Ollama.

На POST отвечает JSON с тем, что дошло до неё: путь, Host, SNI, заголовки и тело. Если в теле
"stream": true — отдаёт SSE из трёх событий с паузой в секунду между ними, чтобы было видно,
приходит ли ответ через прокси порциями или целиком в конце. Разметка потока задаётся полем
"x_stub_framing": "chunked" — chunked-кодирование (так отвечают роутеры по HTTP/1.1), иначе — без
длины, до закрытия соединения. Второй вариант nginx с proxy_buffering on придерживает до конца
ответа, поэтому только он ловит включённую буферизацию.

Порт 9000 — обычный HTTP. Если смонтирован каталог /tls (сертификаты делает proxy_e2e.sh), ещё три
HTTPS-порта для проверки сертификата роутера:
    9443  сертификат тестового CA на имя router-tls          (прокси должен доверять)
    9444  самоподписанный сертификат на имя router-untrusted (чужой CA)
    9445  сертификат тестового CA на имя other.example        (имя не совпадает)
В stdout пишется CONNECT на каждое TLS-соединение и REQUEST на каждый дошедший HTTP-запрос с его
Authorization — по ним тест проверяет, что до непроверенного сервера ключ не доходит.
"""

import http.server
import json
import os
import ssl
import threading
import time


def log(message):
    print(message, flush=True)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        port = self.server.server_address[1]
        sni = getattr(self.connection, "sni", None) or "-"
        log(f"REQUEST port={port} sni={sni} authorization={self.headers.get('Authorization', '-')}")
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length).decode("utf-8"))
        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            chunked = body.get("x_stub_framing") == "chunked"
            if chunked:
                self.send_header("Transfer-Encoding", "chunked")
            else:
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            for i in range(3):
                event = f"data: {json.dumps({'i': i, 'model': body.get('model')})}\n\n".encode()
                self.wfile.write(b"%x\r\n%s\r\n" % (len(event), event) if chunked else event)
                self.wfile.flush()
                if i < 2:
                    time.sleep(1)
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
            return
        out = json.dumps({
            "path": self.path,
            "host": self.headers.get("Host"),
            "sni": sni,
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "body": body,
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


class TLSServer(http.server.ThreadingHTTPServer):
    def get_request(self):
        port = self.server_address[1]
        try:
            sock, addr = self.socket.accept()  # рукопожатие TLS происходит здесь
        except OSError as e:
            log(f"TLS-ERROR port={port} {type(e).__name__}")
            raise
        log(f"CONNECT port={port} sni={getattr(sock, 'sni', None) or '-'}")
        return sock, addr


def remember_sni(sslsock, server_name, ctx):
    sslsock.sni = server_name


def tls_server(port, name):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(f"/tls/{name}.crt", f"/tls/{name}.key")
    ctx.sni_callback = remember_sni
    server = TLSServer(("0.0.0.0", port), Handler)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    return server


servers = [http.server.ThreadingHTTPServer(("0.0.0.0", 9000), Handler)]
if os.path.isdir("/tls"):
    servers += [tls_server(9443, "trusted"), tls_server(9444, "untrusted"), tls_server(9445, "mismatch")]
for s in servers[1:]:
    threading.Thread(target=s.serve_forever, daemon=True).start()
servers[0].serve_forever()
