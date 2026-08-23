#!/usr/bin/env python3
"""호스트-측 HWP/HWPX 추출기 — `<원본>_parse/refined.md` 직접 생산.

배경: 2nd-brain-parser 컨테이너의 HWP 경로(soffice+H2Orestart→docx→docling)는
  ① headless soffice user 프로필 미초기화로 자주 실패하고(inbox 91건 .parse-error)
  ② hwpx 표를 H2Orestart 가 버린다.
호스트엔 이미 검증된 우월 경로가 있다(radsafety-laws/_parse_attachments.py):
  · hwpx = OWPML(개방형 XML) 직독 → LibreOffice 완전 우회 → 무손실 표 복원
  · hwp  = soffice(+H2Orestart)→docx→pandoc gfm(병합셀 clean HTML)
HWP 는 단일소스(mineru N/A·diff 불가)라 refine 이 no-op → 추출=refine 을 한 번에 하고
refined.md 를 곧장 쓴다. brainify `_refined()` 가 이 refined.md 를 소비하며 컨테이너를 안 탄다.

전제: soffice(+H2Orestart 확장, user 프로필) · pandoc. 없으면 해당 파일 실패(.parse-error).
사용: hwp_refine.py <파일.hwp|.hwpx> [<파일2> ...]
  각 파일에 대해 `<파일>_parse/refined.md` 생성(멱등: 있으면 skip), .parse-error 제거.
반환코드: 전건 성공 0, 일부/전부 실패 1.
"""
import sys, os, re, subprocess, tempfile, shutil, zipfile, socket, datetime
import xml.etree.ElementTree as ET

VAULT = os.environ.get("SB_DATA", os.path.expanduser("~/projects/2nd-brain-vault"))
HOST = socket.gethostname()
TODAY = datetime.date.today().isoformat()


# ── OWPML(hwpx) 직접 파싱 — LibreOffice 우회(radsafety-laws 검증 로직 이식) ──
def _ln(tag):
    return tag.split("}")[-1]


def _owpml_hyperlink_url(field_begin):
    """fieldBegin(type=HYPERLINK) 의 parameters 에서 URL 추출 — Path 우선, 없으면 Command 정리."""
    for sp in field_begin.iter():
        if _ln(sp.tag) == "stringParam" and sp.get("name") == "Path":
            return (sp.text or "").strip()
    for sp in field_begin.iter():
        if _ln(sp.tag) == "stringParam" and sp.get("name") == "Command":
            # "URL;n;n;n" 형태 — 세미콜론 뒤 메타데이터 제거
            return (sp.text or "").split(";")[0].strip()
    return None


def _owpml_ptext(p):
    """문단 텍스트 추출. HWPHYPERLINK 필드(fieldBegin~fieldEnd)는 마크다운 [텍스트](URL) 로 변환."""
    parts = []
    link_stack = []  # [(begin_id, url, parts에서 시작 인덱스)]
    for el in p.iter():
        ln = _ln(el.tag)
        if ln == "t":
            parts.append("".join(el.itertext()))
        elif ln == "fieldBegin" and el.get("type") == "HYPERLINK":
            url = _owpml_hyperlink_url(el)
            if url:
                link_stack.append((el.get("id"), url, len(parts)))
        elif ln == "fieldEnd" and link_stack and el.get("beginIDRef") == link_stack[-1][0]:
            begin_id, url, start = link_stack.pop()
            text = "".join(parts[start:])
            del parts[start:]
            parts.append(f"[{text}]({url})" if text else url)
    return "".join(parts)


def _owpml_has_tbl(e):
    return any(_ln(d.tag) == "tbl" for d in e.iter())


def _owpml_cell(tc):
    sub = next((c for c in tc if _ln(c.tag) == "subList"), None)
    if sub is None:
        return ""
    out = []
    for p in sub:
        if _ln(p.tag) != "p":
            continue
        if _owpml_has_tbl(p):
            _owpml_walk(p, out)
        else:
            t = _owpml_ptext(p).strip()
            if t:
                out.append(t)
    return "\n".join(out)


def _owpml_table(tbl):
    rows = ["<table>"]
    for tr in (c for c in tbl if _ln(c.tag) == "tr"):
        rows.append("<tr>")
        for tc in (c for c in tr if _ln(c.tag) == "tc"):
            span = next((c for c in tc if _ln(c.tag) == "cellSpan"), None)
            cs = int(span.get("colSpan", "1")) if span is not None else 1
            rs = int(span.get("rowSpan", "1")) if span is not None else 1
            a = (f' colspan="{cs}"' if cs > 1 else "") + (f' rowspan="{rs}"' if rs > 1 else "")
            rows.append(f"<td{a}>{_owpml_cell(tc)}</td>")
        rows.append("</tr>")
    rows.append("</table>")
    return "\n".join(rows)


