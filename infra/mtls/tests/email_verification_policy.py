"""Изолированная проверка подтверждения почты: настоящие nginx/mTLS-конфиги, HTTP-заглушка.

Запуск: python3 infra/mtls/tests/email_verification_policy.py
Нужны Docker, openssl и nginx:1.27-alpine. Рабочий стек и его сертификаты не затрагиваются.
"""

import http.client
import json
from pathlib import Path
import ssl
import subprocess
import tempfile
import time
import uuid


REPO = Path(__file__).resolve().parents[3]
IMAGE = "nginx:1.27-alpine"


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip()


def main():
    prefix = f"email-policy-{uuid.uuid4().hex[:10]}"
    receiver, gateway, network = f"{prefix}-auth", f"{prefix}-gateway", f"{prefix}-net"
    with tempfile.TemporaryDirectory(prefix="email-policy-") as tmp:
        root = Path(tmp)
        run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign",
            "-subj", "/CN=email-policy-test-ca", "-keyout", str(root / "ca.key"), "-out", str(root / "ca.crt"))
        identities = ("auth-svc", "nginx", "db-svc", "chat-svc", "library-svc", "graph-rag-svc")
        for identity in identities:
            directory = root / identity
            directory.mkdir()
            run("openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", f"/CN={identity}",
                "-keyout", str(directory / "tls.key"), "-out", str(directory / "tls.csr"))
            (directory / "extensions").write_text(
                f"subjectAltName=DNS:{identity}\n"
                "basicConstraints=critical,CA:FALSE\n"
                "keyUsage=critical,digitalSignature,keyEncipherment\n"
                "extendedKeyUsage=serverAuth,clientAuth\n"
                "subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n"
            )
            run("openssl", "x509", "-req", "-days", "1", "-in", str(directory / "tls.csr"),
                "-CA", str(root / "ca.crt"), "-CAkey", str(root / "ca.key"), "-CAcreateserial",
                "-extfile", str(directory / "extensions"), "-out", str(directory / "tls.crt"))
            (directory / "root_ca.crt").write_bytes((root / "ca.crt").read_bytes())
        (root / "stub.conf").write_text('''server {
    listen 127.0.0.1:8000;
    location / {
        default_type application/json;
        return 200 '{"path":"$uri","caller":"$http_x_caller_identity","user_context":"$http_x_user_context","user_id":"$http_x_user_id","user_role":"$http_x_user_role"}';
    }
}
''')
        try:
            run("docker", "network", "create", network)
            run("docker", "run", "-d", "--name", receiver, "--network", network,
                "--network-alias", "auth-svc", "--network-alias", "chat-svc",
                "--network-alias", "library-svc", "--network-alias", "db-svc",
                "-p", "127.0.0.1::8443",
                "-v", f"{REPO}/infra/mtls/auth-svc.conf:/etc/nginx/conf.d/default.conf:ro",
                "-v", f"{root}/stub.conf:/etc/nginx/conf.d/stub.conf:ro",
                "-v", f"{root}/auth-svc:/pki-svc:ro", IMAGE)
            run("docker", "run", "-d", "--name", gateway, "--network", network,
                "-p", "127.0.0.1::80", "-e", "NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx",
                "-e", "UPSTREAM_SCHEME=https", "-e", "UPSTREAM_PORT=8443",
                "-v", f"{REPO}/infra/nginx/nginx.conf:/etc/nginx/templates/nginx.conf.template:ro",
                "-v", f"{REPO}/infra/nginx/backend_tls.conf:/etc/nginx/backend_tls/tls.conf:ro",
                "-v", f"{root}/nginx:/pki-svc:ro", IMAGE)
            for container in (receiver, gateway):
                for attempt in range(30):
                    try:
                        run("docker", "exec", container, "nginx", "-t")
                        break
                    except subprocess.CalledProcessError:
                        if attempt == 29:
                            raise
                        time.sleep(0.2)

            tls_port = int(run("docker", "port", receiver, "8443/tcp").rsplit(":", 1)[1])
            public_port = int(run("docker", "port", gateway, "80/tcp").rsplit(":", 1)[1])

            def request(identity, method, path):
                context = ssl.create_default_context(cafile=str(root / "ca.crt"))
                # Проверяется настоящий сертификат CA; имя сервера здесь 127.0.0.1, а
                # SAN auth-svc. Проверку SAN со стороны шлюза отдельно делает backend_tls.conf.
                context.check_hostname = False
                if identity:
                    context.load_cert_chain(str(root / identity / "tls.crt"), str(root / identity / "tls.key"))
                conn = http.client.HTTPSConnection("127.0.0.1", tls_port, context=context, timeout=10)
                conn.request(method, path, body=b"{}", headers={"X-Caller-Identity": "forged"})
                response = conn.getresponse()
                status, body = response.status, response.read()
                conn.close()
                return status, body

            path = "/internal/notifications/email-verification"
            checks = 0
            for identity, method, target, expected in [
                ("db-svc", "POST", path, 200), ("db-svc", "GET", path, 403),
                ("db-svc", "POST", path + "/other", 403), ("db-svc", "POST", "/auth/register", 403),
                ("nginx", "POST", path, 403), ("chat-svc", "POST", path, 403),
                ("library-svc", "POST", path, 403), ("graph-rag-svc", "POST", path, 403),
                ("chat-svc", "GET", "/internal/users/11111111-1111-4111-8111-111111111111/profile", 200),
            ]:
                status, body = request(identity, method, target)
                assert status == expected, (identity, method, target, expected, status, body)
                if status == 200:
                    assert json.loads(body)["caller"] == identity, body
                checks += 1
            status, _ = request(None, "POST", path)
            assert status != 200, "Запрос без клиентского сертификата принят"
            checks += 1

            conn = http.client.HTTPConnection("127.0.0.1", public_port, timeout=10)
            conn.request("POST", "/api/auth/resend-verification", body=b"{}", headers={
                "X-User-Context": "forged", "X-User-Id": "forged", "X-User-Role": "admin",
            })
            response = conn.getresponse()
            payload = response.read()
            assert response.status == 200, (response.status, payload)
            body = json.loads(payload)
            assert body == {"path": "/auth/resend-verification", "caller": "nginx", "user_context": "", "user_id": "", "user_role": ""}, body
            conn.close()
            checks += 1
            conn = http.client.HTTPConnection("127.0.0.1", public_port, timeout=10)
            conn.request("POST", "/api" + path, body=b"{}")
            response = conn.getresponse()
            response.read()
            assert response.status == 404, response.status
            conn.close()
            checks += 1
            print(f"Passed: {checks} routing and mTLS checks")
        except Exception:
            for container in (receiver, gateway):
                logs = subprocess.run(["docker", "logs", container], capture_output=True, text=True)
                print(f"{container}:\n{logs.stdout}\n{logs.stderr}")
            raise
        finally:
            for container in (gateway, receiver):
                subprocess.run(["docker", "rm", "-f", container], capture_output=True)
            subprocess.run(["docker", "network", "rm", network], capture_output=True)


if __name__ == "__main__":
    main()
