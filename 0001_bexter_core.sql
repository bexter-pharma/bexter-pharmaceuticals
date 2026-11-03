-- Bexter Pharmaceuticals Order Management System
-- Supabase / PostgreSQL starter migration
-- Authentication is handled by Supabase Auth. Never store plaintext passwords.

create extension if not exists pgcrypto;

create type public.app_role as enum ('mr', 'distributor', 'sales_manager', 'admin');
create type public.order_status as enum (
  'pending_manager', 'pending_admin', 'approved', 'rejected', 'cancelled'
);
create type public.approval_stage as enum ('sales_manager', 'admin');
create type public.approval_decision as enum ('pending', 'approved', 'rejected');
create type public.stock_movement_type as enum ('opening', 'in', 'out', 'adjustment');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  employee_code text unique,
  full_name text not null,
  phone text,
  role public.app_role not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  product_code text not null unique,
  product_name text not null,
  strength text,
  dosage_form text,
  pack_size text,
  unit text not null default 'Box',
  unit_price numeric(12,2) not null default 0 check (unit_price >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One central warehouse: one inventory row per product.
create table public.inventory (
  product_id uuid primary key references public.products(id),
  on_hand integer not null default 0 check (on_hand >= 0),
  reorder_level integer not null default 0 check (reorder_level >= 0),
  updated_at timestamptz not null default now()
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_no text not null unique,
  created_by uuid not null references public.profiles(id),
  order_date date not null default current_date,
  status public.order_status not null default 'pending_manager',
  currency char(3) not null default 'BDT' check (currency = 'BDT'),
  subtotal numeric(14,2) not null default 0 check (subtotal >= 0),
  remarks text,
  rejection_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid not null references public.products(id),
  product_code_snapshot text not null,
  product_name_snapshot text not null,
  quantity integer not null check (quantity > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0),
  line_total numeric(14,2) generated always as (quantity * unit_price) stored,
  unique (order_id, product_id)
);

create table public.approvals (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  stage public.approval_stage not null,
  decision public.approval_decision not null default 'pending',
  acted_by uuid references public.profiles(id),
  remarks text,
  acted_at timestamptz,
  created_at timestamptz not null default now(),
  unique (order_id, stage)
);

create table public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id),
  order_id uuid references public.orders(id),
  movement_type public.stock_movement_type not null,
  quantity integer not null check (quantity > 0),
  note text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create index orders_created_by_idx on public.orders(created_by);
create index orders_date_idx on public.orders(order_date desc);
create index orders_status_idx on public.orders(status);
create index order_items_product_idx on public.order_items(product_id);
create index stock_movements_product_date_idx on public.stock_movements(product_id, created_at desc);

create or replace function public.current_app_role()
returns public.app_role
language sql stable security definer
set search_path = public
as $$
  select role from public.profiles
  where id = auth.uid() and is_active = true
$$;

create or replace function public.make_order_no()
returns text
language sql
as $$
  select 'BEX-' || to_char(now(), 'YYYYMMDD') || '-' ||
         upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6))
$$;

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger products_updated_at before update on public.products
for each row execute function public.set_updated_at();

create trigger orders_updated_at before update on public.orders
for each row execute function public.set_updated_at();