def _owpml_walk(elem, out):
    for ch in elem:
        ln = _ln(ch.tag)
        if ln == "tbl":
            out.append(_owpml_table(ch))
        elif ln == "p":
            if _owpml_has_tbl(ch):
                _owpml_walk(ch, out)
            else:
                t = _owpml_ptext(ch).strip()
                if t:
                    out.append(t)
        else:
            _owpml_walk(ch, out)


def parse_hwpx(path):
    """hwpx → 문단+표(HTML) markdown. 실패 시 '' (호출부가 docx 폴백)."""
    try:
        with zipfile.ZipFile(path) as z:
            secs = sorted(n for n in z.namelist()
                          if re.match(r"Contents/section\d+\.xml", n))
            out = []
            for n in secs:
                _owpml_walk(ET.fromstring(z.read(n)), out)
        return re.sub(r"\n{3,}", "\n\n", "\n\n".join(out)).strip()
    except Exception as e:
        print(f"  ? OWPML 파싱 실패({e}) → docx 폴백", file=sys.stderr)
        return ""


# ── hwp(바이너리): soffice→docx→pandoc ──
def clean_md(body):
    """docx→gfm 산출 정리: colgroup 노이즈 + 바깥 페이지-래퍼 표 제거(내용 무손실)."""
    body = re.sub(r"<colgroup>.*?</colgroup>\s*", "", body, flags=re.S)
    m = re.match(r"^<table>\s*<tbody>\s*<tr[^>]*>\s*<td>(.*)</td>\s*</tr>\s*"
                 r"</tbody>\s*</table>\s*$", body, re.S)
    if m:
        body = m.group(1)
    return re.sub(r"\n{3,}", "\n\n", body).strip()


def parse_hwp(path, tmp):
    """hwp → docx(soffice) → gfm(pandoc) → clean_md. 실패 시 ''."""
    subprocess.run(["soffice", "--headless", "--convert-to", "docx", "--outdir", tmp, path],
                   check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
    stem = os.path.splitext(os.path.basename(path))[0]
    docx = os.path.join(tmp, stem + ".docx")
    if not os.path.exists(docx) or os.path.getsize(docx) < 200:
        return ""
    raw = subprocess.run(["pandoc", "-f", "docx", "-t", "gfm", "--wrap=none", docx],
                         capture_output=True, text=True).stdout
    return clean_md(raw)


def vault_rel(path):
    try:
        return os.path.relpath(path, VAULT)
    except ValueError:
        return path


def refined_frontmatter(src_path, engine):
    return (f"---\n"
            f"source_pdf: {vault_rel(src_path)}\n"
            f"base_engine: {engine}\n"
            f"corrections: []\n"
            f"generated: {TODAY}\n"
            f"host: {HOST}\n"
            f"refine_confidence: ok\n"
            f"---\n\n")


def process(path, tmp):
    """파일 1개 → refined.md 생산. (ok, engine|err)."""
    parse_dir = path + "_parse"
    out = os.path.join(parse_dir, "refined.md")
    os.makedirs(parse_dir, exist_ok=True)
    ext = os.path.splitext(path)[1].lstrip(".").lower()
    if ext == "hwpx":
        body = parse_hwpx(path)
        engine = "owpml"
        if not body:                                   # OWPML 실패 → docx 폴백
            body = parse_hwp(path, tmp)
            engine = "hwpx-libreoffice-pandoc"
    else:
        body = parse_hwp(path, tmp)
        engine = "hwp-libreoffice-pandoc"
    if not body:
        open(os.path.join(parse_dir, ".parse-error"), "w").close()
        return False, "본문 추출 실패(soffice/pandoc/OWPML 모두)"
    open(out, "w", encoding="utf-8").write(refined_frontmatter(path, engine) + body + "\n")
    err = os.path.join(parse_dir, ".parse-error")
    if os.path.exists(err):
        os.remove(err)                                 # 재실행 성공 시 실패마커 제거
    return True, engine


def main(argv):
    files = argv[1:]
    if not files:
        print("사용: hwp_refine.py <파일.hwp|.hwpx> [...]", file=sys.stderr)
        return 2
    missing = [t for t in ("soffice", "pandoc") if not shutil.which(t)]
    if missing:
        print(f"[hwp_refine] 도구 미설치: {' '.join(missing)} → 중단", file=sys.stderr)
        return 3
    tmp = tempfile.mkdtemp(prefix="hwp_refine_")
    ok = 0
    fail = []
    try:
        for f in files:
            if not os.path.exists(f):
                fail.append((f, "파일 없음"))
                continue
            out = f + "_parse/refined.md"
            if os.path.exists(out):                     # 멱등
                print(f"  skip(이미 refined): {os.path.basename(f)}")
                ok += 1
                continue
            good, info = process(f, tmp)
            if good:
                ok += 1
                print(f"  ok({info}): {os.path.basename(f)}")
            else:
                fail.append((f, info))
                print(f"  FAIL({info}): {os.path.basename(f)}", file=sys.stderr)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"\n[hwp_refine] 성공 {ok} / 실패 {len(fail)}")
    for f, why in fail:
        print(f"     ✗ {os.path.basename(f)} — {why}")
    return 0 if not fail else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
