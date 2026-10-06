#!/bin/zsh
# 用法: publish_one.sh "<标题>" "<md绝对路径>" "<封面绝对路径>" "tag1,tag2,tag3,tag4"
AB=/usr/local/bin/agent-browser
if ! command -v $AB >/dev/null 2>&1; then AB=agent-browser; fi

TITLE="$1"
MD="$2"
COVER="$3"
TAGS="$4"

echo "=== 发布: $TITLE ==="

# 1. 打开新建文章页
$AB open "https://editor.csdn.net/md/" >/dev/null 2>&1
sleep 6

# 2. 登录态检查
LOGIN=$($AB eval "(()=>{const f=document.querySelector('iframe');return (f&&f.src.includes('passport.csdn.net/account/login'))?'NOT_LOGIN':'LOGIN_OK'})()" 2>/dev/null | tail -1)
if [[ "$LOGIN" == *NOT_LOGIN* ]]; then echo "!!! 登录失效，中止"; exit 9; fi

# 3. 清空编辑器
$AB eval "(()=>{const e=document.querySelector('.editor__inner');if(e){e.focus();document.execCommand('selectAll');document.execCommand('delete');}return 'cleared'})()" >/dev/null 2>&1
sleep 2

# 4. 导入 md
$AB upload "input.hidden-file" "$MD" >/dev/null 2>&1
sleep 6

# 5. 校验导入
$AB eval "(()=>{const e=document.querySelector('.editor__inner');const t=e?e.innerText:'';return JSON.stringify({lines:t.split('\n').length,hasHeader:t.includes('个人主页'),toc:t.includes('[toc]')})})()" 2>/dev/null | tail -1

# 6. 覆盖标题
$AB eval "(()=>{const inp=document.querySelector('input.article-bar__title');if(!inp)return 'NF';Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set.call(inp,${(qqq)TITLE});inp.dispatchEvent(new Event('input',{bubbles:true}));return inp.value})()" 2>/dev/null | tail -1
sleep 2

# 7. 打开发布面板
$AB eval "(()=>{const b=[...document.querySelectorAll('button')].find(x=>x.className.includes('btn-publish'));b.click();return 'ok'})()" >/dev/null 2>&1
sleep 5

# 8. 上传封面
$AB upload "input.el-upload__input" "$COVER" >/dev/null 2>&1
sleep 6
$AB eval "(()=>{const b=[...document.querySelectorAll('.vicp-operate-btn')].find(x=>/确认上传/.test(x.textContent));if(!b)return 'NF';b.click();return 'confirmed'})()" 2>/dev/null | tail -1
sleep 6

# 9. 标签面板
$AB eval "(()=>{const open=[...document.querySelectorAll('.mark_selection_title_el_tag')].length;const inp=[...document.querySelectorAll('input')].find(i=>i.offsetHeight>0&&/请输入文字搜索/.test(i.placeholder));if(!inp)document.querySelector('button.tag__btn-tag').click();return 'opened'})()" >/dev/null 2>&1
sleep 3

# 10. 逐个添加标签（不动已有预选标签，稍后统一清理）
IFS=',' read -r -A TAGARR <<< "$TAGS"
for t in $TAGARR; do
  $AB type "input[placeholder='请输入文字搜索，Enter键入可添加自定义标签']" "$t" >/dev/null 2>&1
  sleep 2
  $AB press Enter >/dev/null 2>&1
  sleep 2
done

# 11. 清理非目标标签
$AB eval "(()=>{const want=${(qqq)TAGS}.split(',');const removed=[];[...document.querySelectorAll('.mark_selection_box_el_tag')].forEach(t=>{const txt=t.textContent.trim();if(!want.includes(txt)){const c=t.querySelector('.el-tag__close');if(c){c.click();removed.push(txt);}}});return JSON.stringify(removed)})()" 2>/dev/null | tail -1
sleep 2
$AB eval "(()=>JSON.stringify([...document.querySelectorAll('.mark_selection_box_el_tag')].map(t=>t.textContent.trim())))()" 2>/dev/null | tail -1

# 12. 选专栏 AI学习专栏
$AB eval "(()=>{const b=[...document.querySelectorAll('button.tag__btn-tag')].find(x=>/新建分类专栏/.test(x.textContent));if(b)b.click();return 'ok'})()" >/dev/null 2>&1
sleep 4
$AB eval "(()=>{const list=document.querySelector('.tag__options-list');if(!list)return 'NF';const it=[...list.querySelectorAll('*')].find(e=>e.children.length===0&&e.textContent.trim()==='AI学习专栏');if(!it)return 'NO_COL';it.click();return 'col_clicked'})()" 2>/dev/null | tail -1
sleep 3
# 关闭下拉（点 modal 标题，不能用 Escape）
$AB eval "(()=>{const h=document.querySelector('.modal .modal-header')||document.querySelector('.modal');if(h)h.click();document.querySelector('.modal').dispatchEvent(new MouseEvent('mousedown',{bubbles:true}));return 'closed'})()" >/dev/null 2>&1
sleep 2

# 13. 创作声明 = 部分内容由AI辅助生成
$AB eval "(()=>{const i=[...document.querySelectorAll('input.el-input__inner')].find(x=>x.placeholder==='无声明');if(!i)return 'ALREADY_OR_NF';i.click();i.dispatchEvent(new MouseEvent('mousedown',{bubbles:true}));return 'opened'})()" >/dev/null 2>&1
sleep 3
$AB eval "(()=>{const it=[...document.querySelectorAll('.el-select-dropdown__item, li')].find(e=>e.offsetHeight>0&&/部分内容由AI辅助生成/.test(e.textContent));if(!it)return 'NF';it.click();return 'ai_declared'})()" 2>/dev/null | tail -1
sleep 2

# 14. 提交前状态汇总
$AB eval "(()=>{const modal=document.querySelector('.modal');const rs=[...document.querySelectorAll('input[type=radio]')].reduce((a,r)=>{if(r.checked)a.push(r.value);return a;},[]);const decl=[...document.querySelectorAll('input.el-input__inner')].map(x=>x.value).filter(v=>/AI/.test(v));const cover=[...document.querySelectorAll('.modal img')].map(i=>i.src).filter(s=>/i-blog/.test(s)).length;return JSON.stringify({radio:rs,decl,cover,tags:[...document.querySelectorAll('.mark_selection_box_el_tag')].map(t=>t.textContent.trim())})})()" 2>/dev/null | tail -1

# 15. 点发布
$AB eval "(()=>{const modal=document.querySelector('.modal');const btns=[...modal.querySelectorAll('button')].filter(b=>b.textContent.trim()==='发布文章');if(!btns.length)return 'NF';btns[btns.length-1].click();return 'submitted'})()" 2>/dev/null | tail -1
sleep 10

# 16. 结果
$AB eval "(()=>{return JSON.stringify({url:location.href,ok:/success/.test(location.href),msg:(document.body.innerText.match(/发布成功[^\n]*/)||[''])[0],err:(document.body.innerText.match(/(失败|不能|请先|错误)[^\n]{0,40}/)||[''])[0]})})()" 2>/dev/null | tail -1
echo "=== 完成: $TITLE ==="
