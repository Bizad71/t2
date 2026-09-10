-- BIZA MARKET
-- SAFE MIGRATION: does not drop database/tables and does not delete business data.
-- Based on the supplied schema snapshot: public stores/products/profiles/batches/sales/etc already exist.
-- Run in Supabase SQL editor after a backup.

create extension if not exists pgcrypto;

-- 1) Store-scoped barcode uniqueness. If duplicates already exist, resolve them manually
-- before creating this index; the migration intentionally stops instead of deleting data.
do $$
begin
  if exists (
    select 1 from public.products
    group by store_id, barcode having count(*) > 1
  ) then
    raise exception 'Duplicate product barcodes exist within a store. Resolve duplicates before applying BIZA barcode index.';
  end if;
end $$;
create unique index if not exists products_store_barcode_uq on public.products(store_id, barcode);

create unique index if not exists sales_store_invoice_uq on public.sales(store_id, invoice_number);
create unique index if not exists store_counters_store_uq on public.store_counters(store_id);
create unique index if not exists invoices_store_invoice_uq on public.invoices(store_id, invoice_number);
create index if not exists products_store_name_idx on public.products(store_id, name);
create index if not exists batches_store_product_remaining_idx on public.inventory_batches(store_id, product_id, remaining_quantity);
create index if not exists sales_store_created_idx on public.sales(store_id, created_at desc);

-- 2) Private helpers used by SECURITY DEFINER functions and RLS.
create schema if not exists private;

create or replace function private.current_user_store_id()
returns uuid
language sql stable security definer
set search_path = public
as $$
  select p.store_id from public.profiles p where p.id = auth.uid() and p.is_active = true limit 1
$$;

create or replace function private.current_user_is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists(
    select 1 from public.profiles p
    where p.id=auth.uid() and p.is_active=true and p.role::text='admin'
  )
$$;

create or replace function private.current_user_has_permission(p_code text)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select private.current_user_is_admin()
  or exists(
    select 1 from public.user_permissions up
    where up.user_id=auth.uid() and up.permission_code=p_code and up.granted=true
  )
$$;

create or replace function private.write_audit_log(
  p_user uuid,p_store uuid,p_action text,p_entity_type text,p_entity_id uuid,p_details jsonb
) returns void
language plpgsql security definer
set search_path=public
as $$
begin
  insert into public.audit_logs(user_id,store_id,action,entity_type,entity_id,details)
  values(p_user,p_store,p_action,p_entity_type,p_entity_id,p_details);
end $$;

-- 3) Recreate core functions around the existing schema.
create or replace function public.create_product(
  p_barcode text,p_name text,p_description text default null,p_unit text default 'عدد'
) returns uuid language plpgsql security definer set search_path=''
as $$
declare sid uuid; pid uuid;
begin
  sid := private.current_user_store_id();
  if sid is null then raise exception 'Store user required'; end if;
  if not private.current_user_has_permission('products.create') then raise exception 'Permission denied'; end if;
  if nullif(trim(p_barcode),'') is null or nullif(trim(p_name),'') is null then raise exception 'Barcode and product name are required'; end if;
  insert into public.products(store_id,barcode,name,description,unit)
  values(sid,trim(p_barcode),trim(p_name),nullif(trim(p_description),''),coalesce(nullif(trim(p_unit),''),'عدد'))
  returning id into pid;
  perform private.write_audit_log(auth.uid(),sid,'create_product','product',pid,jsonb_build_object('barcode',trim(p_barcode),'name',trim(p_name)));
  return pid;
exception when unique_violation then raise exception 'این بارکد قبلاً در این فروشگاه ثبت شده است';
end $$;

