import collections
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent

def prepare():
    samples = []
    counts = collections.Counter()
    for row in (HERE / 'corpus.tsv').read_text().splitlines():
        lang, topic, marked, protected = row.split('\t')
        lang = lang.strip()
        counts[lang] += 1
        text = marked.replace('|', '')
        refs = marked.split('|')
        cuts, pos = [], 0
        for part in refs[:-1]:
            pos += len(part)
            cuts.append(pos)
        sample_id = f'{lang}-{counts[lang]:02d}'
        # Segment boundaries deliberately alternate between phrase and mid-phrase positions.
        split = len(text) // 2
        if counts[lang] % 2 == 0:
            split = cuts[len(cuts) // 2]
        samples.append(dict(id=sample_id, language=lang, topic=topic,
                            segments=[dict(id=sample_id+'-s1', text=text[:split], speaker='A'),
                                      dict(id=sample_id+'-s2', text=text[split:], speaker='A')],
                            join_policy='exact_concatenation', text=text,
                            reference_cuts=cuts, protected_phrases=protected.split(';'),
                            provenance='assistant-authored synthetic; references not human gold',
                            split='development' if counts[lang] <= (4 if lang in ['en','zh-Hans'] else 1) else 'evaluation'))
    assert counts == {'en':20,'zh-Hans':20,'ja':5,'de':5,'fr':5,'es':5,'pt-BR':5}, counts
    (HERE/'dataset.json').write_text(json.dumps(samples,ensure_ascii=False,indent=2)+'\n')
    inputs = []
    for s in samples:
        for budget in ['default','wide']:
            dense=s['language'] in ['zh-Hans','ja']
            inputs.append(dict(id=s['id'],language=s['language'],text=s['text'],budget=budget,
                               maximum=(18 if dense else 56) if budget=='default' else (24 if dense else 72)))
    files = ['Sources/PalmierPro/MediaFlow/SubtitleLLMProcessor.swift',
             'Sources/PalmierPro/MediaFlow/SubtitleTokenRemapper.swift',
             'Sources/PalmierPro/Transcription/Transcription.swift',
             'Sources/PalmierPro/MediaFlow/SubtitleCascadePrompt.swift']
    result = replay(inputs)
    (HERE/'baseline.json').write_text(json.dumps(result,ensure_ascii=False)+'\n')
    manifest={'app_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
              'worker_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT.parent/'voxella-worker-audio-postprocess',text=True).strip(),
              'sha256':{f:hashlib.sha256((ROOT/f).read_bytes()).hexdigest() for f in files},
              'dataset_sha256':hashlib.sha256((HERE/'dataset.json').read_bytes()).hexdigest(),
              'counts':dict(counts),'platform':subprocess.check_output(['sw_vers'],text=True),
              'swift':subprocess.check_output(['swift','--version'],text=True)}
    (HERE/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps({'counts':dict(counts),'samples':len(samples),'baseline_runs':len(inputs)}))

def replay(inputs):
    files = ['Sources/PalmierPro/MediaFlow/SubtitleLLMProcessor.swift',
             'Sources/PalmierPro/MediaFlow/SubtitleTokenRemapper.swift',
             'Sources/PalmierPro/Transcription/Transcription.swift',
             'Sources/PalmierPro/MediaFlow/SubtitleCascadePrompt.swift']
    source = [(ROOT/f).read_text() for f in files]
    readability=source[0].split('enum SubtitleReadabilityPolicy {',1)[1]
    remapper=source[1].split('    // MARK: - Normalization helpers',1)[0]+'}\n'
    join=source[2].split('    static func joinedText(',1)[1].split('\nextension TranscriptionResult {',1)[0]
    swift='import Foundation\nimport NaturalLanguage\n'
    swift+='enum SubtitleReadabilityPolicy {'+readability+'\n'+remapper
    swift+='\nenum TranscriptSegmenter {\n    static func joinedText('+join
    swift+='\n'+source[3]+'\n'+(HERE/'probe.swift').read_text()
    with tempfile.TemporaryDirectory(prefix='subtitle-text-probe-') as td:
        p=Path(td)
        (p/'main.swift').write_text(swift)
        subprocess.run(['swiftc','-O','-module-cache-path',str(p/'cache'),str(p/'main.swift'),'-o',str(p/'probe')],check=True)
        result=subprocess.run([str(p/'probe')],input=json.dumps(inputs),text=True,capture_output=True,check=True)
    return json.loads(result.stdout)

if __name__=='__main__': prepare()
