import collections
import hashlib
import json
from pathlib import Path
from html.parser import HTMLParser
from run import HERE

samples={s['id']:s for s in json.loads((HERE/'dataset.json').read_text())}
records=json.loads((HERE/'subtitles.json').read_text())
verified=0
for record in records:
    if not record['valid']:
        assert record['subtitles'] is None and record['error']
        continue
    s=samples[record['sample_id']];segments={x['id']:x['text'] for x in s['segments']};whole=[]
    for subtitle in record['subtitles']:
        spans=subtitle['source_ranges'];pieces=[]
        for span in spans:
            text=segments[span['segment_id']];a=span['from_codepoint'];b=span['to_codepoint']
            assert type(a) is int and type(b) is int and 0<=a<b<=len(text)
            pieces.append(text[a:b])
        assert ''.join(pieces).strip()==subtitle['text']
        whole.extend(pieces)
    assert ''.join(whole)==s['text']
    verified+=1

for folder,expected,model in [(HERE,353,'gemini-3.5-flash-lite'),(HERE/'nano',353,'gpt-5-nano-2025-08-07'),(HERE/'nano_low',79,'gpt-5-nano-2025-08-07')]:
    raw=[json.loads(f.read_text()) for f in (folder/'raw').glob('*.json')]
    assert len(raw)==expected
    assert all(r.get('model')==model for r in raw)
    grouped=collections.defaultdict(set)
    for r in raw:
        assert 'reference_cuts' not in r['user'] and 'protected_phrases' not in r['user']
        assert r['finish_reason'] in ['stop','STOP']
        if r['repeat']==1:grouped[r['method'],r['budget']].add(r['id'])
    assert all(ids==set(samples) for ids in grouped.values())

class Page(HTMLParser):
    def __init__(self):super().__init__();self.sections=[];self.options=[]
    def handle_starttag(self,tag,attrs):
        attrs=dict(attrs)
        if tag=='section':self.sections.append(attrs['id'])
        if tag=='option':self.options.append(attrs.get('value'))
p=Page();p.feed((HERE/'cross_model.html').read_text())
assert len(p.sections)==65 and set(p.sections)==set(samples) and set(p.options)==set(samples)
manifest=json.loads((HERE/'manifest.json').read_text())
assert manifest['dataset_sha256']==hashlib.sha256((HERE/'dataset.json').read_bytes()).hexdigest()
print(f'PASS: 785 complete request receipts, 65 IDs in every main cell; {verified}/{len(records)} valid result source maps reconstruct exactly; 65 comparison sections; dataset hash matches.')
