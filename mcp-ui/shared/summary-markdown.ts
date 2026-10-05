import { Marked } from 'marked';

const parser = new Marked({extensions:[{
 name:'cjkStrong', level:'inline',
 start(source) { return source.indexOf('**'); },
 tokenizer(source) {
  // Saved summaries commonly put CJK text immediately after a bold label's colon.
  // CommonMark's punctuation delimiter rule otherwise leaves both asterisks visible.
  const match=/^\*\*([^*\n]+\p{P})\*\*(?=[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}])/u.exec(source);
  if(match)return {type:'cjkStrong',raw:match[0],tokens:this.lexer.inlineTokens(match[1])};
 },
 renderer(token) { return `<strong>${this.parser.parseInline(token.tokens??[])}</strong>`; }
}]});

export function parseSummaryMarkdown(markdown:string):string {
 return parser.parse(markdown,{async:false});
}