create or replace function public.update_product(
  p_product_id uuid,p_barcode text,p_name text,p_description text default null,p_unit text default 'عدد',p_is_active boolean default true
) returns boolean language plpgsql security definer set search_path=''
as $$
declare sid uuid;
begin
  sid:=private.current_user_store_id();
  if sid is null then raise exception 'Store user required'; end if;
  if not private.current_user_has_permission('products.update') then raise exception 'Permission denied'; end if;
  update public.products set barcode=trim(p_barcode),name=trim(p_name),description=nullif(trim(p_description),''),unit=coalesce(nullif(trim(p_unit),''),'عدد'),is_active=p_is_active,updated_at=now()
  where id=p_product_id and store_id=sid;
  if not found then raise exception 'Product not found'; end if;
  perform private.write_audit_log(auth.uid(),sid,'update_product','product',p_product_id,jsonb_build_object('barcode',trim(p_barcode),'name',trim(p_name),'is_active',p_is_active));
  return true;
exception when unique_violation then raise exception 'این بارکد قبلاً در این فروشگاه ثبت شده است';
end $$;

create or replace function public.add_stock(
  p_product_id uuid,p_quantity numeric,p_purchase_price numeric,p_sale_price numeric,p_note text default null
) returns uuid language plpgsql security definer set search_path=''
as $$
declare sid uuid; bid uuid;
begin
  sid:=private.current_user_store_id();
  if sid is null then raise exception 'Store user required'; end if;
  if not private.current_user_has_permission('inventory.add') then raise exception 'Permission denied'; end if;
  if p_quantity<=0 or p_purchase_price<0 or p_sale_price<0 then raise exception 'مقدار یا قیمت نامعتبر است'; end if;
  if not exists(select 1 from public.products where id=p_product_id and store_id=sid and is_active) then raise exception 'Product not found'; end if;
  insert into public.inventory_batches(store_id,product_id,quantity,remaining_quantity,purchase_price,sale_price)
  values(sid,p_product_id,p_quantity,p_quantity,p_purchase_price,p_sale_price) returning id into bid;
  update public.products set current_purchase_price=p_purchase_price,current_sale_price=p_sale_price,updated_at=now()
  where id=p_product_id and store_id=sid;
  insert into public.inventory_transactions(store_id,product_id,batch_id,type,quantity,purchase_price,sale_price,note,created_by)
  values(sid,p_product_id,bid,'purchase',p_quantity,p_purchase_price,p_sale_price,p_note,auth.uid());
  perform private.write_audit_log(auth.uid(),sid,'add_stock','inventory_batch',bid,jsonb_build_object('product_id',p_product_id,'quantity',p_quantity,'purchase_price',p_purchase_price,'sale_price',p_sale_price));
  return bid;
end $$;

create or replace function public.create_sale(p_items jsonb,p_discount numeric default 0)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
 sid uuid; sale_id uuid; inv bigint; item jsonb; pid uuid; bid uuid;
 qty numeric; rem numeric; b record; take numeric; sub numeric(14,2):=0; disc numeric(14,2); total numeric(14,2);
