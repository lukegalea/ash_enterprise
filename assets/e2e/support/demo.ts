import {readFileSync} from "node:fs"

/**
 * The clinic-demo tenant (`mix ash_enterprise.demo`). Its administrator, and
 * the password every demo person signs in with.
 *
 * CI seeds the tenant with `--password-file`, so the password is random and
 * lives only in that file, which E2E_DEMO_PASSWORD_FILE names. Without it the
 * task's local default applies: `mix ash_enterprise.demo` with no
 * `--password-file` sets `password1234`.
 */
export const DEMO_ADMIN = "demo-admin@example.com"

export function demoPassword(): string {
  const file = process.env.E2E_DEMO_PASSWORD_FILE
  return file ? readFileSync(file, "utf8").trim() : "password1234"
}
