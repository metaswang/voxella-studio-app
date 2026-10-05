import type {App} from '@modelcontextprotocol/ext-apps';
// Compatibility for pre-0.2 endpoints only. The unified workspace never uses chat navigation.
export async function openLegacyPanel(app:App,title:string,tool:string,args:Record<string,unknown>) {
 const result=await app.sendMessage({role:'user',content:[{type:'text',text:`Open the VoxStudio ${title} panel. Call ${tool} with arguments ${JSON.stringify(args)} and display its independent interactive panel.`}]});
 if(result.isError)throw new Error('The host could not open this page. Please retry in chat.');
}
