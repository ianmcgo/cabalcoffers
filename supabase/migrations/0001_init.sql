create extension if not exists pgcrypto;

create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.admins enable row level security;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to anon, authenticated;

drop policy if exists admins_self_read on public.admins;
create policy admins_self_read on public.admins
  for select to authenticated
  using (user_id = auth.uid());

create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  type text not null check (type in ('tcgplayer','deckbox','ebay','youtube','note')),
  title text check (char_length(title) <= 300),
  body text check (char_length(body) <= 20000),
  url text check (url is null or url ~* '^https://'),
  image_url text check (image_url is null or image_url ~* '^https://'),
  price numeric(12,2) check (price is null or price >= 0),
  cards jsonb check (cards is null or jsonb_typeof(cards) = 'array'),
  card_count integer not null default 0 check (card_count >= 0),
  est_value numeric(12,2) check (est_value is null or est_value >= 0),
  pinned boolean not null default false,
  published boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists posts_feed_idx on public.posts (published, pinned desc, created_at desc);
create index if not exists posts_type_feed_idx on public.posts (type, published, created_at desc);

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists posts_touch on public.posts;
create trigger posts_touch before update on public.posts
  for each row execute function public.touch_updated_at();

alter table public.posts enable row level security;

drop policy if exists posts_public_read on public.posts;
create policy posts_public_read on public.posts
  for select to anon, authenticated
  using (published or public.is_admin());

drop policy if exists posts_admin_insert on public.posts;
create policy posts_admin_insert on public.posts
  for insert to authenticated
  with check (public.is_admin());

drop policy if exists posts_admin_update on public.posts;
create policy posts_admin_update on public.posts
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists posts_admin_delete on public.posts;
create policy posts_admin_delete on public.posts
  for delete to authenticated
  using (public.is_admin());

grant select on public.posts to anon, authenticated;
grant insert, update, delete on public.posts to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('post-images', 'post-images', true, 5242880, array['image/jpeg','image/png','image/webp','image/gif'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists post_images_public_read on storage.objects;
create policy post_images_public_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'post-images');

drop policy if exists post_images_admin_insert on storage.objects;
create policy post_images_admin_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'post-images' and public.is_admin());

drop policy if exists post_images_admin_update on storage.objects;
create policy post_images_admin_update on storage.objects
  for update to authenticated
  using (bucket_id = 'post-images' and public.is_admin())
  with check (bucket_id = 'post-images' and public.is_admin());

drop policy if exists post_images_admin_delete on storage.objects;
create policy post_images_admin_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'post-images' and public.is_admin());

create table if not exists public.site_counter (
  id smallint primary key default 1 check (id = 1),
  views bigint not null default 0
);
insert into public.site_counter (id, views) values (1, 0) on conflict (id) do nothing;

create table if not exists public.site_country_daily (
  day date not null,
  country text not null check (country ~ '^[A-Z]{2}$'),
  views bigint not null default 0,
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  primary key (day, country)
);
create index if not exists site_country_daily_country_idx on public.site_country_daily (country);

create table if not exists public.site_hour_views (
  hour smallint primary key check (hour between 0 and 23),
  views bigint not null default 0
);

create table if not exists public.site_device_daily (
  day date not null,
  device text not null check (device in ('mobile','desktop')),
  views bigint not null default 0,
  primary key (day, device)
);

alter table public.site_counter enable row level security;
alter table public.site_country_daily enable row level security;
alter table public.site_hour_views enable row level security;
alter table public.site_device_daily enable row level security;

revoke all on public.site_counter, public.site_country_daily, public.site_hour_views, public.site_device_daily from anon, authenticated;

create or replace function public.my_country()
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  h json;
  c text;
begin
  begin
    h := current_setting('request.headers', true)::json;
  exception when others then
    h := null;
  end;
  c := upper(coalesce(h->>'cf-ipcountry', h->>'x-country-code', ''));
  if c !~ '^[A-Z]{2}$' or c in ('XX','T1') then
    c := 'ZZ';
  end if;
  return c;
end;
$$;

create or replace function public.get_site_views()
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select views from public.site_counter where id = 1;
$$;

create or replace function public.bump_site_views()
returns bigint
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  total bigint;
  c text := public.my_country();
  d date := (now() at time zone 'utc')::date;
  hr smallint := extract(hour from now() at time zone 'utc')::smallint;
begin
  update public.site_counter set views = views + 1 where id = 1 returning views into total;

  insert into public.site_country_daily as t (day, country, views, first_seen, last_seen)
  values (d, c, 1, now(), now())
  on conflict (day, country) do update set views = t.views + 1, last_seen = now();

  insert into public.site_hour_views as t (hour, views)
  values (hr, 1)
  on conflict (hour) do update set views = t.views + 1;

  return total;
end;
$$;

create or replace function public.bump_site_view_device(p_device text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  dev text := case when p_device = 'mobile' then 'mobile' else 'desktop' end;
begin
  insert into public.site_device_daily as t (day, device, views)
  values ((now() at time zone 'utc')::date, dev, 1)
  on conflict (day, device) do update set views = t.views + 1;
end;
$$;

create or replace function public.get_country_views()
returns table (country text, views bigint, last_seen timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select country, sum(views)::bigint, max(last_seen)
  from public.site_country_daily
  group by country
  order by 2 desc;
$$;

create or replace function public.get_country_firsts()
returns table (country text, first_seen timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select country, min(first_seen)
  from public.site_country_daily
  group by country;
$$;

create or replace function public.get_daily_views(n integer default 365)
returns table (day date, views bigint)
language sql
stable
security definer
set search_path = public
as $$
  select day, sum(views)::bigint
  from public.site_country_daily
  where day > (now() at time zone 'utc')::date - least(greatest(coalesce(n, 365), 1), 3650)
  group by day
  order by day;
$$;

create or replace function public.get_country_daily(n integer default 60)
returns table (day date, country text, views bigint)
language sql
stable
security definer
set search_path = public
as $$
  select day, country, views
  from public.site_country_daily
  where day > (now() at time zone 'utc')::date - least(greatest(coalesce(n, 60), 1), 3650)
  order by day, country;
$$;

create or replace function public.get_hour_views()
returns table (hour integer, views bigint)
language sql
stable
security definer
set search_path = public
as $$
  select hour::integer, views from public.site_hour_views order by hour;
$$;

create or replace function public.get_device_views(n integer default 90)
returns table (day date, device text, views bigint)
language sql
stable
security definer
set search_path = public
as $$
  select day, device, views
  from public.site_device_daily
  where day > (now() at time zone 'utc')::date - least(greatest(coalesce(n, 90), 1), 3650)
  order by day, device;
$$;

revoke all on function public.my_country(), public.get_site_views(), public.bump_site_views(), public.bump_site_view_device(text),
  public.get_country_views(), public.get_country_firsts(), public.get_daily_views(integer), public.get_country_daily(integer),
  public.get_hour_views(), public.get_device_views(integer) from public;

grant execute on function public.my_country(), public.get_site_views(), public.bump_site_views(), public.bump_site_view_device(text),
  public.get_country_views(), public.get_country_firsts(), public.get_daily_views(integer), public.get_country_daily(integer),
  public.get_hour_views(), public.get_device_views(integer) to anon, authenticated;
