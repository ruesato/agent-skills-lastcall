#!/usr/bin/env bash
# Local measurement baselines for lastcall's metric work (clr.4).
#
# Dev tooling, deliberately NOT in install.sh BINSCRIPTS: it calibrates, it is
# not part of the skill surface.
#
# Exists because an external review (2026-08-22) supplied acceptance numbers
# measured on a corpus that is not this machine. Using them would make a correct
# implementation fail its own verification. Re-run this to re-derive the numbers
# that LC-2/LC-3/LC-4/LC-5 should actually be checked against.
#
#   bin/baselines.sh [transcript-glob]
set -euo pipefail
GLOB="${1:-$HOME/.claude/projects/*/*.jsonl}"
python3 - "$GLOB" <<'PY'
import json,glob,os,sys,statistics as st,collections
files=glob.glob(os.path.expanduser(sys.argv[1]))

def turns(f):
    T=[];seen=set()
    for line in open(f,errors="ignore"):
        try: d=json.loads(line)
        except: continue
        m=d.get("message") or {}
        if d.get("type")!="assistant" or m.get("model")=="<synthetic>" or not m.get("usage"): continue
        r=d.get("requestId") or m.get("id") or d.get("uuid")
        if r in seen: continue
        seen.add(r); T.append(d)
    return T

def resident(u):
    cc=u.get("cache_creation") or {}
    return (u.get("cache_read_input_tokens",0)
            + cc.get("ephemeral_5m_input_tokens",0)
            + cc.get("ephemeral_1h_input_tokens",0))

base=[];peak=[];share=[];eff=collections.Counter()
w5=w1=0;ratios=[];dupe=[]
for f in files:
    T=turns(f)
    if len(T)<30: continue
    base.append(resident(T[0]["message"]["usage"]))
    peak.append(max(resident(d["message"]["usage"]) for d in T))
    out=sum(d["message"]["usage"].get("output_tokens",0) for d in T)
    th=sum((d["message"]["usage"].get("output_tokens_details") or {}).get("thinking_tokens",0) for d in T)
    if out: share.append(th/out)
    for d in T:
        u=d["message"]["usage"]; cc=u.get("cache_creation") or {}
        eff[d.get("effort") or "unset"]+=1
        a=cc.get("ephemeral_5m_input_tokens",0); b=cc.get("ephemeral_1h_input_tokens",0)
        w5+=a; w1+=b
        r=resident(u)
        if r>0 and (a+b)>0: ratios.append((a+b)/r)

def pct(xs,q): xs=sorted(xs); return xs[int(q*(len(xs)-1))]
print(f"sessions analysed: {len(base)} (of {len(files)} transcripts; >=30 turns)")
print()
print("== resident context ==")
print(f"  baseline (turn 0): median {st.median(base)/1000:.1f}K  range {min(base)/1000:.1f}K-{max(base)/1000:.1f}K")
print(f"  peak:              median {st.median(peak)/1000:.0f}K  max {max(peak)/1000:.0f}K")
print("  -> LC-5 thresholds MUST be a fraction of resident, never a constant.")
print()
print("== cache write TTL ==")
tot=w5+w1
print(f"  5m: {w5/1e6:.2f}M   1h: {w1/1e6:.2f}M   1h share: {100*w1/tot if tot else 0:.1f}%")
print("  -> 1h prices at 2.00x input, 5m at 1.25x (rates.json multipliers).")
print()
print("== cache re-establishment cutoff (write / resident) ==")
for q in (0.5,0.9,0.95,0.99): print(f"  p{int(q*100):02d} = {pct(ratios,q):.3f}")
print(f"  max  = {max(ratios):.3f}")
for thr in (0.25,0.5,0.75):
    n=sum(1 for r in ratios if r>=thr)
    print(f"  >= {thr:.2f} of resident: {n} turns ({100*n/len(ratios):.1f}%)")
print("  -> distribution is bimodal: ordinary writes cluster under p95, events")
print("     sit near 0.9. Any cutoff in 0.25-0.5 selects nearly the same turns,")
print("     which is what makes the fraction robust.")
print()
print("== reasoning ==")
print(f"  thinking share of output: median {100*st.median(share):.1f}%  range {100*min(share):.1f}%-{100*max(share):.1f}%")
print(f"  effort mix: {dict(eff)}")
PY