begin
 sid:=private.current_user_store_id();
 if sid is null then raise exception 'Store user required'; end if;
 if not private.current_user_has_permission('sales.create') then raise exception 'Permission denied'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Sale must contain at least one item'; end if;
 disc:=coalesce(p_discount,0); if disc<0 then raise exception 'Invalid discount'; end if;

 update public.store_counters set next_invoice_number=next_invoice_number+1 where store_id=sid
 returning next_invoice_number-1 into inv;
 if inv is null then
   insert into public.store_counters(store_id,next_invoice_number) values(sid,2)
   returning 1 into inv;
 end if;

 insert into public.sales(store_id,invoice_number,subtotal,discount,total,status,created_by)
 values(sid,inv,0,0,0,'completed',auth.uid()) returning id into sale_id;

 for item in select value from jsonb_array_elements(p_items) loop
   pid:=(item->>'product_id')::uuid; bid:=nullif(item->>'batch_id','')::uuid; qty:=(item->>'quantity')::numeric;
   if qty is null or qty<=0 then raise exception 'Invalid quantity'; end if;
   if not exists(select 1 from public.products where id=pid and store_id=sid and is_active) then raise exception 'Product not found'; end if;

   if bid is null then
     select b.id into bid from public.inventory_batches b where b.store_id=sid and b.product_id=pid and b.remaining_quantity>0 order by b.created_at asc limit 2;
     if bid is null then raise exception 'موجودی این کالا صفر است'; end if;
     if (select count(*) from public.inventory_batches b where b.store_id=sid and b.product_id=pid and b.remaining_quantity>0)>1 then
       raise exception 'برای این کالا باید Batch/قیمت را انتخاب کنید';
     end if;
   end if;

   select * into b from public.inventory_batches where id=bid and store_id=sid and product_id=pid for update;
   if not found then raise exception 'Batch not found'; end if;
   if b.remaining_quantity<qty then raise exception 'موجودی Batch کافی نیست'; end if;

   insert into public.sale_items(sale_id,store_id,product_id,batch_id,quantity,unit_price,purchase_price,total)
   values(sale_id,sid,pid,bid,qty,b.sale_price,b.purchase_price,qty*b.sale_price);
   insert into public.inventory_transactions(store_id,product_id,batch_id,type,quantity,purchase_price,sale_price,reference_id,created_by)
   values(sid,pid,bid,'sale',qty,b.purchase_price,b.sale_price,sale_id,auth.uid());
   update public.inventory_batches set remaining_quantity=remaining_quantity-qty where id=bid;
   sub:=sub+(qty*b.sale_price);
 end loop;

 if disc>sub then raise exception 'تخفیف نمی‌تواند از جمع بیشتر باشد'; end if;
 total:=sub-disc;
 update public.sales set subtotal=sub,discount=disc,total=total where id=sale_id;
 insert into public.invoices(store_id,sale_id,invoice_number) values(sid,sale_id,inv);
 perform private.write_audit_log(auth.uid(),sid,'create_sale','sale',sale_id,jsonb_build_object('invoice_number',inv,'subtotal',sub,'discount',disc,'total',total));
 return jsonb_build_object('sale_id',sale_id,'invoice_number',inv,'subtotal',sub,'discount',disc,'total',total);
end $$;

create or replace function public.cancel_sale(p_sale_id uuid)
returns boolean language plpgsql security definer set search_path=''
as $$
declare sid uuid; s record; i record;
begin
 sid:=private.current_user_store_id();
 if sid is null then raise exception 'Store user required'; end if;
 if not private.current_user_has_permission('sales.cancel') then raise exception 'Permission denied'; end if;
 select * into s from public.sales where id=p_sale_id and store_id=sid for update;
 if not found then raise exception 'Sale not found'; end if;
 if s.status<>'completed' then raise exception 'Sale is already cancelled'; end if;
 for i in select * from public.sale_items where sale_id=p_sale_id and store_id=sid loop
   update public.inventory_batches set remaining_quantity=remaining_quantity+i.quantity where id=i.batch_id and store_id=sid;
   if not found then raise exception 'Inventory batch missing'; end if;
   insert into public.inventory_transactions(store_id,product_id,batch_id,type,quantity,purchase_price,sale_price,reference_id,created_by,note)
   values(sid,i.product_id,i.batch_id,'return_in',i.quantity,i.purchase_price,i.unit_price,p_sale_id,auth.uid(),'لغو فروش');
 end loop;
 update public.sales set status='cancelled',cancelled_by=auth.uid(),cancelled_at=now() where id=p_sale_id;
 perform private.write_audit_log(auth.uid(),sid,'cancel_sale','sale',p_sale_id,jsonb_build_object('invoice_number',s.invoice_number,'total',s.total));
 return true;
end $$;

create or replace function public.get_inventory_report()
returns table(product_id uuid,barcode text,product_name text,unit text,stock numeric,current_purchase_price numeric,current_sale_price numeric,inventory_value numeric)
language sql security definer set search_path=''
as $$
 select p.id,p.barcode,p.name,p.unit,coalesce(sum(b.remaining_quantity),0),p.current_purchase_price,p.current_sale_price,
 coalesce(sum(b.remaining_quantity*b.purchase_price),0)
 from public.products p left join public.inventory_batches b on b.product_id=p.id and b.store_id=p.store_id and b.remaining_quantity>0
 where p.store_id=private.current_user_store_id()
 group by p.id,p.barcode,p.name,p.unit,p.current_purchase_price,p.current_sale_price order by p.name
