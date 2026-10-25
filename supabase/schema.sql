-- 「市長，你給我好好做！」第一階段：登入、雲端紀錄、排行榜
-- 使用方式：Supabase 後台 → SQL Editor → New query → 整段貼上 → Run。可以重複執行。

-- 1. 市長資料（每個帳號一筆）
create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  mayor_name  text not null check (char_length(mayor_name) between 1 and 12),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- 2. 每一局的紀錄
create table if not exists public.runs (
  id              bigint generated always as identity primary key,
  user_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  mayor_name      text not null check (char_length(mayor_name) between 1 and 12),
  city            text not null check (city in ('taipei','newtaipei','taoyuan','taichung','tainan','kaohsiung')),
  result          text not null check (result in ('complete','over')),
  tier            text not null check (tier in ('over','ok','good','president')),
  style           text check (char_length(style) <= 20),
  approval        int  not null check (approval between 0 and 100),
  months          int  not null check (months between 0 and 48),
  resolved        int  not null check (resolved between 0 and 120),
  failed          int  not null check (failed between 0 and 120),
  score           int  not null check (score between 0 and 6000),
  client_ended_at bigint,
  created_at      timestamptz not null default now(),
  -- 分數要和遊戲公式一致，擋掉直接亂填的分數
  constraint score_formula check (
    score = greatest(0, approval*10 + resolved*40 - failed*25 + case when result = 'complete' then 300 else 0 end)
  ),
  -- 評語要和喜愛度一致
  constraint tier_matches check (
    (tier = 'over' and (result = 'over' or approval <= 30)) or
    (tier = 'ok' and result = 'complete' and approval between 31 and 69) or
    (tier = 'good' and result = 'complete' and approval between 70 and 79) or
    (tier = 'president' and result = 'complete' and approval >= 80)
  ),
  -- 做滿任期一定是 48 個月
  constraint months_matches check (result = 'over' or months = 48)
);
create index if not exists runs_user_idx  on public.runs (user_id, created_at desc);
create index if not exists runs_board_idx on public.runs (city, created_at desc, score desc);

-- 3. 權限：每個人只能讀寫自己的資料
alter table public.profiles enable row level security;
alter table public.runs     enable row level security;

drop policy if exists "profiles: read own"   on public.profiles;
drop policy if exists "profiles: insert own" on public.profiles;
drop policy if exists "profiles: update own" on public.profiles;
create policy "profiles: read own"   on public.profiles for select to authenticated using (id = auth.uid());
create policy "profiles: insert own" on public.profiles for insert to authenticated with check (id = auth.uid());
create policy "profiles: update own" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "runs: read own"   on public.runs;
drop policy if exists "runs: insert own" on public.runs;
drop policy if exists "runs: delete own" on public.runs;
create policy "runs: read own"   on public.runs for select to authenticated using (user_id = auth.uid());
create policy "runs: insert own" on public.runs for insert to authenticated with check (user_id = auth.uid());
create policy "runs: delete own" on public.runs for delete to authenticated using (user_id = auth.uid());
-- 不開放 update：成績送出後不能再改

-- 4. 防止灌紀錄：同一個帳號 20 秒內只能送一筆，一天最多 200 筆
create or replace function public.runs_rate_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.runs where user_id = new.user_id and created_at > now() - interval '20 seconds') then
    raise exception 'too many runs, please wait';
  end if;
  if (select count(*) from public.runs where user_id = new.user_id and created_at > now() - interval '1 day') >= 200 then
    raise exception 'daily run limit reached';
  end if;
  new.created_at := now();
  return new;
end $$;
drop trigger if exists runs_rate_limit on public.runs;
create trigger runs_rate_limit before insert on public.runs for each row execute function public.runs_rate_limit();

-- 5. 排行榜：每人每城市只取最高分；只公開市長姓名、城市、分數、喜愛度、評語、日期
create or replace function public.get_leaderboard(p_city text default null, p_days int default 7, p_limit int default 20)
returns table (mayor_name text, city text, score int, approval int, tier text, played_at timestamptz)
language sql stable security definer set search_path = public as $$
  select mayor_name, city, score, approval, tier, created_at
  from (
    select distinct on (user_id, city) mayor_name, city, score, approval, tier, created_at
    from public.runs
    where (p_city is null or city = p_city)
      and created_at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 3650)))
    order by user_id, city, score desc, created_at asc
  ) best
  order by score desc, played_at asc
  limit greatest(1, least(coalesce(p_limit, 20), 50));
$$;
revoke all on function public.get_leaderboard(text, int, int) from public;
grant execute on function public.get_leaderboard(text, int, int) to anon, authenticated;
