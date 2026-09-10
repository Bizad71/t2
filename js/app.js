import { SUPABASE_URL, SUPABASE_ANON_KEY } from "./config.js";

const { createClient } = window.supabase;
const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
});

const state = { profile:null, store:null, tab:"home", cart:[], barcode:"" };
const $ = (s)=>document.querySelector(s);
const money = (n)=>new Intl.NumberFormat("fa-IR").format(Number(n||0));
const esc = (s)=>String(s??"").replace(/[&<>"']/g,m=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[m]));

async function loadMe(){
  const { data:{session} } = await sb.auth.getSession();
  if(!session){ renderLogin(); return; }
  const { data:p, error } = await sb.from("profiles").select("*").eq("id",session.user.id).single();
  if(error || !p || !p.is_active){ await sb.auth.signOut(); renderLogin(); return; }
  state.profile=p;
  if(p.store_id){
    const r=await sb.from("stores").select("*").eq("id",p.store_id).single();
    state.store=r.data;
  }
  render();
}
sb.auth.onAuthStateChange((event,session)=>{ if(event==="SIGNED_OUT"){ state.profile=null; state.store=null; renderLogin(); } });
window.addEventListener("pageshow",()=>loadMe());

function renderLogin(){
  $("#app").innerHTML=`<main class="auth"><section class="login-card">
    <div class="brand">BIZA <span>MARKET</span></div><p class="muted">مدیریت سریع و امن فروشگاه</p>
    <form id="loginForm"><label>نام کاربری</label><input id="username" required autocomplete="username">
    <label>رمز عبور</label><input id="password" type="password" required autocomplete="current-password">
    <button class="primary">ورود</button><div id="loginErr" class="error"></div></form>
  </section></main>`;
  $("#loginForm").onsubmit=async e=>{
    e.preventDefault(); $("#loginErr").textContent="در حال ورود…";
    const username=$("#username").value.trim();
    const password=$("#password").value;
    const {data:profile,error:pe}=await sb.from("profiles").select("email").eq("username",username).eq("is_active",true).maybeSingle();
    if(pe||!profile?.email){$("#loginErr").textContent="نام کاربری یا رمز عبور نادرست است.";return;}
    const {error}=await sb.auth.signInWithPassword({email:profile.email,password});
    $("#loginErr").textContent=error?"نام کاربری یا رمز عبور نادرست است.":"";
    if(!error) loadMe();
  };
}

function render(){
  if(state.profile.role==="admin"){ renderAdmin(); return; }
  renderStore();
}
function renderStore(){
  const name=state.store?.name||"فروشگاه";
  $("#app").innerHTML=`<div class="shell">
  <header><div><b>BIZA MARKET</b><small>${esc(name)}</small></div><button id="logout" class="ghost">خروج</button></header>
  <main id="content"></main>
  <nav class="bottom"><button data-tab="sales">فروش</button><button data-tab="home" class="active">خانه</button><button data-tab="inventory">انبار</button></nav></div>`;
  document.querySelectorAll("[data-tab]").forEach(b=>b.onclick=()=>{state.tab=b.dataset.tab;renderStore();});
  $("#logout").onclick=()=>sb.auth.signOut();
  if(state.tab==="inventory") inventoryPage();
  else if(state.tab==="sales") salesPage();
  else homePage();
}
async function homePage(){
  const summary=await sb.rpc("get_sales_summary",{p_from:new Date(new Date().setHours(0,0,0,0)).toISOString(),p_to:new Date().toISOString()});
  const invRes=await sb.rpc("get_inventory_report");
  const s=summary.data;
  const inv=invRes.data;
  const dbOk=!summary.error && !invRes.error;
  const stock=(inv||[]).reduce((a,x)=>a+Number(x.stock||0),0);
  $("#content").innerHTML=`<section class="hero"><div class="node"></div><h1>${esc(state.store?.name||"فروشگاه")}</h1>
  <div class="status"><span id="db">● بررسی دیتابیس…</span><span id="net">● بررسی اتصال…</span></div></section>
  <div class="grid stats"><div><small>فروش امروز</small><b>${money(s?.completed_total)} ریال</b></div>
  <div><small>فاکتور امروز</small><b>${money(s?.invoice_count)}</b></div><div><small>موجودی</small><b>${money(stock)}</b></div></div>
  <div class="actions"><button class="primary" id="quickSale">ثبت فروش</button><button id="quickStock">ورود کالا</button><button id="quickProduct">کالای جدید</button></div>
  <p class="muted">وضعیت دیتابیس و وضعیت اینترنت جداگانه نمایش داده می‌شوند.</p></section>`;
  $("#db").textContent=dbOk?"● دیتابیس متصل شد":"● خطا در اتصال به دیتابیس";
  $("#net").textContent=navigator.onLine?"● آنلاین":"● آفلاین";
  $("#quickSale").onclick=()=>{state.tab="sales";renderStore()};
  $("#quickStock").onclick=()=>openStock();
  $("#quickProduct").onclick=()=>openProduct();
}
async function inventoryPage(){
  const {data,error}=await sb.rpc("get_inventory_report");
  $("#content").innerHTML=`<section class="page"><div class="title"><h2>انبار</h2><button class="primary" id="addStock">ورود موجودی</button></div>
  ${error?`<div class="error">${esc(error.message)}</div>`:`<div class="table">${(data||[]).map(x=>`<div class="row"><div><b>${esc(x.product_name)}</b><small>${esc(x.barcode)} · ${esc(x.unit)}</small></div><strong>${money(x.stock)}</strong><span>${money(x.current_sale_price)}</span></div>`).join("")||"<p class='muted'>موجودی خالی است.</p>"}</div>`}</section>`;
  $("#addStock").onclick=openStock;
}
async function salesPage(){
  $("#content").innerHTML=`<section class="page"><div class="title"><h2>فروش</h2><button class="scan" id="scan">اسکن</button></div>
  <div class="searchbar"><input id="barcode" placeholder="بارکد را وارد کنید"><button id="find">جستجو</button></div>
  <div id="results"></div><div id="cart"></div></section>`;
  $("#scan").onclick=()=>openBinaryEye();
  $("#find").onclick=()=>searchBarcode($("#barcode").value.trim());
  const saved=sessionStorage.getItem("biza_barcode"); if(saved){$("#barcode").value=saved;sessionStorage.removeItem("biza_barcode");searchBarcode(saved);}
  drawCart();
}
async function searchBarcode(barcode){
  if(!barcode)return;
  const {data,error}=await sb.from("products").select("id,barcode,name,unit,is_active").eq("barcode",barcode).eq("is_active",true).maybeSingle();
  if(error){toast(error.message);return;}
  if(!data){openProduct(barcode);return;}
  const {data:batches,error:be}=await sb.from("inventory_batches").select("id,quantity,remaining_quantity,purchase_price,sale_price,created_at").eq("product_id",data.id).gt("remaining_quantity",0).order("created_at",{ascending:true});
  if(be){toast(be.message);return;}
  if(!batches?.length){toast("این کالا موجودی ندارد.");return;}
  const chosen=batches.length===1?batches[0]:await chooseBatch(data,batches);
  if(chosen) addCart(data,chosen);
}
function chooseBatch(p,bs){
 return new Promise(resolve=>{
  const opts=bs.map((b,i)=>`<button class="batchOpt" data-i="${i}">موجودی ${money(b.remaining_quantity)} · خرید ${money(b.purchase_price)} · فروش ${money(b.sale_price)}</button>`).join("");
  modal(`<h3>انتخاب بچ / قیمت</h3><p>${esc(p.name)}</p><div>${opts}</div>`);
  document.querySelectorAll(".batchOpt").forEach(x=>x.onclick=()=>{closeModal();resolve(bs[Number(x.dataset.i)])});
 });
}
function addCart(p,b){
 const key=b.id; const old=state.cart.find(x=>x.batch_id===key);
 if(old) old.qty++; else state.cart.push({product_id:p.id,batch_id:b.id,name:p.name,unit:p.unit,qty:1,max:Number(b.remaining_quantity),unit_price:Number(b.sale_price),purchase_price:Number(b.purchase_price)});
 drawCart();
}
function drawCart(){
 const el=$("#cart"); if(!el)return;
 const sub=state.cart.reduce((a,x)=>a+x.qty*x.unit_price,0);
 el.innerHTML=`<h3>سبد فروش</h3>${state.cart.map((x,i)=>`<div class="cartrow"><div><b>${esc(x.name)}</b><small>قیمت فروش: ${money(x.unit_price)}</small></div><div><button data-minus="${i}">−</button><b>${x.qty}</b><button data-plus="${i}">+</button></div><strong>${money(x.qty*x.unit_price)}</strong></div>`).join("")||"<p class='muted'>سبد خالی است.</p>"}
 ${state.cart.length?`<div class="checkout"><label>تخفیف<input id="discount" type="number" min="0" value="0"></label><b>جمع: ${money(sub)} ریال</b><button class="primary" id="checkout">ثبت فاکتور</button></div>`:""}`;
 el.querySelectorAll("[data-minus]").forEach(b=>b.onclick=()=>{const x=state.cart[+b.dataset.minus];x.qty--;if(x.qty<1)state.cart.splice(+b.dataset.minus,1);drawCart()});
 el.querySelectorAll("[data-plus]").forEach(b=>b.onclick=()=>{const x=state.cart[+b.dataset.plus];if(x.qty<x.max)x.qty++;else toast("موجودی کافی نیست.");drawCart()});
 $("#checkout")?.addEventListener("click",checkout);
}
async function checkout(){
 const discount=Number($("#discount").value||0);
 const items=state.cart.map(x=>({product_id:x.product_id,batch_id:x.batch_id,quantity:x.qty}));
 const {data,error}=await sb.rpc("create_sale",{p_items:items,p_discount:discount});
 if(error){toast(error.message);return;}
 toast(`فاکتور ${data.invoice_number} ثبت شد.`);
 state.cart=[];drawCart();
}
function openProduct(barcode=""){
 modal(`<h3>کالای جدید</h3><form id="productForm"><label>بارکد</label><input id="pbar" value="${esc(barcode)}" required><label>نام کالا</label><input id="pname" required><label>واحد</label><input id="punit" value="عدد"><label>توضیحات</label><textarea id="pdesc"></textarea><button class="primary">ذخیره</button></form>`);
 $("#productForm").onsubmit=async e=>{e.preventDefault();const {error}=await sb.rpc("create_product",{p_barcode:$("#pbar").value,p_name:$("#pname").value,p_description:$("#pdesc").value,p_unit:$("#punit").value});if(error)toast(error.message);else{closeModal();toast("کالا ثبت شد.");}};
}
async function openStock(){
 const {data}=await sb.from("products").select("id,name,barcode").eq("is_active",true).order("name");
 modal(`<h3>ورود موجودی</h3><form id="stockForm"><label>کالا</label><select id="sid">${(data||[]).map(p=>`<option value="${p.id}">${esc(p.name)} — ${esc(p.barcode)}</option>`).join("")}</select><label>تعداد</label><input id="qty" type="number" min="0.001" step="0.001" required><label>قیمت خرید</label><input id="buy" type="number" min="0" required><label>قیمت فروش</label><input id="sell" type="number" min="0" required><button class="primary">ثبت بچ جدید</button></form>`);
 $("#stockForm").onsubmit=async e=>{e.preventDefault();const {error}=await sb.rpc("add_stock",{p_product_id:$("#sid").value,p_quantity:Number($("#qty").value),p_purchase_price:Number($("#buy").value),p_sale_price:Number($("#sell").value),p_note:null});if(error)toast(error.message);else{closeModal();toast("بچ جدید ثبت شد.");}};
}
function openBinaryEye(){
 const ret=location.href.split("#")[0]+"?barcode={RESULT}";
 sessionStorage.setItem("biza_barcode_pending","1");
 location.href="binaryeye://scan?ret="+encodeURIComponent(ret);
}
function handleBinaryEye(){
 const q=new URLSearchParams(location.search), b=q.get("barcode");
 if(b){history.replaceState({},document.title,location.pathname);sessionStorage.setItem("biza_barcode",b);setTimeout(()=>{if(state.profile){state.tab="sales";renderStore();}},100);}
}
function renderAdmin(){
 $("#app").innerHTML=`<div class="shell"><header><div><b>BIZA MARKET</b><small>پنل مدیریت</small></div><button id="logout" class="ghost">خروج</button></header><main class="page"><h2>مدیریت سیستم</h2><div class="grid stats"><div><small>نقش</small><b>مدیر</b></div><div><small>کاربر</small><b>${esc(state.profile.full_name||state.profile.username||"")}</b></div></div><div class="card"><p>مدیریت فروشگاه‌ها و کاربران از طریق Function/Edge Function امن انجام می‌شود.</p><button class="primary" id="stores">فروشگاه‌ها</button></div><div id="adminOut"></div></main></div>`;
 $("#logout").onclick=()=>sb.auth.signOut();
 $("#stores").onclick=async()=>{const {data,error}=await sb.from("stores").select("*").order("created_at",{ascending:false});$("#adminOut").innerHTML=error?`<div class=error>${esc(error.message)}</div>`:`<div class=table>${(data||[]).map(s=>`<div class=row><b>${esc(s.name)}</b><span>${esc(s.code)}</span><span>${esc(s.status)}</span></div>`).join("")}</div>`};
}
function modal(html){let x=document.createElement("div");x.className="modalBack";x.innerHTML=`<div class="modal"><button class="close" id="mc">×</button>${html}</div>`;document.body.appendChild(x);$("#mc").onclick=closeModal}
function closeModal(){document.querySelector(".modalBack")?.remove()}
function toast(t){let x=document.createElement("div");x.className="toast";x.textContent=t;document.body.appendChild(x);setTimeout(()=>x.remove(),2800)}
handleBinaryEye(); loadMe();
