-- YardBids MVP data model (PostgreSQL)
-- This is the foundation for connecting the prototype to a real backend.

create extension if not exists pgcrypto;

create type listing_condition as enum ('like_new', 'good', 'fair', 'needs_repair');
create type delivery_option as enum ('pickup', 'shipping', 'both');
create type auction_status as enum ('draft', 'scheduled', 'live', 'ended', 'cancelled');
create type order_status as enum ('awaiting_payment', 'paid', 'meetup_scheduled', 'shipped', 'delivered', 'completed', 'disputed', 'cancelled');
create type verification_level as enum ('basic', 'phone_verified', 'identity_verified');

create table users (
  id uuid primary key default gen_random_uuid(),
  email text unique not null,
  phone text unique,
  created_at timestamptz not null default now()
);

create table profiles (
  user_id uuid primary key references users(id) on delete cascade,
  display_name text not null,
  avatar_url text,
  home_area text,
  verification verification_level not null default 'basic',
  average_rating numeric(2,1) default 0,
  rating_count integer not null default 0,
  created_at timestamptz not null default now()
);

create table listings (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references users(id),
  title text not null,
  description text,
  category text not null,
  condition listing_condition not null,
  delivery delivery_option not null,
  area text,
  is_shippable boolean not null default false,
  media_urls jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);

create table auctions (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid unique not null references listings(id) on delete cascade,
  starting_bid_cents integer not null check (starting_bid_cents > 0),
  current_bid_cents integer not null,
  current_winner_id uuid references users(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status auction_status not null default 'draft',
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);

create table bids (
  id uuid primary key default gen_random_uuid(),
  auction_id uuid not null references auctions(id) on delete cascade,
  bidder_id uuid not null references users(id),
  amount_cents integer not null check (amount_cents > 0),
  created_at timestamptz not null default now()
);

create index bids_auction_created_idx on bids (auction_id, created_at desc);

create table conversations (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid references listings(id) on delete set null,
  buyer_id uuid not null references users(id),
  seller_id uuid not null references users(id),
  created_at timestamptz not null default now(),
  unique (listing_id, buyer_id, seller_id)
);

create table messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversations(id) on delete cascade,
  sender_id uuid not null references users(id),
  body text not null check (char_length(body) <= 2000),
  created_at timestamptz not null default now()
);

create table meetup_locations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text not null,
  area text not null,
  latitude numeric(9,6),
  longitude numeric(9,6),
  verified boolean not null default false,
  safety_notes text
);

create table orders (
  id uuid primary key default gen_random_uuid(),
  auction_id uuid unique not null references auctions(id),
  buyer_id uuid not null references users(id),
  seller_id uuid not null references users(id),
  item_total_cents integer not null,
  buyer_protection_cents integer not null default 0,
  shipping_cents integer not null default 0,
  status order_status not null default 'awaiting_payment',
  meetup_location_id uuid references meetup_locations(id),
  meetup_at timestamptz,
  carrier text,
  tracking_number text,
  paid_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now()
);

create table payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid unique not null references orders(id) on delete cascade,
  processor_reference text unique,
  amount_cents integer not null check (amount_cents > 0),
  status text not null default 'pending',
  created_at timestamptz not null default now(),
  captured_at timestamptz
);

create table payouts (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references users(id),
  order_id uuid unique not null references orders(id) on delete cascade,
  processor_reference text unique,
  amount_cents integer not null check (amount_cents > 0),
  status text not null default 'pending',
  created_at timestamptz not null default now(),
  paid_at timestamptz
);

create table ratings (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  author_id uuid not null references users(id),
  recipient_id uuid not null references users(id),
  stars integer not null check (stars between 1 and 5),
  comment text,
  created_at timestamptz not null default now(),
  unique (order_id, author_id)
);

create table reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references users(id),
  order_id uuid references orders(id),
  reported_user_id uuid references users(id),
  reason text not null,
  details text,
  status text not null default 'open',
  created_at timestamptz not null default now()
);

create table auction_watchers (
  auction_id uuid not null references auctions(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (auction_id, user_id)
);

create table seller_follows (
  follower_id uuid not null references users(id) on delete cascade,
  seller_id uuid not null references users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, seller_id),
  check (follower_id <> seller_id)
);

create table notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references users(id) on delete cascade,
  kind text not null,
  title text not null,
  body text,
  data jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index notifications_recipient_created_idx
  on notifications (recipient_id, created_at desc);

create or replace function submit_rating(
  p_order_id uuid,
  p_author_id uuid,
  p_stars integer,
  p_comment text default null
)
returns uuid
language plpgsql
as $$
declare
  completed_order orders%rowtype;
  recipient uuid;
  new_rating_id uuid;
begin
  if p_stars not between 1 and 5 then
    raise exception 'Ratings must be between 1 and 5 stars';
  end if;

  select * into completed_order
  from orders
  where id = p_order_id;

  if not found or completed_order.status <> 'completed' then
    raise exception 'Ratings can only be left after an order is completed';
  end if;

  if p_author_id = completed_order.buyer_id then
    recipient := completed_order.seller_id;
  elsif p_author_id = completed_order.seller_id then
    recipient := completed_order.buyer_id;
  else
    raise exception 'Only order participants can leave a rating';
  end if;

  insert into ratings (order_id, author_id, recipient_id, stars, comment)
  values (p_order_id, p_author_id, recipient, p_stars, p_comment)
  returning id into new_rating_id;

  update profiles
  set average_rating = (
        select round(avg(stars)::numeric, 1)
        from ratings
        where recipient_id = recipient
      ),
      rating_count = (
        select count(*)
        from ratings
        where recipient_id = recipient
      )
  where user_id = recipient;

  return new_rating_id;
