import {t,shell,backButton,action,openPanel,onDispose,start} from '../shared/ui';
import {createSessionView} from '../shared/session-view';
shell(t('会话详情','Session'),`<div class="back-row">${backButton()}</div><div id="detail"><div class="loading-card"><div class="skeleton wide"></div></div></div>`);
const reader=createSessionView({onBrowse:()=>openPanel('app_workbench')});
action('back',()=>{if(reader.isDirty())throw new Error('Save or discard your edits first.');return openPanel('app_workbench');});
onDispose(reader.dispose);
start('voxstudio.session_panel',data=>reader.show(data));
