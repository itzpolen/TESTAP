-- AquaDirect Supabase schema (patched). Run on a fresh Supabase project via the SQL Editor or CLI.
-- Patch notes: fixed rider permission seed, stock check in create_order, review trigger,
-- ticket policy, expiry job; added rider/admin-cancel/default-address functions and policies.
-- Privileged order/payment operations are server-side functions; client policies do not authorize them.

begin;

-- ============================================================================
-- Extensions and shared database types
-- ============================================================================
create schema if not exists extensions;
create extension if not exists pgcrypto;
create extension if not exists postgis with schema extensions;
create extension if not exists pg_trgm with schema extensions;
create extension if not exists pg_cron;

create type public.app_role as enum (
  'customer',
  'station_owner',
  'station_staff',
  'rider',
  'admin',
  'finance',
  'support',
  'verifier'
);

create policy "Station members manage their order dismissals"
on public.station_order_dismissals for all to authenticated
using (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.orders o
    where o.id = order_id
      and (select public.is_station_member(o.station_id))
  )
)
with check (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.orders o
    where o.id = order_id
      and (select public.is_station_member(o.station_id))
  )
);

create type public.application_status as enum (
  'draft',
  'submitted',
  'in_review',
  'changes_requested',
  'approved',
  'rejected'
);

create type public.verification_status as enum (
  'not_submitted',
  'pending',
  'verified',
  'changes_requested',
  'rejected'
);

create type public.publication_status as enum (
  'unpublished',
  'published',
  'suspended',
  'archived'
);

create type public.station_operational_status as enum (
  'onboarding',
  'active',
  'inactive',
  'suspended',
  'archived'
);

create type public.staff_status as enum ('invited', 'active', 'disabled');
create type public.product_status as enum ('draft', 'active', 'inactive');
create type public.container_option as enum ('refill_existing', 'new_gallon');

create type public.order_status as enum (
  'pending',
  'confirmed',
  'preparing',
  'ready',
  'rider_assigned',
  'out_for_delivery',
  'delivered',
  'cancelled',
  'failed'
);

create type public.payment_method as enum ('cod', 'paymongo');

create type public.payment_status as enum (
  'pending',
  'processing',
  'paid',
  'failed',
  'cancelled',
  'partially_refunded',
  'refunded'
);

create type public.delivery_status as enum (
  'pending',
  'assigned',
  'picked_up',
  'out_for_delivery',
  'delivered',
  'failed',
  'cancelled'
);

create type public.refund_status as enum (
  'requested',
  'processing',
  'succeeded',
  'failed',
  'cancelled'
);

create type public.support_status as enum (
  'open',
  'in_progress',
  'waiting_for_customer',
  'resolved',
  'closed'
);

create type public.document_review_status as enum (
  'pending',
  'approved',
  'changes_requested',
  'rejected'
);

create type public.profile_status as enum ('active', 'suspended');

-- ============================================================================
-- Shared timestamp helper
-- ============================================================================
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ============================================================================
-- Profiles and access-control tables
-- Role grants are shared by customer, station, and admin workflows.
-- ============================================================================
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  phone text,
  avatar_path text,
  status public.profile_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_phone_nonempty check (phone is null or length(trim(phone)) > 0)
);

create table public.user_roles (
  user_id uuid not null references public.profiles(id) on delete cascade,
  role public.app_role not null,
  assigned_by uuid references public.profiles(id) on delete set null,
  assigned_at timestamptz not null default now(),
  primary key (user_id, role)
);

create table public.admin_permissions (
  role public.app_role not null,
  permission_key text not null,
  granted_at timestamptz not null default now(),
  primary key (role, permission_key),
  constraint admin_permissions_admin_roles check (
    role in ('admin', 'finance', 'support', 'verifier', 'rider')
  ),
  constraint admin_permissions_key_nonempty check (length(trim(permission_key)) > 0)
);

-- ============================================================================
-- Customer account and device tables
-- ============================================================================
create table public.addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  label text not null default 'Home',
  recipient_name text,
  phone text,
  address_line text not null,
  barangay text,
  city text not null,
  province text not null,
  psgc_barangay_code text,
  psgc_city_code text,
  psgc_province_code text,
  region text,
  postal_code text,
  landmark text,
  latitude double precision,
  longitude double precision,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint addresses_latitude_range check (
    latitude is null or latitude between -90 and 90
  ),
  constraint addresses_longitude_range check (
    longitude is null or longitude between -180 and 180
  ),
  constraint addresses_coordinates_together check (
    (latitude is null) = (longitude is null)
  ),
  constraint addresses_psgc_codes check (
    (psgc_barangay_code is null or psgc_barangay_code ~ '^[0-9]{4,10}$')
    and (psgc_city_code is null or psgc_city_code ~ '^[0-9]{4,10}$')
    and (psgc_province_code is null or psgc_province_code ~ '^[0-9]{4,10}$')
  )
);

create unique index addresses_one_default_per_user
  on public.addresses(user_id)
  where is_default;
create index addresses_user_idx on public.addresses(user_id);

create table public.user_preferences (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  preferences jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  constraint user_preferences_object check (jsonb_typeof(preferences) = 'object')
);

create table public.user_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  platform text not null,
  push_token text not null unique,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint user_devices_platform check (
    platform in ('ios', 'android', 'web', 'other')
  )
);

-- ============================================================================
-- Station application and verification tables
-- ============================================================================
create table public.station_applications (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete restrict,
  legal_business_name text not null,
  display_name text not null,
  business_registration_number text,
  email text,
  phone text not null,
  address_line text not null,
  barangay text,
  city text not null,
  province text not null,
  region text,
  postal_code text,
  latitude double precision,
  longitude double precision,
  location extensions.geography(point, 4326) generated always as (
    case
      when latitude is not null and longitude is not null
      then extensions.st_setsrid(
        extensions.st_makepoint(longitude, latitude), 4326
      )::extensions.geography
      else null
    end
  ) stored,
  application_status public.application_status not null default 'draft',
  verification_status public.verification_status not null default 'not_submitted',
  admin_notes text,
  submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint station_applications_location_range check (
    (latitude is null or latitude between -90 and 90)
    and (longitude is null or longitude between -180 and 180)
  ),
  constraint station_applications_coordinates_together check (
    (latitude is null) = (longitude is null)
  )
);

create table public.station_application_status_history (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null
    references public.station_applications(id) on delete cascade,
  old_status public.application_status,
  new_status public.application_status not null,
  changed_by uuid references public.profiles(id) on delete set null,
  note text,
  created_at timestamptz not null default now()
);

create index station_application_status_history_idx
  on public.station_application_status_history(application_id, created_at);

create table public.customer_email_access (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  email text not null,
  updated_at timestamptz not null default now()
);

create index station_applications_owner_idx
  on public.station_applications(owner_id, created_at desc);
create index station_applications_review_queue_idx
  on public.station_applications(application_status, created_at)
  where application_status in ('submitted', 'in_review', 'changes_requested');
create unique index station_applications_one_open_per_owner
  on public.station_applications(owner_id)
  where application_status in ('draft', 'submitted', 'in_review', 'changes_requested');
create index station_applications_display_name_trgm_idx
  on public.station_applications using gin (display_name extensions.gin_trgm_ops);
create index station_applications_location_gist_idx
  on public.station_applications using gist(location)
  where location is not null;

create table public.stations (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null unique
    references public.station_applications(id) on delete restrict,
  owner_id uuid not null references public.profiles(id) on delete restrict,
  display_name text not null,
  description text,
  logo_path text,
  facebook_url text,
  instagram_url text,
  email text,
  phone text not null,
  address_line text not null,
  barangay text,
  city text not null,
  province text not null,
  region text,
  postal_code text,
  latitude double precision not null,
  longitude double precision not null,
  location extensions.geography(point, 4326) generated always as (
    extensions.st_setsrid(extensions.st_makepoint(longitude, latitude), 4326)::extensions.geography
  ) stored,
  timezone text not null default 'Asia/Manila',
  service_radius_km numeric(7, 2),
  minimum_order_amount numeric(12, 2) not null default 0,
  default_delivery_fee numeric(12, 2) not null default 0,
  estimated_delivery_minutes integer,
  verification_status public.verification_status not null default 'pending',
  publication_status public.publication_status not null default 'unpublished',
  operational_status public.station_operational_status not null default 'onboarding',
  rating_average numeric(3, 2) not null default 0,
  rating_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint stations_location_range check (
    latitude between -90 and 90 and longitude between -180 and 180
  ),
  constraint stations_facebook_url_check check (
    facebook_url is null or facebook_url ~*
      '^https://([a-z0-9-]+\.)*(facebook\.com|fb\.com)(:[0-9]+)?([/?#]|$)'
  ),
  constraint stations_instagram_url_check check (
    instagram_url is null or instagram_url ~*
      '^https://([a-z0-9-]+\.)*instagram\.com(:[0-9]+)?([/?#]|$)'
  ),
  constraint stations_radius_positive check (
    service_radius_km is null or service_radius_km > 0
  ),
  constraint stations_nonnegative_amounts check (
    minimum_order_amount >= 0 and default_delivery_fee >= 0
  ),
  constraint stations_delivery_time_positive check (
    estimated_delivery_minutes is null or estimated_delivery_minutes > 0
  ),
  constraint stations_rating_range check (
    rating_average between 0 and 5 and rating_count >= 0
  )
);

create index stations_owner_idx on public.stations(owner_id);
create index stations_discovery_idx
  on public.stations(publication_status, operational_status, verification_status, city);
create index stations_location_gist_idx on public.stations using gist(location);
create index stations_display_name_trgm_idx
  on public.stations using gin (display_name extensions.gin_trgm_ops);

create table public.station_staff (
  id uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  staff_role text not null,
  status public.staff_status not null default 'invited',
  invited_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint station_staff_role check (
    staff_role in ('manager', 'staff')
  ),
  unique (station_id, user_id)
);

create index station_staff_user_idx on public.station_staff(user_id, status);

create table public.station_staff_invites (
  id uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations(id) on delete cascade,
  email text not null,
  staff_role text not null,
  invited_by uuid not null references public.profiles(id) on delete restrict,
  invite_token_hash text not null unique,
  expires_at timestamptz not null,
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  constraint station_staff_invites_role check (staff_role in ('manager', 'staff')),
  constraint station_staff_invites_email check (
    length(trim(email)) > 3 and position('@' in email) > 1
  )
);

create index station_staff_invites_station_idx
  on public.station_staff_invites(station_id, expires_at desc);

create table public.station_documents (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null
    references public.station_applications(id) on delete cascade,
  document_type text not null,
  storage_path text not null unique,
  review_status public.document_review_status not null default 'pending',
  submitted_by uuid not null references public.profiles(id) on delete restrict,
  reviewed_by uuid references public.profiles(id) on delete set null,
  review_notes text,
  required_for_verification boolean not null default true,
  is_current boolean not null default true,
  expires_at date,
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  constraint station_documents_type_nonempty check (length(trim(document_type)) > 0)
);

create index station_documents_application_idx
  on public.station_documents(application_id, submitted_at desc);

create unique index station_documents_one_current_per_type
  on public.station_documents(application_id, document_type)
  where is_current;

create table public.station_document_requirements (
  application_id uuid not null
    references public.station_applications(id) on delete cascade,
  document_type text not null,
  required boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (application_id, document_type),
  constraint station_document_requirements_type_nonempty
    check (length(trim(document_type)) > 0)
);

create table public.station_document_type_catalog (
  document_type text primary key,
  description text not null,
  is_required_by_default boolean not null default true,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint station_document_type_catalog_type_nonempty
    check (length(trim(document_type)) > 0)
);

create table public.verification_reviews (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null
    references public.station_applications(id) on delete cascade,
  reviewer_id uuid not null references public.profiles(id) on delete restrict,
  decision public.document_review_status not null,
  notes text,
  created_at timestamptz not null default now()
);

create index verification_reviews_application_idx
  on public.verification_reviews(application_id, created_at desc);

create table public.station_operating_hours (
  id uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations(id) on delete cascade,
  weekday smallint not null,
  opens_at time,
  closes_at time,
  is_closed boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint station_operating_hours_weekday check (weekday between 0 and 6),
  constraint station_operating_hours_time_pair check (
    is_closed or (opens_at is not null and closes_at is not null)
  ),
  unique (station_id, weekday)
);

create table public.station_delivery_zones (
  id uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations(id) on delete cascade,
  zone_name text not null,
  barangay text,
  city text not null,
  province text not null,
  psgc_barangay_code text,
  psgc_city_code text,
  psgc_province_code text,
  timezone text not null default 'Asia/Manila',
  delivery_fee numeric(12, 2) not null default 0,
  minimum_order_amount numeric(12, 2) not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint station_delivery_zones_amounts check (
    delivery_fee >= 0 and minimum_order_amount >= 0
  ),
  constraint station_delivery_zones_psgc_codes check (
    (psgc_barangay_code is null or psgc_barangay_code ~ '^[0-9]{4,10}$')
    and (psgc_city_code is null or psgc_city_code ~ '^[0-9]{4,10}$')
    and (psgc_province_code is null or psgc_province_code ~ '^[0-9]{4,10}$')
  )
);

create index station_delivery_zones_location_idx
  on public.station_delivery_zones(city, province, is_active);
create index station_delivery_zones_station_idx
  on public.station_delivery_zones(station_id);
create index station_delivery_zones_psgc_idx
  on public.station_delivery_zones(
    psgc_city_code, psgc_province_code, psgc_barangay_code, is_active
  );

create table public.station_status_history (
  id uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations(id) on delete cascade,
  changed_by uuid references public.profiles(id) on delete set null,
  verification_status public.verification_status,
  publication_status public.publication_status,
  operational_status public.station_operational_status,
  reason text,
  created_at timestamptz not null default now(),
  constraint station_status_history_change_required check (
    verification_status is not null
    or publication_status is not null
    or operational_status is not null
  )
);

-- ============================================================================
-- Station catalog, delivery coverage, and inventory tables
-- ============================================================================
create table public.water_types (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.container_types (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  volume_liters numeric(8, 2),
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint container_types_volume_positive check (
    volume_liters is null or volume_liters > 0
  )
);

create table public.station_products (
  id uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations(id) on delete cascade,
  water_type_id uuid not null references public.water_types(id) on delete restrict,
  container_type_id uuid not null references public.container_types(id) on delete restrict,
  name text not null,
  description text,
  refill_available boolean not null default true,
  refill_price numeric(12, 2) not null,
  new_container_available boolean not null default false,
  new_container_price numeric(12, 2),
  deposit_amount numeric(12, 2),
  requires_empty_container boolean,
  return_policy text,
  stock_quantity integer,
  max_order_quantity smallint not null default 10,
  status public.product_status not null default 'draft',
  image_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint station_products_refill_price check (refill_price >= 0),
  constraint station_products_container_price check (
    (new_container_available and new_container_price is not null and new_container_price >= 0)
    or (not new_container_available and new_container_price is null)
  ),
  constraint station_products_deposit check (
    deposit_amount is null or deposit_amount >= 0
  ),
  constraint station_products_stock check (stock_quantity is null or stock_quantity >= 0),
  constraint station_products_max_order_quantity check (
    max_order_quantity between 1 and 50
  ),
  constraint station_products_option_available check (
    refill_available or new_container_available
  ),
  unique (station_id, water_type_id, container_type_id, name)
);

create index station_products_station_status_idx
  on public.station_products(station_id, status);

create table public.station_product_images (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.station_products(id) on delete cascade,
  storage_path text not null unique,
  alt_text text,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  constraint station_product_images_sort_order check (sort_order >= 0)
);
create index station_product_images_product_idx
  on public.station_product_images(product_id);

create table public.container_policies (
  id uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations(id) on delete cascade,
  container_type_id uuid not null references public.container_types(id) on delete restrict,
  requires_empty_return boolean not null default false,
  deposit_amount numeric(12, 2) not null default 0,
  return_policy text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint container_policies_deposit check (deposit_amount >= 0),
  unique (station_id, container_type_id)
);

create table public.station_inventory_movements (
  id uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations(id) on delete cascade,
  product_id uuid references public.station_products(id) on delete set null,
  movement_type text not null,
  quantity_change integer not null,
  reference text,
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint station_inventory_movements_type check (
    movement_type in ('stock_in', 'sale', 'adjustment', 'return', 'damage')
  ),
  constraint station_inventory_movements_nonzero check (quantity_change <> 0)
);

create index station_inventory_movements_station_idx
  on public.station_inventory_movements(station_id, created_at desc);

create table public.saved_stations (
  user_id uuid not null references public.profiles(id) on delete cascade,
  station_id uuid not null references public.stations(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, station_id)
);

-- ============================================================================
-- Customer cart, order, delivery, and review tables
-- ============================================================================
create table public.carts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  station_id uuid references public.stations(id) on delete set null,
  status text not null default 'active',
  idempotency_key text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint carts_status check (status in ('active', 'converted', 'abandoned')),
  constraint carts_idempotency_nonempty check (
    idempotency_key is null or length(trim(idempotency_key)) > 0
  )
);

create unique index carts_one_active_per_customer
  on public.carts(user_id)
  where status = 'active';
create unique index carts_user_idempotency_idx
  on public.carts(user_id, idempotency_key)
  where idempotency_key is not null;

create table public.cart_items (
  id uuid primary key default gen_random_uuid(),
  cart_id uuid not null references public.carts(id) on delete cascade,
  product_id uuid not null references public.station_products(id) on delete restrict,
  container_option public.container_option not null,
  quantity integer not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint cart_items_quantity_positive check (quantity > 0),
  unique (cart_id, product_id, container_option)
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number bigint generated always as identity unique,
  customer_id uuid not null references public.profiles(id) on delete restrict,
  station_id uuid not null references public.stations(id) on delete restrict,
  address_id uuid references public.addresses(id) on delete set null,
  address_snapshot jsonb not null,
  station_snapshot jsonb not null default '{}'::jsonb,
  status public.order_status not null default 'pending',
  payment_method public.payment_method not null default 'cod',
  subtotal numeric(12, 2) not null,
  container_total numeric(12, 2) not null default 0,
  deposit_total numeric(12, 2) not null default 0,
  delivery_fee numeric(12, 2) not null default 0,
  discount_total numeric(12, 2) not null default 0,
  total numeric(12, 2) not null,
  currency char(3) not null default 'PHP',
  customer_notes text,
  cancel_reason text,
  cancelled_by uuid references public.profiles(id) on delete set null,
  estimated_delivery_at timestamptz,
  checkout_expires_at timestamptz,
  inventory_released_at timestamptz,
  acceptance_expires_at timestamptz,
  delivery_zone_id uuid references public.station_delivery_zones(id) on delete set null,
  delivery_zone_snapshot jsonb,
  idempotency_key text not null,
  request_fingerprint text,
  cart_id uuid references public.carts(id) on delete set null,
  accepted_at timestamptz,
  delivered_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint orders_amounts_nonnegative check (
    subtotal >= 0
    and container_total >= 0
    and deposit_total >= 0
    and delivery_fee >= 0
    and discount_total >= 0
    and total >= 0
  ),
  constraint orders_total_matches_components check (
    total = subtotal + container_total + deposit_total + delivery_fee - discount_total
  ),
  constraint orders_currency_php check (currency = 'PHP'),
  constraint orders_idempotency_nonempty check (length(trim(idempotency_key)) > 0),
  unique (customer_id, idempotency_key)
);

  create table public.station_order_dismissals (
    user_id uuid not null references public.profiles(id) on delete cascade,
    order_id uuid not null references public.orders(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (user_id, order_id)
  );

create table public.customer_order_dismissals (
  user_id uuid not null references public.profiles(id) on delete cascade,
  order_id uuid not null references public.orders(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, order_id)
);

  create unique index orders_cart_id_unique
  on public.orders(cart_id)
  where cart_id is not null;

create index orders_customer_created_idx
  on public.orders(customer_id, created_at desc);
create index orders_station_status_idx
  on public.orders(station_id, status, created_at desc);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.station_products(id) on delete set null,
  product_name_snapshot text not null,
  water_type_snapshot text not null,
  container_type_snapshot text not null,
  container_option public.container_option not null,
  quantity integer not null,
  unit_refill_price numeric(12, 2) not null,
  unit_container_price numeric(12, 2) not null default 0,
  unit_deposit numeric(12, 2) not null default 0,
  requires_empty_container_snapshot boolean not null default false,
  return_policy_snapshot text,
  line_total numeric(12, 2) not null,
  created_at timestamptz not null default now(),
  constraint order_items_quantity_positive check (quantity > 0),
  constraint order_items_prices_nonnegative check (
    unit_refill_price >= 0
    and unit_container_price >= 0
    and unit_deposit >= 0
    and line_total >= 0
  )
);

create index order_items_order_idx on public.order_items(order_id);
create index order_items_product_idx on public.order_items(product_id);

create table public.order_status_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  old_status public.order_status,
  new_status public.order_status not null,
  changed_by uuid references public.profiles(id) on delete set null,
  note text,
  created_at timestamptz not null default now()
);

create index order_status_history_order_idx
  on public.order_status_history(order_id, created_at);

create table public.deliveries (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders(id) on delete cascade,
  station_id uuid not null references public.stations(id) on delete restrict,
  rider_id uuid references public.profiles(id) on delete set null,
  status public.delivery_status not null default 'pending',
  rider_name text,
  rider_phone text,
  assigned_at timestamptz,
  picked_up_at timestamptz,
  delivered_at timestamptz,
  proof_storage_path text,
  failure_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index deliveries_station_status_idx on public.deliveries(station_id, status);
create index deliveries_rider_status_idx on public.deliveries(rider_id, status)
  where rider_id is not null;

create table public.delivery_tracking (
  id uuid primary key default gen_random_uuid(),
  delivery_id uuid not null references public.deliveries(id) on delete cascade,
  rider_id uuid not null references public.profiles(id) on delete restrict,
  latitude double precision not null,
  longitude double precision not null,
  location extensions.geography(point, 4326) not null,
  accuracy_m numeric(8, 2),
  heading_degrees numeric(6, 2),
  speed_mps numeric(8, 2),
  recorded_at timestamptz not null default now(),
  constraint delivery_tracking_latitude check (latitude between -90 and 90),
  constraint delivery_tracking_longitude check (longitude between -180 and 180),
  constraint delivery_tracking_accuracy check (accuracy_m is null or accuracy_m >= 0),
  constraint delivery_tracking_heading check (
    heading_degrees is null or heading_degrees between 0 and 360
  ),
  constraint delivery_tracking_speed check (speed_mps is null or speed_mps >= 0)
);

create index delivery_tracking_delivery_recorded_idx
  on public.delivery_tracking(delivery_id, recorded_at desc);
create index delivery_tracking_location_gist_idx
  on public.delivery_tracking using gist(location);

create table public.station_reviews (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders(id) on delete restrict,
  station_id uuid not null references public.stations(id) on delete cascade,
  customer_id uuid not null references public.profiles(id) on delete restrict,
  rating smallint not null,
  review_text text,
  is_visible boolean not null default true,
  station_reply text,
  station_replied_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint station_reviews_rating check (rating between 1 and 5)
);

create index station_reviews_station_idx
  on public.station_reviews(station_id, created_at desc)
  where is_visible;

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  body text not null,
  notification_type text not null,
  data jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  dismissed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint notifications_data_object check (jsonb_typeof(data) = 'object')
);

-- ============================================================================
-- Payment and refund tables
-- ============================================================================

