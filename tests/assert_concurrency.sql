-- Assert two simultaneous identical requests settled exactly once.
do $$
declare
  v_balance bigint;
  v_rounds bigint;
  v_spins bigint;
  v_debits bigint;
  v_credits bigint;
  v_responses bigint;
begin
  select balance into v_balance
  from concurrency_test.wallets
  where user_id='00000000-0000-4000-8000-000000000003';

  select count(*) into v_rounds from concurrency_test.rounds
  where idempotency_key='00000000-0000-4000-8000-000000000777';

  select count(*) into v_spins from concurrency_test.spins
  where idempotency_key='00000000-0000-4000-8000-000000000777';

  select count(*) into v_debits from concurrency_test.ledger
  where idempotency_key='00000000-0000-4000-8000-000000000777'
    and entry_type='DEBIT';

  select count(*) into v_credits from concurrency_test.ledger
  where idempotency_key='00000000-0000-4000-8000-000000000777'
    and entry_type='CREDIT';

  select count(distinct response) into v_responses from concurrency_test.spins
  where idempotency_key='00000000-0000-4000-8000-000000000777';

  if v_rounds <> 1 or v_spins <> 1 or v_debits <> 1
     or v_credits <> 1 or v_responses <> 1 then
    raise exception 'Concurrency/idempotency assertion failed: rounds %, spins %, debits %, credits %, responses %',
      v_rounds,v_spins,v_debits,v_credits,v_responses;
  end if;

  if v_balance <> 16800 then
    raise exception 'Expected one debit and one credit: expected 16800, got %',v_balance;
  end if;
end;
$$;
