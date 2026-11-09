defmodule AshEnterprise.Repo.Migrations.TypeTheStranglerUserNulls do
  @moduledoc """
  Brings the installed strangler objects up to what `mix ash_strangler.gen.migration` writes today.

  Written by hand from that task's output, because one statement of it cannot run as generated:

    * `strangler.users` renders its `unmapped ..., as: :null` columns as a NULL cast to the
      attribute's Postgres type (`NULL::uuid`). The installed view has a bare `NULL` there, which
      Postgres types as `text`, and `CREATE OR REPLACE VIEW` refuses to change a column's type. So
      the view is dropped and created again (documentation/topics/phases.md in ash_strangler,
      "Changing a view's shape, in any phase"). Nothing in this schema depends on the view, which is
      why the `DROP VIEW` has no `CASCADE`: a dependent that appears later makes this fail instead
      of being dropped with it. A `DROP` loses the view's privileges, so they are read first and
      granted again afterwards, table and column level alike. The view's owner is the role running
      the migration both before and after.

    * The ledger trigger function names the legacy table's columns instead of calling
      `to_jsonb(NEW)`, runs the row reads inside a savepoint so a legacy migration that renames a
      column cannot abort the legacy application's write, and records the attribution the
      enclosing transaction declared. The columns it writes to already exist on
      `legacy_change_events`; only the function changes (`CREATE OR REPLACE`).

    * `strangler_observations` and `strangler_receipts` are new.

  The statements the generator also writes and that are unchanged (the schema, the key index, the
  `legacy_change_events` table and index, the ledger trigger's definition) are not repeated.
  """

  use Ecto.Migration

  def up do
    save_view_privileges()

    execute("""
    DROP VIEW IF EXISTS "strangler"."users";
    """)

    execute("""
    CREATE OR REPLACE VIEW "strangler"."users" AS
    SELECT
      uuid_generate_v5('ce41843a-c056-4c3e-9c79-50e7e5f4887c'::uuid, 'legacy.users:' || id::text) AS id,
      id AS __legacy_id,
      ('00000000-0000-0000-0000-0000000000fe')::uuid AS organization_id,
      ('00000000-0000-0000-0000-0000000000fd')::uuid AS owning_business_unit_id,
      (CASE WHEN (state = 'active') THEN ('active')::text ELSE ('inactive')::text END) AS lifecycle_status,
      1 AS version_number,
      NULL::bigint AS import_sequence_number,
      NULL::timestamptz AS overridden_created_on,
      NULL::uuid AS modified_on_behalf_by_id,
      NULL::uuid AS created_on_behalf_by_id,
      NULL::uuid AS modified_by_id,
      NULL::uuid AS created_by_id,
      (updated_at AT TIME ZONE 'UTC') AS modified_on,
      (created_at AT TIME ZONE 'UTC') AS created_on,
      id AS legacy_id,
      login AS login,
      (email)::citext AS email,
      (coalesce(first_name, '') || (' ' || coalesce(last_name, ''))) AS full_name,
      (state)::text AS legacy_state,
      (deleted_at AT TIME ZONE 'UTC') AS archived_at
    FROM legacy.users;
    """)

    restore_view_privileges()

    execute("""
    CREATE OR REPLACE FUNCTION "strangler_ledger_legacy_users"() RETURNS trigger
    SET search_path FROM CURRENT
    AS $strangler$
    DECLARE
      event_id bigint;
      affected record;
      old_row jsonb;
      new_row jsonb;
      changed jsonb;
      actor_confidence text;
    BEGIN
      affected := COALESCE(NEW, OLD);

      -- Everything that reads the row runs inside this block, which is a
      -- savepoint. The image names columns, and PL/pgSQL records no dependency
      -- on them: a legacy migration that renames or drops one goes through,
      -- and from then on reading it raises 42703 on every write. Inside the
      -- block that is a skipped event; outside it, an outage of the legacy
      -- application. A ledger that cannot be written is logged and skipped,
      -- never allowed to abort the legacy write.
      BEGIN
        IF (TG_OP = 'DELETE') THEN
          old_row := jsonb_build_object('id', OLD."id", 'login', OLD."login", 'email', OLD."email", 'first_name', OLD."first_name", 'last_name', OLD."last_name", 'crypted_password', OLD."crypted_password", 'salt', OLD."salt", 'remember_token', OLD."remember_token", 'remember_token_expires_at', OLD."remember_token_expires_at", 'activation_code', OLD."activation_code", 'activated_at', OLD."activated_at", 'state', OLD."state", 'deleted_at', OLD."deleted_at", 'company_id', OLD."company_id", 'manager_id', OLD."manager_id", 'created_at', OLD."created_at", 'updated_at', OLD."updated_at");
          new_row := NULL;
          changed := NULL;
        ELSIF (TG_OP = 'INSERT') THEN
          old_row := NULL;
          new_row := jsonb_build_object('id', NEW."id", 'login', NEW."login", 'email', NEW."email", 'first_name', NEW."first_name", 'last_name', NEW."last_name", 'crypted_password', NEW."crypted_password", 'salt', NEW."salt", 'remember_token', NEW."remember_token", 'remember_token_expires_at', NEW."remember_token_expires_at", 'activation_code', NEW."activation_code", 'activated_at', NEW."activated_at", 'state', NEW."state", 'deleted_at', NEW."deleted_at", 'company_id', NEW."company_id", 'manager_id', NEW."manager_id", 'created_at', NEW."created_at", 'updated_at', NEW."updated_at");
          changed := new_row;
        ELSE
          old_row := jsonb_build_object('id', OLD."id", 'login', OLD."login", 'email', OLD."email", 'first_name', OLD."first_name", 'last_name', OLD."last_name", 'crypted_password', OLD."crypted_password", 'salt', OLD."salt", 'remember_token', OLD."remember_token", 'remember_token_expires_at', OLD."remember_token_expires_at", 'activation_code', OLD."activation_code", 'activated_at', OLD."activated_at", 'state', OLD."state", 'deleted_at', OLD."deleted_at", 'company_id', OLD."company_id", 'manager_id', OLD."manager_id", 'created_at', OLD."created_at", 'updated_at', OLD."updated_at");
          new_row := jsonb_build_object('id', NEW."id", 'login', NEW."login", 'email', NEW."email", 'first_name', NEW."first_name", 'last_name', NEW."last_name", 'crypted_password', NEW."crypted_password", 'salt', NEW."salt", 'remember_token', NEW."remember_token", 'remember_token_expires_at', NEW."remember_token_expires_at", 'activation_code', NEW."activation_code", 'activated_at', NEW."activated_at", 'state', NEW."state", 'deleted_at', NEW."deleted_at", 'company_id', NEW."company_id", 'manager_id', NEW."manager_id", 'created_at', NEW."created_at", 'updated_at', NEW."updated_at");
          changed := (
            SELECT COALESCE(jsonb_object_agg(pair.key, pair.value), '{}'::jsonb)
              FROM jsonb_each(new_row) AS pair
             WHERE (old_row -> pair.key) IS DISTINCT FROM pair.value
          );
        END IF;

        -- Attribution: whatever the enclosing transaction declared through
        -- AshStrangler.Context (custom GUCs, transaction-local). Absent context
        -- stays absent -- current_setting's `true` yields NULL and the slot
        -- stays empty, which is the honest value. Capture itself is never
        -- suppressed: the context decorates the event, it does not gate it.
        actor_confidence := CASE
          WHEN nullif(current_setting('ash_strangler.origin', true), '') IS NOT NULL
            OR nullif(current_setting('ash_strangler.correlation_id', true), '') IS NOT NULL
            OR nullif(current_setting('ash_strangler.causation_id', true), '') IS NOT NULL
            OR nullif(current_setting('ash_strangler.actor', true), '') IS NOT NULL
          THEN 'asserted' ELSE NULL END;

        -- Committed WITH the legacy write or not at all: that is the whole
        -- guarantee the ledger exists for, and it is why this is a synchronous
        -- insert rather than a queue.
        INSERT INTO "legacy_change_events"
          (source_schema, source_table, operation, primary_key, old_row, new_row,
           changed_columns, transaction_id, transaction_timestamp,
           source_system, source_correlation_id, source_request_id, source_user,
           actor_confidence)
        VALUES
          (TG_TABLE_SCHEMA, TG_TABLE_NAME, lower(TG_OP),
           jsonb_build_object('id', affected.id),
           old_row, new_row, changed,
           txid_current(), transaction_timestamp(),
           nullif(current_setting('ash_strangler.origin', true), ''),
           nullif(current_setting('ash_strangler.correlation_id', true), ''),
           nullif(current_setting('ash_strangler.causation_id', true), ''),
           nullif(current_setting('ash_strangler.actor', true), ''),
           actor_confidence)
        RETURNING id INTO event_id;

        -- The wake, key-only. The event id is a bigint, so the payload is a
        -- handful of bytes no matter how wide the row is -- the 7999-byte
        -- pg_notify ceiling aborts the LEGACY application's transaction, and a
        -- drain re-reads the durable row anyway.
        PERFORM pg_notify('ash_strangler', 'wake:' || event_id);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'ash_strangler ledger for %.% skipped: % (%)',
          TG_TABLE_SCHEMA, TG_TABLE_NAME, SQLERRM, SQLSTATE;
      END;

      -- The return value of an AFTER row trigger is ignored.
      RETURN NULL;
    END $strangler$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE OR REPLACE TRIGGER "strangler_ledger_legacy_users"
      AFTER INSERT OR UPDATE OR DELETE ON legacy.users
      FOR EACH ROW EXECUTE FUNCTION "strangler_ledger_legacy_users"();
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS "strangler_observations" (
      id uuid PRIMARY KEY,
      source_event_id bigint,
      baseline_group uuid,
      category text NOT NULL,
      resource text NOT NULL,
      record_id text,
      operation text NOT NULL,
      before jsonb,
      after jsonb,
      changed_attributes jsonb,
      invalidated_attributes jsonb,
      origin text NOT NULL,
      attribution jsonb NOT NULL,
      correlation_id text,
      causation_id text,
      mapping_version text NOT NULL,
      source jsonb NOT NULL,
      captured_at timestamptz NOT NULL,
      recorded_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS strangler_observations_event_idx
      ON "strangler_observations" (source_event_id, resource)
      WHERE category = 'observation'
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS strangler_observations_baseline_idx
      ON "strangler_observations" (record_id, resource, baseline_group)
      WHERE category = 'baseline'
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS "strangler_receipts" (
      consumer text NOT NULL,
      observation_id uuid NOT NULL,
      state text NOT NULL,
      attempts integer NOT NULL DEFAULT 0,
      last_error text,
      recorded_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (consumer, observation_id)
    )
    """)
  end

  def down do
    execute("""
    DROP TABLE IF EXISTS "strangler_receipts";
    """)

    execute("""
    DROP INDEX IF EXISTS "strangler_observations_baseline_idx";
    """)

    execute("""
    DROP INDEX IF EXISTS "strangler_observations_event_idx";
    """)

    execute("""
    DROP TABLE IF EXISTS "strangler_observations";
    """)

    # The ledger function as it was before: the whole row through to_jsonb, no savepoint, no
    # attribution. The trigger that calls it is untouched, so replacing the function is enough.
    execute("""
    CREATE OR REPLACE FUNCTION "strangler_ledger_legacy_users"() RETURNS trigger
    SET search_path FROM CURRENT
    AS $strangler$
    DECLARE
      event_id bigint;
      affected record;
      old_row jsonb;
      new_row jsonb;
      changed jsonb;
    BEGIN
      affected := COALESCE(NEW, OLD);

      IF (TG_OP = 'DELETE') THEN
        old_row := to_jsonb(OLD);
        new_row := NULL;
        changed := NULL;
      ELSIF (TG_OP = 'INSERT') THEN
        old_row := NULL;
        new_row := to_jsonb(NEW);
        changed := new_row;
      ELSE
        old_row := to_jsonb(OLD);
        new_row := to_jsonb(NEW);
        changed := (
          SELECT COALESCE(jsonb_object_agg(pair.key, pair.value), '{}'::jsonb)
            FROM jsonb_each(new_row) AS pair
           WHERE (old_row -> pair.key) IS DISTINCT FROM pair.value
        );
      END IF;

      -- Committed WITH the legacy write or not at all: that is the whole
      -- guarantee the ledger exists for, and it is why this is a synchronous
      -- insert rather than a queue.
      INSERT INTO "legacy_change_events"
        (source_schema, source_table, operation, primary_key, old_row, new_row,
         changed_columns, transaction_id, transaction_timestamp)
      VALUES
        (TG_TABLE_SCHEMA, TG_TABLE_NAME, lower(TG_OP),
         jsonb_build_object('id', affected.id),
         old_row, new_row, changed,
         txid_current(), transaction_timestamp())
      RETURNING id INTO event_id;

      -- The wake, key-only. The event id is a bigint, so the payload is a
      -- handful of bytes no matter how wide the row is -- the 7999-byte
      -- pg_notify ceiling aborts the LEGACY application's transaction, and a
      -- drain re-reads the durable row anyway.
      PERFORM pg_notify('ash_strangler', 'wake:' || event_id);

      -- The return value of an AFTER row trigger is ignored.
      RETURN NULL;
    END $strangler$ LANGUAGE plpgsql;
    """)

    save_view_privileges()

    execute("""
    DROP VIEW IF EXISTS "strangler"."users";
    """)

    execute("""
    CREATE OR REPLACE VIEW "strangler"."users" AS
    SELECT
      uuid_generate_v5('ce41843a-c056-4c3e-9c79-50e7e5f4887c'::uuid, 'legacy.users:' || id::text) AS id,
      id AS __legacy_id,
      ('00000000-0000-0000-0000-0000000000fe')::uuid AS organization_id,
      ('00000000-0000-0000-0000-0000000000fd')::uuid AS owning_business_unit_id,
      (CASE WHEN (state = 'active') THEN ('active')::text ELSE ('inactive')::text END) AS lifecycle_status,
      1 AS version_number,
      NULL AS import_sequence_number,
      NULL AS overridden_created_on,
      NULL AS modified_on_behalf_by_id,
      NULL AS created_on_behalf_by_id,
      NULL AS modified_by_id,
      NULL AS created_by_id,
      (updated_at AT TIME ZONE 'UTC') AS modified_on,
      (created_at AT TIME ZONE 'UTC') AS created_on,
      id AS legacy_id,
      login AS login,
      (email)::citext AS email,
      (coalesce(first_name, '') || (' ' || coalesce(last_name, ''))) AS full_name,
      (state)::text AS legacy_state,
      (deleted_at AT TIME ZONE 'UTC') AS archived_at
    FROM legacy.users;
    """)

    restore_view_privileges()
  end

  # A DROP VIEW takes the grants with it. These two read them into a temporary table that lives
  # until the migration's transaction ends, and grant them again on the new view. A view with no
  # grants gives empty tables and the second statement does nothing.
  defp save_view_privileges do
    execute("""
    CREATE TEMP TABLE strangler_users_privileges ON COMMIT DROP AS
    SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END AS grantee,
           a.privilege_type,
           a.is_grantable,
           NULL::text AS column_name
      FROM pg_class c
     CROSS JOIN LATERAL aclexplode(c.relacl) a
      LEFT JOIN pg_roles r ON r.oid = a.grantee
     WHERE c.oid = to_regclass('strangler.users')
    UNION ALL
    SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END,
           a.privilege_type,
           a.is_grantable,
           att.attname::text
      FROM pg_attribute att
     CROSS JOIN LATERAL aclexplode(att.attacl) a
      LEFT JOIN pg_roles r ON r.oid = a.grantee
     WHERE att.attrelid = to_regclass('strangler.users') AND att.attnum > 0 AND att.attacl IS NOT NULL
    """)
  end

  defp restore_view_privileges do
    execute("""
    DO $strangler$
    DECLARE
      p record;
    BEGIN
      FOR p IN SELECT * FROM strangler_users_privileges LOOP
        EXECUTE format('GRANT %s%s ON "strangler"."users" TO %s%s',
          p.privilege_type,
          CASE WHEN p.column_name IS NULL THEN '' ELSE format(' (%I)', p.column_name) END,
          p.grantee,
          CASE WHEN p.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END);
      END LOOP;
    END $strangler$;
    """)

    execute("""
    DROP TABLE strangler_users_privileges;
    """)
  end
end
