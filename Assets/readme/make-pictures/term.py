"""term.py TEXT_FILE "TITLE" OUT.html : draw a text file as a dark terminal window (colours chosen per line)."""
import html, re, sys
from pathlib import Path

src, title, out = sys.argv[1:4]
G, DIM, AMB, RED, BLUE, WHITE = "#3ccf7e", "#72847C", "#F5B84D", "#FF5C6C", "#4DA6FF", "#E8FFF3"
rows = []
for ln in Path(src).read_text().rstrip("\n").split("\n"):
    e = html.escape(ln)
    if ln.startswith("$ "):
        e = f'<span style="color:{BLUE}">you@linux</span><span style="color:{DIM}">:~$</span> <span style="color:{WHITE}">{html.escape(ln[2:])}</span>'
    elif ln.startswith("PASS"):
        e = f'<span style="color:#8dffc0;font-weight:700">PASS</span><span style="color:{G}">{html.escape(ln[4:])}</span>'
    elif re.match(r"(RESULT: PASS|== \d+ passed|\d+ passed|.*PASS exit)", ln):
        e = f'<span style="color:#8dffc0;font-weight:700">{e}</span>'
    elif ln.startswith("=="):
        e = f'<span style="color:{AMB}">{e}</span>'
    elif "SECURITY" in ln or "ERROR" in ln or "no answer" in ln or "Could not resolve" in ln or "reject" in ln:
        e = f'<span style="color:{RED}">{e}</span>'
    elif ln.startswith("#") or ln.startswith("  ..."):
        e = f'<span style="color:{DIM}">{e}</span>'
    rows.append(f'<div class="r">{e or "&nbsp;"}</div>')
Path(out).write_text(f"""<!doctype html><meta charset="utf-8"><style>
html,body{{margin:0;background:transparent}}
.win{{margin:18px;background:#060A08;border:1px solid #1d3326;border-radius:14px;overflow:hidden;
     box-shadow:0 0 0 1px #0d1a13,0 8px 24px rgba(0,0,0,.28),0 0 40px rgba(85,245,160,.07);display:inline-block}}
.bar{{height:34px;background:#0B1611;border-bottom:1px solid #17261D;display:flex;align-items:center;padding:0 14px;gap:8px}}
.dot{{width:12px;height:12px;border-radius:50%}}
.t{{flex:1;text-align:center;color:#72847C;font:13px 'DejaVu Sans Mono',monospace;letter-spacing:2px;margin-right:52px}}
pre{{margin:0;padding:16px 22px 20px;font:15px/1.38 'DejaVu Sans Mono',monospace;color:{G};white-space:pre}}
.r{{white-space:pre;min-height:1.38em}}
</style><div class="win"><div class="bar"><span class="dot" style="background:#FF5C6C"></span><span class="dot" style="background:#F5B84D"></span><span class="dot" style="background:#55F5A0"></span><span class="t">{html.escape(title)}</span></div><pre>{"".join(rows)}</pre></div>""")
