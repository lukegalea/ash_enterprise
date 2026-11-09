# Presenter script: the credentialing tour in five minutes

Five minutes, seven links, on an instance seeded with `mix ash_enterprise.demo --history` (see the
[walkthrough](credentialing-walkthrough.md)). Sign in as `rosa@example.com`, the clinic's credentialing
coordinator, and open `/app/showcase/credentialing`. Everything on it is synthetic.

## Before you present

1. Signed in as `rosa@example.com`, click "Ask to activate" on any one credential on beat 1. Beat 2 has an
   explorer link only while a request waits. Its approval closes after three days; if beat 2 has no link, ask
   again.
2. In a second browser profile or private window, sign in as `ines@example.com`, the clinic director, and open
   the tour. Use it for F1: the coordinator cannot read model calls, so the failed call shows only there.

## The five minutes

| Time | Click | Say |
| --- | --- | --- |
| 0:00 | Nothing yet: the index at the top | "This clinic credentials its clinicians with an agent that asks before it acts. Here are twelve ways that goes wrong, and for each one, the record of what happened." |
| 0:30 | Beat 2, "Open in explorer" | "A request to activate a licence waits for a committee member. As the coordinator who asked, I see it wait and cannot open the approval: the committee reads its packet, the credential, the tool and the digest that ties the approval to this one request." |
| 1:00 | Index F4, "Open in explorer" | "Someone corrected the credential while it waited. The approval went stale with `subject_changed`. Nobody activated a credential nobody looked at." |
| 1:30 | Index F2, "Open in explorer" | "The registry accepted, then its answer was lost. The outcome is unknown, so the application asks a person to settle it on the recovery surface. It never retries an activation blind." |
| 2:15 | In the Ines window: index F1, "Open in explorer" | "The model's answer broke off halfway through reading a licence. The first call succeeded, this one failed with `incomplete_stream`, and every lookup ran once. When its lease ran out the platform picked the run up from the step it had reached: the same step, a new call, and it finished without starting again from the top." |
| 2:45 | Index F6, the "Beat 12" link | "The document webhook came twice. The beat shows 1 webhook delivery recorded and 1 continuation: the case moved on once." |
| 3:30 | Index F10, the "Beat 17" link | "The routing table changed while cases were running. Each case here shows the table version it started under: the newest is on version 2, the older ones stay on version 1." |
| 4:15 | Index F3, "Open in explorer" | "A deploy replaced the tool after a request was approved. The approval was bound to the old release, so it went stale with `manifest_changed`." |
| 4:45 | Back to the index | "Every failure has a beat and a record. What you have not seen, F8, F9, F11 and F12, you can make happen on the beat itself." |

## If you have another minute

- **The review packet.** Sign in as `kenji@example.com`, a committee member, and click "Open the approval"
  on beat 2: the packet shows the credential, the tool and the digest the approval is bound to.

- **F2, settling it.** Sign in as the demo administrator, `demo-admin@example.com`, and click "Settle it on
  the recovery surface" on beat 5: the request reads uncertain, and the form asks what happened: it records the answer, and nothing runs again.

- **F12, a shadow rerun.** Sign in as `ines@example.com`, click "Rerun in shadow" on beat 18, then open its
  first case in the explorer: the tool calls are simulated and nobody is activated.
- **F9, a candidate that fails.** Click beat 16 to measure a candidate release; the gate refuses it and
  names the injection case it failed.

## If something looks wrong

- A failure in the index reads "No record yet": the instance was not seeded with `--history`. Do not
  present that row; the beat itself still explains the failure.
- A beat says "demo build only": the same cause. Skip it.
- The kill variant of beat 5 is never recorded beforehand: the demo registry keeps its activations in the
  memory of the application node that took them, so a record made beforehand would be settled by whichever
  node reconciled it. The beat says so; say so too.
