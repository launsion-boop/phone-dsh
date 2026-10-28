#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build the deterministic `office-files` scenario fixture: small, valid OOXML documents
(docx / xlsx / pptx) written with the standard library only, so the payload is reproducible
byte for byte (fixed zip timestamps, fixed member order, no extra fields).

usage: build_office_fixture.py <fixture dir>   (writes <fixture dir>/files/*.docx|xlsx|pptx)

Two members are deliberately DEFLATED (team-memo.docx, vendor-invoices.xlsx); the rest are
STORED, so a Python without the zlib module can still read them with `zipfile`.
"""
import os, sys, zipfile
from xml.sax.saxutils import escape

STAMP = (2026, 1, 1, 0, 0, 0)

def zwrite(path, members, compression):
    with zipfile.ZipFile(path, "w") as z:
        for name, text in members:
            zi = zipfile.ZipInfo(name, date_time=STAMP); zi.compress_type = compression; zi.external_attr = 0o644 << 16
            z.writestr(zi, text.encode("utf-8"))

# ---------------- docx ----------------
def docx_members(paragraphs):
    """paragraphs: list of (style, text); style 'Heading1' | 'Heading2' | None | 'ListBullet'"""
    body = []
    for style, text in paragraphs:
        ppr = f'<w:pPr><w:pStyle w:val="{style}"/></w:pPr>' if style else ""
        body.append(f'<w:p>{ppr}<w:r><w:t xml:space="preserve">{escape(text)}</w:t></w:r></w:p>')
    document = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
                '<w:body>' + "".join(body) + '<w:sectPr/></w:body></w:document>')
    return [
        ("[Content_Types].xml",
         '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
         '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
         '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
         '<Default Extension="xml" ContentType="application/xml"/>'
         '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
         '</Types>'),
        ("_rels/.rels",
         '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
         '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
         '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
         '</Relationships>'),
        ("word/document.xml", document),
    ]

REPORT = [
    ("Heading1", "Northwind Tools — Q1 2026 Quarterly Report"),
    (None, "Prepared by the finance team on 2026-04-08 for the leadership review."),
    ("Heading2", "1. Headline numbers"),
    (None, "Total revenue for Q1 2026 was 1,284,500 USD, up 12.4% from Q4 2025 (1,142,800 USD). Gross margin held at 41.2%."),
    (None, "Operating expenses were 702,300 USD; the largest line was payroll at 418,900 USD for a headcount of 47."),
    ("Heading2", "2. Revenue by region"),
    ("ListBullet", "North: 512,300 USD (39.9%)"),
    ("ListBullet", "South: 398,700 USD (31.0%)"),
    ("ListBullet", "West: 373,500 USD (29.1%)"),
    ("Heading2", "3. Risks"),
    (None, "Two enterprise renewals (Acme Logistics, 86,000 USD; Brightline Retail, 54,500 USD) slipped from March into April and are not in the Q1 figure."),
    (None, "Cloud hosting cost grew 18% quarter over quarter and now exceeds the 60,000 USD budget line by 7,200 USD."),
    ("Heading2", "4. Action items"),
    ("ListBullet", "Finance: close the two slipped renewals by 2026-04-30 (owner: Dana Whitfield)."),
    ("ListBullet", "Engineering: present a hosting cost reduction plan by 2026-05-15 (owner: Priya Raman)."),
    ("ListBullet", "Sales: hire two account executives for the West region before 2026-06-01 (owner: Marcus Lee)."),
]

MEMO = [
    ("Heading1", "Office move — what every team needs to do"),
    (None, "To: all staff. From: facilities. Date: 2026-04-20."),
    (None, "We move from the 4th floor to the new 9th-floor office on Monday 2026-05-18. The 4th floor must be empty by Friday 2026-05-15 at 18:00."),
    ("Heading2", "Before the move"),
    ("ListBullet", "Label every box with your team name and desk number; unlabelled boxes go to storage."),
    ("ListBullet", "Back up anything on local disks by 2026-05-13; desktops are re-imaged after the move."),
    ("ListBullet", "Return meeting-room keys and parking cards to the front desk by 2026-05-14."),
    ("Heading2", "Questions"),
    (None, "Contact facilities at ext. 4410. Lockers on the 9th floor are first come, first served from 2026-05-18 08:30."),
]

OFFER = [
    ("Heading1", "Offer of employment"),
    (None, "Dear {{CANDIDATE}},"),
    (None, "We are pleased to offer you the position of {{ROLE}} in the {{DEPT}} team, reporting to {{MANAGER}}."),
    (None, "Your start date will be {{START_DATE}}. Your annual base salary will be {{SALARY}}, paid monthly."),
    (None, "This offer is valid until {{EXPIRES}}. Please sign and return a copy to confirm your acceptance."),
    (None, "Kind regards,"),
    (None, "People Operations, Northwind Tools"),
]

# ---------------- xlsx ----------------
def xlsx_members(sheets):
    """sheets: list of (name, rows) where rows are lists of cells (str or int/float)."""
    strings, index = [], {}
    def sidx(s):
        if s not in index: index[s] = len(strings); strings.append(s)
        return index[s]
    def col(n):
        out = ""
        while True:
            n, r = divmod(n, 26); out = chr(65 + r) + out
            if n == 0: return out
            n -= 1
    sheet_xml = []
    for name, rows in sheets:
        rx = []
        for ri, row in enumerate(rows, 1):
            cells = []
            for ci, v in enumerate(row):
                ref = f"{col(ci)}{ri}"
                if isinstance(v, (int, float)): cells.append(f'<c r="{ref}"><v>{v}</v></c>')
                else: cells.append(f'<c r="{ref}" t="s"><v>{sidx(v)}</v></c>')
            rx.append(f'<row r="{ri}">' + "".join(cells) + '</row>')
        sheet_xml.append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                         '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>'
                         + "".join(rx) + '</sheetData></worksheet>')
    sst = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
           f'<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="{len(strings)}" uniqueCount="{len(strings)}">'
           + "".join(f'<si><t xml:space="preserve">{escape(s)}</t></si>' for s in strings) + '</sst>')
    wb = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
          + "".join(f'<sheet name="{escape(n)}" sheetId="{i+1}" r:id="rId{i+1}"/>' for i, (n, _) in enumerate(sheets)) + '</sheets></workbook>')
    wb_rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
               '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
               + "".join(f'<Relationship Id="rId{i+1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{i+1}.xml"/>' for i in range(len(sheets)))
               + f'<Relationship Id="rId{len(sheets)+1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>'
               '</Relationships>')
    ct = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
          '<Default Extension="xml" ContentType="application/xml"/>'
          '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
          + "".join(f'<Override PartName="/xl/worksheets/sheet{i+1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' for i in range(len(sheets)))
          + '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
          '</Types>')
    rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
            '</Relationships>')
    members = [("[Content_Types].xml", ct), ("_rels/.rels", rels), ("xl/workbook.xml", wb), ("xl/_rels/workbook.xml.rels", wb_rels), ("xl/sharedStrings.xml", sst)]
    members += [(f"xl/worksheets/sheet{i+1}.xml", x) for i, x in enumerate(sheet_xml)]
    return members

BUDGET = [
    ("Budget", [
        ["Department", "Q1 Budget (USD)", "Q1 Actual (USD)", "Owner"],
        ["Engineering", 310000, 328400, "Priya Raman"],
        ["Sales", 180000, 171250, "Marcus Lee"],
        ["Marketing", 95000, 102900, "Elena Brooks"],
        ["Support", 60000, 58300, "Tom Okafor"],
        ["Finance", 42000, 41450, "Dana Whitfield"],
        ["Facilities", 15300, 19600, "Facilities"],
    ]),
    ("Headcount", [
        ["Department", "Jan", "Feb", "Mar"],
        ["Engineering", 22, 23, 24],
        ["Sales", 9, 9, 10],
        ["Marketing", 4, 4, 4],
        ["Support", 5, 5, 5],
        ["Finance", 3, 3, 3],
        ["Facilities", 1, 1, 1],
    ]),
]

INVOICES = [
    ("Invoices", [
        ["Invoice", "Vendor", "Date", "Amount (USD)", "Status"],
        ["INV-2026-0101", "Cloudline Hosting", "2026-01-05", 5600, "paid"],
        ["INV-2026-0102", "Brightline Retail", "2026-01-12", 54500, "open"],
        ["INV-2026-0103", "Cloudline Hosting", "2026-02-05", 5600, "paid"],
        ["INV-2026-0104", "Officeworks Supply", "2026-02-19", 1240, "paid"],
        ["INV-2026-0105", "Cloudline Hosting", "2026-03-05", 5800, "open"],
        ["INV-2026-0106", "Acme Logistics", "2026-03-22", 86000, "open"],
        ["INV-2026-0107", "Officeworks Supply", "2026-03-30", 980, "paid"],
    ]),
]

# ---------------- pptx ----------------
def pptx_members(slides):
    """slides: list of (title, [bullets])"""
    def slide_xml(title, bullets):
        paras = "".join(f'<a:p><a:r><a:rPr lang="en-US"/><a:t>{escape(b)}</a:t></a:r></a:p>' for b in bullets)
        return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                '<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree>'
                '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>'
                '<p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr/>'
                f'<p:txBody><a:bodyPr/><a:p><a:r><a:rPr lang="en-US"/><a:t>{escape(title)}</a:t></a:r></a:p></p:txBody></p:sp>'
                '<p:sp><p:nvSpPr><p:cNvPr id="3" name="Content 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph idx="1"/></p:nvPr></p:nvSpPr><p:spPr/>'
                f'<p:txBody><a:bodyPr/>{paras}</p:txBody></p:sp>'
                '</p:spTree></p:cSld></p:sld>')
    n = len(slides)
    pres = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<p:presentation xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:sldIdLst>'
            + "".join(f'<p:sldId id="{256+i}" r:id="rId{i+1}"/>' for i in range(n)) + '</p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/></p:presentation>')
    pres_rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                 '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                 + "".join(f'<Relationship Id="rId{i+1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide{i+1}.xml"/>' for i in range(n))
                 + '</Relationships>')
    ct = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
          '<Default Extension="xml" ContentType="application/xml"/>'
          '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>'
          + "".join(f'<Override PartName="/ppt/slides/slide{i+1}.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>' for i in range(n))
          + '</Types>')
    rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>'
            '</Relationships>')
    members = [("[Content_Types].xml", ct), ("_rels/.rels", rels), ("ppt/presentation.xml", pres), ("ppt/_rels/presentation.xml.rels", pres_rels)]
    members += [(f"ppt/slides/slide{i+1}.xml", slide_xml(t, b)) for i, (t, b) in enumerate(slides)]
    return members

KICKOFF = [
    ("Project Atlas kickoff", ["Goal: replace the legacy order-tracking spreadsheet with a shared web dashboard", "Sponsor: Dana Whitfield (Finance)", "Timeline: discovery in May, pilot in July, rollout in September 2026"]),
    ("Scope for the pilot", ["Order status for the North and South regions only", "Daily import from the ERP export (CSV)", "Read-only for Sales; edit rights for Finance"]),
    ("Team and cadence", ["Product owner: Marcus Lee", "Engineering lead: Priya Raman, two engineers", "Weekly demo on Thursdays at 15:00; retro every second Friday"]),
    ("Risks and open questions", ["ERP export format is undocumented; sample needed by 2026-05-09", "Support team asked for mobile access — out of scope for the pilot", "Budget approval pending: 48,000 USD for hosting and licences"]),
]

def main():
    if len(sys.argv) != 2: sys.exit(__doc__)
    out = os.path.join(sys.argv[1], "files"); os.makedirs(out, exist_ok=True)
    zwrite(os.path.join(out, "quarterly-report.docx"), docx_members(REPORT), zipfile.ZIP_STORED)
    zwrite(os.path.join(out, "offer-template.docx"), docx_members(OFFER), zipfile.ZIP_STORED)
    zwrite(os.path.join(out, "team-memo.docx"), docx_members(MEMO), zipfile.ZIP_DEFLATED)
    zwrite(os.path.join(out, "budget-2026Q1.xlsx"), xlsx_members(BUDGET), zipfile.ZIP_STORED)
    zwrite(os.path.join(out, "vendor-invoices.xlsx"), xlsx_members(INVOICES), zipfile.ZIP_DEFLATED)
    zwrite(os.path.join(out, "kickoff.pptx"), pptx_members(KICKOFF), zipfile.ZIP_STORED)
    for f in sorted(os.listdir(out)):
        p = os.path.join(out, f)
        with zipfile.ZipFile(p) as z:
            kinds = {zi.compress_type for zi in z.infolist()}
            print(f"{f}: {os.path.getsize(p)} bytes, {len(z.infolist())} members, {'DEFLATED' if zipfile.ZIP_DEFLATED in kinds else 'STORED'}")

if __name__ == "__main__":
    main()