$$;

create or replace function public.get_sales_report(p_from timestamptz default null,p_to timestamptz default null)
returns table(sale_id uuid,invoice_number bigint,subtotal numeric,discount numeric,total numeric,status text,created_at timestamptz)
language sql security definer set search_path=''
as $$
 select s.id,s.invoice_number,s.subtotal,s.discount,s.total,s.status,s.created_at from public.sales s
 where s.store_id=private.current_user_store_id() and (p_from is null or s.created_at>=p_from) and (p_to is null or s.created_at<=p_to)
 order by s.created_at desc
$$;

create or replace function public.get_sales_summary(p_from timestamptz default null,p_to timestamptz default null)
returns jsonb language sql security definer set search_path=''
as $$
 select jsonb_build_object(
 'invoice_count',count(*) filter(where status='completed'),
 'completed_total',coalesce(sum(total) filter(where status='completed'),0),
 'cancelled_count',count(*) filter(where status='cancelled'),
 'cancelled_total',coalesce(sum(total) filter(where status='cancelled'),0),
 'profit',coalesce((select sum(si.quantity*(si.unit_price-si.purchase_price)) from public.sale_items si join public.sales sx on sx.id=si.sale_id where si.store_id=private.current_user_store_id() and sx.status='completed' and (p_from is null or sx.created_at>=p_from) and (p_to is null or sx.created_at<=p_to)),0)
 ) from public.sales s where s.store_id=private.current_user_store_id() and (p_from is null or s.created_at>=p_from) and (p_to is null or s.created_at<=p_to)
$$;

create or replace function public.get_next_invoice_number(p_store_id uuid)
returns bigint language plpgsql security definer set search_path=''
as $$
declare n bigint; sid uuid;
begin sid:=private.current_user_store_id(); if not private.current_user_is_admin() and sid<>p_store_id then raise exception 'Store access denied'; end if;
 update public.store_counters set next_invoice_number=next_invoice_number+1 where store_id=p_store_id returning next_invoice_number-1 into n;
 if n is null then insert into public.store_counters(store_id,next_invoice_number) values(p_store_id,2) returning 1 into n; end if; return n; end $$;

-- 4) Grants required by the frontend.
grant execute on function public.create_product(text,text,text,text) to authenticated;
grant execute on function public.update_product(uuid,text,text,text,text,boolean) to authenticated;
grant execute on function public.add_stock(uuid,numeric,numeric,numeric,text) to authenticated;
grant execute on function public.create_sale(jsonb,numeric) to authenticated;
grant execute on function public.cancel_sale(uuid) to authenticated;
grant execute on function public.get_inventory_report() to authenticated;
grant execute on function public.get_sales_report(timestamptz,timestamptz) to authenticated;
grant execute on function public.get_sales_summary(timestamptz,timestamptz) to authenticated;
grant execute on function public.get_next_invoice_number(uuid) to authenticated;

-- 5) RLS: store isolation at database level.
alter table public.products enable row level security;
alter table public.inventory_batches enable row level security;
alter table public.inventory_transactions enable row level security;
alter table public.sale_items enable row level security;
alter table public.sales enable row level security;
alter table public.invoices enable row level security;
alter table public.stores enable row level security;
alter table public.profiles enable row level security;
alter table public.store_counters enable row level security;
alter table public.store_settings enable row level security;
alter table public.audit_logs enable row level security;

-- Replace only the policies used by this application.
do $$
declare r record;
begin
 for r in select schemaname,tablename,policyname from pg_policies where schemaname='public' and tablename in
 ('products','inventory_batches','inventory_transactions','sale_items','sales','invoices','stores','profiles','store_counters','store_settings','audit_logs')
 loop execute format('drop policy if exists %I on %I.%I',r.policyname,r.schemaname,r.tablename); end loop;