create index notifications_user_unread_idx
  on public.notifications(user_id, created_at desc)
  where read_at is null;

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete restrict,
  customer_id uuid not null references public.profiles(id) on delete restrict,
  method public.payment_method not null,
  status public.payment_status not null default 'pending',
  amount numeric(12, 2) not null,
  currency char(3) not null default 'PHP',
  provider text,
  provider_checkout_id text unique,
  provider_payment_id text unique,
  idempotency_key text not null unique,
  attempt_number integer not null default 1,
  paid_at timestamptz,
  failed_at timestamptz,
  failure_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint payments_amount_nonnegative check (amount >= 0),
  constraint payments_currency_php check (currency = 'PHP'),
  constraint payments_attempt_positive check (attempt_number > 0),
  constraint payments_method_provider check (
    (method = 'cod' and provider is null)
    or (method = 'paymongo' and provider = 'paymongo')
  )
);

create unique index payments_one_active_attempt_per_order
  on public.payments(order_id)
  where status in ('pending', 'processing');
create unique index payments_order_attempt_unique
  on public.payments(order_id, attempt_number);

create index payments_customer_created_idx
  on public.payments(customer_id, created_at desc);
create index payments_status_idx on public.payments(status, created_at desc);

create table public.payment_events (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid references public.payments(id) on delete set null,
  provider text not null,
  provider_event_id text not null,
  event_type text not null,
  payload jsonb not null,
  signature_valid boolean not null default false,
  refund_required boolean not null default false,
  processed_at timestamptz,
  processing_error text,
  received_at timestamptz not null default now(),
  constraint payment_events_payload_object check (jsonb_typeof(payload) = 'object'),
  constraint payment_events_provider_event_unique unique (provider, provider_event_id)
);

create index payment_events_payment_idx on public.payment_events(payment_id, received_at);

create table public.payment_refunds (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments(id) on delete restrict,
  requested_by uuid references public.profiles(id) on delete restrict,
  approved_by uuid references public.profiles(id) on delete set null,
  amount numeric(12, 2) not null,
  status public.refund_status not null default 'requested',
  is_automatic boolean not null default false,
  reason text not null,
  provider_refund_id text unique,
  idempotency_key text not null unique,
  processed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint payment_refunds_amount_positive check (amount > 0),
  constraint payment_refunds_requester check (is_automatic or requested_by is not null)
);
create index payment_refunds_payment_idx
  on public.payment_refunds(payment_id, created_at desc);

create table public.payment_provider_actions (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments(id) on delete restrict,
  refund_id uuid references public.payment_refunds(id) on delete restrict,
  action_type text not null,
  idempotency_key text not null unique,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending',
  attempts integer not null default 0,
  available_at timestamptz not null default now(),
  locked_at timestamptz,
  completed_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  constraint payment_provider_actions_type check (
    action_type in ('expire_checkout', 'refund')
  ),
  constraint payment_provider_actions_status check (
    status in ('pending', 'processing', 'completed', 'failed')
  ),
  constraint payment_provider_actions_attempts check (attempts >= 0),
  constraint payment_provider_actions_payload check (jsonb_typeof(payload) = 'object')
);

-- ============================================================================
-- Support tables
-- ============================================================================

create index payment_provider_actions_queue_idx
  on public.payment_provider_actions(status, available_at, created_at)
  where status in ('pending', 'failed');

