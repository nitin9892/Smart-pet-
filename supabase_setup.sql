-- =====================================================================
-- Smart Pet Safety Belt — Supabase security setup (RLS + Storage)
-- Project ref: qxzxzuyrzuqwgdunzlek   (project "Smart-pet-info")
-- Table: public.pets      Storage bucket: pet-images
--
-- This is the authoritative record of the changes applied to the live
-- project. It is idempotent (safe to re-run): every policy is dropped
-- if it exists, then recreated. Postgres has no
-- "CREATE POLICY IF NOT EXISTS", hence the DROP ... IF EXISTS pattern.
--
-- HOW TO RUN: Supabase dashboard -> SQL Editor -> paste -> Run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. TABLE (created only if missing; existing table is left untouched).
--    owner_id links each pet to its authenticated owner.
--    Note: an unquoted "PETS" is stored by Postgres as lowercase "pets",
--    which is the name the app code uses — so the code and DB agree.
-- ---------------------------------------------------------------------
create table if not exists public.pets (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid references auth.users(id) on delete cascade,
  name          text,
  breed         text,
  category      text,
  age           text,
  gender        text,
  description   text,
  image_url     text,
  owner_name    text,
  owner_phone   text,
  locality      text,
  pincode       text,
  emergency_msg text,
  tags          jsonb default '[]'::jsonb,
  vaccines      jsonb default '[]'::jsonb,
  status        text  default 'active',
  created_at    timestamptz default now()
);

alter table public.pets enable row level security;
create index if not exists pets_owner_id_idx on public.pets(owner_id);
create index if not exists pets_status_idx   on public.pets(status);

-- ---------------------------------------------------------------------
-- 2. REMOVE THE INSECURE / OVER-BROAD POLICIES THAT WERE PRESENT.
--    "Anon full access pets" was the critical one: role = public,
--    command = ALL, USING true — it let anyone read, edit or delete
--    every pet, which defeated RLS completely. The other two public
--    SELECT policies (USING true) exposed every pet, including
--    deactivated ones.
-- ---------------------------------------------------------------------
drop policy if exists "Anon full access pets" on public.pets;
drop policy if exists "Public read pets"       on public.pets;
drop policy if exists "pets_public_select"     on public.pets;

-- Redundant duplicate owner policies (superseded by the owners_* set below)
drop policy if exists "pets_owner_insert" on public.pets;
drop policy if exists "pets_owner_update" on public.pets;
drop policy if exists "pets_owner_delete" on public.pets;

-- ---------------------------------------------------------------------
-- 3. OWNER POLICIES — an owner can only ever touch their own rows.
--    owner_id is always the authenticated user's id, so changing the
--    pet id / URL / API request cannot grant access to another owner's
--    pet. This is the real security layer, not JavaScript filtering.
-- ---------------------------------------------------------------------
drop policy if exists "owners_select_own_pets" on public.pets;
create policy "owners_select_own_pets" on public.pets
  for select to authenticated using (owner_id = auth.uid());

drop policy if exists "owners_insert_own_pets" on public.pets;
create policy "owners_insert_own_pets" on public.pets
  for insert to authenticated with check (owner_id = auth.uid());

drop policy if exists "owners_update_own_pets" on public.pets;
create policy "owners_update_own_pets" on public.pets
  for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists "owners_delete_own_pets" on public.pets;
create policy "owners_delete_own_pets" on public.pets
  for delete to authenticated using (owner_id = auth.uid());

-- ---------------------------------------------------------------------
-- 4. PUBLIC READ — the NFC/QR page (index.html?id=<PET_ID>) must work
--    WITHOUT login, but a visitor may read only ACTIVE pets. Deactivated
--    pets stay hidden. The owner phone / name shown on the page are
--    public by design (Call Now, tap-to-reveal, WhatsApp SOS).
-- ---------------------------------------------------------------------
drop policy if exists "public_read_active_pets" on public.pets;
create policy "public_read_active_pets" on public.pets
  for select to anon, authenticated using (status = 'active');

-- ---------------------------------------------------------------------
-- 5. STORAGE (pet-images bucket).
--    Removed: a public ("anon") INSERT policy and blanket authenticated
--    INSERT/DELETE policies with no per-owner scoping — anyone could
--    upload to, or delete from, the bucket. Replaced with folder-scoped
--    policies: an owner may only write under "<their-uuid>/...".
-- ---------------------------------------------------------------------
drop policy if exists "Anon upload pet-images"  on storage.objects;
drop policy if exists "pet_images_auth_upload"  on storage.objects;
drop policy if exists "pet_images_auth_delete"  on storage.objects;
drop policy if exists "Public read pet-images"  on storage.objects;
drop policy if exists "pet_images_public_read"  on storage.objects;

-- Pet photos stay publicly viewable (needed by the public profile)
create policy "pet_images_public_read" on storage.objects
  for select to anon, authenticated using (bucket_id = 'pet-images');

-- Owners may write only inside their own folder: <owner_id>/<filename>
create policy "pet_images_owner_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'pet-images'
              and (storage.foldername(name))[1] = auth.uid()::text);

create policy "pet_images_owner_update" on storage.objects
  for update to authenticated
  using  (bucket_id = 'pet-images' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'pet-images' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "pet_images_owner_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'pet-images' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------------------------------------------------------------------
-- 6. OPTIONAL dashboard setting (not SQL): enable
--    Auth -> Password Security -> "Leaked password protection".
--    The security advisor flags it as disabled.
-- ---------------------------------------------------------------------