end $$;

create policy products_store_read on public.products for select to authenticated using (store_id=private.current_user_store_id() or private.current_user_is_admin());
create policy products_store_write on public.products for all to authenticated using (store_id=private.current_user_store_id() or private.current_user_is_admin()) with check (store_id=private.current_user_store_id() or private.current_user_is_admin());

create policy batches_store_read on public.inventory_batches for select to authenticated using (store_id=private.current_user_store_id() or private.current_user_is_admin());
create policy batches_admin_write on public.inventory_batches for all to authenticated using (private.current_user_is_admin()) with check (private.current_user_is_admin());

create policy transactions_store_read on public.inventory_transactions for select to authenticated using (store_id=private.current_user_store_id() or private.current_user_is_admin());
create policy transactions_admin_write on public.inventory_transactions for all to authenticated using (private.current_user_is_admin()) with check (private.current_user_is_admin());

create policy sale_items_store_read on public.sale_items for select to authenticated using (store_id=private.current_user_store_id() or private.current_user_is_admin());
create policy sale_items_admin_write on public.sale_items for all to authenticated using (private.current_user_is_admin()) with check (private.current_user_is_admin());

create policy sales_store_read on public.sales for select to authenticated using (store_id=private.current_user_store_id() or private.current_user_is_admin());
create policy sales_admin_write on public.sales for all to authenticated using (private.current_user_is_admin()) with check (private.current_user_is_admin());

create policy invoices_store_read on public.invoices for select to authenticated using (store_id=private.current_user_store_id() or private.current_user_is_admin());
create policy invoices_admin_write on public.invoices for all to authenticated using (private.current_user_is_admin()) with check (private.current_user_is_admin());

create policy stores_store_read on public.stores for select to authenticated using (id=private.current_user_store_id() or private.current_user_is_admin());
create policy stores_admin_write on public.stores for all to authenticated using (private.current_user_is_admin()) with check (private.current_user_is_admin());

create policy profiles_self_or_admin on public.profiles for select to authenticated using (id=auth.uid() or private.current_user_is_admin());
create policy profiles_admin_write on public.profiles for all to authenticated using (private.current_user_is_admin()) with check (private.current_user_is_admin());

create policy counters_store_read on public.store_counters for select to authenticated using (store_id=private.current_user_store_id() or private.current_user_is_admin());
create policy counters_admin_write on public.store_counters for all to authenticated using (private.current_user_is_admin()) with check (private.current_user_is_admin());

create policy settings_store_read on public.store_settings for select to authenticated using (store_id=private.current_user_store_id() or private.current_user_is_admin());
create policy settings_admin_write on public.store_settings for all to authenticated using (private.current_user_is_admin()) with check (private.current_user_is_admin());

create policy audit_store_read on public.audit_logs for select to authenticated using (store_id=private.current_user_store_id() or private.current_user_is_admin());
create policy audit_admin_write on public.audit_logs for all to authenticated using (private.current_user_is_admin()) with check (private.current_user_is_admin());

-- Permissions are safe to read; they are not secrets.
alter table public.permissions enable row level security;
drop policy if exists permissions_authenticated_read on public.permissions;
drop policy if exists permissions_admin_all on public.permissions;
create policy permissions_authenticated_read on public.permissions for select to authenticated using (true);
create policy permissions_admin_all on public.permissions for all to authenticated using (private.current_user_is_admin()) with check (private.current_user_is_admin());

-- Seed only permission definitions if absent; no business/mock data.
insert into public.permissions(code,name) values
('products.create','ایجاد کالا'),('products.update','ویرایش کالا'),('inventory.add','ورود موجودی'),
('sales.create','ثبت فروش'),('sales.cancel','لغو فروش'),('reports.read','گزارش‌ها')
on conflict (code) do nothing;
