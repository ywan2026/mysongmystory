-- =====================================================================
-- My Song, My Story · Supabase 설정
-- Supabase 대시보드 > SQL Editor > New query 에 전체를 붙여넣고 Run 하세요.
-- 여러 번 실행해도 괜찮습니다. (단, 아래 학생 행은 이미 있으면 그대로 둡니다)
-- =====================================================================

-- 1) 학생 표: 번호별 발표 순서(slot), 노래, 발표 완료 여부
create table if not exists public.students (
  student_no  int primary key check (student_no between 1 and 40),
  slot        int unique,                                   -- 발표 순서 (1 = Track 01)
  song_title  text check (char_length(song_title) <= 80),
  artist      text check (char_length(artist) <= 60),
  done        boolean not null default false,
  updated_at  timestamptz not null default now()
);

-- 2) 비공개 설정 표: 선생님 비밀번호 (웹페이지에서는 읽을 수 없음)
create table if not exists public.app_settings (
  key   text primary key,
  value text not null
);

-- 3) 학생 27명 행 만들기
insert into public.students (student_no)
select g from generate_series(1, 27) g
on conflict (student_no) do nothing;

-- 4) 선생님 비밀번호 (바꾸고 싶으면 '6840'만 고쳐서 다시 실행)
insert into public.app_settings (key, value) values ('teacher_pin', '6840')
on conflict (key) do update set value = excluded.value;

-- 5) 권한: 누구나 '읽기'만 가능, 쓰기는 아래 함수로만
alter table public.students     enable row level security;
alter table public.app_settings enable row level security;

drop policy if exists "anyone can read" on public.students;
create policy "anyone can read" on public.students
  for select to anon, authenticated using (true);

grant  select                 on public.students     to anon, authenticated;
revoke insert, update, delete on public.students     from anon, authenticated;
revoke all                    on public.app_settings from anon, authenticated;

-- 6) 내부용: 선생님 비밀번호 확인
create or replace function public._is_teacher(p_pin text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from app_settings where key = 'teacher_pin' and value = p_pin);
$$;
revoke all on function public._is_teacher(text) from public, anon, authenticated;

-- 7) 선생님 모드 로그인 확인 (틀리면 1초 지연: 마구 대입 방지)
create or replace function public.verify_teacher(p_pin text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if public._is_teacher(p_pin) then return true; end if;
  perform pg_sleep(1);
  return false;
end $$;

-- 8) 발표 순서 뽑기 (선생님만). 다시 뽑으면 완료 체크도 초기화, 노래 입력은 유지
create or replace function public.draw_order(p_pin text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public._is_teacher(p_pin) then
    perform pg_sleep(1);
    raise exception 'wrong_pin';
  end if;
  update students set slot = null, done = false where true;
  update students s
     set slot = r.rn, updated_at = now()
    from (select student_no, row_number() over (order by random()) as rn from students) r
   where s.student_no = r.student_no;
end $$;

-- 9) 노래 입력: 학번(307 + 두 자리 번호) 또는 선생님 비밀번호
create or replace function public.set_song(p_no int, p_code text, p_title text, p_artist text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_code is distinct from ('307' || lpad(p_no::text, 2, '0'))
     and not public._is_teacher(p_code) then
    perform pg_sleep(1);
    raise exception 'wrong_code';
  end if;
  update students
     set song_title = nullif(btrim(left(coalesce(p_title, ''), 80)), ''),
         artist     = nullif(btrim(left(coalesce(p_artist, ''), 60)), ''),
         updated_at = now()
   where student_no = p_no;
  if not found then raise exception 'no_student'; end if;
end $$;

-- 10) 발표 완료 체크 (선생님만)
create or replace function public.set_done(p_pin text, p_no int, p_done boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public._is_teacher(p_pin) then
    perform pg_sleep(1);
    raise exception 'wrong_pin';
  end if;
  update students set done = p_done, updated_at = now() where student_no = p_no;
end $$;

grant execute on function public.verify_teacher(text)               to anon, authenticated;
grant execute on function public.draw_order(text)                   to anon, authenticated;
grant execute on function public.set_song(int, text, text, text)    to anon, authenticated;
grant execute on function public.set_done(text, int, boolean)       to anon, authenticated;

-- 11) 실시간 반영 (다른 기기에서 입력하면 바로 화면에 나타나게)
do $$
begin
  alter publication supabase_realtime add table public.students;
exception when duplicate_object then null;
end $$;
