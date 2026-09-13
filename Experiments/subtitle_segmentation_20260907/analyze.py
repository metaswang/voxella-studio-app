from __future__ import annotations
import collections
import argparse
import csv
import html
import json
import random
import statistics
import time
from pathlib import Path
from run import HERE, candidates, dp, limits, locate, metrics
from prepare import replay
OUT=HERE


def summarize(rows):
    valid=[r for r in rows if r['metrics']['valid']]
    m=[r['metrics'] for r in valid]
    total=sum(x['count'] for x in m); boundaries=sum(x['boundaries'] for x in m)
    tp=sum(x['tp'] for x in m); refs=sum(x['ref_count'] for x in m)
    durations=[r['latency_s'] for r in rows if 'latency_s' in r]
    return dict(n=len(rows),valid=len(valid),cues=total,
                fallback_count=sum(bool(r.get('fallback')) for r in rows),
                feasible=sum(x['overlong']==0 for x in m),
                f1_micro=2*tp/(boundaries+refs) if boundaries+refs else 0,
                f1_macro=statistics.mean(x['f1'] for x in m) if m else 0,
                f1_macro_all=sum(x['f1'] for x in m)/len(rows) if rows else 0,
                safe_samples=sum(x['overlong']==0 and x['protected_breaks']==0 and x['punctuation_starts']==0 for x in m),
                protected_breaks=sum(x['protected_breaks'] for x in m),
                protected_total=sum(x['protected_total'] for x in m),
                overlong=sum(x['overlong'] for x in m),short=sum(x['short'] for x in m),
                punctuation_starts=sum(x['punctuation_starts'] for x in m),
                latency_median_s=statistics.median(durations) if durations else None,
                input_tokens=sum(r.get('usage',{}).get('promptTokenCount',0) for r in rows),
                output_tokens=sum(r.get('usage',{}).get('candidatesTokenCount',0) for r in rows))


