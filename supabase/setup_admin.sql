insert into public.admins (user_id)
select id from auth.users where lower(email) = lower('ianmcgon@gmail.com')
on conflict (user_id) do nothing;

select u.email, a.created_at as admin_since
from public.admins a join auth.users u on u.id = a.user_id;
