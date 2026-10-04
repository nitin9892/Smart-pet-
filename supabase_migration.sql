-- ============================================================================
-- IDEMPOTENT & PRODUCTION-SAFE SUPABASE MIGRATION SCRIPT (FEATURE SET 2)
-- Project: Smart Pet Safety Belt
-- Target Table: public.pets
-- Target Table: public.pet_events
-- Target Storage Bucket: pet-images
-- ============================================================================

-- ----------------------------------------------------------------------------
-- STEP 1: ADD NEW PET FIELDS & UPDATE PUBLIC READ POLICY FOR LOST MODE
-- ----------------------------------------------------------------------------
ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS medical_info JSONB DEFAULT '{}'::jsonb;
ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS lost_details JSONB DEFAULT '{}'::jsonb;

-- Safely replace existing "Allow public read active pets" policy to include lost pets
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE schemaname = 'public' AND tablename = 'pets' AND policyname = 'Allow public read active pets'
    ) THEN
        DROP POLICY "Allow public read active pets" ON public.pets;
    END IF;
    
    CREATE POLICY "Allow public read active pets"
    ON public.pets
    FOR SELECT
    USING (status IN ('active', 'lost'));
END $$;

-- ----------------------------------------------------------------------------
-- STEP 2: CREATE ANALYTICS TABLE (public.pet_events) & RLS POLICIES
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.pet_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pet_id UUID NOT NULL REFERENCES public.pets(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL CHECK (event_type IN ('scan', 'call', 'whatsapp', 'lost_alert', 'location_shared')),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Performance index for analytics queries by pet_id
CREATE INDEX IF NOT EXISTS idx_pet_events_pet_id ON public.pet_events(pet_id);

-- Enable RLS on pet_events
ALTER TABLE public.pet_events ENABLE ROW LEVEL SECURITY;

-- 1. ANONYMOUS INSERT POLICY FOR PET_EVENTS (Safely created if missing)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE schemaname = 'public' AND tablename = 'pet_events' AND policyname = 'anon_insert_events'
    ) THEN
        CREATE POLICY "anon_insert_events"
        ON public.pet_events
        FOR INSERT
        TO anon
        WITH CHECK (
          pet_id IS NOT NULL AND
          event_type IN ('scan', 'call', 'whatsapp', 'lost_alert', 'location_shared')
        );
    END IF;
END $$;

-- 2. OWNER SELECT POLICY FOR PET_EVENTS (Safely created if missing)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE schemaname = 'public' AND tablename = 'pet_events' AND policyname = 'owner_select_events'
    ) THEN
        CREATE POLICY "owner_select_events"
        ON public.pet_events
        FOR SELECT
        TO authenticated
        USING (
          EXISTS (
            SELECT 1 FROM public.pets p
            WHERE p.id = pet_events.pet_id
              AND p.owner_id = auth.uid()
          )
        );
    END IF;
END $$;

-- ----------------------------------------------------------------------------
-- STEP 3: STORAGE BUCKET CONFIGURATION
-- Existing Storage Policies Preserved:
-- - "Public Read Pet Images"
-- - "Owner Insert Pet Images"
-- - "Owner Update Pet Images"
-- - "Owner Delete Pet Images"
-- ----------------------------------------------------------------------------

-- Ensure pet-images bucket exists and set public = true safely
INSERT INTO storage.buckets (id, name, public)
VALUES ('pet-images', 'pet-images', true)
ON CONFLICT (id) DO UPDATE SET public = true;