def main():
    data=json.loads((HERE/'dataset.json').read_text()); samples={s['id']:s for s in data}
    baseline=json.loads((HERE/'baseline.json').read_text()); bases={(x['id'],x['budget']):x for x in baseline}
    rows=[]
    def add(s,method,budget,lines,**extra):
        rows.append(dict(id=s['id'],language=s['language'],split=s['split'],method=method,budget=budget,
                         lines=lines,metrics=metrics(s,lines,budget),**extra))
    for s in data:
        for budget in ['default','wide']:
            base=bases[s['id'],budget]
            add(s,'R0_swift',budget,base['lines'],latency_s=base['elapsedMilliseconds']/1000)
            start=time.perf_counter(); lines=dp(s,base,budget)
            add(s,'R1_dp',budget,lines,latency_s=time.perf_counter()-start)
        lines=[]; offset=0
        for segment in s['segments']:
            part=dict(s,text=segment['text']); end=offset+len(part['text'])
            local=dict(nlpCuts=[p-offset for p in bases[s['id'],'default']['nlpCuts'] if offset<=p<=end])
            lines.extend(dp(part,local,'default'));offset=end
        add(s,'R1_isolated', 'default',lines)
    raw=[json.loads(p.read_text()) for p in sorted((OUT/'raw').glob('*.json'))]
    requests=[]; repair_map={}
    for r in raw:
        if r['repeat']!=1: continue
        s=samples[r['id']]; budget=r['budget']; base=bases[s['id'],budget]
        row={k:v for k,v in r.items() if k not in ['system','user','raw']}
        row.update(language=s['language'],split=s['split'])
        row['metrics']=metrics(s,r.get('lines'),budget) if r.get('lines') else r['metrics']
        rows.append(row)
        if r['method']=='L2_ids':
            proposed=locate(s['text'],r['lines'])[:-1] if r['metrics']['valid'] else []
            lines=dp(s,base,budget,proposed)
            add(s,'H2_ids_dp',budget,lines,latency_s=r.get('latency_s',0),fallback=not r['metrics']['valid'])
        if r['method']=='L1_semantic':
            proposed=locate(s['text'],r['lines'])[:-1] if r['metrics']['valid'] else []
            lines=dp(s,base,budget,proposed)
            add(s,'H1_text_dp',budget,lines,latency_s=r.get('latency_s',0),fallback=not r['metrics']['valid'])
            for reward in [0.5,1.0,1.5]:
                lines=dp(s,base,budget,proposed,proposal_reward=reward)
                add(s,f'H1_reward_{reward}',budget,lines,latency_s=r.get('latency_s',0),fallback=not r['metrics']['valid'])
        if r['method']=='L0_app' and r['metrics']['valid'] and r['metrics']['overlong']:
            for i,line in enumerate(r['lines']):
                rid=f'{r["id"]}::{i}'
                requests.append(dict(id=rid,language=s['language'],text=line,budget=budget,maximum=limits(s,budget)[2]))
    if requests:
        repair_path=OUT/'swift_repair.json'
        if repair_path.exists():
            repairs=json.loads(repair_path.read_text())
            if {x['id'] for x in repairs}!={x['id'] for x in requests}: repairs=replay(requests)
        else: repairs=replay(requests)
        repair_path.write_text(json.dumps(repairs,ensure_ascii=False)+'\n')
        repair_map={r['id']:r['lines'] for r in repairs}
    for r in raw:
        if r['repeat']!=1 or r['method']!='L0_app': continue
        s=samples[r['id']]; lines=r.get('lines'); stage='unchanged'
        if r['metrics']['valid'] and r['metrics']['overlong']:
            lines=[l for i in range(len(lines)) for l in repair_map[f'{r["id"]}::{i}']]; stage='per_line'
            m=metrics(s,lines,r['budget'])
            if not m['valid'] or m['overlong']:
                lines=bases[s['id'],r['budget']]['lines'];stage='whole_transcript'
        add(s,'L0_length_repair',r['budget'],lines,repair_stage=stage,latency_s=r.get('latency_s',0))
    (OUT/'results.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
    groups=collections.defaultdict(list)
    for r in rows:
        for lang in [r['language'],'ALL']:
            for split in [r['split'],'ALL']:
                groups[r['method'],r['budget'],lang,split].append(r)
    summary=[dict(method=k[0],budget=k[1],language=k[2],split=k[3],**summarize(v)) for k,v in sorted(groups.items())]
    (OUT/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
    with (OUT/'summary.csv').open('w') as f:
        writer=csv.DictWriter(f,fieldnames=list(summary[0]));writer.writeheader();writer.writerows(summary)
    stability=[]
    first={(r['id'],r['method'],r['budget']):r for r in raw if r['repeat']==1}
    for r in raw:
        if r['repeat']!=2:continue
        previous=first[r['id'],r['method'],r['budget']]
        stable=r.get('lines')==previous.get('lines')
        stability.append(dict(id=r['id'],method=r['method'],identical=stable,first_valid=previous['metrics']['valid'],second_valid=r['metrics']['valid']))
    (OUT/'stability.json').write_text(json.dumps(stability,indent=2)+'\n')
    page=['<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>字幕切分实验对照</title><style>body{font:16px system-ui;max-width:1500px;margin:40px auto;padding:0 24px;background:#f7f7f8;color:#222}select{font:inherit;padding:8px}section{margin:32px 0}article{background:white;padding:16px;border:1px solid #ddd;border-radius:10px;min-width:280px} .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:16px}li{margin:8px 0}pre{white-space:pre-wrap} .bad{color:#a12619} .meta{color:#555}</style><h1>字幕切分实验：逐条对照</h1><p>合成文本；参考切法为作者拟定，未经母语字幕编辑确认。数字指标不能替代自然度判断。输入 segment 用换行显示，输出每一项是一条 cue。</p><label>样本 <select id="pick"><option value="">全部</option>']
    for s in data: page.append(f'<option value="{s["id"]}">{s["id"]} · {html.escape(s["topic"])}</option>')
    page.append('</select></label>')
    for s in data:
        page.append(f'<section id="{s["id"]}"><h2>{s["id"]} · {html.escape(s["topic"])}</h2><pre>{html.escape(chr(10).join(x["text"] for x in s["segments"]))}</pre><div class="grid">')
        for r in [x for x in rows if x['id']==s['id']]:
            m=r['metrics'];label=f'{r["method"]} / {r["budget"]}'
            page.append(f'<article><h3>{label}</h3><p class="meta">F1 {m.get("f1",0):.3f} · 保护短语断裂 {m.get("protected_breaks","—")} · 超长 {m.get("overlong","—")}</p><ol>')
            for line in r.get('lines') or []:page.append(f'<li>{html.escape(line)}</li>')
            if not m['valid']:page.append(f'<p class="bad">{html.escape(m.get("error","invalid"))}</p>')
            page.append('</ol></article>')
        page.append('</div></section>')
    page.append('<script>document.querySelector("#pick").addEventListener("change",e=>document.querySelectorAll("section").forEach(s=>s.hidden=!!e.target.value&&s.id!==e.target.value));</script></html>')
    (OUT/'comparison.html').write_text(''.join(page))
    print(json.dumps([r for r in summary if r['language']=='ALL' and r['split']=='ALL'],ensure_ascii=False,indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--provider',choices=['gemini','openai'],default='gemini')
    parser.add_argument('--reasoning',choices=['minimal','low'],default='minimal')
    args=parser.parse_args()
    if args.provider=='openai':OUT=HERE/'nano'
    if args.provider=='openai' and args.reasoning=='low':OUT=HERE/'nano_low'
    main()
