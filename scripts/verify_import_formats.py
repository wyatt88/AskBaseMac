#!/usr/bin/env python3
"""Exercise new import formats through the real local encoder in a disposable library.

Requires a built askbase CLI and the existing loopback EmbeddingGemma 2 service.
Uses only generated fixtures; never opens the user's normal knowledge base.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"


def relationships(items):
    entries = "".join(
        f'<Relationship Id="{name}" Type="{REL}/{kind}" Target="{target}"/>'
        for name, kind, target in items
    )
    return f'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">{entries}</Relationships>'


def archive(path, members):
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as output:
        for name, content in members.items():
            output.writestr(name, content, compress_type=zipfile.ZIP_STORED if name == "mimetype" else zipfile.ZIP_DEFLATED)


def fixtures(directory):
    expected = {}

    def text(name, content, marker, encoding="utf-8"):
        (directory / name).write_text(content, encoding=encoding)
        expected[name] = marker

    def package(name, members, marker):
        archive(directory / name, members)
        expected[name] = marker

    text("兰花.custom", "虚构验收资料：兰花档案的库存编号为 Q782。", "Q782")
    text("README", "虚构验收资料：北风工坊的审核日期为 11 月 6 日。", "11 月 6 日")
    text("紫杉.data", "虚构验收资料：紫杉港口的靠泊码为 ZS57。", "ZS57", "utf-32")
    text("Maple.rtf", r"{\rtf1\ansi Synthetic acceptance fixture: Maple receipt code is M442.}", "M442")
    text("石榴.html", '<!doctype html><html><head><title>Fixture</title></head>'
         '<body><p>虚构验收资料：石榴备份目录编号 SL86。</p>'
         '<script>var ignored = "NOT_SOURCE";</script></body></html>', "SL86")
    package("青禾.docx", {
        "word/document.xml": '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body><w:p><w:r><w:t>虚构验收资料：青禾项目预算为 9000 元，负责人是吴桐。</w:t>'
        '</w:r></w:p></w:body></w:document>',
    }, "9000 元")
    package("春柳.xlsx", {
        "xl/workbook.xml": f'<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="{REL}">'
        '<sheets><sheet name="库存" sheetId="1" r:id="r1"/></sheets></workbook>',
        "xl/_rels/workbook.xml.rels": relationships([("r1", "worksheet", "worksheets/sheet1.xml")]),
        "xl/worksheets/sheet1.xml": '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>虚构验收资料：春柳仓库件号 CL73</t>'
        '</is></c></row></sheetData></worksheet>',
    }, "CL73")
    package("星桥.pptx", {
        "ppt/presentation.xml": f'<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="{REL}">'
        '<p:sldIdLst><p:sldId id="256" r:id="r1"/></p:sldIdLst></p:presentation>',
        "ppt/_rels/presentation.xml.rels": relationships([("r1", "slide", "slides/slide1.xml")]),
        "ppt/slides/slide1.xml": '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody>'
        '<a:p><a:r><a:t>虚构验收资料：星桥试点桥段编号 SJ13。</a:t></a:r></a:p>'
        '</p:txBody></p:sp></p:spTree></p:cSld></p:sld>',
    }, "SJ13")
    package("红杉.odt", {
        "mimetype": "application/vnd.oasis.opendocument.text",
        "content.xml": '<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
        'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text>'
        '<text:p>虚构验收资料：红杉访客凭证编号 HS29。</text:p>'
        '</office:text></office:body></office:document-content>',
    }, "HS29")
    package("银杏.epub", {
        "mimetype": "application/epub+zip",
        "META-INF/container.xml": '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">'
        '<rootfiles><rootfile full-path="OEBPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
        "OEBPS/book.opf": '<package xmlns="http://www.idpf.org/2007/opf" version="3.0"><manifest>'
        '<item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>'
        '<spine><itemref idref="chapter"/></spine></package>',
        "OEBPS/chapter.xhtml": '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Fixture</title></head>'
        '<body><p>虚构验收资料：银杏书库授权号 YX53。</p></body></html>',
    }, "YX53")
    (directory / "unsupported.bin").write_bytes(b"\x89PNG\r\n\x1a\n")
    return expected


def verify(binary):
    start = time.monotonic()
    checks = {}
    with tempfile.TemporaryDirectory(prefix="AskBase-Format-Smoke-") as temporary:
        base = Path(temporary)
        inputs, library = base / "fixtures", base / "library"
        inputs.mkdir()
        expected = fixtures(inputs)

        def cli(*arguments, codes=(0,)):
            result = subprocess.run(
                [str(binary), "--root", str(library), *arguments], capture_output=True,
                text=True, timeout=180, check=False,
            )
            if result.returncode not in codes:
                raise RuntimeError(result.stderr or result.stdout or f"CLI exit {result.returncode}")
            return json.loads(result.stdout)

        imported = cli("import", str(inputs), codes=(0, 1))
        checks["all_ten_text_documents_imported"] = len(imported["imported"]) == len(expected)
        checks["unsupported_binary_isolated"] = len(imported["failures"]) == 1 and "unsupported.bin" in imported["failures"][0]
        checks["no_unexpected_duplicates"] = not imported["skipped"]
        with sqlite3.connect(library / "library.sqlite") as connection:
            documents = [json.loads(row[0]) for row in connection.execute("SELECT record FROM documents")]
            chunks = [json.loads(row[0]) for row in connection.execute("SELECT record FROM chunks ORDER BY ordinal")]
        signatures = {chunk["encoderSignature"] for chunk in chunks}
        checks["one_encoder_signature"] = len(signatures) == 1 and bool(next(iter(signatures), ""))
        checks["valid_768d_vectors"] = bool(chunks) and all(
            chunk["dimensions"] == len(chunk["embedding"]) == 768
            and all(math.isfinite(value) for value in chunk["embedding"])
            and abs(sum(value * value for value in chunk["embedding"]) - 1) < 0.01 for chunk in chunks
        )
        formats = {}
        for name, marker in expected.items():
            matches = [document for document in documents if document["fileName"] == name]
            valid = len(matches) == 1
            if valid:
                document = matches[0]
                source = (inputs / name).read_bytes()
                indexed = [chunk for chunk in chunks if chunk["documentID"] == document["id"]]
                valid = (document["status"] == "ready"
                         and document["byteCount"] == len(source)
                         and document["contentHash"] == hashlib.sha256(source).hexdigest()
                         and (library / document["relativePath"]).read_bytes() == source
                         and marker in "\n".join(chunk["text"] for chunk in indexed)
                         and len(indexed) == document["chunkCount"] > 0)
                if name.endswith(".pptx"):
                    valid = valid and all(chunk.get("page") == 1 for chunk in indexed)
            formats[name] = valid
            checks[f"complete_text_and_original:{name}"] = valid
        for query, marker in [
            ("兰花档案的库存编号是什么？", "Q782"),
            ("青禾项目预算是多少？", "9000 元"),
            ("春柳仓库件号是什么？", "CL73"),
        ]:
            hits = cli("search", query)
            checks[f"retrieved:{marker}"] = any(marker in hit["text"] for hit in hits)
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "checks": checks, "formats": formats, "passed": sum(checks.values()), "total": len(checks),
        "encoder_signatures": sorted(signatures), "seconds": time.monotonic() - start,
        "scope": "synthetic local import/storage/retrieval check; not a corpus quality or capacity benchmark",
        "library": "fresh disposable directory; removed after verification",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    binary = args.binary
    if binary is None:
        output = subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True)
        binary = Path(output.strip().splitlines()[-1]) / "askbase"
    if not binary.is_file():
        raise SystemExit("Build the CLI first: swift build --product askbase")
    report = verify(binary.resolve())
    encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    print(encoded, end="")
    raise SystemExit(0 if report["passed"] == report["total"] else 1)


if __name__ == "__main__":
    main()
