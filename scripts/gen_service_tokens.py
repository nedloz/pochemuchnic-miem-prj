#!/usr/bin/env python3
"""Генерирует случайные межсервисные токены и раскладывает их по .env сервисов.

Схема такая же, как раньше, но токены случайные: у каждого вызывающего сервиса один
SERVICE_TOKEN, а у принимающих он же лежит в TRUSTED_SERVICE_TOKENS под именем вызывающего.
Принимающие и их доверенные вызывающие берутся из уже существующих ключей
TRUSTED_SERVICE_TOKENS, поэтому топологию скрипт не навязывает.

    python3 scripts/gen_service_tokens.py            # заполнить только слабые и пустые
    python3 scripts/gen_service_tokens.py --rotate   # перевыпустить все токены

Без .env берётся .env.example. Остальные строки файла не трогаются. После ротации
сервисы нужно перезапустить: docker compose up -d --force-recreate
"""

from __future__ import annotations

import argparse
import json
import re
import secrets
import sys
from pathlib import Path

SERVICES_DIR = Path(__file__).resolve().parent.parent / "services"
WEAK_MARKERS = ("super-secret-token", "change-me", "change_me", "changeme")
MIN_LENGTH = 24


def is_weak(token: str | None) -> bool:
    if not token or len(token) < MIN_LENGTH:
        return True
    return any(marker in token.lower() for marker in WEAK_MARKERS)


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if match:
            values[match.group(1)] = match.group(2)
    return values


def set_env(text: str, key: str, value: str) -> str:
    line = f"{key}={value}"
    pattern = re.compile(rf"^{re.escape(key)}=.*$", re.MULTILINE)
    if pattern.search(text):
        return pattern.sub(lambda _: line, text, count=1)
    return text.rstrip("\n") + f"\n{line}\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rotate", action="store_true", help="перевыпустить и сильные токены")
    args = parser.parse_args()

    envs: dict[Path, str] = {}
    for service_dir in sorted(p for p in SERVICES_DIR.iterdir() if p.is_dir()):
        env_path = service_dir / ".env"
        example = service_dir / ".env.example"
        needs_tokens = example.exists() and "SERVICE_TOKEN" in example.read_text(encoding="utf-8")
        if not env_path.exists() and needs_tokens:
            env_path.write_text(example.read_text(encoding="utf-8"), encoding="utf-8")
            print(f"создан {env_path.relative_to(SERVICES_DIR.parent)} из .env.example")
        if env_path.exists():
            envs[env_path] = env_path.read_text(encoding="utf-8")

    parsed = {path: read_env(path) for path in envs}

    # Кто кому доверяет: ключи TRUSTED_SERVICE_TOKENS каждого принимающего сервиса.
    trusted: dict[Path, dict[str, str]] = {}
    callers: set[str] = set()
    for path, values in parsed.items():
        raw = values.get("TRUSTED_SERVICE_TOKENS", "").strip()
        if not raw:
            continue
        try:
            tokens = json.loads(raw)
        except json.JSONDecodeError:
            print(f"{path}: TRUSTED_SERVICE_TOKENS не JSON, файл пропущен", file=sys.stderr)
            continue
        trusted[path] = {str(k): str(v) for k, v in tokens.items()}
        callers.update(trusted[path])

    # Один токен на вызывающего: сначала то, что у него уже лежит в SERVICE_TOKEN.
    token_for: dict[str, str] = {}
    own_env: dict[str, Path] = {}
    for path, values in parsed.items():
        name = values.get("SERVICE_NAME")
        if name:
            own_env[name] = path
            if name in callers and not args.rotate and not is_weak(values.get("SERVICE_TOKEN")):
                token_for[name] = values["SERVICE_TOKEN"]
    for name in sorted(callers):
        if name in token_for:
            continue
        # Если сильный токен уже есть у принимающих (например, у вызывающего нет своего .env),
        # сохраняем его, пока не просят ротацию.
        existing = [t[name] for t in trusted.values() if name in t and not is_weak(t[name])]
        token_for[name] = existing[0] if existing and not args.rotate else secrets.token_urlsafe(32)

    for path, text in envs.items():
        name = parsed[path].get("SERVICE_NAME")
        if name in token_for and "SERVICE_TOKEN" in parsed[path]:
            text = set_env(text, "SERVICE_TOKEN", token_for[name])
        elif "SERVICE_TOKEN" in parsed[path] and is_weak(parsed[path]["SERVICE_TOKEN"]):
            # Сервис сам никого не вызывает (например, embedding-svc): токен не используется,
            # но заглушка в .env не должна оставаться.
            text = set_env(text, "SERVICE_TOKEN", secrets.token_urlsafe(32))
        if path in trusted:
            merged = {caller: token_for[caller] for caller in trusted[path]}
            text = set_env(text, "TRUSTED_SERVICE_TOKENS", json.dumps(merged, separators=(",", ":")))
        if text != envs[path]:
            path.write_text(text, encoding="utf-8")
            print(f"обновлён {path.relative_to(SERVICES_DIR.parent)}")

    missing = sorted(c for c in callers if c not in own_env or "SERVICE_TOKEN" not in parsed[own_env[c]])
    if missing:
        print(
            "У этих вызывающих нет SERVICE_TOKEN в своём .env, токен записан только у принимающих: "
            + ", ".join(missing)
        )
    print(f"готово, токенов: {len(token_for)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
