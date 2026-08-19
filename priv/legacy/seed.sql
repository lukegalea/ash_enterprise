-- Deliberately hostile seed data.
--
-- A clean seed proves nothing. Every row below violates something the target
-- model asserts, and each violation has a defined resolution in the migration
-- story rather than a fix the tooling can derive. See
-- docs/plans/ash-strangler-in-reference-app.md §3.
--
-- Idempotent: truncate first, so `mix ash_enterprise.legacy.setup` can be run
-- repeatedly without accumulating rows.

TRUNCATE legacy.permissions, legacy.roles_users, legacy.roles, legacy.users, legacy.companies
  RESTART IDENTITY CASCADE;

INSERT INTO legacy.companies (id, name, parent_id, created_at, updated_at) VALUES
  (1, 'Corp Holdings',        NULL, '2009-03-02 09:14:00', '2009-03-02 09:14:00'),
  (2, 'Corp Manufacturing',      1, '2010-07-19 11:02:00', '2014-01-08 16:45:00'),
  (3, 'Corp Logistics',          1, '2011-11-30 08:30:00', '2011-11-30 08:30:00'),
  (4, 'Northwind (acquired)',    2, '2016-05-04 13:20:00', '2016-05-04 13:20:00');

-- created_at values sit in three different local time zones, because the app
-- was moved between hosts twice (US/Eastern -> US/Pacific -> UTC) and the
-- column is a bare `timestamp`. Nothing in the database records which is which.
INSERT INTO legacy.users
  (id, login, email, first_name, last_name, crypted_password, salt, state,
   deleted_at, company_id, manager_id, created_at, updated_at)
VALUES
  -- The founder. Written while the app ran in US/Eastern.
  (1, 'awhitfield', 'a.whitfield@corp.example', 'Alan', 'Whitfield',
   '5baa61e4c9b93f3f0682250b6cf8331b7ee68fd8', 'f1c9a0', 'active',
   NULL, 1, NULL, '2009-03-02 09:15:00', '2019-02-11 10:00:00'),

  -- Two users whose emails differ only by case. `identity :unique_email` on a
  -- :ci_string considers these the same person. The legacy index does not, and
  -- under this cluster's C collation citext folds ASCII only -- which these are.
  (2, 'dana.k', 'Dana@corp.example', 'Dana', 'Kowalczyk',
   '7c4a8d09ca3762af61e59520943dc26494f8941b', 'a83b21', 'active',
   NULL, 2, 1, '2010-08-14 15:41:00', '2018-06-02 09:12:00'),
  (3, 'dkowalczyk', 'dana@corp.example', 'Dana', 'Kowalczyk',
   'b1b3773a05c0ed0176787a4f1574ff0075f7521e', 'c02f9d', 'active',
   NULL, 2, 1, '2013-01-07 10:05:00', '2013-01-07 10:05:00'),

  -- No email at all. Signs in by `login`, which is what restful_authentication
  -- actually keyed on. `allow_nil? false` on email is false of this row.
  (4, 'shipping.terminal', NULL, 'Shipping', 'Terminal',
   'da39a3ee5e6b4b0d3255bfef95601890afd80709', '0000aa', 'active',
   NULL, 3, 1, '2012-04-22 07:00:00', '2012-04-22 07:00:00'),

  -- Written while the app ran in US/Pacific.
  (5, 'rmcallister', 'r.mcallister@corp.example', 'Rosa', 'McAllister',
   '3f8ec2a5b1d9c0e4a7b6f2d1c8e5a4b3f9d2c1e0', 'd41d8c', 'active',
   NULL, 2, 7, '2015-09-08 16:30:00', '2021-03-19 11:47:00'),

  -- A surname no splitting rule fixes, which is why `full_name` is read-only.
  (6, 'jdelacruz', 'j.delacruz@corp.example', 'Josefa', 'de la Cruz',
   'ab4d8d2a5f907d3b1a1e37e0f9f4e1cbb2a0c3d7', 'e8f1b2', 'active',
   NULL, 4, 1, '2016-05-11 09:22:00', '2020-08-30 14:03:00'),

  -- Deleted (acts_as_paranoid) -- and user 5 still reports to them. A dangling
  -- manager chain the old app never noticed, because it scoped every query.
  (7, 'tobrien', 't.obrien@corp.example', 'Tomas', 'O''Brien', NULL, NULL, 'deleted',
   '2021-03-19 11:45:00', 2, 1, '2011-02-15 08:00:00', '2021-03-19 11:45:00'),

  -- Never activated. `state = 'passive'` is restful_authentication's initial
  -- state, and the row has sat here for a decade.
  (8, 'pending.contractor', 'contractor@vendor.example', 'Pat', 'Nguyen',
   NULL, NULL, 'passive',
   NULL, 3, 5, '2019-10-01 12:00:00', '2019-10-01 12:00:00'),

  -- Suspended. Written after the move to UTC.
  (9, 'lfeng', 'l.feng@corp.example', 'Li', 'Feng',
   '9c1185a5c5e9fc54612808977ee8f548b2258d31', '77bd2c', 'suspended',
   NULL, 4, 6, '2022-01-17 03:14:00', '2023-07-04 22:08:00');

SELECT setval('legacy.users_id_seq', (SELECT max(id) FROM legacy.users));
SELECT setval('legacy.companies_id_seq', (SELECT max(id) FROM legacy.companies));

INSERT INTO legacy.roles (id, name, authorizable_type, authorizable_id) VALUES
  (1, 'admin',    NULL,        NULL),
  (2, 'manager',  'Company',      2),
  (3, 'auditor',  NULL,        NULL);

-- Row (99, 4) references a role that no longer exists. There is no foreign key
-- to stop it, and the old app silently ignored the miss.
INSERT INTO legacy.roles_users (role_id, user_id) VALUES
  (1, 1), (2, 2), (2, 5), (3, 6), (99, 4);

SELECT setval('legacy.roles_id_seq', (SELECT max(id) FROM legacy.roles));

-- `action = 'manage'` means read+write+delete to the legacy app and has no
-- single equivalent in the eight-privilege Dataverse model (§4.7).
INSERT INTO legacy.permissions (role_id, subject_class, action, scope) VALUES
  (1, 'Invoice',       'manage', NULL),
  (2, 'Invoice',       'edit',   'company'),
  (2, 'PurchaseOrder', 'read',   'company'),
  (3, 'Report',        'read',   NULL),
  (3, 'Invoice',       'read',   'own');
