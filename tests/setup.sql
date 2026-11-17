-- Synthetic, disposable PostgreSQL fixture.
-- This deliberately does NOT copy GAME WORLD production tables, payout code,
-- wallet identifiers, users, secrets, or the Royal Arena paytable.

drop schema if exists concurrency_test cascade;
create schema concurrency_test;

create table concurrency_test.wallets (
  user_id uuid primary key,
  balance bigint not null check (balance >= 0)
);

create table concurrency_test.rounds (
  round_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references concurrency_test.wallets(user_id),
  idempotency_key uuid not null,
  unique (user_id, idempotency_key)
);

create table concurrency_test.spins (
  spin_id uuid primary key default gen_random_uuid(),
  round_id uuid not null references concurrency_test.rounds(round_id),
  user_id uuid not null references concurrency_test.wallets(user_id),
  idempotency_key uuid not null,
  response jsonb not null,
  unique (user_id, idempotency_key)
);

create table concurrency_test.ledger (
  ledger_id bigint generated always as identity primary key,
  user_id uuid not null references concurrency_test.wallets(user_id),
  idempotency_key uuid not null,
  entry_type text not null check (entry_type in ('DEBIT','CREDIT')),
  amount bigint not null check (amount > 0),
  unique (user_id, idempotency_key, entry_type)
);

insert into concurrency_test.wallets(user_id, balance)
values ('00000000-0000-4000-8000-000000000003', 10000);

-- A minimal model of the production settlement pattern:
-- lock the player's wallet row first, then re-check the idempotency key,
-- and write the spin + ledger entries in the same transaction.
-- The payout is a fixed synthetic value solely for testing concurrency.
create or replace function concurrency_test.spin(
  p_user_id uuid,
  p_bet bigint,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_balance bigint;
  v_existing jsonb;
  v_round_id uuid;
  v_response jsonb;
  v_payout constant bigint := 6900;
begin
  if p_bet <> 100 then
    raise exception 'Synthetic test accepts exactly 100 coins';
  end if;

  select w.balance into v_balance
  from concurrency_test.wallets w
  where w.user_id = p_user_id
  for update;

  if not found then
    raise exception 'Synthetic test wallet not found';
  end if;

  select s.response into v_existing
  from concurrency_test.spins s
  where s.user_id = p_user_id
    and s.idempotency_key = p_idempotency_key;

  if found then
    return v_existing;
  end if;

  if v_balance < p_bet then
    raise exception 'Insufficient synthetic balance';
  end if;

  insert into concurrency_test.rounds(user_id, idempotency_key)
  values (p_user_id, p_idempotency_key)
  returning round_id into v_round_id;

  update concurrency_test.wallets
  set balance = balance - p_bet + v_payout
  where user_id = p_user_id
  returning balance into v_balance;

  insert into concurrency_test.ledger(user_id,idempotency_key,entry_type,amount)
  values
    (p_user_id,p_idempotency_key,'DEBIT',p_bet),
    (p_user_id,p_idempotency_key,'CREDIT',v_payout);

  v_response := jsonb_build_object(
    'roundId', v_round_id,
    'userId', p_user_id,
    'bet', p_bet,
    'payout', v_payout,
    'walletBalance', v_balance
  );

  insert into concurrency_test.spins(user_id,round_id,idempotency_key,response)
  values (p_user_id,v_round_id,p_idempotency_key,v_response);

  return v_response;
end;
$$;
