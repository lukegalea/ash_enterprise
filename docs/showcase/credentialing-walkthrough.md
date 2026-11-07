# The credentialing tour, walked through

The credentialing tour at `/app/showcase/credentialing` takes a clinic credentialing coordinator from
asking for a licence to be activated through a case that checks the licence, routes it and puts it in front
of a committee, and on to a new release of the agent that reads licence documents. On the way it shows
twelve things going wrong, F1 to F12, and what the application does about each one. Every person, clinic
and licence on it is synthetic: the `clinic-demo` tenant ("Riverside Demo") that `mix ash_enterprise.demo`
creates.

This page says what each beat shows and where to click. The images are slots, not screenshots yet: each one
names the file `scripts/screenshots/capture-showcase.mjs` writes for it (see "Capturing the images" below).

## Before you start

Seed the demo tenant and its history on your own development database:

```bash
devenv shell -- mix ash_enterprise.demo --history --password-file PATH
```

- `PATH` is a file that holds the demo password. Without `--password-file` the task generates one and prints
  it once.
- `--history` records the beats that need a fault: it runs each of them once, through the same actions the
  fault panel uses, arming the fault points in the seed process only. It writes only to `clinic-demo` and
  refuses any other tenant. A second run finds every beat already recorded and changes nothing.
- Sign in as `rosa@example.com`, the clinic's credentialing coordinator, with that password.

On a development build the fault panel is on as well, and you can make each failure happen live. On a
shared instance the panel is off, and the beats show the history's records instead.

## The index

The tour opens with a table of the twelve failures. Each row names the failure, links to the beat that
shows it, and opens its record in the execution explorer. A failure that has no record yet says
"No record yet" and offers no link, so no link on the tour opens an empty page.

> Image slot: `tour-index.png`

| Failure | What goes wrong | Beat |
| --- | --- | --- |
| F1 | The model times out mid-run | 7 |
| F2 | The registry's answer is lost | 5 |
| F3 | A deploy changes the approved tool | 19 |
| F4 | The record changes during approval | 3 |
| F5 | The requester's grant is revoked | 4 |
| F6 | A webhook arrives twice, or early | 12 |
| F7 | One parallel check is refused | 11 |
| F8 | The token budget runs out | 8 |
| F9 | A candidate fails its injection case | 16 |
| F10 | A routing table changes under a case | 17 |
| F11 | A person asks to be erased | 9 |
| F12 | A shadow rerun must touch nothing | 18 |

The history records F1 to F7 and F10. F8, F9, F11 and F12 are made by clicking their beat on the tour,
because each is a deliberate act a presenter makes in front of the room.

Every beat also has its own "Open in explorer" link, to the newest record that is that beat's outcome, or
the line "Nothing to open in the explorer yet."

## Activation requests (beats 1 to 5)

1. **Ask to activate a credential.** The coordinator asks; the request is a governed invocation that waits
   for approval.
2. **A committee member approves it.** Each waiting request links to its approval ("Open the approval") on the approvals
   surface, where a committee member (`kenji@example.com` or `amaka@example.com`) reads what is being
   approved and approves it.
3. **The credential changes during approval (F4).** The credential is corrected after the request was made.
   The approval goes stale with `subject_changed` instead of activating a credential nobody looked at. A
   waiting request's review packet shows the change before anyone approves; a decided request's packet is
   read by the clinic's administrator.

   > Image slot: `tour-beat-stale.png`

4. **The coordinator's grant is revoked (F5).** The grant is withdrawn between asking and acting, and the
   request fails as denied.

   > Image slot: `tour-beat-revoked.png`

5. **The worker dies after the registry accepted (F2).** The registry accepted the activation but its answer
   never came back. The request's outcome is unknown, and it is settled on the recovery surface
   (`/app/recovery/<id>`), never retried blind. The variant where the worker process is killed is not
   recorded beforehand: the registry's memory of the activation lives in the application node, so it is
   gone when the node restarts. The beat says so.

   > Image slots: `tour-beat-reconciled.png`, `recovery-F2.png`, `explorer-F2.png`

## The licence reader (beats 6 to 9)

6. **Read a credential's licence documents.** An agent run reads the documents and records findings.
7. **The model times out mid-run (F1).** The first model call succeeds, the second times out. The run waits
   on its lease; every tool lookup ran once, not twice.

   > Image slots: `tour-beat-timeout.png`, `explorer-F1.png`

8. **The token budget runs out (F8).** Click the beat to run a reading under a small budget.
9. **The clinician asks to be erased (F11).** Click the beat to erase a run's content; the trace keeps its
   shape and says the content was erased.

## The credentialing case (beats 10 to 15)

10. **Open a credential's case.** A BPMN process instance per credential.
11. **One of the parallel checks fails (F7).** One check is refused for a missing licence document, the
    others succeed, and the case waits for the document.

    > Image slot: `tour-beat-checks.png`

12. **The document webhook arrives twice, and out of order (F6).** The first delivery is received, the
    second is a duplicate, and the case moves on once.

    > Image slots: `tour-beat-webhook.png`, `explorer-F6.png`

13. **The committee decides.** The case's review links to its packet on the approvals surface.
14. **The re-credentialing timer.** The timer that brings the credential back for review.
15. **An approval over ACP survives a restart.** A request approved over the Agent Client Protocol.

## Releases (beats 16 to 19)

16. **A candidate release fails its injection case (F9).** Click the beat to measure a candidate; the gate
    refuses it and names the case.
17. **The routing table changes under a running case (F10).** A newer case runs on the new table while the
    older one keeps the version its release pinned.

    > Image slots: `tour-beat-routing.png`, `explorer-F10.png`

18. **A shadow rerun activates nobody (F12).** Signed in as the clinic's director (`ines@example.com`),
    click "Rerun in shadow". Each case of the shadow run opens in the explorer, and its tool calls are
    simulated.
19. **A deploy changes activate_credential (F3).** A request approved against one release goes stale with
    `manifest_changed` when a deploy replaces the tool.

    > Image slots: `tour-beat-deploy.png`, `explorer-F3.png`

The remaining slots, `tour-beat-*.png` and `explorer-F4.png`, `explorer-F5.png` and `explorer-F7.png`, are
captured the same way.

## Capturing the images

Run the capture against a server you started yourself, on a database you seeded yourself with
`--history`:

```bash
node scripts/screenshots/capture-showcase.mjs --base-url http://localhost:PORT --password-file PATH
```

It signs in headless as the demo's personas, reading the password from `PATH` and never printing it, and
writes the images to `tmp/showcase-capture`. It fails, naming each problem, if any page shows a
"demo build only" note, an empty table, an empty trace or an error, or shows a tenant other than
"Riverside Demo" or a person who is not one of the demo's personas.

See also the five-minute [presenter script](presenter-script.md).
