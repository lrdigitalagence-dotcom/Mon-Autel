-- MON AUTEL : schéma Supabase. Colle tout dans SQL Editor, puis touche Run.

create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  name text,
  plan text not null default 'gratuit' check (plan in ('gratuit','standard','premium')),
  created_at timestamptz default now()
);
create table public.groups (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users on delete cascade,
  name text not null,
  code text unique not null default substr(upper(md5(random()::text)),1,6),
  created_at timestamptz default now()
);
create table public.group_members (
  group_id uuid references public.groups on delete cascade,
  user_id uuid references auth.users on delete cascade,
  joined_at timestamptz default now(),
  primary key (group_id, user_id)
);
create table public.programs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  group_id uuid references public.groups on delete cascade,
  theme text not null,
  days int not null check (days in (7,21,40)),
  hour time not null,
  fast boolean default false,
  start_date date not null,
  created_at timestamptz default now()
);
create table public.progress (
  program_id uuid references public.programs on delete cascade,
  user_id uuid references auth.users on delete cascade,
  day int not null,
  done_at timestamptz default now(),
  primary key (program_id, user_id, day)
);
create table public.journal (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  program_id uuid references public.programs on delete set null,
  day int,
  body text not null,
  created_at timestamptz default now()
);

alter table public.profiles enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.programs enable row level security;
alter table public.progress enable row level security;
alter table public.journal enable row level security;

create function public.is_member(g uuid) returns boolean
language sql security definer set search_path = public as $$
  select exists(select 1 from group_members where group_id = g and user_id = auth.uid())
      or exists(select 1 from groups where id = g and owner_id = auth.uid())
$$;

create function public.join_group(c text) returns uuid
language plpgsql security definer set search_path = public as $$
declare g uuid;
begin
  select id into g from groups where code = upper(c);
  if g is null then raise exception 'Code inconnu'; end if;
  insert into group_members(group_id, user_id) values (g, auth.uid()) on conflict do nothing;
  return g;
end $$;

create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, name) values (new.id, coalesce(new.raw_user_meta_data->>'name',''));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Profil : lecture et modification du nom seulement. Le plan ne change que via le paiement (serveur).
create policy "profil: lire le sien" on public.profiles for select using (id = auth.uid());
create policy "profil: modifier le sien" on public.profiles for update using (id = auth.uid());
revoke update on public.profiles from authenticated, anon;
grant update (name) on public.profiles to authenticated;

-- Groupes : seul un abonné Premium peut en créer.
create policy "groupe: lire" on public.groups for select using (public.is_member(id));
create policy "groupe: créer (Premium)" on public.groups for insert
  with check (owner_id = auth.uid() and exists(select 1 from public.profiles where id = auth.uid() and plan = 'premium'));
create policy "groupe: modifier" on public.groups for update using (owner_id = auth.uid());
create policy "groupe: supprimer" on public.groups for delete using (owner_id = auth.uid());

create policy "membres: lire" on public.group_members for select using (public.is_member(group_id));
create policy "membres: quitter ou retirer" on public.group_members for delete
  using (user_id = auth.uid() or exists(select 1 from public.groups g where g.id = group_id and g.owner_id = auth.uid()));

create policy "programme: lire" on public.programs for select
  using (user_id = auth.uid() or (group_id is not null and public.is_member(group_id)));
create policy "programme: créer" on public.programs for insert
  with check (user_id = auth.uid() and (group_id is null or exists(select 1 from public.groups g where g.id = group_id and g.owner_id = auth.uid())));
create policy "programme: modifier" on public.programs for update using (user_id = auth.uid());
create policy "programme: supprimer" on public.programs for delete using (user_id = auth.uid());

create policy "progression: lire" on public.progress for select
  using (user_id = auth.uid() or exists(select 1 from public.programs p join public.groups g on g.id = p.group_id where p.id = program_id and g.owner_id = auth.uid()));
create policy "progression: écrire" on public.progress for insert with check (user_id = auth.uid());
create policy "progression: retirer" on public.progress for delete using (user_id = auth.uid());

create policy "journal: privé" on public.journal for all using (user_id = auth.uid()) with check (user_id = auth.uid());
