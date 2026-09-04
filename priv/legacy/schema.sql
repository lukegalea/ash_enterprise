-- The simulated legacy schema: a 2010-era Rails 2.3 application.
--
-- `restful_authentication` for identity, an `acl9`-shaped role table, and a
-- `permissions` table someone bolted on in 2013. Every ugly detail here exists
-- because it was the normal thing to do at the time.
--
-- This file is applied with `psql`, NOT as an Ecto migration and NOT via Ash.
-- That is the point: the whole exercise is about a schema this application does
-- not own. See priv/legacy/README.md, and
-- docs/plans/ash-strangler-in-reference-app.md §2.

CREATE SCHEMA IF NOT EXISTS legacy;

-- The closest thing the legacy app has to an org chart. Used for report
-- filtering, never for authorization.
CREATE TABLE IF NOT EXISTS legacy.companies (
  id         serial PRIMARY KEY,
  name       varchar(255) NOT NULL,
  parent_id  integer REFERENCES legacy.companies(id),
  created_at timestamp,          -- no time zone. Written in the server's local time.
  updated_at timestamp
);

-- restful_authentication's generated users table, essentially verbatim,
-- plus the columns that accreted over fifteen years.
CREATE TABLE IF NOT EXISTS legacy.users (
  id                        serial PRIMARY KEY,
  login                     varchar(40),
  email                     varchar(100),
  first_name                varchar(40),
  last_name                 varchar(40),
  crypted_password          varchar(40),   -- SHA1(salt + password), 40 hex chars
  salt                      varchar(40),
  remember_token            varchar(40),
  remember_token_expires_at timestamp,
  activation_code           varchar(40),
  activated_at              timestamp,
  state                     varchar(20) NOT NULL DEFAULT 'passive',
  deleted_at                timestamp,     -- acts_as_paranoid
  company_id                integer REFERENCES legacy.companies(id),
  manager_id                integer REFERENCES legacy.users(id),
  created_at                timestamp,
  updated_at                timestamp
);

-- The `state` column is a CHECK constraint rather than a Rails enum, because
-- that is what `restful_authentication`'s state machine compiled down to. It is
-- load-bearing for the twin generator: a CHECK (col IN (...)) becomes an :atom
-- with `one_of`, which is what gives the mapping compiler a domain to enumerate.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'legacy_users_state_check'
  ) THEN
    ALTER TABLE legacy.users
      ADD CONSTRAINT legacy_users_state_check
      CHECK (state IN ('passive', 'pending', 'active', 'suspended', 'deleted'));
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS index_users_on_login ON legacy.users (login);
-- NOT unique. Case-sensitive. Both properties are deliberate: see §4.5.
CREATE        INDEX IF NOT EXISTS index_users_on_email ON legacy.users (email);

-- acl9-shaped roles: a role can be global (both authorizable columns NULL)
-- or scoped to one record of one class.
CREATE TABLE IF NOT EXISTS legacy.roles (
  id                serial PRIMARY KEY,
  name              varchar(40),
  authorizable_type varchar(40),
  authorizable_id   integer
);

-- HABTM join table. No primary key, no timestamps, and no foreign keys --
-- Rails 2.3 added none of the three. That is why the seed can contain a row
-- pointing at a role that no longer exists, which is a defect the new model
-- surfaces and the old one tolerated (§4.5 generalised).
CREATE TABLE IF NOT EXISTS legacy.roles_users (
  role_id integer,
  user_id integer
);

-- Added in 2013. `scope` was added in 2016 and is NULL on 94% of rows.
CREATE TABLE IF NOT EXISTS legacy.permissions (
  id            serial PRIMARY KEY,
  role_id       integer REFERENCES legacy.roles(id),
  subject_class varchar(60),   -- 'Invoice', 'PurchaseOrder', 'Report'
  action        varchar(20),   -- 'read', 'edit', 'destroy', 'manage'
  scope         varchar(20)    -- NULL | 'own' | 'company'
);

