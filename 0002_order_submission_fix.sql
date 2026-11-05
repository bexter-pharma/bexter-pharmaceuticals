-- Bexter OMS compatibility fix
-- Run once in Supabase SQL Editor, then click Run.

alter table public.orders
  add column if not exists customer_name text,
  add column if not exists doctor_name text;

-- Replace the original two-argument RPC with the four-argument version
-- used by the web application.
drop function if exists public.submit_order(jsonb, text);

create or replace function public.submit_order(
  p_items jsonb,
  p_remarks text default null,
  p_customer_name text default null,
  p_doctor_name text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id uuid;
  v_item jsonb;
  v_product public.products%rowtype;
  v_qty integer;
  v_total numeric(14,2) := 0;
begin
  if auth.uid() is null then
    raise exception 'Login required';
  end if;

  if public.current_app_role() not in ('mr', 'distributor', 'admin') then
    raise exception 'Only MR, Distributor or Admin can submit orders';
  end if;

  if coalesce(trim(p_customer_name), '') = '' then
    raise exception 'Customer / Distributor name is required';
  end if;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'At least one product is required';
  end if;

  insert into public.orders(
    order_no, created_by, remarks, customer_name, doctor_name
  )
  values (
    public.make_order_no(), auth.uid(), p_remarks,
    trim(p_customer_name), nullif(trim(coalesce(p_doctor_name, '')), '')
  )
  returning id into v_order_id;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    select * into v_product
    from public.products
    where id = (v_item->>'product_id')::uuid and is_active = true;

    if not found then
      raise exception 'Product not found or inactive';
    end if;

    v_qty := (v_item->>'quantity')::integer;
    if v_qty <= 0 then
      raise exception 'Quantity must be greater than zero';
    end if;

    insert into public.order_items(
      order_id, product_id, product_code_snapshot,
      product_name_snapshot, quantity, unit_price
    )
    values (
      v_order_id, v_product.id, v_product.product_code,
      v_product.product_name, v_qty, v_product.unit_price
    );

    v_total := v_total + (v_qty * v_product.unit_price);
  end loop;

  update public.orders set subtotal = v_total where id = v_order_id;

  insert into public.approvals(order_id, stage)
  values
    (v_order_id, 'sales_manager'),
    (v_order_id, 'admin');

  return v_order_id;
end;
$$;

revoke all on function public.submit_order(jsonb, text, text, text) from public;
grant execute on function public.submit_order(jsonb, text, text, text) to authenticated;
