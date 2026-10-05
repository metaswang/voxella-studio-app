import assert from 'node:assert/strict';
import { test } from 'node:test';
import { build } from 'esbuild';

const bundle=await build({entryPoints:['shared/summary-markdown.ts'],bundle:true,format:'esm',platform:'node',write:false});
const {parseSummaryMarkdown}=await import('data:text/javascript;base64,'+Buffer.from(bundle.outputFiles[0].contents).toString('base64'));

test('saved CJK bold labels retain punctuation and adjacent text',()=>{
 for(const markdown of ['**日常注意事项：**避免趴睡。','**重要：**注意事項。','**주의：**설명']) {
  const html=parseSummaryMarkdown(markdown);
  assert.match(html,/<strong>[^<]+：<\/strong>/);
  assert.ok(!html.includes('**'));
 }
});

test('ordinary Markdown preserves headings, lists, quotes, tables and code',()=>{
 const html=parseSummaryMarkdown('# Summary\n\n- **A point**\n\n> A quote\n\n| Key | Value |\n| --- | --- |\n| A | B |\n\n```text\n**literal：**正文\n```');
 for(const tag of ['h1','ul','strong','blockquote','table','pre','code'])assert.ok(html.includes('<'+tag));
 assert.ok(html.includes('**literal：**正文'));
});

test('CJK compatibility keeps inline code and unmatched delimiters literal',()=>{
 const html=parseSummaryMarkdown('`**标签：**正文`\n\n**未闭合：正文');
 assert.ok(html.includes('<code>**标签：**正文</code>'));
 assert.ok(html.includes('**未闭合：正文'));
 assert.ok(!html.includes('<strong>'));
});