-- The VendorPM estate, as dumped in VPM-11 and mapped in VPM-12: the knex-era
-- `vendorpm` schema, plus the two `clm_*` contract-management tables the CLM
-- feature parked in the database's default schema.
--
-- The strangler compatibility migration declares views, notify triggers and
-- expression indexes over these tables, and that migration runs against the
-- test database too -- so these fixtures have to stand in for the estate. The
-- real tables exist only in the VendorPM database; tests never ran in CI on
-- this branch before, which is why the omission surfaced only now. Columns are
-- synthesized from the twins
-- (lib/ash_enterprise/legacy/twins/vendorpm_contracts.ex, generated from the
-- VPM-11 dump) and from the strangler views' SELECT lists; timestamps are bare
-- `timestamp` like everything above, because that is what the twins read and
-- what the views' AT TIME ZONE casts were generated against. No test seeds
-- rows here -- the tables exist so the compatibility layer can build.
--
-- `IF NOT EXISTS`, like everything above: against the real VendorPM database
-- this file is a no-op, and the real tables win.

CREATE SCHEMA IF NOT EXISTS vendorpm;

CREATE TABLE IF NOT EXISTS public.clm_parties (
  id          uuid PRIMARY KEY,
  "clientId"  text,
  name        text NOT NULL,
  metadata    jsonb NOT NULL,
  "createdAt" timestamp NOT NULL
);

CREATE TABLE IF NOT EXISTS public.clm_contracts (
  id                       uuid PRIMARY KEY,
  name                     text NOT NULL,
  description              text,
  "effectiveDate"          date,
  "expiryDate"             date,
  value                    numeric,
  "paymentTerm"            text,
  clauses                  jsonb NOT NULL,
  metadata                 jsonb NOT NULL,
  processed                boolean,
  verified                 boolean,
  archived                 timestamp,
  "createdAt"              timestamp NOT NULL,
  "serviceProviderPartyId" uuid,
  "clientPartyId"          uuid
);

CREATE TABLE IF NOT EXISTS vendorpm.vendors (
  id              serial PRIMARY KEY,
  company         text NOT NULL,
  email           text,
  phone           text,
  verified_status text,
  blacklisted     boolean NOT NULL,
  onboarding      boolean NOT NULL,
  created         timestamp NOT NULL
);

CREATE TABLE IF NOT EXISTS vendorpm.enterprises (
  id          serial PRIMARY KEY,
  company     text NOT NULL,
  created     timestamp,
  archived    boolean NOT NULL,
  clm_enabled boolean NOT NULL,
  data_region text NOT NULL
);

CREATE TABLE IF NOT EXISTS vendorpm.rfqs (
  id                 serial PRIMARY KEY,
  deadline           timestamp,
  created            timestamp,
  cancelled          timestamp,
  submitted          timestamp,
  last_modified      timestamp,
  cancel_reason      text,
  additional_message text,
  "public"           boolean NOT NULL
);

CREATE TABLE IF NOT EXISTS vendorpm.rfq_responses (
  id                          serial PRIMARY KEY,
  rfq_id                      integer NOT NULL,
  vendor_id                   integer NOT NULL,
  interested                  boolean,
  reason                      text,
  created                     timestamp,
  archived                    timestamp,
  additional_insured_document text
);

CREATE TABLE IF NOT EXISTS vendorpm.quotes (
  id                          serial PRIMARY KEY,
  rfq_id                      integer NOT NULL,
  vendor_id                   integer NOT NULL,
  created                     timestamp,
  submitted                   timestamp,
  updated                     timestamp,
  total_price                 numeric NOT NULL,
  procurement_review_complete boolean NOT NULL
);

CREATE TABLE IF NOT EXISTS vendorpm.compliance_documents (
  id          serial PRIMARY KEY,
  vendor_id   integer NOT NULL,
  type        text NOT NULL,
  status      text NOT NULL,
  expiry_date timestamp,
  attachment  text NOT NULL,
  created     timestamp
);
