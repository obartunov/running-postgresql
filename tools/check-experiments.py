#!/usr/bin/env python3
"""Проверка провенанса книги.

Скучный скрипт без зависимостей. Проверяет:

  1. у каждого experiments/**/measured.md есть заголовок с полем Chapter
     и остальными обязательными полями;
  2. все пути experiments/... , упомянутые в книге, существуют;
  3. нет повторяющихся идентификаторов экспериментов;
  4. каждый эксперимент в репозитории где-то упомянут (в книге или в
     docs/measurements.md);
  5. записи docs/version-claims.md разбираются и имеют полный набор
     полей.

Выводит список нарушений и, с --recheck, - список утверждений,
подлежащих пересверке перед печатью.

Код возврата 1, если есть нарушения (кроме --recheck).
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BOOK = ROOT / "book" / "Running-PostgreSQL.md"
EXPERIMENTS = ROOT / "experiments"
CLAIMS = ROOT / "docs" / "version-claims.md"
INDEX = ROOT / "docs" / "measurements.md"

MEASURED_FIELDS = [
    "Experiment", "Chapter", "PostgreSQL", "Machine/OS",
    "Date", "Question", "Result",
]
CLAIM_FIELDS = [
    "Chapter / section", "Claim", "PostgreSQL version", "Status",
    "Last verified", "Recheck before print",
]
CLAIM_STATUSES = {"timeless", "versioned", "beta/dev"}


def field(text, name):
    """Значение поля вида 'Name: value' в первых строках файла."""
    m = re.search(rf"^{re.escape(name)}:\s*(.+)$", text, re.M)
    return m.group(1).strip() if m else None


def check_measured(problems):
    seen = {}
    files = sorted(EXPERIMENTS.rglob("measured.md"))
    if not files:
        problems.append("нет ни одного experiments/**/measured.md")
    for path in files:
        rel = path.relative_to(ROOT)
        text = path.read_text(encoding="utf-8")
        head = "\n".join(text.splitlines()[:40])
        for name in MEASURED_FIELDS:
            if field(head, name) is None:
                problems.append(f"{rel}: нет поля '{name}' в заголовке")
        exp_id = field(head, "Experiment")
        if exp_id:
            if exp_id in seen:
                problems.append(
                    f"{rel}: идентификатор '{exp_id}' уже занят {seen[exp_id]}")
            else:
                seen[exp_id] = rel
        for section in ("## Observed", "### Observed"):
            if section in text:
                break
        else:
            problems.append(f"{rel}: нет раздела Observed")
    return files, seen


def book_references():
    if not BOOK.exists():
        return set(), f"нет книги по пути {BOOK.relative_to(ROOT)}"
    text = BOOK.read_text(encoding="utf-8")
    refs = set(re.findall(r"experiments/[A-Za-z0-9_./-]*", text))
    return {r.rstrip("./") for r in refs}, None


def check_references(problems, files):
    refs, err = book_references()
    if err:
        problems.append(err)
        return
    for ref in sorted(refs):
        if not (ROOT / ref).exists():
            problems.append(f"книга ссылается на {ref}, которого нет в репозитории")

    index_text = INDEX.read_text(encoding="utf-8") if INDEX.exists() else ""
    for path in files:
        d = path.parent.relative_to(ROOT).as_posix()
        mentioned = any(d in r for r in refs) or d in index_text
        if not mentioned:
            problems.append(
                f"{d}: эксперимент есть в репозитории, но не упомянут "
                f"ни в книге, ни в docs/measurements.md")


def parse_claims(problems):
    if not CLAIMS.exists():
        problems.append(f"нет {CLAIMS.relative_to(ROOT)}")
        return []
    text = CLAIMS.read_text(encoding="utf-8")
    blocks = re.split(r"^## ", text, flags=re.M)[1:]
    claims = []
    for block in blocks:
        cid = block.splitlines()[0].strip()
        if not cid.startswith("VC-"):
            continue
        entry = {"id": cid}
        for name in CLAIM_FIELDS:
            value = field(block, name)
            if value is None:
                problems.append(f"{cid}: нет поля '{name}'")
            entry[name] = value
        status = entry.get("Status")
        if status and status not in CLAIM_STATUSES:
            problems.append(
                f"{cid}: статус '{status}' не из {sorted(CLAIM_STATUSES)}")
        recheck = entry.get("Recheck before print")
        if recheck and recheck not in ("yes", "no"):
            problems.append(f"{cid}: 'Recheck before print' = '{recheck}', "
                            f"ожидается yes или no")
        claims.append(entry)
    ids = [c["id"] for c in claims]
    for cid in set(ids):
        if ids.count(cid) > 1:
            problems.append(f"дублирующийся идентификатор утверждения {cid}")
    return claims


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--recheck", action="store_true",
                    help="напечатать список утверждений к пересверке и выйти")
    args = ap.parse_args()

    problems = []
    files, seen = check_measured(problems)
    check_references(problems, files)
    claims = parse_claims(problems)

    if args.recheck:
        todo = [c for c in claims if c.get("Recheck before print") == "yes"]
        print(f"К пересверке перед печатью: {len(todo)} из {len(claims)}\n")
        for c in todo:
            print(f"{c['id']}  [{c.get('PostgreSQL version')}]  "
                  f"{c.get('Chapter / section')}")
            print(f"    {c.get('Claim')}")
            print(f"    последняя сверка: {c.get('Last verified')}")
        return 0

    print(f"экспериментов с measured.md: {len(files)}")
    print(f"уникальных идентификаторов:  {len(seen)}")
    print(f"версионных утверждений:      {len(claims)}")
    print()
    if problems:
        print(f"НАРУШЕНИЙ: {len(problems)}")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("нарушений нет")
    return 0


if __name__ == "__main__":
    sys.exit(main())
