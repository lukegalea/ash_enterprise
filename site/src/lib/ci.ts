/**
 * The CI workflow as the site describes it, read from `.github/workflows/ci.yml`
 * at build time. The proof page lists the jobs and steps from here, so it says
 * what CI runs rather than what someone remembers it running.
 *
 * The workflow's shape is regular (two-space YAML, one job per `  id:` line,
 * steps as `      - name:` or `      - run:`), so a line reader is enough and
 * no YAML dependency is added. `describe()` throws when a job in the file has
 * no description below, or a description names a job that is gone: adding or
 * removing a CI job fails the site build until this page is updated with it.
 */

const files = import.meta.glob('../../../.github/workflows/ci.yml', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

const text: string = Object.values(files)[0] ?? '';

/** The workflow's repo-relative path, for links. */
export const ciPath = '.github/workflows/ci.yml';

export interface CiStep {
  /** The step's `name`, or null for an unnamed `- run:` step. */
  name: string | null;
  /** First line of its `run:` command, if it has one. */
  run: string | null;
}

export interface CiJob {
  id: string;
  name: string;
  /** False when the job sets `continue-on-error: true`. */
  blocking: boolean;
  /** Matrix size, for a job that fans out (the test shards). */
  matrix: number | null;
  steps: CiStep[];
}

const unquote = (s: string): string => s.trim().replace(/^["']|["']$/g, '');

function parse(source: string): { jobs: CiJob[]; pushBranches: string[]; pullRequests: boolean } {
  const lines = source.split('\n');
  const jobsAt = lines.findIndex((l) => l === 'jobs:');
  if (jobsAt < 0) throw new Error(`${ciPath}: no top-level jobs: key`);

  const branchesLine = lines.slice(0, jobsAt).find((l) => /^\s+branches:\s*\[/.test(l)) ?? '';
  const pushBranches = (branchesLine.match(/\[(.*)\]/)?.[1] ?? '').split(',').map(unquote).filter(Boolean);
  const pullRequests = lines.slice(0, jobsAt).some((l) => /^  pull_request:/.test(l));

  const jobs: CiJob[] = [];
  let job: CiJob | null = null;
  let step: CiStep | null = null;

  for (let i = jobsAt + 1; i < lines.length; i += 1) {
    const line = lines[i];
    if (/^\S/.test(line)) break;

    const header = line.match(/^  ([A-Za-z0-9_-]+):\s*$/);
    if (header) {
      job = { id: header[1], name: header[1], blocking: true, matrix: null, steps: [] };
      jobs.push(job);
      step = null;
      continue;
    }
    if (!job) continue;

    const name = line.match(/^    name:\s*(.+)$/);
    if (name) job.name = unquote(name[1]);
    if (/^    continue-on-error:\s*true\s*$/.test(line)) job.blocking = false;

    const partition = line.match(/^        partition:\s*\[(.*)\]/);
    if (partition) job.matrix = partition[1].split(',').filter((s) => s.trim()).length;

    const named = line.match(/^      - name:\s*(.+)$/);
    const bareRun = line.match(/^      - run:\s*(.+)$/);
    if (named) {
      step = { name: unquote(named[1]), run: null };
      job.steps.push(step);
    } else if (bareRun) {
      step = { name: null, run: bareRun[1].trim() };
      job.steps.push(step);
    } else if (/^      - /.test(line)) {
      step = null;
    } else if (step && step.run === null) {
      const run = line.match(/^        run:\s*(.*)$/);
      if (run) {
        const first = run[1].trim();
        step.run = first === '|' ? (lines[i + 1] ?? '').trim() : first;
      }
    }
  }

  if (jobs.length === 0) throw new Error(`${ciPath}: no jobs found`);
  return { jobs, pushBranches, pullRequests };
}

const parsed = parse(text);

/** Every job in the workflow, in file order. */
export const ciJobs: readonly CiJob[] = parsed.jobs;
/** Branches a push runs CI on, e.g. `main`, `ci/**`. */
export const ciPushBranches: readonly string[] = parsed.pushBranches;
/** True when pull requests run the workflow. */
export const ciOnPullRequests: boolean = parsed.pullRequests;

/** A job by id; throws when the workflow has no such job. */
export function ciJob(id: string): CiJob {
  const found = ciJobs.find((j) => j.id === id);
  if (!found) throw new Error(`${ciPath} has no job "${id}"`);
  return found;
}

/** A step by name in a job; throws when it is gone, so prose about it cannot outlive it. */
export function ciStep(jobId: string, stepName: string): CiStep {
  const found = ciJob(jobId).steps.find((s) => s.name === stepName);
  if (!found) throw new Error(`${ciPath}: job "${jobId}" has no step "${stepName}"`);
  return found;
}

/** A job's display name with the matrix variable written as `N`. */
export function jobTitle(job: CiJob): string {
  return job.name.replace(/\$\{\{\s*matrix\.[a-z_]+\s*\}\}/g, 'N');
}

/**
 * Pair each job with the caller's one-line description of it. Throws when the
 * two sets of ids differ, naming the difference.
 */
export function describe<T>(descriptions: Record<string, T>): { job: CiJob; about: T }[] {
  const ids = ciJobs.map((j) => j.id);
  const missing = ids.filter((id) => !(id in descriptions));
  const stale = Object.keys(descriptions).filter((id) => !ids.includes(id));
  if (missing.length || stale.length) {
    throw new Error(
      `${ciPath} and the proof page disagree. ` +
        (missing.length ? `Jobs with no description: ${missing.join(', ')}. ` : '') +
        (stale.length ? `Descriptions of jobs that are gone: ${stale.join(', ')}.` : ''),
    );
  }
  return ciJobs.map((job) => ({ job, about: descriptions[job.id] }));
}