-- Create an order and its lines atomically. Price is copied from the product master.
create or replace function public.submit_order(
  p_items jsonb,
  p_remarks text default null
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

  if public.current_app_role() not in ('mr', 'distributor') then
    raise exception 'Only MR or Distributor can submit orders';
  end if;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'At least one product is required';
  end if;

  insert into public.orders(order_no, created_by, remarks)
  values (public.make_order_no(), auth.uid(), p_remarks)
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

-- Sales Manager approves first; Admin gives final approval.
-- Stock is deducted exactly once, in the same transaction as final approval.
create or replace function public.review_order(
  p_order_id uuid,
  p_decision public.approval_decision,
  p_remarks text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role public.app_role;
  v_stage public.approval_stage;
  v_order public.orders%rowtype;
  v_line record;
  v_approval public.approvals%rowtype;
begin
  if auth.uid() is null then raise exception 'Login required'; end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'Decision must be approved or rejected';
  end if;

  v_role := public.current_app_role();

  if v_role = 'sales_manager' then
    v_stage := 'sales_manager';
  elsif v_role = 'admin' then
    v_stage := 'admin';
  else
    raise exception 'Not authorized to review orders';
  end if;

  select * into v_order from public.orders
  where id = p_order_id for update;

  if not found then raise exception 'Order not found'; end if;

  if v_stage = 'sales_manager' and v_order.status <> 'pending_manager' then
    raise exception 'Order is not awaiting Sales Manager approval';
  end if;

  if v_stage = 'admin' and v_order.status <> 'pending_admin' then
    raise exception 'Order is not awaiting Admin approval';
  end if;

  select * into v_approval from public.approvals
  where order_id = p_order_id and stage = v_stage for update;

  if v_approval.decision <> 'pending' then
    raise exception 'This approval step has already been completed';
  end if;

  update public.approvals
  set decision = p_decision, acted_by = auth.uid(),
      remarks = p_remarks, acted_at = now()
  where id = v_approval.id;

  if p_decision = 'rejected' then
    update public.orders set status = 'rejected',
      rejection_reason = p_remarks where id = p_order_id;
    return;
  end if;

  if v_stage = 'sales_manager' then
    update public.orders set status = 'pending_admin'
    where id = p_order_id;
    return;
  end if;

  -- Lock inventory rows in stable product order and validate all quantities first.
  for v_line in
    select product_id, quantity
    from public.order_items
    where order_id = p_order_id
    order by product_id
  loop
    perform 1 from public.inventory
    where product_id = v_line.product_id
      and on_hand >= v_line.quantity
    for update;

    if not found then
      raise exception 'Insufficient stock for one or more products';
    end if;
  end loop;

  for v_line in
    select product_id, quantity
    from public.order_items
    where order_id = p_order_id
    order by product_id
  loop
    update public.inventory
    set on_hand = on_hand - v_line.quantity, updated_at = now()
    where product_id = v_line.product_id;

    insert into public.stock_movements(
      product_id, order_id, movement_type, quantity, note, created_by
    )
    values (
      v_line.product_id, p_order_id, 'out',
      v_line.quantity, 'Approved order dispatch', auth.uid()
    );
  end loop;

  update public.orders set status = 'approved'
  where id = p_order_id;
end;
$$;

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.inventory enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.approvals enable row level security;
alter table public.stock_movements enable row level security;

-- Profiles: users see themselves; managers/admin can view staff; only admin manages profiles.
create policy "profile self or management read" on public.profiles
for select to authenticated
using (
  id = auth.uid()
  or public.current_app_role() in ('sales_manager','admin')
);

create policy "admin manages profiles" on public.profiles
for all to authenticated
using (public.current_app_role() = 'admin')
with check (public.current_app_role() = 'admin');

-- Active products visible to all authenticated users; only admin can edit.
create policy "active products read" on public.products
for select to authenticated using (is_active = true or public.current_app_role() in ('sales_manager','admin'));
create policy "admin product management" on public.products
for all to authenticated
using (public.current_app_role() = 'admin')
with check (public.current_app_role() = 'admin');

create policy "inventory read authenticated" on public.inventory
for select to authenticated using (true);
create policy "admin inventory management" on public.inventory
for all to authenticated
using (public.current_app_role() = 'admin')
with check (public.current_app_role() = 'admin');

create policy "orders read own or management" on public.orders
for select to authenticated
using (
  created_by = auth.uid()
  or public.current_app_role() in ('sales_manager','admin')
);

create policy "order items read own or management" on public.order_items
for select to authenticated
using (
  exists (
    select 1 from public.orders o
    where o.id = order_id
      and (o.created_by = auth.uid()
           or public.current_app_role() in ('sales_manager','admin'))
  )
);

create policy "approvals read own or management" on public.approvals
for select to authenticated
using (
  exists (
    select 1 from public.orders o
    where o.id = order_id
      and (o.created_by = auth.uid()
           or public.current_app_role() in ('sales_manager','admin'))
  )
);

create policy "stock movements read management" on public.stock_movements
for select to authenticated
using (public.current_app_role() in ('sales_manager','admin'));

-- Mutations go through the checked RPC functions, not direct client table writes.
revoke insert, update, delete on public.orders from authenticated;
revoke insert, update, delete on public.order_items from authenticated;
revoke insert, update, delete on public.approvals from authenticated;
revoke insert, update, delete on public.stock_movements from authenticated;

grant execute on function public.submit_order(jsonb, text) to authenticated;
grant execute on function public.review_order(uuid, public.approval_decision, text) to authenticated;
