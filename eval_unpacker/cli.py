# eval_unpacker/cli.py
import sys, argparse
from .core import (
    find_eval_function_calls,
    unpack_payload_from_call_args,
    fix_malformed_setrequestheader,
    maybe_beautify,
)

def main():
    parser = argparse.ArgumentParser(
        prog="eval-unpack",
        description="Robust unpacker for eval(function(p,a,c,k,e,d){...})(...) packers"
    )
    parser.add_argument("input", help="input file path or '-' for stdin")
    parser.add_argument("--beautify", action="store_true", help="beautify with jsbeautifier (optional)")
    parser.add_argument("--indent", type=int, default=2, help="beautify indent size")
    parser.add_argument("--wrap", type=int, default=0, help="beautify wrap length (0 = no wrap)")
    parser.add_argument("--recursive", action="store_true", help="recursively unpack nested packers")
    parser.add_argument("--debug", action="store_true", help="debug output (to stderr)")
    args = parser.parse_args()

    # read text
    if args.input == "-":
        txt = sys.stdin.read()
    else:
        import codecs
        with open(args.input, "r", encoding="utf-8", errors="ignore") as fh:
            txt = fh.read()

    matches = find_eval_function_calls(txt)
    if args.debug:
        print(f"[debug] found {len(matches)} eval(function(...)) occurrences", file=sys.stderr)
    if not matches:
        print("No packer patterns found.", file=sys.stderr)
        sys.exit(1)

    _, _, call_args = matches[0]
    unpacked = unpack_payload_from_call_args(call_args, debug=args.debug)
    if unpacked is None:
        print("Failed to parse/unpack the packer call.", file=sys.stderr)
        sys.exit(1)

    out = unpacked
    if args.recursive:
        seen = set()
        while True:
            if out in seen: break
            seen.add(out)
            nested = find_eval_function_calls(out)
            if not nested: break
            _, _, nested_args = nested[0]
            deeper = unpack_payload_from_call_args(nested_args, debug=args.debug)
            if not deeper: break
            out = deeper

    out = fix_malformed_setrequestheader(out)

    if args.beautify:
        out = maybe_beautify(out, args.indent, args.wrap)

    print(out)

if __name__ == "__main__":
    main()
