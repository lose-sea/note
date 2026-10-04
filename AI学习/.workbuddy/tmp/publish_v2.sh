#!/bin/zsh
# 用法: publish_v2.sh "<期望标题>" "<md绝对路径>" "<封面绝对路径>" "tag1,tag2,tag3,tag4"
# 关键修正：导入 md 后标题已自动=文件名，**绝不覆盖标题**（覆盖会触发 CSDN 推荐标题回填，导致标题错乱）
AB=agent-browser
TITLE="$1"; MD="$2"; COVER="$3"; TAGS="$4"

say(){ echo "[$(date +%H:%M:%S)] $1"; }
jq_get(){ /Users/lose_sea/.workbuddy/binaries/python/versions/3.13.12/bin/python3 -c "import sys,json;d=json.loads(sys.stdin.read().strip().strip('\"').replace('\\\\\"','\"'));print(d.get('$1',''))" 2>/dev/null; }

# 1. 新建文章页
$AB open "https://editor.csdn.net/md/" >/dev/null 2>&1; sleep 7
U=$($AB eval "location.href" 2>/dev/null | tail -1)
say "页面: $U"

# 2. 登录态
L=$($AB eval "(()=>{const f=document.querySelector('iframe');return (f&&f.src.includes('passport.csdn.net/account/login'))?1:0})()" 2>/dev/null | tail -1)
if [[ "$L" == *1* ]]; then say "!!! 登录失效"; exit 9; fi

# 3. 清空 + 导入
$AB eval "(()=>{const e=document.querySelector('.editor__inner');if(e){e.focus();document.execCommand('selectAll');document.execCommand('delete');}return 1})()" >/dev/null 2>&1
sleep 2
$AB upload "input.hidden-file" "$MD" >/dev/null 2>&1; sleep 7

# 4. 校验导入 + 标题（标题必须自动=文件名/期望标题）
CHK=$($AB eval "(()=>{const e=document.querySelector('.editor__inner');const t=e?e.innerText:'';const ti=document.querySelector('input.article-bar__title');return JSON.stringify({h1:(t.match(/^# .*/m)||[''])[0].slice(2),title:ti?ti.value:'',lines:t.split('\n').length,ok:t.includes('个人主页')&&t.includes('[toc]')})})()" 2>/dev/null | tail -1)
say "导入: $CHK"
if [[ "$CHK" != *"$TITLE"* ]]; then say "!!! 标题与预期不符，中止"; exit 8; fi

# 5. 发布面板
$AB eval "(()=>{const b=[...document.querySelectorAll('button')].find(x=>String(x.className).includes('btn-publish'));if(!b)return 0;b.click();return 1})()" >/dev/null 2>&1
sleep 5
M=$($AB eval "(()=>!!document.querySelector('.modal'))()" 2>/dev/null | tail -1)
say "发布面板: $M"
if [[ "$M" != *true* ]]; then say "!!! 面板未打开，中止"; exit 7; fi

# 6. 封面 + 确认上传
$AB upload "input.el-upload__input" "$COVER" >/dev/null 2>&1; sleep 7
$AB eval "(()=>{const b=[...document.querySelectorAll('.vicp-operate-btn')].find(x=>/确认上传/.test(x.textContent));if(!b)return 0;b.click();return 1})()" >/dev/null 2>&1
sleep 7

# 7. 标签
$AB eval "(()=>{const inp=[...document.querySelectorAll('input')].find(i=>i.offsetHeight>0&&/请输入文字搜索/.test(i.placeholder||''));if(!inp){const b=[...document.querySelectorAll('button.tag__btn-tag')].find(x=>/添加文章标签/.test(x.textContent));if(b)b.click();}return 1})()" >/dev/null 2>&1
sleep 4
IFS=',' read -r -A TA <<< "$TAGS"
for t in $TA; do
  $AB type "input[placeholder='请输入文字搜索，Enter键入可添加自定义标签']" "$t" >/dev/null 2>&1; sleep 2
  $AB press Enter >/dev/null 2>&1; sleep 2
done
# 清掉非目标标签
$AB eval "(()=>{const want=${(qqq)TAGS}.split(',');[...document.querySelectorAll('.mark_selection_box_el_tag')].forEach(t=>{if(!want.includes(t.textContent.trim())){t.querySelector('.el-tag__close')?.click();}});return 1})()" >/dev/null 2>&1
sleep 3
say "标签: $($AB eval "JSON.stringify([...document.querySelectorAll('.mark_selection_box_el_tag')].map(t=>t.textContent.trim()))" 2>/dev/null | tail -1)"

# 8. 专栏
$AB eval "(()=>{const b=[...document.querySelectorAll('button.tag__btn-tag')].find(x=>/新建分类专栏/.test(x.textContent));if(b)b.click();return 1})()" >/dev/null 2>&1
sleep 4
say "专栏: $($AB eval "(()=>{const l=document.querySelector('.tag__options-list');if(!l)return 'NF';const it=[...l.querySelectorAll('*')].find(e=>e.children.length===0&&e.textContent.trim()==='AI学习专栏');if(!it)return 'NO_COL';it.click();return 'ok'})()" 2>/dev/null | tail -1)"
sleep 3
$AB eval "(()=>{const h=document.querySelector('.modal .modal-header')||document.querySelector('.modal');h?.click();document.querySelector('.modal')?.dispatchEvent(new MouseEvent('mousedown',{bubbles:true}));return 1})()" >/dev/null 2>&1
sleep 2

# 9. 创作声明
$AB eval "(()=>{const i=[...document.querySelectorAll('input.el-input__inner')].find(x=>x.placeholder==='无声明');if(!i)return 'ALREADY';i.click();i.dispatchEvent(new MouseEvent('mousedown',{bubbles:true}));return 'opened'})()" >/dev/null 2>&1
sleep 3
$AB eval "(()=>{const it=[...document.querySelectorAll('.el-select-dropdown__item, li')].find(e=>e.offsetHeight>0&&/部分内容由AI辅助生成/.test(e.textContent));if(!it)return 0;it.click();return 1})()" >/dev/null 2>&1
sleep 3

# 10. 提交前汇总
say "汇总: $($AB eval "(()=>{const rs=[...document.querySelectorAll('input[type=radio]')].reduce((a,r)=>{if(r.checked)a.push(r.value);return a;},[]);const decl=[...document.querySelectorAll('input.el-input__inner')].map(x=>x.value).filter(v=>/AI/.test(v));const cover=[...document.querySelectorAll('.modal img')].map(i=>i.src).filter(s=>/i-blog/.test(s)).length;return JSON.stringify({radio:rs,decl,cover})})()" 2>/dev/null | tail -1)"

# 11. 发布
$AB eval "(()=>{const m=document.querySelector('.modal');const bs=[...m.querySelectorAll('button')].filter(b=>b.textContent.trim()==='发布文章');if(!bs.length)return 0;bs[bs.length-1].click();return 1})()" >/dev/null 2>&1
sleep 12
say "结果: $($AB eval "JSON.stringify({url:location.href,ok:/creation\/success/.test(location.href)})" 2>/dev/null | tail -1)"
