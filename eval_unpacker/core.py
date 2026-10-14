# eval_unpacker/core.py
from typing import List, Optional, Tuple
import re
import codecs
import time
from datetime import datetime

# Optional beautifier
try:
    import jsbeautifier  # type: ignore
except Exception:
    jsbeautifier = None

_DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

def num_to_base(n: int, base: int) -> str:
    if n == 0:
        return "0"
    if base < 2 or base > 36:
        raise ValueError("base must be between 2 and 36")
    out = []
    while n:
        out.append(_DIGITS[n % base])
        n //= base
    return "".join(reversed(out))

def unescape_js_string(s: str) -> str:
    s = s.replace(r"\'", "'").replace(r'\"', '"').replace(r"\\", "\\")
    s = re.sub(r'\\x([0-9a-fA-F]{2})', lambda m: chr(int(m.group(1), 16)), s)
    s = re.sub(r'\\u([0-9a-fA-F]{4})', lambda m: chr(int(m.group(1), 16)), s)
    s = s.replace(r"\n", "\n").replace(r"\r", "\r").replace(r"\t", "\t")
    return s

def parse_top_level_args(s: str) -> List[str]:
    args, i, n, buf, stack = [], 0, len(s), [], []
    while i < n:
        ch = s[i]
        if ch in ("'", '"'):
            q = ch; buf.append(ch); i += 1
            while i < n:
                ch2 = s[i]; buf.append(ch2); i += 1
                if ch2 == "\\":
                    if i < n: buf.append(s[i]); i += 1
                    continue
                if ch2 == q: break
            continue
        if ch in "([{":
            stack.append(ch); buf.append(ch); i += 1; continue
        if ch in ")]}":
            if stack: stack.pop()
            buf.append(ch); i += 1; continue
        if ch == "," and not stack:
            args.append("".join(buf).strip()); buf = []; i += 1; continue
        buf.append(ch); i += 1
    if buf: args.append("".join(buf).strip())
    return args

def find_eval_function_calls(text: str) -> List[Tuple[int, int, str]]:
    results = []; idx = 0
    while True:
        pos = text.find("eval(function", idx)
        if pos == -1:
            break
        func_pos = text.find("function", pos)
        if func_pos == -1:
            idx = pos + 1; continue
        brace_pos = text.find("{", func_pos)
        if brace_pos == -1:
            idx = pos + 1; continue
        depth = 0; i = brace_pos; n = len(text)
        while i < n:
            ch = text[i]
            if ch == "{": depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0: break
            elif ch in ("'", '"'):
                quote = ch; i += 1
                while i < n:
                    if text[i] == "\\": i += 2; continue
                    if text[i] == quote: i += 1; break
                    i += 1
                continue
            i += 1
        if i >= n:
            idx = pos + 1; continue
        func_body_end = i
        j = func_body_end + 1
        while j < n and text[j].isspace(): j += 1
        if j >= n or text[j] != "(":
            idx = pos + 1; continue
        par_depth = 0; k = j; n = len(text)
        while k < n:
            ch = text[k]
            if ch == "(": par_depth += 1
            elif ch == ")":
                par_depth -= 1
                if par_depth == 0: break
            elif ch in ("'", '"'):
                quote = ch; k += 1
                while k < n:
                    if text[k] == "\\": k += 2; continue
                    if text[k] == quote: k += 1; break
                    k += 1
                continue
            k += 1
        if k >= n: idx = pos + 1; continue
        call_args = text[j + 1 : k]
        results.append((pos, k + 1, call_args))
        idx = k + 1
    return results

def two_pass_replace(p: str, a: int, c: int, klist: List[str]) -> str:
    placeholders = {}
    for i in range(c):
        tok = num_to_base(i, a)
        placeholders[tok] = f"__PKG_TOK_{i}__"
    keys_sorted = sorted(placeholders.keys(), key=len, reverse=True)
    pattern = re.compile(r'(?<![A-Za-z0-9_])(' + '|'.join(re.escape(k) for k in keys_sorted) + r')(?![A-Za-z0-9_])')
    intermediate = pattern.sub(lambda m: placeholders[m.group(1)], p)
    for i in range(c):
        ph = f"__PKG_TOK_{i}__"
        if i < len(klist):
            val = klist[i]
            if val == "": val = num_to_base(i, a)
        else:
            val = num_to_base(i, a)
        intermediate = intermediate.replace(ph, val or "")
    return intermediate

def unpack_payload_from_call_args(call_args: str, debug: bool = False) -> Optional[str]:
    import sys
    args = parse_top_level_args(call_args)
    if debug:
        print(f"[debug] parsed {len(args)} args", file=sys.stderr)
    if len(args) < 4: return None
    raw_p = args[0].strip()
    if not (raw_p.startswith("'") or raw_p.startswith('"')): return None
    quote = raw_p[0]
    p_inner = raw_p[1:-1] if raw_p.endswith(quote) else raw_p[1:]
    p = unescape_js_string(p_inner)
    try:
        a = int(args[1], 10); c = int(args[2], 10)
    except Exception:
        return None
    kexpr = args[3].strip()
    tokens: List[str] = []
    if kexpr.startswith("["):
        parts = re.findall(r"""(['"])(.*?)\1""", kexpr, re.DOTALL)
        tokens = [unescape_js_string(p[1]) for p in parts]
    else:
        m = re.match(r"""(['"])(.*)\1\.split\s*\(\s*(.*?)\s*\)\s*$""", kexpr, re.DOTALL)
        if m:
            body = unescape_js_string(m.group(2))
            tokens = body.split("|") if body != "" else []
        else:
            tokens = [t for t in re.split(r"\s*\|\s*", kexpr) if t]
    if len(tokens) < c:
        tokens = tokens + [""] * (c - len(tokens))
    return two_pass_replace(p, a, c, tokens)

def fix_malformed_setrequestheader(js_text: str) -> str:
    def repl(m):
        quote = m.group("q")
        first = m.group("first")
        second = m.group("second")
        if ":" in first:
            name, rest = first.split(":", 1)
            name = name.strip(); rest = rest.strip()
            value = second if second is not None and second.strip() != "" else rest
            return f'setRequestHeader({quote}{name}{quote}, {quote}{value}{quote})'
        else:
            return m.group(0)
    pattern = re.compile(r'setRequestHeader\s*\(\s*(?P<q>["\'])(?P<first>.*?)(?P=q)\s*,\s*(?P<q2>["\'])(?P<second>.*?)(?P=q2)\s*\)', re.DOTALL)
    return pattern.sub(lambda mm: repl(mm), js_text)

def maybe_beautify(js_text: str, indent_size: int, wrap_line_length: int) -> str:
    if jsbeautifier is None:
        return js_text
    opts = jsbeautifier.default_options()
    opts.indent_size = indent_size
    opts.wrap_line_length = wrap_line_length if wrap_line_length > 0 else 0
    return jsbeautifier.beautify(js_text, opts)
