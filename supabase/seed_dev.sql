-- DEVELOPMENT ONLY. Never run against production. Creates no auth users (create them via the app / dashboard);
-- shows how to bootstrap a demo group once two accounts exist. Replace the emails first.
do $$
declare a uuid; b uuid; g uuid;
begin
  select id into a from auth.users where email = 'demo.one@example.com';
  select id into b from auth.users where email = 'demo.two@example.com';
  if a is null or b is null then raise notice 'Create the two demo accounts first.'; return; end if;
  perform set_config('request.jwt.claim.sub', a::text, true);
  g := create_group('Demo Room');
  raise notice 'Created group % (invite code: %)', g, create_group_invite(g);
end $$;