create or replace function public.claim_payment_provider_actions(p_limit integer default 20)
returns table (
  action_id uuid,
  payment_id uuid,
  refund_id uuid,
  action_type text,
  idempotency_key text,
  payload jsonb,
  attempts integer
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Payment provider actions are restricted to trusted servers';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'Action claim limit must be between 1 and 100';
  end if;

  return query
  with candidates as (
    select a.id
    from public.payment_provider_actions a
    where (
      a.status in ('pending', 'failed') and a.available_at <= now()
    ) or (
      a.status = 'processing' and a.locked_at < now() - interval '5 minutes'
    )
    order by a.available_at, a.created_at
    for update skip locked
    limit p_limit
  )
  update public.payment_provider_actions a
  set status = 'processing',
      attempts = a.attempts + 1,
      locked_at = now(),
      last_error = null
  from candidates c
  where a.id = c.id
  returning a.id, a.payment_id, a.refund_id, a.action_type,
    a.idempotency_key, a.payload, a.attempts;
end;
$$;

create or replace function public.complete_payment_provider_action(
  p_action_id uuid,
  p_success boolean,
  p_error text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Payment provider actions are restricted to trusted servers';
  end if;
  if p_success is null then
    raise exception 'Action result is required';
  end if;

  update public.payment_provider_actions a
  set status = case when p_success then 'completed' else 'failed' end,
      completed_at = case when p_success then now() else null end,
      locked_at = null,
      last_error = case when p_success then null else left(coalesce(p_error, 'Provider action failed'), 2000) end,
      available_at = case
        when p_success then a.available_at
        else now() + make_interval(secs => least(3600, 30 * (2 ^ least(a.attempts, 7))::integer))
      end
  where a.id = p_action_id
    and a.status = 'processing';
  if not found then
    raise exception 'Processing provider action was not found';
  end if;
end;
$$;

comment on table public.payment_provider_actions is
  'Transactional outbox for trusted server workers to expire PayMongo checkouts and execute refunds.';

create table public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete restrict,
  station_id uuid references public.stations(id) on delete set null,
  order_id uuid references public.orders(id) on delete set null,
  subject text not null,
  category text not null,
  status public.support_status not null default 'open',
  assigned_to uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resolved_at timestamptz
);

create index support_tickets_requester_idx
  on public.support_tickets(requester_id, created_at desc);
create index support_tickets_queue_idx
  on public.support_tickets(status, created_at);
create index support_tickets_station_order_idx
  on public.support_tickets(station_id, order_id);

create table public.support_messages (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_tickets(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete restrict,
  message text not null,
  attachment_path text,
  created_at timestamptz not null default now(),
  constraint support_messages_nonempty check (length(trim(message)) > 0)
);

create index support_messages_ticket_idx
  on public.support_messages(ticket_id, created_at  );

  -- ============================================================================
  -- Admin audit tables
  -- ============================================================================
  create table public.admin_audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  before_data jsonb,
  after_data jsonb,
  ip_address inet,
  created_at timestamptz not null default now(),
  constraint admin_audit_logs_action_nonempty check (length(trim(action)) > 0)
);

create index admin_audit_logs_entity_idx
  on public.admin_audit_logs(entity_type, entity_id, created_at desc);
create index admin_audit_logs_actor_idx
  on public.admin_audit_logs(actor_id, created_at desc);

create or replace function public.has_role(
  target_user_id uuid,
  required_role public.app_role
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.user_roles ur
    where ur.user_id = target_user_id
      and ur.role = required_role
  );
$$;

create or replace function public.has_permission(required_permission text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(auth.uid() is not null
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.status = 'active'
    )
    and exists (
    select 1
    from public.user_roles ur
    join public.admin_permissions ap on ap.role = ur.role
    where ur.user_id = auth.uid()
      and ap.permission_key = required_permission
  ), false);
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.has_permission('admin.access');
$$;

create or replace function public.is_public_station(target_station_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.stations s
    where s.id = target_station_id
      and s.publication_status = 'published'
      and s.operational_status = 'active'
      and s.verification_status = 'verified'
  );
$$;

create or replace function public.get_public_station_phone(p_station_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
   select s.phone
   from public.stations s
   where s.id = p_station_id
     and public.is_public_station(s.id);
$$;

create or replace function public.get_public_station_social_links(p_station_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'facebook_url', s.facebook_url,
    'instagram_url', s.instagram_url
  )
  from public.stations s
  where s.id = p_station_id
    and public.is_public_station(s.id);
$$;

create or replace function public.is_station_open(
  target_station_id uuid,
  at_time timestamptz default now()
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  station_timezone text;
  local_time timestamp;
  local_weekday smallint;
  local_clock time;
begin
  select s.timezone into station_timezone
  from public.stations s
  where s.id = target_station_id;
  if not found then
    return false;
  end if;

  local_time := at_time at time zone station_timezone;
  local_weekday := extract(dow from local_time)::smallint;
  local_clock := local_time::time;

  return exists (
    select 1
    from public.station_operating_hours h
    where h.station_id = target_station_id
      and not h.is_closed
      and (
        (
          h.weekday = local_weekday
          and (
            (h.opens_at < h.closes_at and local_clock >= h.opens_at and local_clock < h.closes_at)
            or (h.opens_at > h.closes_at and local_clock >= h.opens_at)
          )
        )
        or (
          h.weekday = (local_weekday + 6) % 7
          and h.opens_at > h.closes_at
          and local_clock < h.closes_at
        )
      )
  );
end;
$$;

create or replace function public.is_station_member(target_station_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(auth.uid() is not null
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.status = 'active'
    )
    and exists (
    select 1
    from public.stations s
    where s.id = target_station_id
      and (
        s.owner_id = auth.uid()
        or exists (
          select 1
          from public.station_staff ss
          where ss.station_id = s.id
            and ss.user_id = auth.uid()
            and ss.status = 'active'
        )
      )
  ), false);
$$;

create or replace function public.is_station_manager(target_station_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(auth.uid() is not null
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.status = 'active'
    )
    and exists (
    select 1
    from public.stations s
    where s.id = target_station_id
      and (
        s.owner_id = auth.uid()
        or exists (
          select 1
          from public.station_staff ss
          where ss.station_id = s.id
            and ss.user_id = auth.uid()
            and ss.status = 'active'
            and ss.staff_role = 'manager'
        )
      )
  ), false);
$$;

create or replace function public.is_station_owner(target_station_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(auth.uid() is not null
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.status = 'active'
    )
    and exists (
    select 1
    from public.stations s
    where s.id = target_station_id
      and s.owner_id = auth.uid()
  ), false);
$$;

create or replace function public.is_order_party(target_order_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(auth.uid() is not null and (
    exists (
      select 1 from public.orders o
      where o.id = target_order_id and o.customer_id = auth.uid()
    )
    or exists (
      select 1 from public.orders o
      where o.id = target_order_id
        and public.is_station_member(o.station_id)
        and (
          o.payment_method <> 'paymongo'
          or exists (
            select 1 from public.payments p
            where p.order_id = o.id and p.status = 'paid'
          )
        )
    )
    or exists (
      select 1
      from public.deliveries d
      where d.order_id = target_order_id
        and d.rider_id = auth.uid()
        and public.has_permission('delivery.track')
    )
  ), false);
$$;

create or replace function public.protect_station_admin_fields()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') = 'service_role'
    or public.has_permission('admin.access')
  then
    return new;
  end if;

  if new.owner_id is distinct from old.owner_id
    or new.application_id is distinct from old.application_id
    or new.latitude is distinct from old.latitude
    or new.longitude is distinct from old.longitude
  then
    if current_setting('app.station_setup', true) is distinct from 'on'
      or old.operational_status <> 'onboarding'
      or old.verification_status = 'verified'
    then
      raise exception 'Only an administrator can change station ownership or location';
    end if;
  end if;

  if old.verification_status = 'verified'
    and (
      new.display_name is distinct from old.display_name
      or new.email is distinct from old.email
      or new.phone is distinct from old.phone
      or new.address_line is distinct from old.address_line
      or new.barangay is distinct from old.barangay
      or new.city is distinct from old.city
      or new.province is distinct from old.province
      or new.region is distinct from old.region
      or new.postal_code is distinct from old.postal_code
    )
  then
    raise exception 'Station identity and contact details require administrator re-review after verification';
  end if;

  if (
    new.display_name is distinct from old.display_name
    or new.email is distinct from old.email
    or new.phone is distinct from old.phone
    or new.address_line is distinct from old.address_line
    or new.barangay is distinct from old.barangay
    or new.city is distinct from old.city
    or new.province is distinct from old.province
    or new.region is distinct from old.region
    or new.postal_code is distinct from old.postal_code
    or new.latitude is distinct from old.latitude
    or new.longitude is distinct from old.longitude
  ) and exists (
    select 1
    from public.station_applications a
    where a.id = old.application_id
      and a.application_status in ('submitted', 'in_review')
  ) then
    raise exception 'Station identity is locked while its application is under review';
  end if;

  if new.verification_status is distinct from old.verification_status
    and current_setting('app.station_review', true) is distinct from 'on'
  then
    raise exception 'Station verification changes require the review function';
  end if;

  if new.publication_status is distinct from old.publication_status
    and current_setting('app.station_publish', true) is distinct from 'on'
  then
    raise exception 'Station publication changes require the publication function';
  end if;

  if new.operational_status is distinct from old.operational_status
    and current_setting('app.station_suspend', true) is distinct from 'on'
  then
    raise exception 'Station operational changes require the administration function';
  end if;

  if (new.rating_average is distinct from old.rating_average
    or new.rating_count is distinct from old.rating_count)
    and current_setting('app.station_rating_update', true) is distinct from 'on'
  then
    raise exception 'Station ratings are maintained by customer reviews';
  end if;

  return new;
end;
$$;

create or replace function public.protect_application_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') = 'service_role'
    or public.has_permission('admin.access')
    or public.has_permission('station.review')
  then
    return new;
  end if;

  if new.owner_id is distinct from old.owner_id
    or new.admin_notes is distinct from old.admin_notes
    or new.reviewed_by is distinct from old.reviewed_by
    or new.reviewed_at is distinct from old.reviewed_at
  then
    raise exception 'Application review fields can only be changed by application functions';
  end if;

  if new.application_status is distinct from old.application_status
    and current_setting('app.submit_application', true) is distinct from 'on'
    and not public.has_permission('station.review')
  then
    raise exception 'Application status changes require an authorized function';
  end if;

  if new.verification_status is distinct from old.verification_status
    and current_setting('app.submit_application', true) is distinct from 'on'
    and not public.has_permission('station.review')
  then
    raise exception 'Application verification changes require an authorized function';
  end if;

  return new;
end;
$$;

create or replace function public.sync_station_application_details()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.application_status not in ('draft', 'changes_requested')
    or new.application_status is distinct from old.application_status
  then
    return new;
  end if;

  perform set_config('app.station_setup', 'on', true);
  update public.stations
  set display_name = new.display_name,
      email = new.email,
      phone = new.phone,
      address_line = new.address_line,
      barangay = new.barangay,
      city = new.city,
      province = new.province,
      region = new.region,
      postal_code = new.postal_code,
      latitude = coalesce(new.latitude, latitude),
      longitude = coalesce(new.longitude, longitude)
  where application_id = new.id
    and owner_id = new.owner_id
    and operational_status = 'onboarding';
  perform set_config('app.station_setup', 'off', true);
  return new;
end;
$$;

create or replace function public.protect_station_document_review()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if coalesce(auth.role(), '') <> 'service_role'
      and (
        new.submitted_by is distinct from auth.uid()
        or new.review_status <> 'pending'
        or new.reviewed_by is not null
        or new.review_notes is not null
        or new.reviewed_at is not null
      )
    then
      raise exception 'Applicants may only upload unreviewed station documents';
    end if;
    perform set_config('app.document_supersede', 'on', true);
    update public.station_documents
    set is_current = false
    where application_id = new.application_id
      and document_type = new.document_type
      and is_current;
    perform set_config('app.document_supersede', 'off', true);
    return new;
  end if;

  if current_setting('app.document_supersede', true) = 'on' then
    if new.is_current
      or new.id is distinct from old.id
      or new.application_id is distinct from old.application_id
      or new.document_type is distinct from old.document_type
    then
      raise exception 'Only superseding a prior document is permitted';
    end if;
    return new;
  end if;

  if coalesce(auth.role(), '') <> 'service_role'
    and current_setting('app.document_review', true) is distinct from 'on'
  then
    raise exception 'Station document reviews require the review function';
  end if;

  if new.id is distinct from old.id
    or new.application_id is distinct from old.application_id
    or new.document_type is distinct from old.document_type
    or new.storage_path is distinct from old.storage_path
    or new.submitted_by is distinct from old.submitted_by
    or new.required_for_verification is distinct from old.required_for_verification
    or new.expires_at is distinct from old.expires_at
    or new.submitted_at is distinct from old.submitted_at
  then
    raise exception 'Station document details cannot be changed during review';
  end if;
  return new;
end;
$$;

create or replace function public.enforce_application_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.application_status = old.application_status then
    return new;
  end if;

  if old.application_status = 'draft'
    and new.application_status = 'submitted'
    and current_setting('app.submit_application', true) = 'on'
  then
    return new;
  elsif old.application_status = 'submitted'
    and new.application_status in ('in_review', 'changes_requested', 'approved', 'rejected')
    and public.has_permission('station.review')
  then
    return new;
  elsif old.application_status = 'in_review'
    and new.application_status in ('changes_requested', 'approved', 'rejected')
    and public.has_permission('station.review')
  then
    return new;
  elsif old.application_status = 'changes_requested'
    and new.application_status = 'submitted'
    and current_setting('app.submit_application', true) = 'on'
  then
    return new;
  end if;

  raise exception 'Invalid station application status transition: % -> %',
    old.application_status, new.application_status;
end;
$$;

create or replace function public.log_application_status_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.station_application_status_history (
    application_id, old_status, new_status, changed_by, note
  )
  values (
    new.id,
    old.application_status,
    new.application_status,
    auth.uid(),
    new.admin_notes
  );
  return new;
end;
$$;

create or replace function public.enforce_order_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  transition_allowed boolean := false;
begin
  if new.status = old.status then
    return new;
  end if;

  transition_allowed := case old.status
    when 'pending' then new.status in ('confirmed', 'cancelled', 'failed')
    when 'confirmed' then new.status in ('preparing', 'cancelled', 'failed')
    when 'preparing' then new.status in ('ready', 'cancelled', 'failed')
    when 'ready' then new.status in ('rider_assigned', 'delivered', 'cancelled', 'failed')
    when 'rider_assigned' then new.status in ('out_for_delivery', 'cancelled', 'failed')
    when 'out_for_delivery' then new.status in ('delivered', 'failed')
    else false
  end;

  if not transition_allowed then
    raise exception 'Invalid order status transition: % -> %', old.status, new.status;
  end if;

  if current_setting('app.order_transition', true) is distinct from 'on'
    and coalesce(auth.role(), '') <> 'service_role'
  then
    raise exception 'Order status changes require an authorized function';
  end if;

  insert into public.order_status_history (
    order_id, old_status, new_status, changed_by, note
  )
  values (
    new.id,
    old.status,
    new.status,
    auth.uid(),
    coalesce(
      nullif(current_setting('app.order_transition_note', true), ''),
      new.cancel_reason
    )
  );

  return new;
end;
$$;

create or replace function public.log_initial_order_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.order_status_history (
    order_id, old_status, new_status, changed_by, note
  )
  values (new.id, null, new.status, new.customer_id, 'Order created');
  return new;
end;
$$;

create or replace function public.enforce_payment_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  transition_allowed boolean := false;
begin
  if new.status = old.status then
    return new;
  end if;

  transition_allowed := case old.status
    when 'pending' then new.status in ('processing', 'paid', 'failed', 'cancelled')
    when 'processing' then new.status in ('paid', 'failed', 'cancelled')
    when 'paid' then new.status in ('partially_refunded', 'refunded')
    when 'partially_refunded' then new.status = 'refunded'
    when 'cancelled' then
      new.status = 'refunded'
      and current_setting('app.late_payment_refund', true) = 'on'
    else false
  end;

  if not transition_allowed then
    raise exception 'Invalid payment status transition: % -> %', old.status, new.status;
  end if;

  if current_setting('app.payment_transition', true) is distinct from 'on'
    and coalesce(auth.role(), '') <> 'service_role'
  then
    raise exception 'Payment status changes require an authorized function';
  end if;

  return new;
end;
$$;

create or replace function public.enforce_review_owner_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if current_setting('app.station_review_reply', true) = 'on'
      and public.is_station_manager(new.station_id)
      and new.station_id is not distinct from old.station_id
      and new.order_id is not distinct from old.order_id
      and new.customer_id is not distinct from old.customer_id
      and new.rating is not distinct from old.rating
      and new.review_text is not distinct from old.review_text
      and new.is_visible is not distinct from old.is_visible
    then
      return new;
    end if;

    if coalesce(auth.role(), '') <> 'service_role'
      and not public.has_permission('reviews.moderate')
      and (
        new.station_id is distinct from old.station_id
        or new.order_id is distinct from old.order_id
        or new.customer_id is distinct from old.customer_id
        or new.is_visible is distinct from old.is_visible
        or new.station_reply is distinct from old.station_reply
        or new.station_replied_at is distinct from old.station_replied_at
      )
    then
      raise exception 'Customers may only edit review rating and text';
    end if;
  elsif tg_op = 'INSERT' then
    if coalesce(auth.role(), '') <> 'service_role'
      and not public.has_permission('reviews.moderate')
      and (
        new.station_reply is not null
        or new.station_replied_at is not null
      )
    then
      raise exception 'Customers cannot set a station reply';
    end if;
  end if;

  if new.is_visible then
    if not exists (
      select 1
      from public.orders o
      where o.id = new.order_id
        and o.customer_id = new.customer_id
        and o.station_id = new.station_id
        and o.status = 'delivered'
    ) then
      raise exception 'A review must match the customer station and a delivered order';
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.refresh_station_rating(target_station_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  average_rating numeric(3, 2);
  visible_count integer;
begin
  select coalesce(round(avg(r.rating)::numeric, 2), 0), count(*)::integer
    into average_rating, visible_count
  from public.station_reviews r
  where r.station_id = target_station_id and r.is_visible;

  perform set_config('app.station_rating_update', 'on', true);
  update public.stations
  set rating_average = average_rating, rating_count = visible_count
  where id = target_station_id;
  perform set_config('app.station_rating_update', 'off', true);
end;
$$;

create or replace function public.update_station_rating_from_review()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    perform public.refresh_station_rating(old.station_id);
    return old;
  end if;

  if tg_op = 'UPDATE' and old.station_id is distinct from new.station_id then
    perform public.refresh_station_rating(old.station_id);
  end if;

  perform public.refresh_station_rating(new.station_id);
  return new;
end;
$$;

create or replace function public.protect_notification_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.user_id is distinct from old.user_id
    or new.title is distinct from old.title
    or new.body is distinct from old.body
    or new.notification_type is distinct from old.notification_type
    or new.data is distinct from old.data
    or new.created_at is distinct from old.created_at
    or (
      new.dismissed_at is distinct from old.dismissed_at
      and new.dismissed_at is null
    )
  then
    raise exception 'Users may only mark notifications as read or dismissed';
  end if;
  return new;
end;
$$;

create or replace function public.prevent_direct_stock_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.stock_quantity is distinct from old.stock_quantity
    and coalesce(auth.role(), '') <> 'service_role'
    and current_setting('app.inventory_update', true) is distinct from 'on'
  then
    raise exception 'Stock changes must use the inventory adjustment ledger';
  end if;
  return new;
end;
$$;

create or replace function public.record_initial_product_stock()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.stock_quantity is not null and new.stock_quantity > 0 then
    insert into public.station_inventory_movements (
      station_id, product_id, movement_type, quantity_change, notes, created_by
    )
    values (
      new.station_id, new.id, 'stock_in', new.stock_quantity,
      'Initial product stock', auth.uid()
    );
  end if;
  return new;
end;
$$;

create or replace function public.notify_order_activity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  notification_title text;
  notification_body text;
begin
  if tg_op = 'INSERT' then
    insert into public.notifications (
      user_id, title, body, notification_type, data
    )
    select recipients.user_id,
      'New customer order',
      'A customer placed a new order. Review it in your station orders.',
      'order_status',
      jsonb_build_object('order_id', new.id, 'status', new.status)
    from (
      select s.owner_id as user_id
      from public.stations s
      where s.id = new.station_id
      union
      select ss.user_id
      from public.station_staff ss
      where ss.station_id = new.station_id
        and ss.status = 'active'
    ) recipients
    where recipients.user_id is not null;
    return new;
  end if;

  if new.status is not distinct from old.status then
    return new;
  end if;

  notification_title := case new.status
    when 'confirmed' then 'Order confirmed'
    when 'preparing' then 'Order is being prepared'
    when 'ready' then 'Order is ready'
    when 'rider_assigned' then 'Rider assigned'
    when 'out_for_delivery' then 'Order is on the way'
    when 'delivered' then 'Order delivered'
    when 'cancelled' then 'Order cancelled'
    when 'failed' then 'Order could not be completed'
    else 'Order status updated'
  end;
  notification_body := case new.status
    when 'confirmed' then 'The station confirmed your order.'
    when 'preparing' then 'The station is preparing your order.'
    when 'ready' then 'Your order is ready for delivery.'
    when 'rider_assigned' then 'A rider has been assigned to your order.'
    when 'out_for_delivery' then 'Your order is on the way.'
    when 'delivered' then 'Your order has been delivered.'
    when 'cancelled' then 'Your order was cancelled.'
    when 'failed' then 'Your order could not be completed.'
    else 'Your order status has changed.'
  end;

  insert into public.notifications (
    user_id, title, body, notification_type, data
  )
  values (
    new.customer_id, notification_title, notification_body, 'order_status',
    jsonb_build_object('order_id', new.id, 'status', new.status)
  );
  return new;
end;
$$;

create or replace function public.audit_sensitive_table_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_row jsonb;
  new_row jsonb;
  row_data jsonb;
  entity_uuid uuid;
begin
  if tg_op <> 'INSERT' then
    old_row := to_jsonb(old);
  end if;
  if tg_op <> 'DELETE' then
    new_row := to_jsonb(new);
  end if;
  row_data := coalesce(new_row, old_row);
  entity_uuid := nullif(
    coalesce(row_data ->> 'id', row_data ->> 'user_id', row_data ->> 'station_id'),
    ''
  )::uuid;

  insert into public.admin_audit_logs (
    actor_id, action, entity_type, entity_id, before_data, after_data
  )
  values (
    auth.uid(),
    lower(tg_table_name) || '_' || lower(tg_op),
    tg_table_name,
    entity_uuid,
    old_row,
    new_row
  );
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create or replace function public.prevent_audit_log_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'Audit logs are append-only';
end;
$$;

create or replace function public.register_device(
  p_platform text,
  p_push_token text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  device_id uuid;
begin
  if auth.uid() is null
    or not exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.status = 'active'
    )
  then
    raise exception 'An active authenticated account is required';
  end if;
  if p_platform not in ('ios', 'android', 'web', 'other')
    or nullif(trim(p_push_token), '') is null
  then
    raise exception 'Valid device platform and push token are required';
  end if;

  insert into public.user_devices (user_id, platform, push_token, last_seen_at)
  values (auth.uid(), p_platform, trim(p_push_token), now())
  on conflict (push_token) do update
    set user_id = excluded.user_id,
        platform = excluded.platform,
        last_seen_at = now()
  returning id into device_id;
  return device_id;
end;
$$;

create or replace function public.disable_station_staff(
  p_station_id uuid,
  p_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_station_manager(p_station_id) then
    raise exception 'Station manager permission is required';
  end if;
  if p_user_id is null or p_user_id = auth.uid() then
    raise exception 'Select another staff member';
  end if;
  update public.station_staff
  set status = 'disabled'
  where station_id = p_station_id
    and user_id = p_user_id
    and status = 'active';
  if not found then
    raise exception 'Active station staff member was not found';
  end if;
end;
$$;

create or replace function public.reply_to_station_review(
  p_review_id uuid,
  p_reply text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  station_id_value uuid;
begin
  if nullif(trim(p_reply), '') is null then
    raise exception 'A non-empty station reply is required';
  end if;
  select r.station_id into station_id_value
  from public.station_reviews r
  where r.id = p_review_id
  for update;
  if not found or not public.is_station_manager(station_id_value) then
    raise exception 'Review was not found for this station';
  end if;
  perform set_config('app.station_review_reply', 'on', true);
  update public.station_reviews
  set station_reply = trim(p_reply),
      station_replied_at = now()
  where id = p_review_id;
  perform set_config('app.station_review_reply', 'off', true);
end;
$$;

create or replace function public.record_station_status_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.verification_status is distinct from old.verification_status
    or new.publication_status is distinct from old.publication_status
    or new.operational_status is distinct from old.operational_status
  then
    insert into public.station_status_history (
      station_id, changed_by, verification_status, publication_status,
      operational_status, reason
    )
    values (
      new.id, auth.uid(), new.verification_status, new.publication_status,
      new.operational_status, null
    );
  end if;
  return new;
end;
$$;

create or replace function public.start_station_application(
  p_legal_business_name text,
  p_display_name text,
  p_phone text,
  p_address_line text,
  p_city text,
  p_province text,
  p_latitude double precision,
  p_longitude double precision,
  p_email text default null,
  p_barangay text default null,
  p_region text default null,
  p_postal_code text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  new_application_id uuid;
  possible_duplicate record;
begin
  if actor_id is null then
    raise exception 'Authentication is required';
  end if;
  if not exists (
    select 1 from public.profiles p
    where p.id = actor_id and p.status = 'active'
  ) then
    raise exception 'An active customer account is required';
  end if;
  if coalesce(auth.role(), '') <> 'service_role'
    and not public.has_role(actor_id, 'customer'::public.app_role)
    and not public.has_role(actor_id, 'station_owner'::public.app_role)
  then
    raise exception 'This account cannot start a station application';
  end if;
  if nullif(trim(p_legal_business_name), '') is null
    or nullif(trim(p_display_name), '') is null
    or nullif(trim(p_phone), '') is null
    or nullif(trim(p_address_line), '') is null
    or nullif(trim(p_city), '') is null
    or nullif(trim(p_province), '') is null
  then
    raise exception 'Complete all required station application fields';
  end if;
  if p_latitude is null or p_latitude not between -90 and 90
    or p_longitude is null or p_longitude not between -180 and 180
  then
    raise exception 'A valid station map location is required';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(871204662915::bigint);
  if exists (
    select 1
    from public.station_applications a
    where a.owner_id = actor_id
      and a.application_status in ('draft', 'submitted', 'in_review', 'changes_requested')
  ) then
    raise exception 'This account already has an application in progress';
  end if;

  select candidate.id, candidate.display_name, candidate.application_status
  into possible_duplicate
  from (
    select
      a.id,
      a.display_name,
      a.application_status,
      a.location,
      a.owner_id
    from public.station_applications a
    where a.application_status <> 'rejected'
    union all
    select
      s.application_id as id,
      s.display_name,
      a.application_status,
      s.location,
      s.owner_id
    from public.stations s
    join public.station_applications a on a.id = s.application_id
    where s.operational_status <> 'archived'
      and a.application_status <> 'rejected'
  ) candidate
  where candidate.owner_id <> actor_id
    and (
      -- Similar name AND nearby (same neighbourhood), or near-identical
      -- coordinates with at least a loosely similar name.
      (
        extensions.similarity(lower(candidate.display_name), lower(trim(p_display_name))) >= 0.60
        and extensions.st_dwithin(
          candidate.location,
          extensions.st_setsrid(
            extensions.st_makepoint(p_longitude, p_latitude), 4326
          )::extensions.geography,
          2000
        )
      )
      or (
        extensions.similarity(lower(candidate.display_name), lower(trim(p_display_name))) >= 0.30
        and extensions.st_dwithin(
          candidate.location,
          extensions.st_setsrid(
            extensions.st_makepoint(p_longitude, p_latitude), 4326
          )::extensions.geography,
          15
        )
      )
    )
  limit 1;
  if found then
    raise exception 'A similar station application already exists (application %; name: %; status: %)',
      possible_duplicate.id, possible_duplicate.display_name,
      possible_duplicate.application_status;
  end if;

  insert into public.station_applications (
    owner_id, legal_business_name, display_name, phone, email,
    address_line, barangay, city, province, region, postal_code,
    latitude, longitude
  )
  values (
    actor_id, trim(p_legal_business_name), trim(p_display_name), trim(p_phone),
    nullif(trim(p_email), ''), trim(p_address_line), nullif(trim(p_barangay), ''),
    trim(p_city), trim(p_province), nullif(trim(p_region), ''),
    nullif(trim(p_postal_code), ''), p_latitude, p_longitude
  )
  returning id into new_application_id;

  insert into public.station_document_requirements (application_id, document_type)
  select new_application_id, c.document_type
  from public.station_document_type_catalog c
  where c.is_active and c.is_required_by_default;

  insert into public.stations (
    application_id, owner_id, display_name, email, phone, address_line,
    barangay, city, province, region, postal_code, latitude, longitude,
    verification_status, publication_status, operational_status
  )
  values (
    new_application_id, actor_id, trim(p_display_name),
    nullif(trim(p_email), ''), trim(p_phone), trim(p_address_line),
    nullif(trim(p_barangay), ''), trim(p_city), trim(p_province),
    nullif(trim(p_region), ''), nullif(trim(p_postal_code), ''),
    p_latitude, p_longitude, 'not_submitted', 'unpublished', 'onboarding'
  );

  insert into public.user_roles (user_id, role)
  values (actor_id, 'station_owner'::public.app_role)
  on conflict (user_id, role) do nothing;

  return new_application_id;
end;
$$;

create or replace function public.submit_application(p_application_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_row public.station_applications%rowtype;
  station_row public.stations%rowtype;
  required_documents integer;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required';
  end if;

  select * into application_row
  from public.station_applications
  where id = p_application_id and owner_id = auth.uid()
  for update;

  if not found then
    raise exception 'Station application was not found';
  end if;
  if application_row.application_status not in ('draft', 'changes_requested') then
    raise exception 'Only draft or returned applications can be submitted';
  end if;
  if nullif(btrim(application_row.legal_business_name), '') is null
    or nullif(btrim(application_row.display_name), '') is null
    or nullif(btrim(application_row.phone), '') is null
    or nullif(btrim(application_row.address_line), '') is null
    or nullif(btrim(application_row.city), '') is null
    or nullif(btrim(application_row.province), '') is null
  then
    raise exception 'Complete all required station profile fields before submitting';
  end if;
  if application_row.latitude is null or application_row.longitude is null then
    raise exception 'A valid station map location is required before submitting';
  end if;

  select * into station_row
  from public.stations
  where application_id = p_application_id;
  if not found then
    raise exception 'Complete station setup before submitting';
  end if;
  if station_row.service_radius_km is null or station_row.service_radius_km <= 0 then
    raise exception 'Set a delivery radius greater than zero before submitting';
  end if;
  if station_row.default_delivery_fee is null or station_row.default_delivery_fee < 0
    or station_row.minimum_order_amount is null or station_row.minimum_order_amount < 0
  then
    raise exception 'Set valid delivery fees and minimum order before submitting';
  end if;
  if not exists (
    select 1 from public.station_products p
    where p.station_id = station_row.id and p.status = 'active'
  ) then
    raise exception 'Add at least one active water product before submitting';
  end if;
  if exists (
    select 1
    from public.station_products p
    where p.station_id = station_row.id
      and p.status = 'active'
      and not exists (
        select 1 from public.container_policies cp
        where cp.station_id = p.station_id
          and cp.container_type_id = p.container_type_id
          and cp.is_active
      )
  ) then
    raise exception 'Save an active container policy for every active product before submitting';
  end if;
  if not exists (
    select 1
    from public.station_operating_hours h
    where h.station_id = station_row.id
      and not h.is_closed
      and h.opens_at is not null
      and h.closes_at is not null
      and h.opens_at <> h.closes_at
  ) then
    raise exception 'Set at least one valid open day before submitting';
  end if;

  select count(*) into required_documents
  from public.station_document_requirements r
  where r.application_id = p_application_id and r.required;

  if required_documents = 0 or exists (
    select 1
    from public.station_document_requirements r
    where r.application_id = p_application_id
      and r.required
      and not exists (
        select 1 from public.station_documents d
        where d.application_id = r.application_id
          and d.document_type = r.document_type
          and d.is_current
          and d.required_for_verification
      )
  ) then
    raise exception 'Upload every required document type before submitting';
  end if;

  if exists (
    select 1
    from public.station_documents d
    where d.application_id = p_application_id
      and d.is_current
      and d.required_for_verification
      and (
        d.review_status = 'rejected'
        or
        not exists (
          select 1 from storage.objects so
          where so.bucket_id = 'station-documents'
            and so.name = d.storage_path
        )
        or (
          d.document_type = 'business_permit'
          and (d.expires_at is null or d.expires_at <= current_date)
        )
        or d.expires_at is not null and d.expires_at <= current_date
      )
  ) then
    raise exception 'Every current required document must exist in private storage and be unexpired';
  end if;

  perform set_config('app.submit_application', 'on', true);
  update public.station_applications
  set application_status = 'submitted',
      verification_status = 'pending',
      submitted_at = now()
  where id = p_application_id;
  perform set_config('app.station_review', 'on', true);
  update public.stations
  set verification_status = 'pending'
  where application_id = p_application_id;
  perform set_config('app.station_review', 'off', true);
  perform set_config('app.submit_application', 'off', true);
end;
$$;

create or replace function public.review_station_document(
  p_document_id uuid,
  p_decision public.document_review_status,
  p_notes text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  document_row public.station_documents%rowtype;
  application_status_value public.application_status;
begin
  if not public.has_permission('station.review') then
    raise exception 'Station review permission is required';
  end if;
  if p_decision not in ('approved', 'changes_requested', 'rejected') then
    raise exception 'Invalid document review decision';
  end if;

  select * into document_row
  from public.station_documents
  where id = p_document_id
    and is_current
  for update;
  if not found then
    raise exception 'Station document was not found';
  end if;

  select a.application_status into application_status_value
  from public.station_applications a
  where a.id = document_row.application_id;
  if application_status_value not in ('submitted', 'in_review', 'changes_requested') then
    raise exception 'Documents can only be reviewed for an active application';
  end if;

  perform set_config('app.document_review', 'on', true);
  update public.station_documents
  set review_status = p_decision,
      reviewed_by = auth.uid(),
      review_notes = p_notes,
      reviewed_at = now()
  where id = p_document_id;
  perform set_config('app.document_review', 'off', true);

  insert into public.admin_audit_logs (
    actor_id, action, entity_type, entity_id, before_data, after_data
  )
  values (
    auth.uid(),
    'station_document_reviewed',
    'station_document',
    p_document_id,
    jsonb_build_object('review_status', document_row.review_status),
    jsonb_build_object('review_status', p_decision, 'notes', p_notes)
  );
end;
$$;

create or replace function public.review_application(
  p_application_id uuid,
  p_decision public.application_status,
  p_notes text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_row public.station_applications%rowtype;
  next_verification public.verification_status;
  station_id_value uuid;
begin
  if not public.has_permission('station.review') then
    raise exception 'Station review permission is required';
  end if;
  if p_decision not in ('in_review', 'changes_requested', 'approved', 'rejected') then
    raise exception 'Invalid application review decision';
  end if;

  select * into application_row
  from public.station_applications
  where id = p_application_id
  for update;
  if not found then
    raise exception 'Station application was not found';
  end if;

  if p_decision = 'approved' and (
    not exists (
      select 1
      from public.station_document_requirements r
      where r.application_id = p_application_id and r.required
    )
    or exists (
      select 1
      from public.station_document_requirements r
      where r.application_id = p_application_id
        and r.required
        and not exists (
          select 1 from public.station_documents d
          where d.application_id = r.application_id
            and d.document_type = r.document_type
            and d.required_for_verification
            and d.is_current
            and d.review_status = 'approved'
        )
    )
  ) then
    raise exception 'Every required document type must have an approved current version';
  end if;

  next_verification := case p_decision
    when 'approved' then 'verified'::public.verification_status
    when 'rejected' then 'rejected'::public.verification_status
    when 'changes_requested' then 'changes_requested'::public.verification_status
    else application_row.verification_status
  end;

  update public.station_applications
  set application_status = p_decision,
      verification_status = next_verification,
      admin_notes = p_notes,
      reviewed_by = auth.uid(),
      reviewed_at = now()
  where id = p_application_id;

  select s.id into station_id_value
  from public.stations s
  where s.application_id = p_application_id
  for update;
  if station_id_value is null then
    raise exception 'Unpublished station setup record is missing';
  end if;

  if p_decision in ('approved', 'rejected', 'changes_requested') then
    perform set_config('app.station_review', 'on', true);
    update public.stations
    set verification_status = next_verification
    where id = station_id_value;
    perform set_config('app.station_review', 'off', true);
  end if;

  if p_decision <> 'in_review' then
    insert into public.verification_reviews (
      application_id, reviewer_id, decision, notes
    )
    values (
      p_application_id,
      auth.uid(),
      case p_decision
        when 'approved' then 'approved'::public.document_review_status
        when 'rejected' then 'rejected'::public.document_review_status
        else 'changes_requested'::public.document_review_status
      end,
      p_notes
    );
  end if;

  insert into public.admin_audit_logs (
    actor_id, action, entity_type, entity_id, before_data, after_data
  )
  values (
    auth.uid(),
    'station_application_reviewed',
    'station_application',
    p_application_id,
    jsonb_build_object('status', application_row.application_status),
    jsonb_build_object('status', p_decision, 'notes', p_notes)
  );
end;
$$;

create or replace function public.publish_station(p_station_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  station_row public.stations%rowtype;
begin
  if not public.has_permission('station.publish') then
    raise exception 'Station publication permission is required';
  end if;

  select * into station_row
  from public.stations
  where id = p_station_id
  for update;
  if not found then
    raise exception 'Station was not found';
  end if;
  if station_row.verification_status <> 'verified'
    or station_row.operational_status not in ('onboarding', 'active', 'inactive')
  then
    raise exception 'Station must be verified and operational before publication';
  end if;
  if not exists (
    select 1
    from public.station_applications a
    where a.id = station_row.application_id
      and a.application_status = 'approved'
  ) then
    raise exception 'The linked station application must be approved before publication';
  end if;
  if not exists (
    select 1 from public.station_products p
    where p.station_id = p_station_id and p.status = 'active'
  ) then
    raise exception 'Station needs at least one active product';
  end if;
  if not exists (
    select 1 from public.station_operating_hours h
    where h.station_id = p_station_id and not h.is_closed
  ) then
    raise exception 'Configure at least one open operating day before publication';
  end if;
  if exists (
    select 1
    from public.station_products p
    where p.station_id = p_station_id
      and p.status = 'active'
      and not exists (
        select 1
        from public.container_policies cp
        where cp.station_id = p.station_id
          and cp.container_type_id = p.container_type_id
          and cp.is_active
      )
  ) then
    raise exception 'Configure an active container policy for every active product type';
  end if;
  if station_row.default_delivery_fee is null
    or station_row.default_delivery_fee < 0
    or exists (
      select 1 from public.station_delivery_zones z
      where z.station_id = p_station_id and z.is_active
        and (z.delivery_fee is null or z.delivery_fee < 0)
    )
  then
    raise exception 'Configure a valid delivery fee before publication';
  end if;
  if station_row.service_radius_km is null and not exists (
    select 1 from public.station_delivery_zones z
    where z.station_id = p_station_id and z.is_active
  ) then
    raise exception 'Configure a delivery radius or an active delivery zone';
  end if;

  perform set_config('app.station_suspend', 'on', true);
  update public.stations
  set operational_status = 'active'
  where id = p_station_id;
  perform set_config('app.station_suspend', 'off', true);
  perform set_config('app.station_publish', 'on', true);
  update public.stations
  set publication_status = 'published'
  where id = p_station_id;
  perform set_config('app.station_publish', 'off', true);

  insert into public.admin_audit_logs (
    actor_id, action, entity_type, entity_id, before_data, after_data
  )
  values (
    auth.uid(), 'station_published', 'station', p_station_id,
    jsonb_build_object('publication_status', station_row.publication_status),
    jsonb_build_object('publication_status', 'published')
  );
end;
$$;

create or replace function public.suspend_station(
  p_station_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_status public.station_operational_status;
begin
  if not public.has_permission('station.suspend') then
    raise exception 'Station suspension permission is required';
  end if;

  select operational_status into old_status
  from public.stations
  where id = p_station_id
  for update;
  if not found then
    raise exception 'Station was not found';
  end if;
  if old_status = 'archived' then
    raise exception 'An archived station cannot be suspended';
  end if;
  -- Suspension stops NEW orders immediately (create_order requires a published,
  -- active station). In-flight orders are allowed to finish or be handled with
  -- admin_cancel_order, so suspension is never blocked by open orders.

  perform set_config('app.station_suspend', 'on', true);
  update public.stations
  set operational_status = 'suspended'
  where id = p_station_id;
  perform set_config('app.station_suspend', 'off', true);
  perform set_config('app.station_publish', 'on', true);
  update public.stations
  set publication_status = 'suspended'
  where id = p_station_id;
  perform set_config('app.station_publish', 'off', true);

  insert into public.admin_audit_logs (
    actor_id, action, entity_type, entity_id, before_data, after_data
  )
  values (
    auth.uid(), 'station_suspended', 'station', p_station_id,
    jsonb_build_object('operational_status', old_status),
    jsonb_build_object('operational_status', 'suspended', 'reason', p_reason)
  );
end;
$$;

create or replace function public.pause_station(p_station_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_status public.station_operational_status;
begin
  if not public.is_station_manager(p_station_id) then
    raise exception 'Station manager permission is required';
  end if;

  select operational_status into old_status
  from public.stations
  where id = p_station_id
  for update;
  if not found or old_status <> 'active' then
    raise exception 'Only an active station can be paused';
  end if;

  perform set_config('app.station_suspend', 'on', true);
  update public.stations
  set operational_status = 'inactive'
  where id = p_station_id;
  perform set_config('app.station_suspend', 'off', true);

  insert into public.admin_audit_logs (
    actor_id, action, entity_type, entity_id, before_data, after_data
  )
  values (
    auth.uid(), 'station_paused', 'station', p_station_id,
    jsonb_build_object('operational_status', old_status),
    jsonb_build_object('operational_status', 'inactive', 'reason', p_reason)
  );
end;
$$;

create or replace function public.resume_station(p_station_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_station_manager(p_station_id) then
    raise exception 'Station manager permission is required';
  end if;
  if not exists (
    select 1 from public.stations s
    where s.id = p_station_id
      and s.publication_status = 'published'
      and s.verification_status = 'verified'
      and s.operational_status = 'inactive'
  ) then
    raise exception 'Only a verified, published, paused station can resume';
  end if;

  perform set_config('app.station_suspend', 'on', true);
  update public.stations
  set operational_status = 'active'
  where id = p_station_id;
  perform set_config('app.station_suspend', 'off', true);
end;
$$;

create or replace function public.reinstate_station(p_station_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  station_row public.stations%rowtype;
begin
  if not public.has_permission('station.suspend') then
    raise exception 'Station administration permission is required';
  end if;

  select * into station_row
  from public.stations
  where id = p_station_id
  for update;
  if not found or station_row.operational_status <> 'suspended'
    or station_row.verification_status <> 'verified'
  then
    raise exception 'Only a suspended, verified station can be reinstated';
  end if;

  perform set_config('app.station_suspend', 'on', true);
  update public.stations
  set operational_status = 'inactive'
  where id = p_station_id;
  perform set_config('app.station_suspend', 'off', true);
  perform set_config('app.station_publish', 'on', true);
  update public.stations
  set publication_status = 'unpublished'
  where id = p_station_id;
  perform set_config('app.station_publish', 'off', true);

  insert into public.admin_audit_logs (
    actor_id, action, entity_type, entity_id, before_data, after_data
  )
  values (
    auth.uid(), 'station_reinstated', 'station', p_station_id,
    jsonb_build_object(
      'operational_status', station_row.operational_status,
      'publication_status', station_row.publication_status
    ),
    jsonb_build_object(
      'operational_status', 'inactive',
      'publication_status', 'unpublished',
      'reason', p_reason
    )
  );
end;
$$;

create or replace function public.archive_station(p_station_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  station_row public.stations%rowtype;
begin
  if not public.has_permission('station.suspend') then
    raise exception 'Station administration permission is required';
  end if;
  select * into station_row
  from public.stations
  where id = p_station_id
  for update;
  if not found then
    raise exception 'Station was not found';
  end if;
  if station_row.operational_status = 'archived' then
    raise exception 'Station is already archived';
  end if;
  if exists (
    select 1 from public.orders o
    where o.station_id = p_station_id
      and o.status in (
        'pending', 'confirmed', 'preparing', 'ready',
        'rider_assigned', 'out_for_delivery'
      )
  ) then
    raise exception 'Resolve in-flight orders before archiving this station';
  end if;

  perform set_config('app.station_suspend', 'on', true);
  update public.stations
  set operational_status = 'archived'
  where id = p_station_id;
  perform set_config('app.station_suspend', 'off', true);
  perform set_config('app.station_publish', 'on', true);
  update public.stations
  set publication_status = 'archived'
  where id = p_station_id;
  perform set_config('app.station_publish', 'off', true);

  insert into public.admin_audit_logs (actor_id, action, entity_type, entity_id, after_data)
  values (
    auth.uid(), 'station_archived', 'station', p_station_id,
    jsonb_build_object('reason', p_reason)
  );
end;
$$;

create or replace function public.nearby_stations(
  p_latitude double precision,
  p_longitude double precision,
  p_radius_km double precision default 25,
  p_filters jsonb default '{}'::jsonb,
  p_page_size integer default 20,
  p_page_offset integer default 0
)
returns table (
  station_id uuid,
  display_name text,
  description text,
  logo_path text,
  city text,
  province text,
  latitude double precision,
  longitude double precision,
  distance_km double precision,
  starting_price numeric,
  estimated_delivery_minutes integer,
  is_open boolean,
  rating_average numeric,
  rating_count integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  customer_location extensions.geography(point, 4326);
  requested_water_type text;
  requested_city text;
  requested_province text;
  requested_barangay text;
  requested_city_code text;
  requested_province_code text;
  requested_barangay_code text;
begin
  if p_latitude is null or p_latitude not between -90 and 90
    or p_longitude is null or p_longitude not between -180 and 180
  then
    raise exception 'Valid latitude and longitude are required';
  end if;
  if p_radius_km is null or p_radius_km <= 0 or p_radius_km > 250 then
    raise exception 'Search radius must be between 0 and 250 kilometers';
  end if;
  if p_filters is null or jsonb_typeof(p_filters) <> 'object' then
    raise exception 'Filters must be a JSON object';
  end if;
  if p_page_size is null or p_page_size < 1 or p_page_size > 100
    or p_page_offset is null or p_page_offset < 0
  then
    raise exception 'Page size must be 1–100 and page offset must not be negative';
  end if;

  customer_location :=
    extensions.st_setsrid(extensions.st_makepoint(p_longitude, p_latitude), 4326)::extensions.geography;
  requested_water_type := nullif(trim(p_filters ->> 'water_type'), '');
  requested_city := nullif(trim(p_filters ->> 'city'), '');
  requested_province := nullif(trim(p_filters ->> 'province'), '');
  requested_barangay := nullif(trim(p_filters ->> 'barangay'), '');
  requested_city_code := nullif(trim(p_filters ->> 'psgc_city_code'), '');
  requested_province_code := nullif(trim(p_filters ->> 'psgc_province_code'), '');
  requested_barangay_code := nullif(trim(p_filters ->> 'psgc_barangay_code'), '');

  return query
  with eligible as (
    select
      s.id,
      s.display_name,
      s.description,
      s.logo_path,
      s.city,
      s.province,
      s.latitude,
      s.longitude,
      extensions.st_distance(s.location, customer_location) / 1000.0 as km,
      (
        select min(least(
          case when p.refill_available then p.refill_price end,
          case when p.new_container_available then
            p.refill_price + p.new_container_price
              + coalesce(p.deposit_amount, cp.deposit_amount, 0)
          end
        ))
        from public.station_products p
        join public.water_types wt on wt.id = p.water_type_id and wt.is_active
        left join public.container_policies cp
          on cp.station_id = p.station_id
          and cp.container_type_id = p.container_type_id
          and cp.is_active
        where p.station_id = s.id
          and p.status = 'active'
          and (p.stock_quantity is null or p.stock_quantity > 0)
          and (requested_water_type is null or wt.name = requested_water_type)
      ) as start_price,
      s.estimated_delivery_minutes,
      s.rating_average,
      s.rating_count,
      public.is_station_open(s.id) as open_now
    from public.stations s
    where s.publication_status = 'published'
      and s.operational_status = 'active'
      and s.verification_status = 'verified'
      and (
        extensions.st_dwithin(s.location, customer_location, p_radius_km * 1000.0)
        and (
          s.service_radius_km is not null
          and extensions.st_dwithin(s.location, customer_location, s.service_radius_km * 1000.0)
        )
        or exists (
          select 1
          from public.station_delivery_zones z
          where z.station_id = s.id
            and z.is_active
            and (
              case
                when requested_city_code is not null
                  and requested_province_code is not null
                  and z.psgc_city_code is not null
                  and z.psgc_province_code is not null
                then z.psgc_city_code = requested_city_code
                  and z.psgc_province_code = requested_province_code
                  and (
                    z.psgc_barangay_code is null
                    or z.psgc_barangay_code = requested_barangay_code
                  )
                else requested_city is not null
                  and requested_province is not null
                  and lower(trim(z.city)) = lower(requested_city)
                  and lower(trim(z.province)) = lower(requested_province)
                  and (z.barangay is null or (
                    requested_barangay is not null
                    and lower(trim(z.barangay)) = lower(requested_barangay)
                  ))
              end
            )
            and extensions.st_dwithin(s.location, customer_location, p_radius_km * 1000.0)
        )
      )
  )
  select
    e.id,
    e.display_name,
    e.description,
    e.logo_path,
    e.city,
    e.province,
    e.latitude,
    e.longitude,
    e.km,
    e.start_price,
    e.estimated_delivery_minutes,
    e.open_now,
    e.rating_average,
    e.rating_count
  from eligible e
  where e.start_price is not null
    and (coalesce((p_filters ->> 'open_now')::boolean, false) is false or e.open_now)
  order by e.km, e.id
  limit p_page_size
  offset p_page_offset;
end;
$$;

create or replace function public.nearby_stations_with_barangay(
  p_latitude double precision,
  p_longitude double precision,
  p_radius_km double precision default 25,
  p_filters jsonb default '{}'::jsonb,
  p_page_size integer default 20,
  p_page_offset integer default 0
)
returns table (
  station_id uuid,
  display_name text,
  description text,
  logo_path text,
  barangay text,
  city text,
  province text,
  latitude double precision,
  longitude double precision,
  distance_km double precision,
  starting_price numeric,
  estimated_delivery_minutes integer,
  is_open boolean,
  rating_average numeric,
  rating_count integer
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    nearby.station_id,
    nearby.display_name,
    nearby.description,
    nearby.logo_path,
    station.barangay,
    nearby.city,
    nearby.province,
    nearby.latitude,
    nearby.longitude,
    nearby.distance_km,
    nearby.starting_price,
    nearby.estimated_delivery_minutes,
    nearby.is_open,
    nearby.rating_average,
    nearby.rating_count
  from public.nearby_stations(
    p_latitude,
    p_longitude,
    p_radius_km,
    p_filters,
    p_page_size,
    p_page_offset
  ) as nearby
  join public.stations as station on station.id = nearby.station_id;
$$;

create or replace function public.create_order(
  p_station_id uuid,
  p_address_id uuid,
  p_items jsonb,
  p_payment_method public.payment_method default 'cod',
  p_idempotency_key text default null,
  p_customer_notes text default null,
  p_cart_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  request_key text;
  request_fingerprint_value text;
  existing_fingerprint text;
  cart_row public.carts%rowtype;
  cart_found boolean := false;
  station_row public.stations%rowtype;
  address_row public.addresses%rowtype;
  new_order_id uuid;
  order_total numeric(12, 2) := 0;
  subtotal_value numeric(12, 2) := 0;
  container_total_value numeric(12, 2) := 0;
  deposit_total_value numeric(12, 2) := 0;
  delivery_fee_value numeric(12, 2) := 0;
  zone_id_value uuid;
  zone_fee_value numeric(12, 2);
  zone_minimum numeric(12, 2);
  item jsonb;
  product_row public.station_products%rowtype;
  policy_row public.container_policies%rowtype;
  item_quantity integer;
  requested_quantity integer;
  reserved_quantity integer;
  option_value public.container_option;
  effective_deposit numeric(12, 2);
  effective_requires_empty boolean;
  effective_return_policy text;
  line_refill numeric(12, 2);
  line_container numeric(12, 2);
  line_deposit numeric(12, 2);
  item_sum numeric(12, 2);
  item_snapshots jsonb := '[]'::jsonb;
  item_snapshot jsonb;
  stock_rows_updated integer;
begin
  if actor_id is null then raise exception 'Authentication is required'; end if;
  if not exists (
    select 1 from public.profiles p
    where p.id = actor_id and p.status = 'active'
  ) then
    raise exception 'An active customer account is required';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array'
    or jsonb_array_length(p_items) = 0
  then
    raise exception 'At least one cart item is required';
  end if;
  if p_payment_method not in ('cod', 'paymongo') then
    raise exception 'Unsupported payment method';
  end if;

  if p_cart_id is not null then
    select * into cart_row
    from public.carts c
    where c.id = p_cart_id
      and c.user_id = actor_id
    for update;
    cart_found := found;
    if not cart_found
      or cart_row.status not in ('active', 'converted')
      or cart_row.station_id is distinct from p_station_id
    then
      raise exception 'The selected cart is invalid or no longer active';
    end if;
    request_key := coalesce(
      nullif(trim(p_idempotency_key), ''),
      nullif(trim(cart_row.idempotency_key), ''),
      'cart:' || cart_row.id::text
    );
    if cart_row.idempotency_key is not null
      and p_idempotency_key is not null
      and trim(p_idempotency_key) <> cart_row.idempotency_key
    then
      raise exception 'This cart is already bound to a different checkout key';
    end if;
    if cart_row.idempotency_key is null then
      update public.carts
      set idempotency_key = request_key
      where id = cart_row.id;
    end if;
    if cart_row.status = 'active' and (
      (select count(*) from public.cart_items ci where ci.cart_id = p_cart_id)
        <> jsonb_array_length(p_items)
      or exists (
        select 1
        from public.cart_items ci
        join public.station_products p on p.id = ci.product_id
        where ci.cart_id = p_cart_id
          and (
            p.station_id <> p_station_id
            or not exists (
              select 1
              from jsonb_array_elements(p_items) requested(value)
              where requested.value ->> 'product_id' = ci.product_id::text
                and requested.value ->> 'container_option' = ci.container_option::text
                and (requested.value ->> 'quantity')::integer = ci.quantity
            )
          )
      )
    ) then
      raise exception 'Checkout items do not match the selected cart';
    end if;
  else
    request_key := nullif(trim(p_idempotency_key), '');
  end if;
  if request_key is null then
    raise exception 'An idempotency key or active cart is required';
  end if;

  request_fingerprint_value := md5(jsonb_build_object(
    'station_id', p_station_id,
    'address_id', p_address_id,
    'items', p_items,
    'payment_method', p_payment_method,
    'customer_notes', p_customer_notes
  )::text);

  if p_cart_id is not null and cart_row.status = 'converted' then
    select o.id, o.request_fingerprint
    into new_order_id, existing_fingerprint
    from public.orders o
    where o.cart_id = p_cart_id;
    if new_order_id is null then
      raise exception 'Converted cart has no matching order';
    end if;
    if existing_fingerprint is distinct from request_fingerprint_value then
      raise exception 'This cart was already checked out with different order details';
    end if;
    return new_order_id;
  end if;

  select o.id, o.request_fingerprint
  into new_order_id, existing_fingerprint
  from public.orders o
  where o.customer_id = actor_id and o.idempotency_key = request_key;
  if new_order_id is not null then
    if existing_fingerprint is distinct from request_fingerprint_value then
      raise exception 'This idempotency key was already used with different order details';
    end if;
    return new_order_id;
  end if;

  select * into station_row
  from public.stations
  where id = p_station_id
  for update;
  if not found
    or station_row.publication_status <> 'published'
    or station_row.operational_status <> 'active'
    or station_row.verification_status <> 'verified'
  then
    raise exception 'Station is not currently accepting orders';
  end if;
  if not public.is_station_open(p_station_id) then
    raise exception 'Station is currently closed and cannot accept orders';
  end if;

  select * into address_row
  from public.addresses
  where id = p_address_id and user_id = actor_id;
  if not found then raise exception 'Delivery address is invalid'; end if;

  select z.id, z.delivery_fee, z.minimum_order_amount
    into zone_id_value, zone_fee_value, zone_minimum
  from public.station_delivery_zones z
  where z.station_id = p_station_id
    and z.is_active
    and (
      case
        when address_row.psgc_city_code is not null
          and address_row.psgc_province_code is not null
          and z.psgc_city_code is not null
          and z.psgc_province_code is not null
        then z.psgc_city_code = address_row.psgc_city_code
          and z.psgc_province_code = address_row.psgc_province_code
          and (
            z.psgc_barangay_code is null
            or z.psgc_barangay_code = address_row.psgc_barangay_code
          )
        else lower(trim(z.city)) = lower(trim(address_row.city))
          and lower(trim(z.province)) = lower(trim(address_row.province))
          and (z.barangay is null or lower(trim(z.barangay)) = lower(trim(address_row.barangay)))
      end
    )
  order by (z.barangay is not null) desc
  limit 1;

  if zone_id_value is not null then
    delivery_fee_value := zone_fee_value;
  elsif address_row.latitude is not null
    and station_row.service_radius_km is not null
    and extensions.st_dwithin(
      station_row.location,
      extensions.st_setsrid(
        extensions.st_makepoint(address_row.longitude, address_row.latitude), 4326
      )::extensions.geography,
      station_row.service_radius_km * 1000
    )
  then
    delivery_fee_value := station_row.default_delivery_fee;
    zone_minimum := station_row.minimum_order_amount;
  else
    raise exception 'Station does not deliver to this address';
  end if;

  for item in select value from jsonb_array_elements(p_items)
  loop
    if jsonb_typeof(item) <> 'object' then
      raise exception 'Each item must be an object';
    end if;

    item_quantity := (item ->> 'quantity')::integer;
    option_value := (item ->> 'container_option')::public.container_option;
    if item_quantity is null or item_quantity <= 0 then
      raise exception 'Item quantity must be positive';
    end if;

    select * into product_row
    from public.station_products
    where id = (item ->> 'product_id')::uuid
      and station_id = p_station_id
      and status = 'active'
    for update;
    if not found then raise exception 'Product is unavailable'; end if;

    if option_value = 'refill_existing' and not product_row.refill_available then
      raise exception 'Refill option is unavailable for product %', product_row.name;
    elsif option_value = 'new_gallon' and not product_row.new_container_available then
      raise exception 'New gallon option is unavailable for product %', product_row.name;
    end if;
    select coalesce(sum((entry.value ->> 'quantity')::integer), 0)::integer
    into requested_quantity
    from jsonb_array_elements(p_items) entry(value)
    where entry.value ->> 'product_id' = product_row.id::text;
    if requested_quantity > product_row.max_order_quantity then
      raise exception 'Quantity exceeds the per-order product limit of %', product_row.max_order_quantity;
    end if;
    select coalesce(sum(oi.quantity), 0)::integer
    into reserved_quantity
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    where oi.product_id = product_row.id
      and o.customer_id = actor_id
      and o.status in (
        'pending', 'confirmed', 'preparing', 'ready', 'rider_assigned', 'out_for_delivery'
      );
    if requested_quantity + reserved_quantity > 20 then
      raise exception 'A customer may reserve up to 20 units of a product across active orders';
    end if;

    if product_row.stock_quantity is not null then
      perform set_config('app.inventory_update', 'on', true);
      update public.station_products
      set stock_quantity = stock_quantity - item_quantity
      where id = product_row.id and stock_quantity >= item_quantity;
      get diagnostics stock_rows_updated = row_count;
      perform set_config('app.inventory_update', 'off', true);
      if stock_rows_updated = 0 then
        raise exception 'Insufficient stock for product %', product_row.name;
      end if;
    end if;

    select * into policy_row
    from public.container_policies cp
    where cp.station_id = p_station_id
      and cp.container_type_id = product_row.container_type_id
      and cp.is_active;

    effective_deposit := case when option_value = 'new_gallon'
      then coalesce(product_row.deposit_amount, policy_row.deposit_amount, 0)
      else 0
    end;
    effective_requires_empty := option_value = 'refill_existing' and coalesce(
      product_row.requires_empty_container,
      policy_row.requires_empty_return,
      false
    );
    effective_return_policy := case when option_value = 'refill_existing'
      then coalesce(product_row.return_policy, policy_row.return_policy)
      else null
    end;

    line_refill := product_row.refill_price * item_quantity;
    line_container := case when option_value = 'new_gallon'
      then coalesce(product_row.new_container_price, 0) * item_quantity
      else 0
    end;
    line_deposit := effective_deposit * item_quantity;
    item_sum := line_refill + line_container + line_deposit;
    subtotal_value := subtotal_value + line_refill;
    container_total_value := container_total_value + line_container;
    deposit_total_value := deposit_total_value + line_deposit;

    item_snapshots := item_snapshots || jsonb_build_array(jsonb_build_object(
      'product_id', product_row.id,
      'product_name', product_row.name,
      'water_type', (select wt.name from public.water_types wt where wt.id = product_row.water_type_id),
      'container_type', (select ct.name from public.container_types ct where ct.id = product_row.container_type_id),
      'container_option', option_value,
      'quantity', item_quantity,
      'refill_price', product_row.refill_price,
      'container_price', case when option_value = 'new_gallon' then product_row.new_container_price else 0 end,
      'deposit', effective_deposit,
      'requires_empty', effective_requires_empty,
      'return_policy', effective_return_policy,
      'line_total', item_sum
    ));
  end loop;

  if subtotal_value < coalesce(zone_minimum, 0) then
    raise exception 'Order subtotal is below this delivery area minimum';
  end if;

  order_total := subtotal_value + container_total_value + deposit_total_value
    + delivery_fee_value;

  insert into public.orders (
    customer_id, station_id, address_id, address_snapshot, station_snapshot,
    payment_method,
    subtotal, container_total, deposit_total, delivery_fee, total,
    customer_notes, delivery_zone_id, delivery_zone_snapshot, idempotency_key,
    request_fingerprint, cart_id, checkout_expires_at, acceptance_expires_at
  )
  values (
    actor_id, p_station_id, p_address_id,
    jsonb_build_object(
      'label', address_row.label,
      'recipient_name', address_row.recipient_name,
      'phone', address_row.phone,
      'address_line', address_row.address_line,
      'barangay', address_row.barangay,
      'city', address_row.city,
      'province', address_row.province,
      'psgc_barangay_code', address_row.psgc_barangay_code,
      'psgc_city_code', address_row.psgc_city_code,
      'psgc_province_code', address_row.psgc_province_code,
      'region', address_row.region,
      'postal_code', address_row.postal_code,
      'landmark', address_row.landmark,
      'latitude', address_row.latitude,
      'longitude', address_row.longitude
    ),
    jsonb_build_object(
      'display_name', station_row.display_name,
      'logo_path', station_row.logo_path,
      'phone', station_row.phone,
      'email', station_row.email,
      'address_line', station_row.address_line,
      'barangay', station_row.barangay,
      'city', station_row.city,
      'province', station_row.province
    ),
    p_payment_method,
    subtotal_value,
    container_total_value,
    deposit_total_value,
    delivery_fee_value,
    order_total,
    p_customer_notes,
    zone_id_value,
    case when zone_id_value is null then null else
      jsonb_build_object('delivery_fee', zone_fee_value, 'minimum_order_amount', zone_minimum)
    end,
    request_key,
    request_fingerprint_value,
    p_cart_id,
    case when p_payment_method = 'paymongo' then now() + interval '30 minutes' else null end,
    now() + interval '15 minutes'
  )
  returning id into new_order_id;

  for item_snapshot in select value from jsonb_array_elements(item_snapshots)
  loop
    insert into public.order_items (
      order_id, product_id, product_name_snapshot, water_type_snapshot,
      container_type_snapshot, container_option, quantity, unit_refill_price,
      unit_container_price, unit_deposit, requires_empty_container_snapshot,
      return_policy_snapshot, line_total
    )
    values (
      new_order_id,
      (item_snapshot ->> 'product_id')::uuid,
      item_snapshot ->> 'product_name',
      item_snapshot ->> 'water_type',
      item_snapshot ->> 'container_type',
      (item_snapshot ->> 'container_option')::public.container_option,
      (item_snapshot ->> 'quantity')::integer,
      (item_snapshot ->> 'refill_price')::numeric,
      (item_snapshot ->> 'container_price')::numeric,
      (item_snapshot ->> 'deposit')::numeric,
      (item_snapshot ->> 'requires_empty')::boolean,
      item_snapshot ->> 'return_policy',
      (item_snapshot ->> 'line_total')::numeric
    );
  end loop;

  insert into public.station_inventory_movements (
    station_id, product_id, movement_type, quantity_change,
    reference, notes, created_by
  )
  select
    p_station_id,
    p.id,
    'sale',
    -sum(oi.quantity)::integer,
    new_order_id::text,
    'Inventory reserved for customer order',
    actor_id
  from public.order_items oi
  join public.station_products p on p.id = oi.product_id
  where oi.order_id = new_order_id
    and p.stock_quantity is not null
  group by p.id;

  insert into public.payments (
    order_id, customer_id, method, status, amount, provider,
    attempt_number, idempotency_key
  )
  values (
    new_order_id, actor_id, p_payment_method, 'pending', order_total,
    case when p_payment_method = 'paymongo' then 'paymongo' else null end,
    1, new_order_id::text || ':payment:1'
  );

  if p_cart_id is not null then
    update public.carts
    set status = 'converted',
        updated_at = now()
    where id = p_cart_id
      and user_id = actor_id
      and status = 'active';
  end if;

  return new_order_id;
exception
  when unique_violation then
    select o.id, o.request_fingerprint
    into new_order_id, existing_fingerprint
    from public.orders o
    where customer_id = actor_id and idempotency_key = request_key;
    if new_order_id is not null then
      if existing_fingerprint is distinct from request_fingerprint_value then
        raise exception 'This idempotency key was already used with different order details';
      end if;
      return new_order_id;
    end if;
    raise;
end;
$$;

create or replace function public.release_order_inventory(
  p_order_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  order_row public.orders%rowtype;
begin
  if current_setting('app.release_inventory', true) is distinct from 'on' then
    raise exception 'Inventory release is only available through an authorized order workflow';
  end if;

  select * into order_row
  from public.orders
  where id = p_order_id
  for update;
  if not found then
    raise exception 'Order was not found';
  end if;
  if order_row.inventory_released_at is not null then
    return;
  end if;

  update public.orders
  set inventory_released_at = now()
  where id = p_order_id;

  perform set_config('app.inventory_update', 'on', true);
  update public.station_products p
  set stock_quantity = p.stock_quantity + item_totals.quantity
  from (
    select oi.product_id, sum(oi.quantity)::integer as quantity
    from public.order_items oi
    where oi.order_id = p_order_id
      and oi.product_id is not null
    group by oi.product_id
  ) item_totals
  where p.id = item_totals.product_id
    and p.station_id = order_row.station_id
    and p.stock_quantity is not null;
  perform set_config('app.inventory_update', 'off', true);

  insert into public.station_inventory_movements (
    station_id, product_id, movement_type, quantity_change,
    reference, notes, created_by
  )
  select
    order_row.station_id,
    item_totals.product_id,
    'return',
    item_totals.quantity,
    p_order_id::text,
    p_reason,
    auth.uid()
  from (
    select oi.product_id, sum(oi.quantity)::integer as quantity
    from public.order_items oi
    where oi.order_id = p_order_id
      and oi.product_id is not null
    group by oi.product_id
  ) item_totals
  join public.station_products p
    on p.id = item_totals.product_id
   and p.station_id = order_row.station_id
   and p.stock_quantity is not null;
end;
$$;

create or replace function public.cancel_order(
  p_order_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  order_row public.orders%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;

  select * into order_row
  from public.orders
  where id = p_order_id
  for update;
  if not found or order_row.customer_id <> auth.uid() then
    raise exception 'Order was not found';
  end if;
  if order_row.status not in ('pending', 'confirmed', 'preparing') then
    raise exception 'This order can no longer be cancelled';
  end if;
  if exists (
    select 1 from public.payments p
    where p.order_id = p_order_id
      and p.status in ('paid', 'partially_refunded')
  ) then
    raise exception 'Paid orders require the refund workflow before cancellation';
  end if;

  perform set_config('app.order_transition', 'on', true);
  perform set_config('app.order_transition_note', nullif(trim(p_reason), ''), true);
  update public.orders
  set status = 'cancelled',
      cancelled_at = now(),
      cancel_reason = nullif(trim(p_reason), ''),
      cancelled_by = auth.uid()
  where id = p_order_id;
  perform set_config('app.order_transition', 'off', true);
  perform set_config('app.order_transition_note', '', true);

  perform set_config('app.payment_transition', 'on', true);
  update public.payments
  set status = 'cancelled'
  where order_id = p_order_id
    and status in ('pending', 'processing');
  perform set_config('app.payment_transition', 'off', true);

  update public.deliveries
  set status = 'cancelled'
  where order_id = p_order_id
    and status not in ('delivered', 'failed', 'cancelled');

  perform set_config('app.release_inventory', 'on', true);
  perform public.release_order_inventory(
    p_order_id, 'Inventory restored after customer cancellation'
  );
  perform set_config('app.release_inventory', 'off', true);
end;
$$;

create or replace function public.cancel_station_order(
  p_order_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  order_row public.orders%rowtype;
  payment_row public.payments%rowtype;
  payment_found boolean := false;
  refunded_amount numeric(12, 2);
  refundable numeric(12, 2);
  refund_id_value uuid;
  reason_value text := nullif(trim(p_reason), '');
begin
  if auth.uid() is null then
    raise exception 'Authentication is required';
  end if;
  if reason_value is null then
    raise exception 'A cancellation reason is required';
  end if;

  select * into order_row
  from public.orders
  where id = p_order_id
  for update;
  if not found or not public.is_station_member(order_row.station_id) then
    raise exception 'Order was not found for this station';
  end if;
  if order_row.status not in ('pending', 'confirmed', 'preparing', 'ready', 'rider_assigned') then
    raise exception 'This order can no longer be cancelled by the station';
  end if;

  select * into payment_row
  from public.payments
  where order_id = p_order_id
  order by attempt_number desc
  limit 1
  for update;
  payment_found := found;

  if payment_found and payment_row.status in ('paid', 'partially_refunded') then
    if payment_row.provider is distinct from 'paymongo'
      or payment_row.provider_payment_id is null
    then
      raise exception 'This paid order requires administrator refund assistance before cancellation';
    end if;

    select coalesce(sum(pr.amount), 0) into refunded_amount
    from public.payment_refunds pr
    where pr.payment_id = payment_row.id
      and pr.status in ('requested', 'processing', 'succeeded');
    refundable := payment_row.amount - refunded_amount;

    if refundable > 0 then
      refund_id_value := null;
      insert into public.payment_refunds (
        payment_id, requested_by, amount, status, reason, idempotency_key
      )
      values (
        payment_row.id, auth.uid(), refundable, 'requested',
        'Station cancellation: ' || reason_value,
        'station-cancel-refund:' || p_order_id::text
      )
      on conflict (idempotency_key) do nothing
      returning id into refund_id_value;

      if refund_id_value is null then
        select pr.id into refund_id_value
        from public.payment_refunds pr
        where pr.idempotency_key = 'station-cancel-refund:' || p_order_id::text;
      end if;

      insert into public.payment_provider_actions (
        payment_id, refund_id, action_type, idempotency_key, payload
      )
      values (
        payment_row.id, refund_id_value, 'refund',
        'execute-refund:' || refund_id_value::text,
        jsonb_build_object(
          'provider', payment_row.provider,
          'provider_payment_id', payment_row.provider_payment_id,
          'amount', refundable,
          'reason', 'Station cancellation: ' || reason_value
        )
      )
      on conflict (idempotency_key) do nothing;
    end if;
  elsif payment_found
    and payment_row.status in ('pending', 'processing')
    and payment_row.provider = 'paymongo'
    and payment_row.provider_checkout_id is not null
  then
    insert into public.payment_provider_actions (
      payment_id, action_type, idempotency_key, payload
    )
    values (
      payment_row.id, 'expire_checkout',
      'expire-checkout:' || payment_row.id::text,
      jsonb_build_object(
        'provider', payment_row.provider,
        'provider_checkout_id', payment_row.provider_checkout_id,
        'order_id', p_order_id
      )
    )
    on conflict (idempotency_key) do nothing;
  end if;

  perform set_config('app.order_transition_note', reason_value, true);
  perform set_config('app.order_transition', 'on', true);
  update public.orders
  set status = 'cancelled',
      cancelled_at = now(),
      cancel_reason = reason_value,
      cancelled_by = auth.uid()
  where id = p_order_id;
  perform set_config('app.order_transition', 'off', true);
  perform set_config('app.order_transition_note', '', true);

  perform set_config('app.payment_transition', 'on', true);
  update public.payments
  set status = 'cancelled'
  where order_id = p_order_id and status in ('pending', 'processing');
  perform set_config('app.payment_transition', 'off', true);

  update public.deliveries
  set status = 'cancelled'
  where order_id = p_order_id
    and status not in ('delivered', 'failed', 'cancelled');

  perform set_config('app.release_inventory', 'on', true);
  perform public.release_order_inventory(p_order_id, reason_value);
  perform set_config('app.release_inventory', 'off', true);
end;
$$;

create or replace function public.fail_order(
  p_order_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  order_row public.orders%rowtype;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'This order failure workflow is restricted to trusted servers';
  end if;

  select * into order_row
  from public.orders
  where id = p_order_id
  for update;
  if not found then
    raise exception 'Order was not found';
  end if;
  if order_row.status not in (
    'pending', 'confirmed', 'preparing', 'ready', 'rider_assigned', 'out_for_delivery'
  ) then
    raise exception 'This order cannot be failed from its current state';
  end if;
  if exists (
    select 1 from public.payments p
    where p.order_id = p_order_id and p.status in ('paid', 'partially_refunded')
  ) then
    raise exception 'Paid orders require the refund workflow';
  end if;

  perform set_config('app.order_transition_note', nullif(trim(p_reason), ''), true);
  perform set_config('app.order_transition', 'on', true);
  update public.orders
  set status = 'failed',
      cancel_reason = nullif(trim(p_reason), '')
  where id = p_order_id;
  perform set_config('app.order_transition', 'off', true);
  perform set_config('app.order_transition_note', '', true);

  perform set_config('app.payment_transition', 'on', true);
  update public.payments
  set status = 'cancelled'
  where order_id = p_order_id and status in ('pending', 'processing');
  perform set_config('app.payment_transition', 'off', true);

  update public.deliveries
  set status = 'failed', failure_reason = nullif(trim(p_reason), '')
  where order_id = p_order_id
    and status not in ('delivered', 'failed', 'cancelled');

  perform set_config('app.release_inventory', 'on', true);
  perform public.release_order_inventory(
    p_order_id, coalesce(nullif(trim(p_reason), ''), 'Inventory restored after order failure')
  );
  perform set_config('app.release_inventory', 'off', true);
end;
$$;

create or replace function public.expire_pending_paymongo_orders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  expired_order record;
  expired_count integer := 0;
begin
  if coalesce(auth.role(), '') <> 'service_role'
    and not exists (
      select 1 from pg_catalog.pg_roles
      where rolname = current_user and (rolsuper or rolbypassrls)
    )
  then
    raise exception 'Checkout expiry is restricted to trusted servers';
  end if;

  for expired_order in
    select o.id, o.customer_id
    from public.orders o
    where o.payment_method = 'paymongo'
      and o.status in ('pending', 'confirmed')
      and o.checkout_expires_at <= now()
      and exists (
        select 1
        from public.payments p
        where p.order_id = o.id
          and p.status in ('pending', 'processing')
      )
    order by o.checkout_expires_at
    for update of o skip locked
  loop
    insert into public.payment_provider_actions (
      payment_id, action_type, idempotency_key, payload
    )
    select
      p.id,
      'expire_checkout',
      'expire-checkout:' || p.id::text,
      jsonb_build_object(
        'provider', p.provider,
        'provider_checkout_id', p.provider_checkout_id,
        'order_id', expired_order.id
      )
    from public.payments p
    where p.order_id = expired_order.id
      and p.provider = 'paymongo'
      and p.status in ('pending', 'processing')
      and p.provider_checkout_id is not null
    on conflict (idempotency_key) do nothing;

    perform set_config('app.order_transition_note', 'PayMongo checkout expired', true);
    perform set_config('app.order_transition', 'on', true);
    update public.orders
    set status = 'cancelled',
        cancel_reason = 'PayMongo checkout expired',
        cancelled_at = now()
    where id = expired_order.id and status in ('pending', 'confirmed');
    perform set_config('app.order_transition', 'off', true);
    perform set_config('app.order_transition_note', '', true);

    perform set_config('app.payment_transition', 'on', true);
    update public.payments
    set status = 'cancelled'
    where order_id = expired_order.id and status in ('pending', 'processing');
    perform set_config('app.payment_transition', 'off', true);

    perform set_config('app.release_inventory', 'on', true);
    perform public.release_order_inventory(
      expired_order.id, 'Inventory restored after PayMongo checkout expiry'
    );
    perform set_config('app.release_inventory', 'off', true);
    expired_count := expired_count + 1;
  end loop;

  return expired_count;
end;
$$;

create or replace function public.expire_unaccepted_cod_orders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  expired_order record;
  expired_count integer := 0;
begin
  if coalesce(auth.role(), '') <> 'service_role'
    and not exists (
      select 1 from pg_catalog.pg_roles
      where rolname = current_user and (rolsuper or rolbypassrls)
    )
  then
    raise exception 'Unaccepted order expiry is restricted to trusted servers';
  end if;

  for expired_order in
    select o.id
    from public.orders o
    where o.payment_method = 'cod'
      and o.status = 'pending'
      and coalesce(o.acceptance_expires_at, o.created_at + interval '15 minutes') <= now()
    order by coalesce(o.acceptance_expires_at, o.created_at + interval '15 minutes')
    for update of o skip locked
  loop
    perform set_config('app.order_transition_note', 'Station did not accept the COD order in time', true);
    perform set_config('app.order_transition', 'on', true);
    update public.orders
    set status = 'cancelled',
        cancel_reason = 'Station did not accept the COD order in time',
        cancelled_at = now()
    where id = expired_order.id and status = 'pending';
    perform set_config('app.order_transition', 'off', true);
    perform set_config('app.order_transition_note', '', true);

    perform set_config('app.payment_transition', 'on', true);
    update public.payments
    set status = 'cancelled'
    where order_id = expired_order.id
      and status in ('pending', 'processing');
    perform set_config('app.payment_transition', 'off', true);

    perform set_config('app.release_inventory', 'on', true);
    perform public.release_order_inventory(
      expired_order.id, 'Inventory restored after COD acceptance timeout'
    );
    perform set_config('app.release_inventory', 'off', true);
    expired_count := expired_count + 1;
  end loop;
  return expired_count;
end;
$$;

create or replace function public.run_order_expiry_jobs()
returns table (
  paymongo_expired integer,
  cod_expired integer,
  paid_unaccepted_expired integer
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- EXECUTE is revoked from public/anon/authenticated, so only the owner
  -- (pg_cron runs as postgres) can call this. No superuser check: the hosted
  -- Supabase postgres role is not a superuser.
  paymongo_expired := public.expire_pending_paymongo_orders();
  cod_expired := public.expire_unaccepted_cod_orders();
  paid_unaccepted_expired := public.expire_unaccepted_paid_orders();
  return next;
end;
$$;

create or replace function public.apply_payment_event(
  p_provider text,
  p_provider_event_id text,
  p_payment_id uuid,
  p_event_type text,
  p_payload jsonb,
  p_signature_valid boolean,
  p_payment_status public.payment_status,
  p_amount numeric default null,
  p_provider_payment_id text default null,
  p_refund_id uuid default null,
  p_refund_status public.refund_status default null
)
returns table (
  event_id uuid,
  duplicate boolean,
  refund_required boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  payment_row public.payments%rowtype;
  order_row public.orders%rowtype;
  refund_row public.payment_refunds%rowtype;
  payment_found boolean := false;
  order_found boolean := false;
  refund_id_value uuid;
  event_id_value uuid;
  refunded_total numeric(12, 2);
  late_payment boolean := false;
  cancel_order_due_to_payment boolean := false;
  order_cancel_reason text;
  error_value text;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Payment events are restricted to trusted servers';
  end if;
  if nullif(trim(p_provider), '') is null
    or nullif(trim(p_provider_event_id), '') is null
    or nullif(trim(p_event_type), '') is null
    or p_payload is null
    or jsonb_typeof(p_payload) <> 'object'
  then
    raise exception 'A provider event ID, type, and object payload are required';
  end if;

  select * into payment_row
  from public.payments
  where id = p_payment_id;
  payment_found := found;
  if payment_found then
    select * into order_row
    from public.orders
    where id = payment_row.order_id
    for update;
    order_found := found;
    select * into payment_row
    from public.payments
    where id = p_payment_id
    for update;
  end if;

  insert into public.payment_events (
    payment_id, provider, provider_event_id, event_type, payload,
    signature_valid
  )
  values (
    case when payment_found then p_payment_id else null end,
    trim(p_provider), trim(p_provider_event_id), trim(p_event_type),
    p_payload, coalesce(p_signature_valid, false)
  )
  on conflict (provider, provider_event_id) do nothing
  returning id into event_id_value;

  if event_id_value is null then
    select pe.id, pe.refund_required
    into event_id, refund_required
    from public.payment_events pe
    where pe.provider = trim(p_provider)
      and pe.provider_event_id = trim(p_provider_event_id);
    duplicate := true;
    return next;
    return;
  end if;

  event_id := event_id_value;
  duplicate := false;
  refund_required := false;

  if not coalesce(p_signature_valid, false) then
    error_value := 'Provider signature validation failed';
  elsif not payment_found or not order_found then
    error_value := 'No matching payment and order were found';
  elsif payment_row.provider is distinct from trim(p_provider) then
    error_value := 'Provider does not match the payment';
  elsif p_refund_id is not null then
    select * into refund_row
    from public.payment_refunds
    where id = p_refund_id and payment_id = payment_row.id
    for update;
    if not found then
      error_value := 'No matching refund request was found';
    elsif p_refund_status is null
      or p_refund_status not in ('processing', 'succeeded', 'failed', 'cancelled')
    then
      error_value := 'Unsupported provider refund status';
    elsif refund_row.status in ('succeeded', 'cancelled')
      and refund_row.status is distinct from p_refund_status
    then
      error_value := 'Ignored provider event that conflicts with the settled refund status';
    else
      update public.payment_refunds
      set status = p_refund_status,
          provider_refund_id = coalesce(
            nullif(p_payload ->> 'provider_refund_id', ''),
            provider_refund_id
          ),
          processed_at = case
            when p_refund_status in ('succeeded', 'failed', 'cancelled')
              then coalesce(processed_at, now())
            else processed_at
          end
      where id = p_refund_id;

      if p_refund_status = 'succeeded' then
        select coalesce(sum(pr.amount), 0) into refunded_total
        from public.payment_refunds pr
        where pr.payment_id = payment_row.id and pr.status = 'succeeded';
        perform set_config('app.payment_transition', 'on', true);
        if refunded_total >= payment_row.amount
          and payment_row.status = 'cancelled'
        then
          perform set_config('app.late_payment_refund', 'on', true);
        end if;
        update public.payments
        set status = case
              when refunded_total >= payment_row.amount then 'refunded'::public.payment_status
              else 'partially_refunded'::public.payment_status
            end
        where id = payment_row.id
          and (
            status in ('paid', 'partially_refunded')
            or status = 'cancelled' and refunded_total >= payment_row.amount
          );
        perform set_config('app.late_payment_refund', 'off', true);
        perform set_config('app.payment_transition', 'off', true);
      end if;
    end if;
  elsif p_payment_status is null
    or p_payment_status not in ('processing', 'paid', 'failed', 'cancelled')
  then
    error_value := 'Unsupported provider payment status';
  elsif p_payment_status = 'paid'
    and (p_amount is null or p_amount <= 0)
  then
    error_value := 'Captured payment amount is missing or invalid';
  elsif p_payment_status = 'paid'
    and p_amount <> payment_row.amount
  then
    late_payment := true;
    error_value := 'Captured payment amount mismatch requires an automatic refund';
  elsif p_payment_status = 'paid'
    and (
      payment_row.status in ('cancelled', 'failed')
      or order_row.status in ('cancelled', 'failed')
      or (
        order_row.checkout_expires_at is not null
        and order_row.checkout_expires_at <= now()
        and order_row.status in ('pending', 'confirmed')
      )
    )
  then
    late_payment := true;
    error_value := 'Late captured payment requires an automatic refund';
  elsif payment_row.status in ('cancelled', 'failed')
    and payment_row.status is distinct from p_payment_status
  then
    error_value := 'Ignored provider event that conflicts with a terminal payment status';
  elsif payment_row.status in ('paid', 'partially_refunded', 'refunded')
    and payment_row.status is distinct from p_payment_status
  then
    error_value := 'Ignored provider event that conflicts with the settled payment status';
  elsif p_payment_status = 'failed'
    and order_row.status = 'pending'
    and order_row.checkout_expires_at is not null
    and order_row.checkout_expires_at > now()
  then
    -- A single failed attempt inside a live PayMongo checkout session is not
    -- terminal: the customer may retry until the session expires. Keep the
    -- payment open (processing) and let expiry or a later event settle it.
    perform set_config('app.payment_transition', 'on', true);
    update public.payments
    set status = case when status = 'pending' then 'processing'::public.payment_status else status end,
        failure_reason = p_event_type
    where id = p_payment_id;
    perform set_config('app.payment_transition', 'off', true);
  else
    perform set_config('app.payment_transition', 'on', true);
    update public.payments
    set status = p_payment_status,
        provider_payment_id = coalesce(
          nullif(trim(p_provider_payment_id), ''),
          provider_payment_id
        ),
        paid_at = case when p_payment_status = 'paid' then coalesce(paid_at, now()) else paid_at end,
        failed_at = case when p_payment_status = 'failed' then coalesce(failed_at, now()) else failed_at end,
        failure_reason = case when p_payment_status = 'failed' then p_event_type else failure_reason end
    where id = p_payment_id;
    perform set_config('app.payment_transition', 'off', true);
    if p_payment_status = 'paid' then
      -- Restart the station acceptance window from the moment money is captured.
      update public.orders
      set acceptance_expires_at = now() + interval '15 minutes'
      where id = order_row.id;
    end if;
    cancel_order_due_to_payment :=
      p_payment_status in ('failed', 'cancelled')
      and order_row.status in ('pending', 'confirmed', 'preparing', 'ready', 'rider_assigned');
  end if;

  if late_payment
    and order_row.status in ('pending', 'confirmed', 'preparing', 'ready', 'rider_assigned')
  then
    cancel_order_due_to_payment := true;
  end if;

  if cancel_order_due_to_payment then
    order_cancel_reason := case
      when late_payment then 'Late PayMongo capture; automatic refund required'
      else 'PayMongo checkout ' || p_payment_status::text
    end;
    perform set_config(
      'app.order_transition_note',
      order_cancel_reason,
      true
    );
    perform set_config('app.order_transition', 'on', true);
    update public.orders
    set status = 'cancelled',
        cancel_reason = order_cancel_reason,
        cancelled_at = now()
    where id = order_row.id;
    perform set_config('app.order_transition', 'off', true);
    perform set_config('app.order_transition_note', '', true);

    update public.deliveries
    set status = 'cancelled'
    where order_id = order_row.id
      and status not in ('delivered', 'failed', 'cancelled');

    perform set_config('app.release_inventory', 'on', true);
    perform public.release_order_inventory(
      order_row.id, 'Inventory restored after ' || order_cancel_reason
    );
    perform set_config('app.release_inventory', 'off', true);
  end if;

  if late_payment then
    if payment_row.status in ('pending', 'processing') then
      perform set_config('app.payment_transition', 'on', true);
      update public.payments
      set status = 'cancelled',
          provider_payment_id = coalesce(
            nullif(trim(p_provider_payment_id), ''),
            provider_payment_id
          )
      where id = payment_row.id;
      perform set_config('app.payment_transition', 'off', true);
    end if;

    insert into public.payment_refunds (
      payment_id, amount, status, is_automatic, reason, idempotency_key
    )
    values (
      payment_row.id,
      coalesce(p_amount, payment_row.amount),
      'requested',
      true,
      'Automatic refund for late PayMongo capture',
      'late-payment-refund:' || trim(p_provider) || ':' || trim(p_provider_event_id)
    )
    on conflict (idempotency_key) do nothing
    returning id into refund_id_value;

    if refund_id_value is null then
      select pr.id into refund_id_value
      from public.payment_refunds pr
      where pr.idempotency_key =
        'late-payment-refund:' || trim(p_provider) || ':' || trim(p_provider_event_id);
    end if;

    insert into public.payment_provider_actions (
      payment_id, refund_id, action_type, idempotency_key, payload
    )
    values (
      payment_row.id,
      refund_id_value,
      'refund',
      'execute-refund:' || refund_id_value::text,
      jsonb_build_object(
        'provider', payment_row.provider,
        'provider_payment_id', coalesce(
          nullif(trim(p_provider_payment_id), ''),
          payment_row.provider_payment_id
        ),
        'amount', coalesce(p_amount, payment_row.amount),
        'reason', error_value,
        'event_payload', p_payload
      )
    )
    on conflict (idempotency_key) do nothing;
    refund_required := true;
  end if;

  update public.payment_events
  set refund_required = apply_payment_event.refund_required,
      processing_error = error_value,
      processed_at = now()
  where id = event_id_value;

  return next;
end;
$$;

create or replace function public.record_paymongo_checkout(
  p_payment_id uuid,
  p_checkout_id text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  payment_row public.payments%rowtype;
  order_row public.orders%rowtype;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'PayMongo checkout registration is restricted to trusted servers';
  end if;
  if nullif(trim(p_checkout_id), '') is null then
    raise exception 'A PayMongo checkout ID is required';
  end if;

  select * into payment_row
  from public.payments
  where id = p_payment_id
  for update;
  if not found or payment_row.method <> 'paymongo' then
    raise exception 'PayMongo payment was not found';
  end if;
  select * into order_row
  from public.orders
  where id = payment_row.order_id
  for update;
  if not found
    or order_row.status <> 'pending'
    or order_row.checkout_expires_at <= now()
    or payment_row.status not in ('pending', 'processing')
  then
    raise exception 'PayMongo checkout is no longer available';
  end if;
  if payment_row.provider_checkout_id is not null
    and payment_row.provider_checkout_id <> trim(p_checkout_id)
  then
    raise exception 'A different PayMongo checkout is already registered';
  end if;

  update public.payments
  set provider_checkout_id = trim(p_checkout_id)
  where id = p_payment_id;
end;
$$;

create or replace function public.request_refund(
  p_payment_id uuid,
  p_amount numeric,
  p_reason text,
  p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  payment_row public.payments%rowtype;
  refund_id_value uuid;
  refunded_amount numeric(12, 2);
begin
  if not public.has_permission('payments.refund') then
    raise exception 'Payment refund permission is required';
  end if;
  if p_amount is null or p_amount <= 0
    or nullif(trim(p_reason), '') is null
    or nullif(trim(p_idempotency_key), '') is null
  then
    raise exception 'A positive refund amount, reason, and idempotency key are required';
  end if;

  select * into payment_row
  from public.payments
  where id = p_payment_id
  for update;
  if not found then
    raise exception 'Payment was not found';
  end if;

  select pr.id into refund_id_value
  from public.payment_refunds pr
  where pr.idempotency_key = trim(p_idempotency_key);
  if refund_id_value is not null then
    if not exists (
      select 1 from public.payment_refunds pr
      where pr.id = refund_id_value
        and pr.payment_id = p_payment_id
        and pr.amount = p_amount
        and pr.reason = trim(p_reason)
    ) then
      raise exception 'Idempotency key is already used for a different refund request';
    end if;
    return refund_id_value;
  end if;

  if payment_row.status not in ('paid', 'partially_refunded') then
    raise exception 'Only captured payments can be refunded';
  end if;
  if payment_row.provider <> 'paymongo'
    or payment_row.provider_payment_id is null
  then
    raise exception 'This payment cannot be refunded through the PayMongo refund workflow';
  end if;
  select coalesce(sum(pr.amount), 0) into refunded_amount
  from public.payment_refunds pr
  where pr.payment_id = p_payment_id
    and pr.status in ('requested', 'processing', 'succeeded');
  if p_amount > payment_row.amount - refunded_amount then
    raise exception 'Refund amount exceeds the remaining refundable balance';
  end if;

  insert into public.payment_refunds (
    payment_id, requested_by, amount, status, reason, idempotency_key
  )
  values (
    p_payment_id, auth.uid(), p_amount, 'requested',
    trim(p_reason), trim(p_idempotency_key)
  )
  returning id into refund_id_value;

  insert into public.payment_provider_actions (
    payment_id, refund_id, action_type, idempotency_key, payload
  )
  values (
    p_payment_id,
    refund_id_value,
    'refund',
    'execute-refund:' || refund_id_value::text,
    jsonb_build_object(
      'provider', payment_row.provider,
      'provider_payment_id', payment_row.provider_payment_id,
      'amount', p_amount,
      'reason', trim(p_reason)
    )
  );

  return refund_id_value;
end;
$$;

create or replace function public.update_order_status(
  p_order_id uuid,
  p_status public.order_status,
  p_note text default null,
  p_estimated_delivery_at timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  order_row public.orders%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;

  select * into order_row
  from public.orders
  where id = p_order_id
  for update;
  if not found or not public.is_station_member(order_row.station_id) then
    raise exception 'Order was not found for this station';
  end if;
  if p_status in ('cancelled', 'failed') then
    raise exception 'Use the authorized cancellation or failure workflow';
  end if;
  if p_status = 'confirmed'
    and order_row.payment_method = 'paymongo'
    and not exists (
      select 1
      from public.payments p
      where p.order_id = p_order_id
        and p.status = 'paid'
    )
  then
    raise exception 'A PayMongo order cannot be confirmed until its payment is captured';
  end if;
  if p_status = 'out_for_delivery' and not exists (
    select 1 from public.deliveries d
    where d.order_id = p_order_id
      and nullif(trim(d.rider_name), '') is not null
      and nullif(trim(d.rider_phone), '') is not null
  ) then
    raise exception 'Assign a delivery person before marking the order out for delivery';
  end if;

  -- The note is stored in order_status_history so the station and the customer
  -- can both see it on the order timeline.
  perform set_config('app.order_transition_note', coalesce(nullif(trim(p_note), ''), ''), true);
  perform set_config('app.order_transition', 'on', true);
  update public.orders
  set status = p_status,
      accepted_at = case when p_status = 'confirmed' then now() else accepted_at end,
      delivered_at = case when p_status = 'delivered' then now() else delivered_at end,
      estimated_delivery_at = coalesce(p_estimated_delivery_at, estimated_delivery_at)
  where id = p_order_id;
  perform set_config('app.order_transition', 'off', true);
  perform set_config('app.order_transition_note', '', true);

  if p_status in ('rider_assigned', 'out_for_delivery', 'delivered') then
    update public.deliveries
    set status = case p_status
          when 'rider_assigned' then 'assigned'::public.delivery_status
          when 'out_for_delivery' then 'out_for_delivery'::public.delivery_status
          else 'delivered'::public.delivery_status
        end,
        delivered_at = case when p_status = 'delivered' then now() else delivered_at end
    where order_id = p_order_id;
  end if;
end;
$$;

create or replace function public.assign_delivery_person(
  p_order_id uuid,
  p_name text,
  p_phone text,
  p_estimated_delivery_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  order_row public.orders%rowtype;
  delivery_id_value uuid;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  if nullif(trim(p_name), '') is null or nullif(trim(p_phone), '') is null then
    raise exception 'Delivery person name and phone are required';
  end if;

  select * into order_row
  from public.orders
  where id = p_order_id
  for update;
  if not found or not public.is_station_member(order_row.station_id) then
    raise exception 'Order was not found for this station';
  end if;
  if order_row.status not in ('ready', 'rider_assigned', 'out_for_delivery') then
    raise exception 'A delivery person can only be assigned to a ready or active delivery order';
  end if;

  insert into public.deliveries as existing_delivery (
    order_id, station_id, status, rider_name, rider_phone, assigned_at
  )
  values (
    p_order_id, order_row.station_id, 'assigned',
    trim(p_name), trim(p_phone), now()
  )
  on conflict (order_id) do update
    set status = case
          when order_row.status = 'out_for_delivery' then 'out_for_delivery'::public.delivery_status
          else 'assigned'::public.delivery_status
        end,
        rider_name = excluded.rider_name,
        rider_phone = excluded.rider_phone,
        assigned_at = coalesce(existing_delivery.assigned_at, now())
  returning id into delivery_id_value;

  if order_row.status = 'ready' then
    perform set_config('app.order_transition', 'on', true);
    perform set_config('app.order_transition_note', 'Delivery person assigned', true);
    update public.orders
    set status = 'rider_assigned',
        estimated_delivery_at = coalesce(p_estimated_delivery_at, estimated_delivery_at)
    where id = p_order_id;
    perform set_config('app.order_transition', 'off', true);
    perform set_config('app.order_transition_note', '', true);
  elsif p_estimated_delivery_at is not null then
    update public.orders
    set estimated_delivery_at = p_estimated_delivery_at
    where id = p_order_id;
  end if;

  return delivery_id_value;
end;
$$;

create or replace function public.assign_delivery_rider(
  p_order_id uuid,
  p_rider_id uuid,
  p_rider_name text,
  p_rider_phone text,
  p_estimated_delivery_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  order_row public.orders%rowtype;
  delivery_id_value uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required';
  end if;
  if p_rider_id is null
    or not public.has_role(p_rider_id, 'rider'::public.app_role)
    or not exists (
      select 1 from public.profiles p
      where p.id = p_rider_id and p.status = 'active'
    )
  then
    raise exception 'An active rider account is required';
  end if;

  select * into order_row
  from public.orders
  where id = p_order_id
  for update;
  if not found or not public.is_station_manager(order_row.station_id) then
    raise exception 'Order was not found for this station';
  end if;

  delivery_id_value := public.assign_delivery_person(
    p_order_id, p_rider_name, p_rider_phone, p_estimated_delivery_at
  );
  update public.deliveries
  set rider_id = p_rider_id
  where id = delivery_id_value;

  return delivery_id_value;
end;
$$;

create or replace function public.update_delivery_location(
  p_delivery_id uuid,
  p_latitude double precision,
  p_longitude double precision,
  p_accuracy_m numeric default null,
  p_heading_degrees numeric default null,
  p_speed_mps numeric default null,
  p_recorded_at timestamptz default now()
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  delivery_row public.deliveries%rowtype;
  tracking_id_value uuid;
begin
  if auth.uid() is null
    or not public.has_permission('delivery.track')
    or not exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.status = 'active'
    )
  then
    raise exception 'An authenticated rider account is required';
  end if;
  if p_latitude is null or p_latitude not between -90 and 90
    or p_longitude is null or p_longitude not between -180 and 180
    or p_accuracy_m is not null and p_accuracy_m < 0
    or p_heading_degrees is not null and p_heading_degrees not between 0 and 360
    or p_speed_mps is not null and p_speed_mps < 0
    or p_recorded_at is null
    or p_recorded_at < now() - interval '24 hours'
    or p_recorded_at > now() + interval '5 minutes'
  then
    raise exception 'Invalid delivery tracking location or metadata';
  end if;

  select * into delivery_row
  from public.deliveries
  where id = p_delivery_id
    and rider_id = auth.uid()
  for update;
  if not found or delivery_row.status not in ('assigned', 'picked_up', 'out_for_delivery') then
    raise exception 'No active delivery is assigned to this rider';
  end if;

  insert into public.delivery_tracking (
    delivery_id, rider_id, latitude, longitude, location,
    accuracy_m, heading_degrees, speed_mps, recorded_at
  )
  values (
    p_delivery_id, auth.uid(), p_latitude, p_longitude,
    extensions.st_setsrid(
      extensions.st_makepoint(p_longitude, p_latitude), 4326
    )::extensions.geography,
    p_accuracy_m, p_heading_degrees, p_speed_mps, p_recorded_at
  )
  returning id into tracking_id_value;

  return tracking_id_value;
end;
$$;

create or replace function public.set_delivery_proof(
  p_order_id uuid,
  p_storage_path text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  delivery_row public.deliveries%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required';
  end if;
  if nullif(trim(p_storage_path), '') is null
    or split_part(p_storage_path, '/', 1) <> p_order_id::text
    or not exists (
      select 1
      from storage.objects so
      where so.bucket_id = 'delivery-proofs'
        and so.name = trim(p_storage_path)
    )
  then
    raise exception 'Upload the proof under the order ID before linking it';
  end if;

  select * into delivery_row
  from public.deliveries d
  where d.order_id = p_order_id;
  if not found or not (
    (
      public.is_station_member(delivery_row.station_id)
      and public.is_order_party(p_order_id)
    )
    or (
      delivery_row.rider_id = auth.uid()
      and public.has_permission('delivery.track')
    )
  ) then
    raise exception 'Order was not found for this station';
  end if;

  update public.deliveries
  set proof_storage_path = trim(p_storage_path)
  where order_id = p_order_id;
  if not found then
    raise exception 'Delivery record was not found';
  end if;
end;
$$;

create or replace function public.get_station_order_payment_status(p_order_id uuid)
returns table (
  order_id uuid,
  payment_method public.payment_method,
  payment_status public.payment_status,
  amount numeric(12, 2),
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication is required';
  end if;

  return query
  select p.order_id, p.method, p.status, p.amount, p.updated_at
  from public.payments p
  join public.orders o on o.id = p.order_id
  where p.order_id = p_order_id
    and public.is_station_member(o.station_id);
end;
$$;

create or replace function public.get_customer_order_station(p_order_id uuid)
returns table (
  station_id uuid,
  display_name text,
  logo_path text,
  phone text,
  email text,
  address_line text,
  barangay text,
  city text,
  province text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  snapshot jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required';
  end if;

  select o.station_id, o.station_snapshot
  into station_id, snapshot
  from public.orders o
  where o.id = p_order_id
    and public.is_order_party(o.id);
  if not found then
    raise exception 'Order was not found';
  end if;

  display_name := snapshot ->> 'display_name';
  logo_path := snapshot ->> 'logo_path';
  phone := snapshot ->> 'phone';
  email := snapshot ->> 'email';
  address_line := snapshot ->> 'address_line';
  barangay := snapshot ->> 'barangay';
  city := snapshot ->> 'city';
  province := snapshot ->> 'province';
  return next;
end;
$$;

create or replace function public.record_cod_collection(
  p_order_id uuid,
  p_amount numeric(12, 2),
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  order_row public.orders%rowtype;
  payment_row public.payments%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;

  select * into order_row
  from public.orders
  where id = p_order_id
  for update;
  if not found or not (
    public.is_station_member(order_row.station_id)
    or exists (
      select 1 from public.deliveries d
      where d.order_id = p_order_id
        and d.rider_id = auth.uid()
        and public.has_permission('delivery.track')
    )
  ) then
    raise exception 'Order was not found for this station or rider';
  end if;
  if order_row.payment_method <> 'cod' then
    raise exception 'Only cash-on-delivery orders can record cash collection';
  end if;
  if order_row.status <> 'delivered' then
    raise exception 'COD can only be collected for a delivered order';
  end if;

  select * into payment_row
  from public.payments
  where order_id = p_order_id
  for update;
  if not found or payment_row.status <> 'pending' then
    raise exception 'Payment is not awaiting COD collection';
  end if;
  if p_amount <> payment_row.amount then
    raise exception 'Collected amount must match the order total';
  end if;

  perform set_config('app.payment_transition', 'on', true);
  update public.payments
  set status = 'paid', paid_at = now()
  where id = payment_row.id;
  perform set_config('app.payment_transition', 'off', true);

  insert into public.admin_audit_logs (
    actor_id, action, entity_type, entity_id, after_data
  )
  values (
    auth.uid(), 'cod_collection_recorded', 'payment', payment_row.id,
    jsonb_build_object('order_id', p_order_id, 'amount', p_amount, 'note', p_note)
  );

  return payment_row.id;
end;
$$;

create or replace function public.adjust_inventory(
  p_product_id uuid,
  p_quantity_change integer,
  p_movement_type text,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  product_row public.station_products%rowtype;
  movement_id uuid;
  new_stock integer;
begin
  if auth.uid() is null then raise exception 'Authentication is required'; end if;
  if p_quantity_change = 0 then raise exception 'Inventory adjustment cannot be zero'; end if;
  if p_movement_type not in ('stock_in', 'adjustment', 'return', 'damage') then
    raise exception 'Invalid inventory movement type';
  end if;

  select * into product_row
  from public.station_products
  where id = p_product_id
  for update;
  if not found or not public.is_station_member(product_row.station_id) then
    raise exception 'Product was not found for this station';
  end if;
  if product_row.stock_quantity is null then
    raise exception 'This product does not use tracked inventory';
  end if;

  new_stock := product_row.stock_quantity + p_quantity_change;
  if new_stock < 0 then raise exception 'Inventory cannot be negative'; end if;

  perform set_config('app.inventory_update', 'on', true);
  update public.station_products
  set stock_quantity = new_stock
  where id = p_product_id;
  perform set_config('app.inventory_update', 'off', true);

  insert into public.station_inventory_movements (
    station_id, product_id, movement_type, quantity_change, notes, created_by
  )
  values (
    product_row.station_id, p_product_id, p_movement_type,
    p_quantity_change, p_notes, auth.uid()
  )
  returning id into movement_id;

  return movement_id;
end;
$$;

create or replace function public.create_station_staff_invite(
  p_station_id uuid,
  p_email text,
  p_staff_role text,
  p_token_hash text,
  p_expires_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  invite_id uuid;
begin
  if not public.is_station_manager(p_station_id) then
    raise exception 'Station manager permission is required';
  end if;
  if p_staff_role not in ('manager', 'staff')
    or nullif(trim(p_email), '') is null
    or nullif(trim(p_token_hash), '') is null
    or p_expires_at <= now()
  then
    raise exception 'Invalid station staff invitation';
  end if;

  insert into public.station_staff_invites (
    station_id, email, staff_role, invited_by, invite_token_hash, expires_at
  )
  values (
    p_station_id, lower(trim(p_email)), p_staff_role, auth.uid(),
    p_token_hash, p_expires_at
  )
  returning id into invite_id;

  return invite_id;
end;
$$;

create or replace function public.accept_station_staff_invite(p_token_hash text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  invite_row public.station_staff_invites%rowtype;
  account_email text;
begin
  if actor_id is null then raise exception 'Authentication is required'; end if;

  select lower(u.email) into account_email
  from auth.users u
  where u.id = actor_id;
  if not exists (
    select 1
    from auth.users u
    where u.id = actor_id
      and u.email_confirmed_at is not null
  ) then
    raise exception 'Confirm your email before accepting a station staff invitation';
  end if;

  select * into invite_row
  from public.station_staff_invites
  where invite_token_hash = p_token_hash
    and accepted_at is null
    and expires_at > now()
  for update;
  if not found or invite_row.email <> account_email then
    raise exception 'Invitation is invalid, expired, or belongs to another email';
  end if;

  insert into public.station_staff (station_id, user_id, staff_role, status, invited_by)
  values (invite_row.station_id, actor_id, invite_row.staff_role, 'active', invite_row.invited_by)
  on conflict (station_id, user_id) do update
    set staff_role = excluded.staff_role, status = 'active';

  update public.station_staff_invites
  set accepted_at = now()
  where id = invite_row.id;

  insert into public.user_roles (user_id, role)
  values (actor_id, 'station_staff'::public.app_role)
  on conflict (user_id, role) do nothing;

  return invite_row.station_id;
end;
$$;

create or replace function public.protect_profile_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status is distinct from old.status
    and coalesce(auth.role(), '') <> 'service_role'
    and not public.has_permission('customer.suspend')
  then
    raise exception 'Only an authorized administrator can change profile status';
  end if;

  return new;
end;
$$;

create or replace function public.set_customer_status(
  p_user_id uuid,
  p_status public.profile_status,
  p_reason text default null,
  p_actor_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_status public.profile_status;
  actor_id_value uuid := coalesce(p_actor_id, auth.uid());
begin
  if coalesce(auth.role(), '') = 'service_role' then
    if p_actor_id is null or not exists (
      select 1
      from public.user_roles ur
      join public.admin_permissions ap on ap.role = ur.role
      where ur.user_id = p_actor_id
        and ap.permission_key = 'customer.suspend'
    ) then
      raise exception 'Customer management permission is required';
    end if;
  elsif not public.has_permission('customer.suspend') then
    raise exception 'Customer management permission is required';
  end if;
  if p_user_id is null or p_user_id = actor_id_value then
    raise exception 'A different customer account must be selected';
  end if;

  select status into old_status
  from public.profiles
  where id = p_user_id
  for update;
  if not found then
    raise exception 'Customer profile was not found';
  end if;

  update public.profiles
  set status = p_status
  where id = p_user_id;

  insert into public.admin_audit_logs (
    actor_id, action, entity_type, entity_id, before_data, after_data
  )
  values (
    actor_id_value,
    'customer_status_changed',
    'profile',
    p_user_id,
    jsonb_build_object('status', old_status),
    jsonb_build_object('status', p_status, 'reason', p_reason)
  );
end;
$$;

create or replace function public.bootstrap_first_admin(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'First administrator bootstrap is restricted to a trusted server';
  end if;
  if p_user_id is null or not exists (
    select 1 from auth.users u where u.id = p_user_id
  ) then
    raise exception 'Select an existing authenticated user for administrator access';
  end if;
  if exists (
    select 1
    from public.user_roles ur
    where ur.role = 'admin'
  ) then
    raise exception 'An administrator is already assigned; use the audited role-management workflow';
  end if;

  insert into public.user_roles (user_id, role)
  values (p_user_id, 'admin'::public.app_role)
  on conflict (user_id, role) do nothing;
end;
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', '')
  )
  on conflict (id) do nothing;

  insert into public.user_roles (user_id, role)
  values (new.id, 'customer'::public.app_role)
  on conflict (user_id, role) do nothing;

  if new.email is not null then
    insert into public.customer_email_access (user_id, email)
    values (new.id, lower(new.email))
    on conflict (user_id) do update
      set email = excluded.email, updated_at = now();
  end if;

  return new;
end;
$$;

create or replace function public.sync_customer_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.email is null then
    delete from public.customer_email_access where user_id = new.id;
  else
    insert into public.customer_email_access (user_id, email)
    values (new.id, lower(new.email))
    on conflict (user_id) do update
      set email = excluded.email, updated_at = now();
  end if;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create trigger on_auth_user_email_updated
  after update of email on auth.users
  for each row
  when (old.email is distinct from new.email)
  execute function public.sync_customer_email();

create trigger protect_station_admin_fields
  before update on public.stations
  for each row execute function public.protect_station_admin_fields();

create trigger protect_profile_status
  before update on public.profiles
  for each row execute function public.protect_profile_status();

create trigger protect_application_update
  before update on public.station_applications
  for each row execute function public.protect_application_update();

create trigger sync_station_application_details
  after update of legal_business_name, display_name, email, phone, address_line,
    barangay, city, province, region, postal_code, latitude, longitude
  on public.station_applications
  for each row execute function public.sync_station_application_details();

create trigger protect_station_document_review
  before insert or update on public.station_documents
  for each row execute function public.protect_station_document_review();

create trigger prevent_direct_stock_update
  before update of stock_quantity on public.station_products
  for each row execute function public.prevent_direct_stock_update();

create trigger record_initial_product_stock
  after insert on public.station_products
  for each row execute function public.record_initial_product_stock();

create trigger enforce_application_transition
  before update of application_status on public.station_applications
  for each row execute function public.enforce_application_transition();

create trigger log_application_status_change
  after update of application_status on public.station_applications
  for each row
  when (old.application_status is distinct from new.application_status)
  execute function public.log_application_status_change();

create trigger enforce_order_transition
  before update of status on public.orders
  for each row execute function public.enforce_order_transition();

create trigger log_initial_order_status
  after insert on public.orders
  for each row execute function public.log_initial_order_status();

create trigger enforce_payment_transition
  before update of status on public.payments
  for each row execute function public.enforce_payment_transition();

create trigger enforce_review_owner_update
  before insert or update on public.station_reviews
  for each row execute function public.enforce_review_owner_update();

create trigger audit_role_changes
  after insert or update or delete on public.user_roles
  for each row execute function public.audit_sensitive_table_change();

create trigger audit_permission_changes
  after insert or update or delete on public.admin_permissions
  for each row execute function public.audit_sensitive_table_change();

create trigger audit_water_type_changes
  after insert or update or delete on public.water_types
  for each row execute function public.audit_sensitive_table_change();

create trigger audit_container_type_changes
  after insert or update or delete on public.container_types
  for each row execute function public.audit_sensitive_table_change();

create trigger audit_product_changes
  after insert or delete or update of
    water_type_id, container_type_id, name, description, refill_available,
    refill_price, new_container_available, new_container_price, deposit_amount,
    requires_empty_container, return_policy, max_order_quantity, status, image_path
  on public.station_products
  for each row execute function public.audit_sensitive_table_change();

create trigger audit_product_image_changes
  after insert or update or delete on public.station_product_images
  for each row execute function public.audit_sensitive_table_change();

create trigger audit_review_moderation
  after insert or update or delete on public.station_reviews
  for each row execute function public.audit_sensitive_table_change();

create trigger update_station_rating_from_review
  after insert or update or delete on public.station_reviews
  for each row execute function public.update_station_rating_from_review();

create trigger protect_notification_update
  before update on public.notifications
  for each row execute function public.protect_notification_update();

create trigger notify_station_of_new_order
  after insert on public.orders
  for each row execute function public.notify_order_activity();

create trigger notify_customer_of_order_status
  after update of status on public.orders
  for each row
  when (old.status is distinct from new.status)
  execute function public.notify_order_activity();

create trigger prevent_audit_log_mutation
  before update or delete on public.admin_audit_logs
  for each row execute function public.prevent_audit_log_mutation();

create trigger record_station_status_change
  after update of verification_status, publication_status, operational_status
  on public.stations
  for each row
  when (
    old.verification_status is distinct from new.verification_status
    or old.publication_status is distinct from new.publication_status
    or old.operational_status is distinct from new.operational_status
  )
  execute function public.record_station_status_change();

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'profiles',
    'addresses',
    'user_preferences',
    'station_applications',
    'stations',
    'station_staff',
    'station_operating_hours',
    'station_delivery_zones',
    'water_types',
    'container_types',
    'station_products',
    'container_policies',
    'carts',
    'cart_items',
    'orders',
    'deliveries',
    'station_reviews',
    'payments',
    'payment_refunds',
    'support_tickets'
  ]
  loop
    execute format(
      'create trigger set_updated_at before update on public.%I for each row execute function public.set_updated_at()',
      table_name
    );
  end loop;
end;
$$;

alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;
alter table public.admin_permissions enable row level security;
alter table public.addresses enable row level security;
alter table public.user_preferences enable row level security;
alter table public.user_devices enable row level security;
alter table public.station_applications enable row level security;
alter table public.station_application_status_history enable row level security;
alter table public.customer_email_access enable row level security;
alter table public.stations enable row level security;
alter table public.station_staff enable row level security;
alter table public.station_staff_invites enable row level security;
alter table public.station_documents enable row level security;
alter table public.station_document_requirements enable row level security;
alter table public.station_document_type_catalog enable row level security;
alter table public.verification_reviews enable row level security;
alter table public.station_operating_hours enable row level security;
alter table public.station_delivery_zones enable row level security;
alter table public.station_status_history enable row level security;
alter table public.water_types enable row level security;
alter table public.container_types enable row level security;
alter table public.station_products enable row level security;
alter table public.station_product_images enable row level security;
alter table public.container_policies enable row level security;
alter table public.station_inventory_movements enable row level security;
alter table public.saved_stations enable row level security;
alter table public.carts enable row level security;
alter table public.cart_items enable row level security;
alter table public.orders enable row level security;
alter table public.station_order_dismissals enable row level security;
alter table public.customer_order_dismissals enable row level security;
alter table public.order_items enable row level security;
alter table public.order_status_history enable row level security;
alter table public.deliveries enable row level security;
alter table public.delivery_tracking enable row level security;
alter table public.station_reviews enable row level security;
alter table public.notifications enable row level security;
alter table public.payments enable row level security;
alter table public.payment_events enable row level security;
alter table public.payment_refunds enable row level security;
alter table public.payment_provider_actions enable row level security;
alter table public.support_tickets enable row level security;
alter table public.support_messages enable row level security;
alter table public.admin_audit_logs enable row level security;

create policy "Profiles are viewable by owner and admins"
  on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select public.is_admin()));
create policy "Support staff view customer profiles"
  on public.profiles for select to authenticated
  using ((select public.has_permission('customer.read')));
create policy "Users update their own profile"
  on public.profiles for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

create policy "Users view their assigned roles"
  on public.user_roles for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));
create policy "Admins manage user roles"
  on public.user_roles for all to authenticated
  using ((select public.has_permission('roles.manage')))
  with check ((select public.has_permission('roles.manage')));

create policy "Admins view permissions"
  on public.admin_permissions for select to authenticated
  using ((select public.has_permission('admin.access')));
create policy "Admins manage permissions"
  on public.admin_permissions for all to authenticated
  using ((select public.has_permission('roles.manage')))
  with check ((select public.has_permission('roles.manage')));

create policy "Customers manage their addresses"
  on public.addresses for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
create policy "Customer managers view addresses"
  on public.addresses for select to authenticated
  using ((select public.has_permission('customer.read')));

create policy "Users manage their preferences"
  on public.user_preferences for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
create policy "Customer managers view preferences"
  on public.user_preferences for select to authenticated
  using ((select public.has_permission('customer.read')));

create policy "Users view their devices"
  on public.user_devices for select to authenticated
  using (user_id = (select auth.uid()));
create policy "Customer managers view devices"
  on public.user_devices for select to authenticated
  using ((select public.has_permission('customer.read')));

create policy "Applicants view their applications"
  on public.station_applications for select to authenticated
  using (owner_id = (select auth.uid()) or (select public.is_admin()));
create policy "Reviewers view station applications"
  on public.station_applications for select to authenticated
  using (owner_id = (select auth.uid()) or (select public.has_permission('station.review')));
create policy "Applicants edit application details"
  on public.station_applications for update to authenticated
  using (
    owner_id = (select auth.uid())
    and application_status in ('draft', 'changes_requested')
  )
  with check (
    owner_id = (select auth.uid())
    and application_status in ('draft', 'changes_requested')
  );
create policy "Application participants view status history"
  on public.station_application_status_history for select to authenticated
  using (
    exists (
      select 1 from public.station_applications a
      where a.id = application_id and a.owner_id = (select auth.uid())
    )
    or (select public.has_permission('station.review'))
  );
create policy "Applicants and reviewers view document requirements"
  on public.station_document_requirements for select to authenticated
  using (
    exists (
      select 1 from public.station_applications a
      where a.id = application_id and a.owner_id = (select auth.uid())
    )
    or (select public.has_permission('station.review'))
  );
create policy "Administrators manage document type catalog"
  on public.station_document_type_catalog for all to authenticated
  using ((select public.has_permission('catalog.manage')))
  with check ((select public.has_permission('catalog.manage')));
create policy "Authorized staff view customer emails"
  on public.customer_email_access for select to authenticated
  using ((select public.has_permission('customer.email.view')));

create policy "Station members view their station"
  on public.stations for select to authenticated
  using (
    (select public.is_station_member(id))
    or (select public.has_permission('station.review'))
    or (select public.is_admin())
  );
create policy "Station owners update station details"
  on public.stations for update to authenticated
  using (public.is_station_owner(id))
  with check (public.is_station_owner(id));
create policy "Station members view all products"
  on public.station_products for select to authenticated
  using ((select public.is_station_member(station_id)));
create policy "Station staff view their memberships"
  on public.station_staff for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_station_member(station_id))
    or (select public.is_admin()));
create policy "Station managers manage station staff"
  on public.station_staff for all to authenticated
  using (public.is_station_manager(station_id))
  with check (public.is_station_manager(station_id));
create policy "Authorized administrators manage station staff"
  on public.station_staff for all to authenticated
  using ((select public.has_permission('station.staff.manage')))
  with check ((select public.has_permission('station.staff.manage')));

create policy "Station managers view staff invites"
  on public.station_staff_invites for select to authenticated
  using (public.is_station_manager(station_id));

create policy "Applicants and admins view station documents"
  on public.station_documents for select to authenticated
  using (
    exists (
      select 1 from public.station_applications a
      where a.id = application_id and a.owner_id = (select auth.uid())
    )
    or (select public.has_permission('station.review'))
  );
create policy "Applicants upload documents to their editable application"
  on public.station_documents for insert to authenticated
  with check (
    submitted_by = (select auth.uid())
    and review_status = 'pending'
    and exists (
      select 1 from public.station_applications a
      where a.id = application_id
        and a.owner_id = (select auth.uid())
        and a.application_status in ('draft', 'changes_requested')
        and exists (
          select 1 from public.station_document_requirements r
          where r.application_id = a.id
            and r.document_type = public.station_documents.document_type
        )
    )
    and is_current
  );
create policy "Applicants and admins view verification reviews"
  on public.verification_reviews for select to authenticated
  using (
    (select public.has_permission('station.review'))
    or exists (
      select 1 from public.station_applications a
      where a.id = application_id and a.owner_id = (select auth.uid())
    )
  );
create policy "Station operating hours are public for published stations"
  on public.station_operating_hours for select to anon, authenticated
  using ((select public.is_public_station(station_id)));
create policy "Station members view operating hours"
  on public.station_operating_hours for select to authenticated
  using ((select public.is_station_member(station_id)));
create policy "Station managers manage operating hours"
  on public.station_operating_hours for all to authenticated
  using (public.is_station_manager(station_id))
  with check (public.is_station_manager(station_id));

create policy "Active delivery zones are visible"
  on public.station_delivery_zones for select to anon, authenticated
  using (is_active and (select public.is_public_station(station_id)));
create policy "Station members view delivery zones"
  on public.station_delivery_zones for select to authenticated
  using ((select public.is_station_member(station_id)));
create policy "Station managers manage delivery zones"
  on public.station_delivery_zones for all to authenticated
  using (public.is_station_manager(station_id))
  with check (public.is_station_manager(station_id));

create policy "Station members and admins view station status history"
  on public.station_status_history for select to authenticated
  using ((select public.is_station_member(station_id)) or (select public.is_admin()));
create policy "Active water types are visible"
  on public.water_types for select to anon, authenticated using (is_active);
create policy "Admins manage water types"
  on public.water_types for all to authenticated
  using ((select public.has_permission('catalog.manage')))
  with check ((select public.has_permission('catalog.manage')));

create policy "Active container types are visible"
  on public.container_types for select to anon, authenticated using (is_active);
create policy "Admins manage container types"
  on public.container_types for all to authenticated
  using ((select public.has_permission('catalog.manage')))
  with check ((select public.has_permission('catalog.manage')));

create policy "Eligible station products are discoverable"
  on public.station_products for select to anon, authenticated
  using (
    status = 'active'
    and (select public.is_public_station(station_id))
  );
create policy "Station members manage products"
  on public.station_products for all to authenticated
  using (public.is_station_manager(station_id))
  with check (public.is_station_manager(station_id));
create policy "Station reviewers view all station products"
  on public.station_products for select to authenticated
  using ((select public.has_permission('station.review')));

create policy "Product images follow product visibility"
  on public.station_product_images for select to anon, authenticated
  using (exists (
    select 1 from public.station_products p
    where p.id = product_id
      and p.status = 'active'
      and (select public.is_public_station(p.station_id))
  ));
create policy "Station members view all product images"
  on public.station_product_images for select to authenticated
  using (exists (
    select 1 from public.station_products p
    where p.id = product_id
      and (select public.is_station_member(p.station_id))
  ));
create policy "Station members manage product images"
  on public.station_product_images for all to authenticated
  using (
    exists (
      select 1 from public.station_products p
      where p.id = product_id and public.is_station_manager(p.station_id)
    )
    or (select public.is_admin())
  )
  with check (
    exists (
      select 1 from public.station_products p
      where p.id = product_id and public.is_station_manager(p.station_id)
    )
    or (select public.has_permission('station.review'))
  );

create policy "Station managers manage container policies"
  on public.container_policies for all to authenticated
  using (public.is_station_manager(station_id))
  with check (public.is_station_manager(station_id));

create policy "Station members and admins view inventory movements"
  on public.station_inventory_movements for select to authenticated
  using ((select public.is_station_member(station_id)) or (select public.is_admin()));
create policy "Users manage their saved stations"
  on public.saved_stations for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
create policy "Customer managers view saved stations"
  on public.saved_stations for select to authenticated
  using ((select public.has_permission('customer.read')));

create policy "Users manage their carts"
  on public.carts for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
create policy "Customer managers view carts"
  on public.carts for select to authenticated
  using ((select public.has_permission('customer.read')));
create policy "Users manage items in their carts"
  on public.cart_items for all to authenticated
  using (exists (
    select 1 from public.carts c
    where c.id = cart_id and c.user_id = (select auth.uid())
  ))
  with check (exists (
    select 1 from public.carts c
    where c.id = cart_id and c.user_id = (select auth.uid())
  ));
create policy "Customer managers view cart items"
  on public.cart_items for select to authenticated
  using ((select public.has_permission('customer.read')));

create policy "Customers station members and admins view orders"
  on public.orders for select to authenticated
  using (
    customer_id = (select auth.uid())
    or (select public.is_station_member(station_id))
    or public.is_order_party(id)
    or (select public.is_admin())
    or (select public.has_permission('support.manage'))
    or (select public.has_permission('payments.view'))
  );

create policy "Customers view their order dismissals"
  on public.customer_order_dismissals for select to authenticated
  using (user_id = (select auth.uid()));
create policy "Customers dismiss their cancelled orders"
  on public.customer_order_dismissals for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1
      from public.orders o
      where o.id = order_id
        and o.customer_id = (select auth.uid())
        and o.status = 'cancelled'
    )
  );

create policy "Order parties view order items"
  on public.order_items for select to authenticated
  using (
    public.is_order_party(order_id)
    or exists (
      select 1
      from public.orders o
      where o.id = order_id
        and (select public.is_station_member(o.station_id))
    )
    or (select public.is_admin())
    or (select public.has_permission('support.manage'))
    or (select public.has_permission('payments.view'))
  );

create policy "Order parties view status history"
  on public.order_status_history for select to authenticated
  using (
    public.is_order_party(order_id)
    or (select public.is_admin())
    or (select public.has_permission('support.manage'))
    or (select public.has_permission('payments.view'))
  );
create policy "Delivery parties view deliveries"
  on public.deliveries for select to authenticated
  using (
    public.is_order_party(order_id)
    or (select public.is_admin())
    or (select public.has_permission('support.manage'))
    or (select public.has_permission('payments.view'))
  );
create policy "Delivery parties and assigned riders view tracking"
  on public.delivery_tracking for select to authenticated
  using (
    (rider_id = (select auth.uid())
      and (select public.has_permission('delivery.track')))
    or exists (
      select 1
      from public.deliveries d
      join public.orders o on o.id = d.order_id
      where d.id = public.delivery_tracking.delivery_id
        and (
          o.customer_id = (select auth.uid())
          or public.is_order_party(o.id)
          or (select public.has_permission('admin.access'))
          or (select public.has_permission('support.manage'))
        )
    )
  );

create policy "Customers view their own reviews"
  on public.station_reviews for select to authenticated
  using (
    customer_id = (select auth.uid())
    or (select public.has_permission('reviews.moderate'))
  );
create policy "Station members view station reviews"
  on public.station_reviews for select to authenticated
  using ((select public.is_station_member(station_id)));
create policy "Customers review their delivered orders"
  on public.station_reviews for insert to authenticated
  with check (
    customer_id = (select auth.uid())
    and is_visible
    and exists (
      select 1 from public.orders o
      where o.id = public.station_reviews.order_id
        and o.customer_id = (select auth.uid())
        and o.station_id = public.station_reviews.station_id
        and o.status = 'delivered'
    )
  );
create policy "Customers edit their own reviews"
  on public.station_reviews for update to authenticated
  using (customer_id = (select auth.uid()))
  with check (
    customer_id = (select auth.uid())
    and exists (
      select 1 from public.orders o
      where o.id = public.station_reviews.order_id
        and o.customer_id = (select auth.uid())
        and o.station_id = public.station_reviews.station_id
        and o.status = 'delivered'
    )
  );
create policy "Admins moderate station reviews"
  on public.station_reviews for select to authenticated
  using ((select public.has_permission('reviews.moderate')));
create policy "Authorized admins update review visibility"
  on public.station_reviews for update to authenticated
  using ((select public.has_permission('reviews.moderate')))
  with check ((select public.has_permission('reviews.moderate')));

create policy "Users view and mark their notifications"
  on public.notifications for select to authenticated
  using (user_id = (select auth.uid()) or (select public.has_permission('notifications.view')));
create policy "Users mark their notifications read"
  on public.notifications for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "Customers and finance staff view payments"
  on public.payments for select to authenticated
  using (
    customer_id = (select auth.uid())
    or (select public.has_permission('payments.view'))
    or (select public.has_permission('admin.access'))
  );

create policy "Finance staff and admins view payment events"
  on public.payment_events for select to authenticated
  using (
    (select public.has_permission('payments.view'))
    or (select public.has_permission('admin.access'))
  );

create policy "Finance staff and admins view refunds"
  on public.payment_refunds for select to authenticated
  using (
    (select public.has_permission('payments.view'))
    or (select public.has_permission('admin.access'))
  );

create policy "Ticket participants view support tickets"
  on public.support_tickets for select to authenticated
  using (
    requester_id = (select auth.uid())
    or (assigned_to = (select auth.uid()))
    or (station_id is not null and (select public.is_station_member(station_id)))
    or (select public.has_permission('support.manage'))
  );
create policy "Customers create their own tickets"
  on public.support_tickets for insert to authenticated
  with check (
    requester_id = (select auth.uid())
    and status = 'open'
    and assigned_to is null
    and resolved_at is null
    and (
      (
        order_id is null
        and (
          station_id is null
          or (select public.is_public_station(station_id))
        )
      )
      or exists (
        select 1
        from public.orders o
        where o.id = public.support_tickets.order_id
          and o.customer_id = (select auth.uid())
          and (
            public.support_tickets.station_id is null
            or public.support_tickets.station_id = o.station_id
          )
      )
    )
  );
create policy "Support staff manage support tickets"
  on public.support_tickets for update to authenticated
  using ((select public.has_permission('support.manage')))
  with check ((select public.has_permission('support.manage')));

create policy "Ticket participants view messages"
  on public.support_messages for select to authenticated
  using (exists (
    select 1 from public.support_tickets t
    where t.id = ticket_id
      and (
        t.requester_id = (select auth.uid())
        or t.assigned_to = (select auth.uid())
        or (t.station_id is not null and (select public.is_station_member(t.station_id)))
        or (select public.has_permission('support.manage'))
      )
  ));
create policy "Ticket participants send messages"
  on public.support_messages for insert to authenticated
  with check (
    sender_id = (select auth.uid())
    and exists (
      select 1 from public.support_tickets t
      where t.id = ticket_id
        and (
          t.requester_id = (select auth.uid())
          or t.assigned_to = (select auth.uid())
          or (t.station_id is not null and (select public.is_station_member(t.station_id)))
          or (select public.has_permission('support.manage'))
        )
    )
  );

create policy "Admins view audit logs"
  on public.admin_audit_logs for select to authenticated
  using ((select public.has_permission('admin.access')));

insert into public.admin_permissions (role, permission_key)
values
  ('admin', 'admin.access'),
  ('admin', 'roles.manage'),
  ('admin', 'station.review'),
  ('admin', 'station.publish'),
  ('admin', 'station.suspend'),
  ('admin', 'station.staff.manage'),
  ('admin', 'catalog.manage'),
  ('admin', 'reviews.moderate'),
  ('admin', 'payments.view'),
  ('admin', 'payments.refund'),
  ('admin', 'notifications.view'),
  ('admin', 'customer.read'),
  ('admin', 'customer.email.view'),
  ('admin', 'customer.suspend'),
  ('admin', 'support.manage'),
  ('finance', 'payments.view'),
  ('finance', 'payments.refund'),
  ('rider', 'delivery.track'),
  ('support', 'customer.read'),
  ('support', 'support.manage'),
  ('support', 'customer.email.view'),
  ('verifier', 'station.review')
on conflict (role, permission_key) do nothing;

insert into public.station_document_type_catalog (
  document_type, description, is_required_by_default
)
values
  ('business_permit', 'Current business permit or registration', true),
  ('owner_id', 'Government-issued identification for the applicant', true),
  ('sanitary_permit', 'Current sanitary permit for the station', true),
  ('water_quality_test', 'Recent water quality laboratory result', true)
on conflict (document_type) do nothing;

create or replace view public.public_stations
with (security_barrier = true)
as
select
  s.id as station_id,
  s.display_name,
  s.description,
  s.logo_path,
  s.address_line,
  s.barangay,
  s.city,
  s.province,
  s.region,
  s.postal_code,
  s.latitude,
  s.longitude,
  s.timezone,
  s.service_radius_km,
  s.minimum_order_amount,
  s.default_delivery_fee,
  s.estimated_delivery_minutes,
  s.rating_average,
  s.rating_count
from public.stations s
where s.publication_status = 'published'
  and s.operational_status = 'active'
  and s.verification_status = 'verified';

create or replace view public.customer_order_stations
with (security_barrier = true)
as
select distinct
  o.station_id,
  o.station_snapshot ->> 'display_name' as display_name,
  o.station_snapshot ->> 'logo_path' as logo_path,
  o.station_snapshot ->> 'phone' as phone,
  o.station_snapshot ->> 'email' as email
from public.orders o
where public.is_order_party(o.id);

create or replace view public.station_order_payment_status
with (security_barrier = true)
as
select distinct on (o.id)
  o.id as order_id,
  p.method as payment_method,
  p.status as payment_status,
  p.amount,
  p.updated_at
from public.orders o
join public.payments p on p.order_id = o.id
where public.is_station_member(o.station_id)
order by o.id, p.created_at desc;

create or replace view public.public_station_reviews
with (security_barrier = true)
as
select r.station_id, r.rating, r.review_text, r.created_at
     , r.station_reply, r.station_replied_at
from public.station_reviews r
join public.stations s on s.id = r.station_id
where r.is_visible
  and s.publication_status = 'published'
  and s.operational_status = 'active'
  and s.verification_status = 'verified';

create or replace view public.support_customer_emails
with (security_barrier = true)
as
select e.user_id, e.email
from public.customer_email_access e
where public.has_permission('customer.email.view');

create or replace view public.support_order_payment_status
with (security_barrier = true)
as
select
  p.order_id,
  p.method,
  p.status,
  p.amount,
  p.currency,
  p.paid_at,
  p.updated_at
from public.payments p
where public.has_permission('support.manage');
insert into public.water_types (name, description)
values
  ('Purified', 'Purified drinking water'),
  ('Alkaline', 'Alkaline drinking water'),
  ('Mineral', 'Mineral drinking water'),
  ('Distilled', 'Distilled drinking water')
on conflict (name) do nothing;

insert into public.container_types (name, volume_liters, description)
values
  ('5-gallon container', 18.93, 'Common refillable water container'),
  ('3-gallon container', 11.36, 'Smaller refillable water container')
on conflict (name) do nothing;

insert into storage.buckets (id, name, public)
values
  ('station-documents', 'station-documents', false),
  ('avatars', 'avatars', false),
  ('station-assets', 'station-assets', true),
  ('delivery-proofs', 'delivery-proofs', false),
  ('support-attachments', 'support-attachments', false)
on conflict (id) do update set
  name = excluded.name,
  public = excluded.public;

update storage.buckets
set file_size_limit = case id
      when 'station-documents' then 20 * 1024 * 1024
      when 'avatars' then 5 * 1024 * 1024
      when 'station-assets' then 10 * 1024 * 1024
      when 'delivery-proofs' then 15 * 1024 * 1024
      when 'support-attachments' then 15 * 1024 * 1024
    end,
    allowed_mime_types = case id
      when 'station-documents' then array[
        'application/pdf', 'image/jpeg', 'image/png', 'image/webp'
      ]::text[]
      when 'avatars' then array[
        'image/jpeg', 'image/png', 'image/webp'
      ]::text[]
      when 'station-assets' then array[
        'image/jpeg', 'image/png', 'image/webp'
      ]::text[]
      when 'delivery-proofs' then array[
        'image/jpeg', 'image/png', 'image/webp'
      ]::text[]
      when 'support-attachments' then array[
        'application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'text/plain'
      ]::text[]
    end
where id in (
  'station-documents', 'avatars', 'station-assets',
  'delivery-proofs', 'support-attachments'
);

create policy "Applicants and admins read their private station documents"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'station-documents'
    and (
      exists (
        select 1
        from public.station_documents d
        join public.station_applications a on a.id = d.application_id
        where d.storage_path = name
          and a.owner_id = (select auth.uid())
      )
      or (select public.has_permission('station.review'))
    )
  );

create policy "Applicants upload private station documents"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'station-documents'
    and exists (
      select 1
      from public.station_documents d
      join public.station_applications a on a.id = d.application_id
      where d.storage_path = name
        and a.owner_id = (select auth.uid())
        and a.application_status in ('draft', 'changes_requested')
    )
  );

create policy "Users read their private avatars"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
create policy "Users upload their private avatars"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
create policy "Users update their private avatars"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
create policy "Users delete their private avatars"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "Station assets are publicly readable"
  on storage.objects for select to anon, authenticated
  using (bucket_id = 'station-assets');
create policy "Station managers upload station assets"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'station-assets'
    and exists (
      select 1 from public.stations s
      where s.id::text = (storage.foldername(name))[1]
        and public.is_station_manager(s.id)
    )
  );
create policy "Station managers update station assets"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'station-assets'
    and exists (
      select 1 from public.stations s
      where s.id::text = (storage.foldername(name))[1]
        and public.is_station_manager(s.id)
    )
  )
  with check (
    bucket_id = 'station-assets'
    and exists (
      select 1 from public.stations s
      where s.id::text = (storage.foldername(name))[1]
        and public.is_station_manager(s.id)
    )
  );
create policy "Station managers delete station assets"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'station-assets'
    and exists (
      select 1 from public.stations s
      where s.id::text = (storage.foldername(name))[1]
        and public.is_station_manager(s.id)
    )
  );

create policy "Delivery parties read private delivery proofs"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'delivery-proofs'
    and exists (
      select 1
      from public.deliveries d
      join public.orders o on o.id = d.order_id
      where o.id::text = (storage.foldername(name))[1]
        and (
          public.is_order_party(o.id)
          or d.rider_id = (select auth.uid())
          or o.customer_id = (select auth.uid())
          or (select public.has_permission('admin.access'))
        )
    )
  );
create policy "Station members upload delivery proofs"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'delivery-proofs'
    and exists (
      select 1
      from public.deliveries d
      join public.orders o on o.id = d.order_id
      where o.id::text = (storage.foldername(name))[1]
        and (
          (
            public.is_station_member(d.station_id)
            and public.is_order_party(d.order_id)
          )
          or (
            d.rider_id = (select auth.uid())
            and (select public.has_permission('delivery.track'))
          )
        )
    )
  );

create policy "Support participants read private attachments"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'support-attachments'
    and exists (
      select 1 from public.support_tickets t
      where t.id::text = (storage.foldername(name))[1]
        and (
          t.requester_id = (select auth.uid())
          or t.assigned_to = (select auth.uid())
          or (t.station_id is not null and (select public.is_station_member(t.station_id)))
          or (select public.has_permission('support.manage'))
        )
    )
  );
create policy "Support participants upload private attachments"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'support-attachments'
    and exists (
      select 1 from public.support_tickets t
      where t.id::text = (storage.foldername(name))[1]
        and (
          t.requester_id = (select auth.uid())
          or t.assigned_to = (select auth.uid())
          or (t.station_id is not null and (select public.is_station_member(t.station_id)))
          or (select public.has_permission('support.manage'))
        )
    )
  );

-- ============================================================================
-- Patch additions: rider workflow, admin cancel + refund, paid-order expiry,
-- default-address helper, extra read policies.
-- ============================================================================

insert into public.admin_permissions (role, permission_key)
values ('admin', 'orders.manage')
on conflict (role, permission_key) do nothing;

create or replace function public.set_default_address(p_address_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication is required';
  end if;

  perform 1
  from public.addresses a
  where a.id = p_address_id and a.user_id = auth.uid()
  for update;
  if not found then
    raise exception 'Address was not found';
  end if;

  update public.addresses
  set is_default = false
  where user_id = auth.uid() and is_default and id <> p_address_id;

  update public.addresses
  set is_default = true
  where id = p_address_id;
end;
$$;

create or replace function public.rider_update_delivery_status(
  p_order_id uuid,
  p_status public.order_status,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  order_row public.orders%rowtype;
  delivery_row public.deliveries%rowtype;
begin
  if auth.uid() is null or not public.has_permission('delivery.track') then
    raise exception 'An active rider account is required';
  end if;
  if p_status not in ('out_for_delivery', 'delivered') then
    raise exception 'Riders can only mark an order out for delivery or delivered';
  end if;

  select * into order_row
  from public.orders
  where id = p_order_id
  for update;
  if not found then
    raise exception 'No delivery is assigned to this rider for that order';
  end if;

  select * into delivery_row
  from public.deliveries d
  where d.order_id = p_order_id and d.rider_id = auth.uid()
  for update;
  if not found then
    raise exception 'No delivery is assigned to this rider for that order';
  end if;

  if p_status = 'out_for_delivery' and order_row.status <> 'rider_assigned' then
    raise exception 'Only an order with an assigned rider can go out for delivery';
  end if;
  if p_status = 'delivered' and order_row.status <> 'out_for_delivery' then
    raise exception 'Only an order that is out for delivery can be marked delivered';
  end if;

  perform set_config(
    'app.order_transition_note', coalesce(nullif(trim(p_note), ''), ''), true
  );
  perform set_config('app.order_transition', 'on', true);
  update public.orders
  set status = p_status,
      delivered_at = case when p_status = 'delivered' then now() else delivered_at end
  where id = p_order_id;
  perform set_config('app.order_transition', 'off', true);
  perform set_config('app.order_transition_note', '', true);

  update public.deliveries
  set status = case p_status
        when 'out_for_delivery' then 'out_for_delivery'::public.delivery_status
        else 'delivered'::public.delivery_status
      end,
      picked_up_at = case
        when p_status = 'out_for_delivery' then coalesce(picked_up_at, now())
        else picked_up_at
      end,
      delivered_at = case when p_status = 'delivered' then now() else delivered_at end
  where id = delivery_row.id;
end;
$$;

create or replace function public.admin_cancel_order(
  p_order_id uuid,
  p_reason text,
  p_refund boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  order_row public.orders%rowtype;
  payment_row public.payments%rowtype;
  payment_found boolean := false;
  target_status public.order_status;
  refunded_amount numeric(12, 2);
  refundable numeric(12, 2);
  refund_id_value uuid;
  cancel_reason_value text := nullif(trim(p_reason), '');
begin
  if not public.has_permission('orders.manage') then
    raise exception 'Order management permission is required';
  end if;
  if cancel_reason_value is null then
    raise exception 'A cancellation reason is required';
  end if;

  select * into order_row
  from public.orders
  where id = p_order_id
  for update;
  if not found then
    raise exception 'Order was not found';
  end if;
  if order_row.status in ('delivered', 'cancelled', 'failed') then
    raise exception 'This order is already closed';
  end if;

  select * into payment_row
  from public.payments
  where order_id = p_order_id
  order by attempt_number desc
  limit 1
  for update;
  payment_found := found;

  if payment_found and payment_row.status in ('paid', 'partially_refunded') then
    if not coalesce(p_refund, true) then
      raise exception 'A paid order must be cancelled together with a refund';
    end if;
    if not public.has_permission('payments.refund') then
      raise exception 'Payment refund permission is required to cancel a paid order';
    end if;
    if payment_row.provider is distinct from 'paymongo' then
      raise exception 'This payment cannot be refunded through the PayMongo refund workflow';
    end if;

    select coalesce(sum(pr.amount), 0) into refunded_amount
    from public.payment_refunds pr
    where pr.payment_id = payment_row.id
      and pr.status in ('requested', 'processing', 'succeeded');
    refundable := payment_row.amount - refunded_amount;

    if refundable > 0 then
      insert into public.payment_refunds (
        payment_id, requested_by, amount, status, reason, idempotency_key
      )
      values (
        payment_row.id, auth.uid(), refundable, 'requested',
        'Order cancelled by administrator: ' || cancel_reason_value,
        'admin-cancel-refund:' || p_order_id::text
      )
      on conflict (idempotency_key) do nothing
      returning id into refund_id_value;

      if refund_id_value is null then
        select pr.id into refund_id_value
        from public.payment_refunds pr
        where pr.idempotency_key = 'admin-cancel-refund:' || p_order_id::text;
      end if;

      insert into public.payment_provider_actions (
        payment_id, refund_id, action_type, idempotency_key, payload
      )
      values (
        payment_row.id, refund_id_value, 'refund',
        'execute-refund:' || refund_id_value::text,
        jsonb_build_object(
          'provider', payment_row.provider,
          'provider_payment_id', payment_row.provider_payment_id,
          'amount', refundable,
          'reason', cancel_reason_value
        )
      )
      on conflict (idempotency_key) do nothing;
    end if;
  elsif payment_found
    and payment_row.status in ('pending', 'processing')
    and payment_row.provider = 'paymongo'
    and payment_row.provider_checkout_id is not null
  then
    -- Expire the open checkout so the customer cannot pay for a dead order.
    insert into public.payment_provider_actions (
      payment_id, action_type, idempotency_key, payload
    )
    values (
      payment_row.id, 'expire_checkout',
      'expire-checkout:' || payment_row.id::text,
      jsonb_build_object(
        'provider', payment_row.provider,
        'provider_checkout_id', payment_row.provider_checkout_id,
        'order_id', p_order_id
      )
    )
    on conflict (idempotency_key) do nothing;
  end if;

  -- An order that is already out for delivery can only move to 'failed'.
  target_status := case
    when order_row.status = 'out_for_delivery' then 'failed'::public.order_status
    else 'cancelled'::public.order_status
  end;

  perform set_config(
    'app.order_transition_note', 'Administrator: ' || cancel_reason_value, true
  );
  perform set_config('app.order_transition', 'on', true);
  update public.orders
  set status = target_status,
      cancel_reason = cancel_reason_value,
      cancelled_at = case when target_status = 'cancelled' then now() else cancelled_at end,
      cancelled_by = auth.uid()
  where id = p_order_id;
  perform set_config('app.order_transition', 'off', true);
  perform set_config('app.order_transition_note', '', true);

  perform set_config('app.payment_transition', 'on', true);
  update public.payments
  set status = 'cancelled'
  where order_id = p_order_id and status in ('pending', 'processing');
  perform set_config('app.payment_transition', 'off', true);

  update public.deliveries
  set status = case
        when target_status = 'failed' then 'failed'::public.delivery_status
        else 'cancelled'::public.delivery_status
      end,
      failure_reason = case when target_status = 'failed' then cancel_reason_value else failure_reason end
  where order_id = p_order_id
    and status not in ('delivered', 'failed', 'cancelled');

  perform set_config('app.release_inventory', 'on', true);
  perform public.release_order_inventory(
    p_order_id, 'Inventory restored after administrator cancellation'
  );
  perform set_config('app.release_inventory', 'off', true);

  insert into public.admin_audit_logs (
    actor_id, action, entity_type, entity_id, before_data, after_data
  )
  values (
    auth.uid(), 'order_cancelled_by_admin', 'order', p_order_id,
    jsonb_build_object('status', order_row.status),
    jsonb_build_object(
      'status', target_status,
      'reason', cancel_reason_value,
      'refund_id', refund_id_value
    )
  );

  return refund_id_value;
end;
$$;

create or replace function public.expire_unaccepted_paid_orders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  expired_order record;
  payment_row public.payments%rowtype;
  refunded_amount numeric(12, 2);
  refundable numeric(12, 2);
  refund_id_value uuid;
  expired_count integer := 0;
begin
  if coalesce(auth.role(), '') <> 'service_role'
    and not exists (
      select 1 from pg_catalog.pg_roles
      where rolname = current_user and (rolsuper or rolbypassrls)
    )
  then
    raise exception 'Unaccepted paid order expiry is restricted to trusted servers';
  end if;

  for expired_order in
    select o.id
    from public.orders o
    where o.payment_method = 'paymongo'
      and o.status = 'pending'
      and o.acceptance_expires_at <= now()
      and exists (
        select 1 from public.payments p
        where p.order_id = o.id and p.status = 'paid'
      )
    order by o.acceptance_expires_at
    for update of o skip locked
  loop
    select * into payment_row
    from public.payments
    where order_id = expired_order.id and status = 'paid'
    for update;
    if not found then
      continue;
    end if;

    perform set_config(
      'app.order_transition_note', 'Station did not accept the paid order in time', true
    );
    perform set_config('app.order_transition', 'on', true);
    update public.orders
    set status = 'cancelled',
        cancel_reason = 'Station did not accept the paid order in time',
        cancelled_at = now()
    where id = expired_order.id and status = 'pending';
    perform set_config('app.order_transition', 'off', true);
    perform set_config('app.order_transition_note', '', true);

    select coalesce(sum(pr.amount), 0) into refunded_amount
    from public.payment_refunds pr
    where pr.payment_id = payment_row.id
      and pr.status in ('requested', 'processing', 'succeeded');
    refundable := payment_row.amount - refunded_amount;

    if refundable > 0 then
      refund_id_value := null;
      insert into public.payment_refunds (
        payment_id, amount, status, is_automatic, reason, idempotency_key
      )
      values (
        payment_row.id, refundable, 'requested', true,
        'Automatic refund: station did not accept the paid order in time',
        'unaccepted-order-refund:' || payment_row.id::text
      )
      on conflict (idempotency_key) do nothing
      returning id into refund_id_value;

      if refund_id_value is null then
        select pr.id into refund_id_value
        from public.payment_refunds pr
        where pr.idempotency_key = 'unaccepted-order-refund:' || payment_row.id::text;
      end if;

      insert into public.payment_provider_actions (
        payment_id, refund_id, action_type, idempotency_key, payload
      )
      values (
        payment_row.id, refund_id_value, 'refund',
        'execute-refund:' || refund_id_value::text,
        jsonb_build_object(
          'provider', payment_row.provider,
          'provider_payment_id', payment_row.provider_payment_id,
          'amount', refundable,
          'reason', 'Station did not accept the paid order in time'
        )
      )
      on conflict (idempotency_key) do nothing;
    end if;

    perform set_config('app.release_inventory', 'on', true);
    perform public.release_order_inventory(
      expired_order.id, 'Inventory restored after paid order acceptance timeout'
    );
    perform set_config('app.release_inventory', 'off', true);
    expired_count := expired_count + 1;
  end loop;

  return expired_count;
end;
$$;

-- Station owners control delivery status; these jobs no longer cancel orders
-- merely because the station did not accept them before a timeout.
create or replace function public.expire_unaccepted_cod_orders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role'
    and not exists (
      select 1 from pg_catalog.pg_roles
      where rolname = current_user and (rolsuper or rolbypassrls)
    )
  then
    raise exception 'Unaccepted order expiry is restricted to trusted servers';
  end if;
  return 0;
end;
$$;

create or replace function public.expire_unaccepted_paid_orders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role'
    and not exists (
      select 1 from pg_catalog.pg_roles
      where rolname = current_user and (rolsuper or rolbypassrls)
    )
  then
    raise exception 'Unaccepted paid order expiry is restricted to trusted servers';
  end if;
  return 0;
end;
$$;

-- Reviewers / publishers must see publication-readiness data of unpublished stations.
create policy "Reviewers view station operating hours"
  on public.station_operating_hours for select to authenticated
  using (
    (select public.has_permission('station.review'))
    or (select public.has_permission('station.publish'))
    or (select public.is_admin())
  );
create policy "Reviewers view station delivery zones"
  on public.station_delivery_zones for select to authenticated
  using (
    (select public.has_permission('station.review'))
    or (select public.has_permission('station.publish'))
    or (select public.is_admin())
  );
create policy "Reviewers view container policies"
  on public.container_policies for select to authenticated
  using (
    (select public.has_permission('station.review'))
    or (select public.has_permission('station.publish'))
    or (select public.is_admin())
  );
create policy "Station members view container policies"
  on public.container_policies for select to authenticated
  using ((select public.is_station_member(station_id)));
-- Customers need the effective deposit / return policy on product screens.
create policy "Container policies visible for published stations"
  on public.container_policies for select to anon, authenticated
  using (is_active and (select public.is_public_station(station_id)));

revoke all privileges on all tables in schema public from public, anon, authenticated;
grant all privileges on all tables in schema public to service_role;
grant all privileges on all sequences in schema public to service_role;
grant usage on schema public to anon, authenticated, service_role;
grant usage on schema extensions to anon, authenticated, service_role;

grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.user_roles, public.admin_permissions to authenticated;
grant select, insert, update, delete on public.addresses to authenticated;
grant select, insert, update, delete on public.user_preferences to authenticated;
grant select on public.user_devices to authenticated;
grant select, update on public.station_applications to authenticated;
grant select on public.station_application_status_history to authenticated;
grant select, update on public.stations to authenticated;
grant select on public.station_staff to authenticated;
grant select on public.station_staff_invites to authenticated;
grant select, insert on public.station_documents to authenticated;
grant select on public.verification_reviews to authenticated;
grant select on public.station_document_requirements to authenticated;
grant select on public.station_document_type_catalog to authenticated;
grant select on public.station_operating_hours, public.station_delivery_zones to anon, authenticated;
grant insert, update, delete on public.station_operating_hours, public.station_delivery_zones to authenticated;
grant select on public.station_status_history to authenticated;
grant select on public.water_types, public.container_types to anon, authenticated;
grant insert, update, delete on public.water_types, public.container_types to authenticated;
-- Anonymous visitors get every product column except exact stock_quantity.
grant select (
  id, station_id, water_type_id, container_type_id, name, description,
  refill_available, refill_price, new_container_available, new_container_price,
  deposit_amount, requires_empty_container, return_policy, max_order_quantity,
  status, image_path, created_at, updated_at
) on public.station_products to anon;
grant select on public.station_products to authenticated;
grant select on public.station_product_images to anon, authenticated;
grant select on public.container_policies to anon;
grant insert, update, delete on public.station_products, public.station_product_images to authenticated;
grant select, insert, update, delete on public.container_policies to authenticated;
grant select on public.station_inventory_movements to authenticated;
grant select, insert, update, delete on public.saved_stations, public.carts, public.cart_items to authenticated;
grant select on public.orders, public.order_items, public.order_status_history, public.deliveries to authenticated;
grant select, insert, delete on public.station_order_dismissals to authenticated;
grant select, insert on public.customer_order_dismissals to authenticated;
grant select on public.delivery_tracking to authenticated;
grant select, insert, update on public.station_reviews to authenticated;
grant select, update on public.notifications to authenticated;
grant select on public.payments, public.payment_events, public.payment_refunds to authenticated;
grant select, insert, update on public.support_tickets to authenticated;
grant select, insert on public.support_messages to authenticated;
grant select on public.admin_audit_logs to authenticated;
grant select on public.public_stations, public.public_station_reviews to anon, authenticated;
grant select on public.customer_order_stations to authenticated;
grant select on public.station_order_payment_status to authenticated;
grant select on public.support_customer_emails, public.support_order_payment_status to authenticated;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.has_permission(text) to authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.is_public_station(uuid) to anon, authenticated;
grant execute on function public.get_public_station_phone(uuid) to anon, authenticated;
grant execute on function public.get_public_station_social_links(uuid) to anon, authenticated;
grant execute on function public.is_station_member(uuid) to authenticated;
grant execute on function public.is_station_manager(uuid) to authenticated;
grant execute on function public.is_station_owner(uuid) to authenticated;
grant execute on function public.is_order_party(uuid) to authenticated;

grant execute on function public.start_station_application(text, text, text, text, text, text, double precision, double precision, text, text, text, text) to authenticated;
grant execute on function public.submit_application(uuid) to authenticated;
grant execute on function public.review_station_document(uuid, public.document_review_status, text) to authenticated;
grant execute on function public.review_application(uuid, public.application_status, text) to authenticated;
grant execute on function public.publish_station(uuid) to authenticated;
grant execute on function public.suspend_station(uuid, text) to authenticated;
grant execute on function public.nearby_stations(double precision, double precision, double precision, jsonb, integer, integer) to anon, authenticated;
grant execute on function public.nearby_stations_with_barangay(double precision, double precision, double precision, jsonb, integer, integer) to anon, authenticated;
grant execute on function public.create_order(uuid, uuid, jsonb, public.payment_method, text, text, uuid) to authenticated;
grant execute on function public.cancel_order(uuid, text) to authenticated;
grant execute on function public.update_order_status(uuid, public.order_status, text, timestamptz) to authenticated;
grant execute on function public.assign_delivery_person(uuid, text, text, timestamptz) to authenticated;
grant execute on function public.record_cod_collection(uuid, numeric, text) to authenticated;
grant execute on function public.adjust_inventory(uuid, integer, text, text) to authenticated;
grant execute on function public.create_station_staff_invite(uuid, text, text, text, timestamptz) to authenticated;
grant execute on function public.accept_station_staff_invite(text) to authenticated;
grant execute on function public.get_station_order_payment_status(uuid) to authenticated;
grant execute on function public.set_customer_status(uuid, public.profile_status, text, uuid) to service_role;
grant execute on function public.cancel_station_order(uuid, text) to authenticated;
grant execute on function public.set_delivery_proof(uuid, text) to authenticated;
grant execute on function public.get_customer_order_station(uuid) to authenticated;
grant execute on function public.assign_delivery_rider(uuid, uuid, text, text, timestamptz) to authenticated;
grant execute on function public.update_delivery_location(uuid, double precision, double precision, numeric, numeric, numeric, timestamptz) to authenticated;
grant execute on function public.register_device(text, text) to authenticated;
grant execute on function public.disable_station_staff(uuid, uuid) to authenticated;
grant execute on function public.reply_to_station_review(uuid, text) to authenticated;
grant execute on function public.pause_station(uuid, text) to authenticated;
grant execute on function public.resume_station(uuid) to authenticated;
grant execute on function public.reinstate_station(uuid, text) to authenticated;
grant execute on function public.archive_station(uuid, text) to authenticated;
grant execute on function public.bootstrap_first_admin(uuid) to service_role;
grant execute on function public.fail_order(uuid, text) to service_role;
grant execute on function public.expire_pending_paymongo_orders() to service_role;
grant execute on function public.expire_unaccepted_cod_orders() to service_role;
grant execute on function public.record_paymongo_checkout(uuid, text) to service_role;
grant execute on function public.claim_payment_provider_actions(integer) to service_role;
grant execute on function public.complete_payment_provider_action(uuid, boolean, text) to service_role;
grant execute on function public.apply_payment_event(text, text, uuid, text, jsonb, boolean, public.payment_status, numeric, text, uuid, public.refund_status) to service_role;
grant execute on function public.request_refund(uuid, numeric, text, text) to authenticated;
grant execute on function public.set_default_address(uuid) to authenticated;
grant execute on function public.rider_update_delivery_status(uuid, public.order_status, text) to authenticated;
grant execute on function public.admin_cancel_order(uuid, text, boolean) to authenticated;
grant execute on function public.expire_unaccepted_paid_orders() to service_role;

alter default privileges in schema public
  revoke all privileges on tables from public, anon, authenticated;
alter default privileges in schema public
  revoke all privileges on sequences from public, anon, authenticated;
alter default privileges in schema public
  revoke execute on functions from public, anon, authenticated;

do $$
declare
  table_name text;
begin
  if not exists (
    select 1 from pg_catalog.pg_publication
    where pubname = 'supabase_realtime'
  ) then
    create publication supabase_realtime;
  end if;

  foreach table_name in array array[
    'orders',
    'deliveries',
    'delivery_tracking',
    'payments',
    'notifications',
    'order_status_history',
    'support_messages'
  ]
  loop
    if not exists (
      select 1
      from pg_catalog.pg_publication_tables p
      where p.pubname = 'supabase_realtime'
        and p.schemaname = 'public'
        and p.tablename = table_name
    ) then
      execute format(
        'alter publication supabase_realtime add table public.%I',
        table_name
      );
    end if;
  end loop;
end;
$$;

do $$
begin
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'aquadirect-expire-paymongo-orders',
      '* * * * *',
      'select public.run_order_expiry_jobs();'
    );
  else
    raise notice 'pg_cron is unavailable; call public.expire_pending_paymongo_orders(), public.expire_unaccepted_cod_orders() and public.expire_unaccepted_paid_orders() every minute from a trusted Edge Function cron (service role).';
  end if;
end;
$$;

commit;