end;
$$;

-- Important: bids must be placed through a server-side transaction.
-- The transaction must lock the auction, validate that it is live, ensure
-- the bid is higher, extend the end time for last-minute bids, insert the bid,
-- and update the current winner as one atomic operation.

create or replace function place_bid(
  p_auction_id uuid,
  p_bidder_id uuid,
  p_amount_cents integer
)
returns table (
  current_bid_cents integer,
  current_winner_id uuid,
  ends_at timestamptz
)
language plpgsql
as $$
declare
  locked_auction auctions%rowtype;
  updated_end_time timestamptz;
begin
  -- Lock the auction row so simultaneous bids are processed one at a time.
  select * into locked_auction
  from auctions
  where id = p_auction_id
  for update;

  if not found then
    raise exception 'Auction not found';
  end if;

  if locked_auction.status <> 'live' or locked_auction.ends_at <= now() then
    raise exception 'This auction is no longer accepting bids';
  end if;

  if p_amount_cents <= locked_auction.current_bid_cents then
    raise exception 'Your bid must be higher than the current bid';
  end if;

  -- Give everyone a fair chance: extend one minute for any bid in the final minute.
  updated_end_time := case
    when locked_auction.ends_at <= now() + interval '1 minute'
      then locked_auction.ends_at + interval '1 minute'
    else locked_auction.ends_at
  end;

  insert into bids (auction_id, bidder_id, amount_cents)
  values (p_auction_id, p_bidder_id, p_amount_cents);

  update auctions
  set current_bid_cents = p_amount_cents,
      current_winner_id = p_bidder_id,
      ends_at = updated_end_time
  where id = p_auction_id;

  return query
  select p_amount_cents, p_bidder_id, updated_end_time;
end;
$$;

create or replace function close_auction(p_auction_id uuid)
returns uuid
language plpgsql
as $$
declare
  locked_auction auctions%rowtype;
  seller uuid;
  new_order_id uuid;
begin
  select * into locked_auction
  from auctions
  where id = p_auction_id
  for update;

  if not found then
    raise exception 'Auction not found';
  end if;

  if locked_auction.status <> 'live' or locked_auction.ends_at > now() then
    raise exception 'Auction is not ready to close';
  end if;

  update auctions
  set status = 'ended'
  where id = p_auction_id;

  -- An auction with no bids ends cleanly without creating an order.
  if locked_auction.current_winner_id is null then
    return null;
  end if;

  select seller_id into seller
  from listings
  where id = locked_auction.listing_id;

  insert into orders (
    auction_id,
    buyer_id,
    seller_id,
    item_total_cents,
    status
  ) values (
    p_auction_id,
    locked_auction.current_winner_id,
    seller,
    locked_auction.current_bid_cents,
    'awaiting_payment'
  ) returning id into new_order_id;

  return new_order_id;
end;
$$;

create or replace function mark_order_paid(p_order_id uuid)
returns void
language plpgsql
as $$
begin
  update orders
  set status = 'paid',
      paid_at = now()
  where id = p_order_id
    and status = 'awaiting_payment';

  if not found then
    raise exception 'Order cannot be marked paid in its current state';
  end if;
end;
$$;

create or replace function schedule_safe_meetup(
  p_order_id uuid,
  p_meetup_location_id uuid,
  p_meetup_at timestamptz
)
returns void
language plpgsql
as $$
begin
  if p_meetup_at <= now() then
    raise exception 'Meetup time must be in the future';
  end if;

  update orders
  set meetup_location_id = p_meetup_location_id,
      meetup_at = p_meetup_at,
      status = 'meetup_scheduled'
  where id = p_order_id
    and status = 'paid';

  if not found then
    raise exception 'Order must be paid before scheduling a meetup';
  end if;
end;
$$;

create or replace function confirm_pickup_complete(
  p_order_id uuid,
  p_confirming_user_id uuid
)
returns void
language plpgsql
as $$
begin
  update orders
  set status = 'completed',
      completed_at = now()
  where id = p_order_id
    and buyer_id = p_confirming_user_id
    and status = 'meetup_scheduled';

  if not found then
    raise exception 'Only the buyer can confirm this scheduled pickup';
  end if;
end;
$$;

create or replace function confirm_delivery_complete(
  p_order_id uuid,
  p_confirming_user_id uuid
)
returns void
language plpgsql
as $$
begin
  update orders
  set status = 'completed',
      completed_at = now()
  where id = p_order_id
    and buyer_id = p_confirming_user_id
    and status = 'delivered';

  if not found then
    raise exception 'Only the buyer can confirm a delivered order';
  end if;
end;
$$;

create or replace function open_order_dispute(
  p_order_id uuid,
  p_reporter_id uuid,
  p_reason text,
  p_details text default null
)
returns uuid
language plpgsql
as $$
declare
  locked_order orders%rowtype;
  reported_user uuid;
  new_report_id uuid;
begin
  select * into locked_order
  from orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Order not found';
  end if;

  if p_reporter_id not in (locked_order.buyer_id, locked_order.seller_id) then
    raise exception 'Only a participant can report this order';
  end if;

  if locked_order.status in ('completed', 'cancelled') then
    raise exception 'This order can no longer be disputed';
  end if;

  reported_user := case
    when p_reporter_id = locked_order.buyer_id then locked_order.seller_id
    else locked_order.buyer_id
  end;

  update orders
  set status = 'disputed'
  where id = p_order_id;

  insert into reports (
    reporter_id,
    order_id,
    reported_user_id,
    reason,
    details
  ) values (
    p_reporter_id,
    p_order_id,
    reported_user,
    p_reason,
    p_details
  ) returning id into new_report_id;

  return new_report_id;
end;
$$;
