-- ============================================================================
-- FinAgent OS: Seed 0008: fao_settings
-- ============================================================================
-- Inserts the five FinAgent settings with their live defaults. The closed
-- key list is enforced by a CHECK on public.fao_settings.key.
--
-- Control IDs implemented:
--   FAO-GOV-002  settings are configuration: every change needs
--                fao.change_reason and is audited
--   FAO-GOV-007  notification settings (Slack API base URL, channel, retry
--                attempts) and the approval link base URL
--   FAO-GOV-001  refusal journal flood cap per actor per minute
--
-- Settings:
--   approval_app_base_url   https://approval.invalid (placeholder; set per
--                           environment with a change reason after seeding)
--   slack_api_base_url      https://slack.com/api
--   slack_channel_id        C0AUUAXS6G7 (the channel already in the exports)
--   notify_max_attempts     3
--   journal_cap_per_minute  20
--
-- A key that already exists is left as it is, so a re-run never overwrites a
-- value set for the environment.
--
-- Author: Rizwan Ahmed, ACCA, Velocyt Consulting
-- Date:   2026-11-07
-- ============================================================================

-- FAO-GOV-002: change reason for this session (required by the
-- fao_settings triggers).
SELECT set_config('fao.change_reason', 'seed 0008', false);

INSERT INTO public.fao_settings (key, value)
VALUES
  ('approval_app_base_url',  'https://approval.invalid'),
  ('slack_api_base_url',     'https://slack.com/api'),
  ('slack_channel_id',       'C0AUUAXS6G7'),
  ('notify_max_attempts',    '3'),
  ('journal_cap_per_minute', '20')
ON CONFLICT (key) DO NOTHING;

-- --- Check: all five keys present ------------------------------------------
DO $$
DECLARE
  v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM public.fao_settings;
  IF v_n <> 5 THEN
    RAISE EXCEPTION 'FAO-GOV-002 seed 0008: expected 5 settings rows, found %', v_n
      USING ERRCODE = '22023';
  END IF;
END
$$;
