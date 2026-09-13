import json
import unittest
from run import HERE, candidates, dp, locate, metrics

class ContractTests(unittest.TestCase):
    def sample(self,text,lang='en',protected=()):
        return dict(text=text,language=lang,reference_cuts=[],protected_phrases=list(protected))

    def test_reconstruction_preserves_internal_whitespace_and_punctuation(self):
        self.assertEqual(locate('One  thing. Next?', ['One  thing.', 'Next?']),[12,17])
        for lines in [['One thing.','Next?'],['One  thing','Next?'],['One  thing.'],['One  thing.','Next?','Next?']]:
            with self.subTest(lines=lines):
                with self.assertRaises(ValueError):locate('One  thing. Next?',lines)

    def test_empty_and_malformed_outputs_are_rejected(self):
        for lines in [[],None,[''],[1],['a','']]:
            with self.subTest(lines=lines):
                with self.assertRaises(ValueError):locate('a',lines)

    def test_protected_phrase_metric_detects_demonstrative_and_predicate_split(self):
        s=self.sample('先把这个打开，后面会比较顺。','zh-Hans',['这个','比较顺'])
        m=metrics(s,['先把这','个打开，后面会比较','顺。'],'default')
        self.assertTrue(m['valid']);self.assertEqual(m['protected_breaks'],2)

    def test_candidate_ids_never_split_spaced_words_or_decimal(self):
        s=self.sample('Use USB-C at 3.5 watts, please.')
        cuts=candidates(s,{})
        for phrase in ['USB-C','3.5']:
            start=s['text'].index(phrase)
            self.assertFalse(any(start<c<start+len(phrase) for c in cuts))

    def test_dp_preserves_overlong_indivisible_word(self):
        s=self.sample('x'*80)
        lines=dp(s,{},'default')
        self.assertEqual(lines,[s['text']]);self.assertEqual(metrics(s,lines,'default')['overlong'],1)

    def test_dp_accepts_empty_source_without_mutation(self):
        self.assertEqual(dp(self.sample(''),{},'default'),[])

    def test_dataset_counts_and_exact_segment_coverage(self):
        from collections import Counter
        samples=json.loads((HERE/'dataset.json').read_text())
        self.assertEqual(Counter(s['language'] for s in samples),{'en':20,'zh-Hans':20,'ja':5,'de':5,'fr':5,'es':5,'pt-BR':5})
        for s in samples:
            self.assertEqual(''.join(x['text'] for x in s['segments']),s['text'])
            self.assertTrue(all(p in s['text'] for p in s['protected_phrases']))

    def test_all_dp_results_reconstruct_source(self):
        samples={s['id']:s for s in json.loads((HERE/'dataset.json').read_text())}
        for b in json.loads((HERE/'baseline.json').read_text()):
            s=samples[b['id']]
            self.assertTrue(metrics(s,dp(s,b,b['budget']),b['budget'])['valid'])

if __name__=='__main__': unittest.main()
