#!/usr/bin/env python3
"""Случайные ключи доступа MinIO вместо minioadmin/minioadmin.

    python3 scripts/gen_minio_credentials.py             # заменить слабые и пустые
    python3 scripts/gen_minio_credentials.py --rotate    # перевыпустить

Пишет MINIO_ACCESS_KEY и MINIO_SECRET_KEY в корневой .env. Данные в MinIO при смене ключей
сохраняются (меняется только учётная запись root). После смены пересоздать MinIO и сервисы,
которые в него ходят:
    docker compose up -d --no-deps minio minio-mtls library-svc db-svc ingest-worker
"""

from __future__ import annotations

import argparse
import os
import re
import secrets
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENV = Path(os.environ.get("MINIO_ENV_FILE") or ROOT / ".env")  # путь переопределяется только в тестах
WEAK = ("minioadmin", "change", "example", "password")


def weak(value: str | None) -> bool:
    return not value or len(value) < 20 or any(w in value.lower() for w in WEAK)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rotate", action="store_true", help="перевыпустить ключи")
    args = parser.parse_args()

    text = ENV.read_text(encoding="utf-8") if ENV.exists() else ""
    changed = []
    for name, size in (("MINIO_ACCESS_KEY", 15), ("MINIO_SECRET_KEY", 32)):
        m = re.search(rf"^{name}=(.*)$", text, re.M)
        if args.rotate or weak(m.group(1) if m else None):
            value = secrets.token_hex(size)
            line = f"{name}={value}"
            text = re.sub(rf"^{name}=.*$", line, text, flags=re.M) if m else text + ("" if text.endswith("\n") or not text else "\n") + line + "\n"
            changed.append(name)
    if changed:
        ENV.write_text(text, encoding="utf-8")
    print(f"{ENV}: " + (f"обновлено {', '.join(changed)}" if changed else "ключи уже надёжные"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
