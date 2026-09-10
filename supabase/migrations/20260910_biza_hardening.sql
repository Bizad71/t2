-- BIZA MARKET hardening migration. Non-destructive: no DROP/TRUNCATE.
-- Fixes the legacy shop_id/current_shop_id split, strengthens indexes, adds dashboard RPC,
-- and makes create_sale honor explicit batch selection while remaining transactional.

create index if not exists idx_products_store_barcode on public.products(store_id, barcode);
create index if not exists idx_products_store_name on public.products(store_id, name);
create index if not exists idx_batches_store_product_remaining on public.inventory_batches(store_id, product_id, remaining_quantity);
create index if not exists idx_sales_store_created on public.sales(store_id, created_at desc);
create index if not exists idx_sale_items_sale on public.sale_items(sale_id);
create index if not exists idx_audit_logs_store_created on public.audit_logs(store_id, created_at desc);

create or replace function public.current_shop_id()
returns uuid language sql stable security definer set search_path = public
as $$ select store_id from public.profiles where id = auth.uid() limit 1 $$;

create or replace function public.get_my_user_data()
returns jsonb language sql stable security definer set search_path = public
as $$
  select jsonb_build_object('profile',to_jsonb(p),'store',to_jsonb(s))
  from public.profiles p left join public.stores s on s.id=p.store_id
  where p.id=auth.uid() limit 1;
$$;

create or replace function public.get_dashboard_summary()
returns jsonb language sql stable security definer set search_path = ''
as $$
declare sid uuid; d date := current_date; begin
 sid := (select private.current_user_store_id());
 if sid is null then raise exception 'Store user required'; end if;
 return jsonb_build_object(
  'today_revenue',coalesce((select sum(total) from public.sales where store_id=sid and status='completed' and created_at>=d and created_at<d+1),0),
  'today_invoices',coalesce((select count(*) from public.sales where store_id=sid and status='completed' and created_at>=d and created_at<d+1),0),
  'today_profit',coalesce((select sum((si.unit_price-si.purchase_price)*si.quantity) from public.sale_items si join public.sales s on s.id=si.sale_id where si.store_id=sid and s.status='completed' and s.created_at>=d and s.created_at<d+1),0),
  'today_avg_invoice',coalesce((select avg(total) from public.sales where store_id=sid and status='completed' and created_at>=d and created_at<d+1),0),
  'product_count',coalesce((select count(*) from public.products where store_id=sid and is_active),0),
  'stock_qty',coalesce((select sum(remaining_quantity) from public.inventory_batches where store_id=sid and remaining_quantity>0),0),
  'low_stock',coalesce((select count(*) from (select product_id,sum(remaining_quantity) q from public.inventory_batches where store_id=sid group by product_id having sum(remaining_quantity)>0 and sum(remaining_quantity)<=5)x),0),
  'out_of_stock',coalesce((select count(*) from public.products p where p.store_id=sid and p.is_active and not exists(select 1 from public.inventory_batches b where b.product_id=p.id and b.store_id=sid and b.remaining_quantity>0)),0)
 );
end $$;

grant execute on function public.get_dashboard_summary() to authenticated;
grant execute on function public.current_shop_id() to authenticated;
grant execute on function public.get_my_user_data() to authenticated;

create or replace function public.create_sale(p_items jsonb,p_discount numeric default 0)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare sid uuid; sale_id uuid; inv bigint; subtotal numeric(14,2):=0; discount numeric(14,2):=coalesce(p_discount,0); total numeric(14,2); item jsonb; pid uuid; bid uuid; qty numeric(14,3); b record; take numeric(14,3); remaining numeric(14,3); begin
 sid := (select private.current_user_store_id()); if sid is null then raise exception 'Store user required'; end if;
 if not (select private.current_user_has_permission('sales.create')) then raise exception 'Permission denied'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Sale must contain at least one item'; end if;
 if discount<0 then raise exception 'Invalid discount'; end if;
 for item in select value from jsonb_array_elements(p_items) loop
  pid:=(item->>'product_id')::uuid; bid:=nullif(item->>'batch_id','')::uuid; qty:=(item->>'quantity')::numeric;
  if qty is null or qty<=0 then raise exception 'Invalid quantity'; end if;
  if not exists(select 1 from public.products p where p.id=pid and p.store_id=sid and p.is_active) then raise exception 'Product not found'; end if;
  if bid is null then raise exception 'Batch selection required'; end if;
  if not exists(select 1 from public.inventory_batches b where b.id=bid and b.product_id=pid and b.store_id=sid and b.remaining_quantity>=qty) then raise exception 'موجودی کافی نیست'; end if;
 end loop;
 update public.store_counters set next_invoice_number=next_invoice_number+1 where store_id=sid returning next_invoice_number-1 into inv;
 if inv is null then insert into public.store_counters(store_id,next_invoice_number) values(sid,2) returning 1 into inv; end if;
 insert into public.sales(store_id,invoice_number,subtotal,discount,total,status,created_by) values(sid,inv,0,0,0,'completed',auth.uid()) returning id into sale_id;
 for item in select value from jsonb_array_elements(p_items) loop
  pid:=(item->>'product_id')::uuid; bid:=(item->>'batch_id')::uuid; qty:=(item->>'quantity')::numeric; remaining:=qty;
  select id,remaining_quantity,purchase_price,sale_price into b from public.inventory_batches where id=bid and product_id=pid and store_id=sid for update;
  if b.remaining_quantity<remaining then raise exception 'موجودی کافی نیست'; end if;
  take:=remaining;
  insert into public.sale_items(sale_id,store_id,product_id,batch_id,quantity,unit_price,purchase_price,total) values(sale_id,sid,pid,b.id,take,b.sale_price,b.purchase_price,take*b.sale_price);
  insert into public.inventory_transactions(store_id,product_id,batch_id,type,quantity,purchase_price,sale_price,reference_id,created_by) values(sid,pid,b.id,'sale',take,b.purchase_price,b.sale_price,sale_id,auth.uid());
  update public.inventory_batches set remaining_quantity=remaining_quantity-take where id=b.id;
  subtotal:=subtotal+take*b.sale_price;
 end loop;
 if discount>subtotal then raise exception 'Discount cannot exceed subtotal'; end if; total:=subtotal-discount;
 update public.sales set subtotal=subtotal,discount=discount,total=total where id=sale_id;
 insert into public.invoices(store_id,sale_id,invoice_number) values(sid,sale_id,inv);
 perform private.write_audit_log(auth.uid(),sid,'create_sale','sale',sale_id,jsonb_build_object('invoice_number',inv,'subtotal',subtotal,'discount',discount,'total',total));
 return jsonb_build_object('sale_id',sale_id,'invoice_number',inv,'subtotal',subtotal,'discount',discount,'total',total);
end $$;
grant execute on function public.create_sale(jsonb,numeric) to authenticated;
