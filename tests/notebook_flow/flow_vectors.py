"""Детерминированные «эмбеддинги» для сквозной проверки пайплайна ноутбука.

Общий модуль для заглушки embedding-svc (embedding_stub.py, внутри контейнера) и для теста,
который кладёт в базу векторы чанков, вариантов быстрых ответов и ссылок: векторы в базе и
векторы вопросов обязаны считаться одной функцией, иначе косинус между ними бессмыслен.

Вектор — мешок слов: каждое слово (нижний регистр) через sha256 попадает в несколько
координат со знаком, сумма нормируется по L2. Тексты с общими словами близки по косинусу,
одинаковый набор слов даёт косинус 1. Только стандартная библиотека.
"""

import hashlib
import math
import re

DIM = 768
MODEL = "stub-e5"
_SLOTS_PER_WORD = 3
_WORD_RE = re.compile(r"[0-9a-zа-яё]+")


def embed(text: str) -> list[float]:
    vector = [0.0] * DIM
    for word in _WORD_RE.findall(str(text).lower()):
        digest = hashlib.sha256(word.encode("utf-8")).digest()
        for slot in range(_SLOTS_PER_WORD):
            idx = int.from_bytes(digest[slot * 4:slot * 4 + 4], "big") % DIM
            sign = 1.0 if digest[16 + slot] & 1 else -1.0
            vector[idx] += sign
    norm = math.sqrt(sum(x * x for x in vector))
    if norm == 0:
        # Текст без слов: фиксированный единичный вектор, чтобы нормировка не делила на ноль.
        vector[0] = 1.0
        return vector
    return [x / norm for x in vector]


def cosine(a: list[float], b: list[float]) -> float:
    return sum(x * y for x, y in zip(a, b))


def literal(vector: list[float]) -> str:
    """Текстовая форма для pgvector: '[0.1,0.2,...]'."""
    return "[" + ",".join(f"{x:.7f}" for x in vector) + "]"
