-- Funnel 1 (headline) — Interpretation lifecycle · actor_role = analyst
-- analysis_table_explored → evidence_saved → interpretation_created
--   → interpretation_viewed → interpretation_approved → interpretation_published
--
-- Distinct-actor sequential funnel: an actor counts at step k only if they hit
-- every prior step in order (ts_server monotonic). Identity is the stable
-- anonymous_id (preserved across the pre-auth → login stitch, FR6), falling back to
-- user_id. Paste into a Metabase Native question and render as a Funnel. Optional
-- {{start_date}} / {{end_date}} are Date variables.
WITH actor_steps AS (
  SELECT
    COALESCE(anonymous_id, user_id) AS actor,
    MIN(ts_server) FILTER (WHERE event = 'analysis_table_explored')  AS s1,
    MIN(ts_server) FILTER (WHERE event = 'evidence_saved')           AS s2,
    MIN(ts_server) FILTER (WHERE event = 'interpretation_created')   AS s3,
    MIN(ts_server) FILTER (WHERE event = 'interpretation_viewed')    AS s4,
    MIN(ts_server) FILTER (WHERE event = 'interpretation_approved')  AS s5,
    MIN(ts_server) FILTER (WHERE event = 'interpretation_published') AS s6
  FROM organization_svc.events
  WHERE actor_role = 'analyst'
    AND COALESCE(anonymous_id, user_id) IS NOT NULL
    [[ AND ts_server >= {{start_date}} ]]
    [[ AND ts_server <  {{end_date}} ]]
  GROUP BY 1
),
reached AS (
  SELECT
    (s1 IS NOT NULL)                                                               AS r1,
    (s1 IS NOT NULL AND s2 >= s1)                                                  AS r2,
    (s1 IS NOT NULL AND s2 >= s1 AND s3 >= s2)                                     AS r3,
    (s1 IS NOT NULL AND s2 >= s1 AND s3 >= s2 AND s4 >= s3)                        AS r4,
    (s1 IS NOT NULL AND s2 >= s1 AND s3 >= s2 AND s4 >= s3 AND s5 >= s4)           AS r5,
    (s1 IS NOT NULL AND s2 >= s1 AND s3 >= s2 AND s4 >= s3 AND s5 >= s4 AND s6 >= s5) AS r6
  FROM actor_steps
),
by_step AS (
  SELECT v.step_no, v.step_name, count(*) FILTER (WHERE v.reached) AS users
  FROM reached r
  CROSS JOIN LATERAL (VALUES
    (1, '1. analysis_table_explored',  r.r1),
    (2, '2. evidence_saved',           r.r2),
    (3, '3. interpretation_created',   r.r3),
    (4, '4. interpretation_viewed',    r.r4),
    (5, '5. interpretation_approved',  r.r5),
    (6, '6. interpretation_published', r.r6)
  ) AS v(step_no, step_name, reached)
  GROUP BY v.step_no, v.step_name
)
SELECT
  step_name,
  users,
  round(100.0 * users / NULLIF(first_value(users) OVER (ORDER BY step_no), 0), 1) AS pct_of_entry,
  round(100.0 * users / NULLIF(lag(users)         OVER (ORDER BY step_no), 0), 1) AS pct_of_prev_step
FROM by_step
ORDER BY step_no;
