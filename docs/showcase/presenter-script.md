# Presenter script: the credentialing tour in five minutes

Five minutes, seven links, on an instance seeded with `mix ash_enterprise.demo --history` (see the
[walkthrough](credentialing-walkthrough.md)). Sign in as `rosa@example.com`, the clinic's credentialing
coordinator, and open `/app/showcase/credentialing`. Everything on it is synthetic.

| Time | Click | Say |
| --- | --- | --- |
| 0:00 | Nothing yet: the index at the top | "This clinic credentials its clinicians with an agent that asks before it acts. Here are twelve ways that goes wrong, and for each one, the record of what happened." |
| 0:30 | Beat 2, "Open in explorer" | "A request to activate a licence waits for a committee member. As the coordinator who asked, I see it wait and cannot open the approval: the committee reads its packet, the credential, the tool and the release it runs on." |
| 1:00 | Index F4, "Open in explorer" | "Someone corrected the credential while it waited. The approval went stale with `subject_changed`. Nobody activated a credential nobody looked at." |
| 1:30 | Index F2, "Open in explorer" | "The registry accepted, then its answer was lost. The outcome is unknown, so the application asks a person to settle it on the recovery surface. It never retries an activation blind." |
| 2:15 | Index F1, "Open in explorer" | "The model timed out halfway through reading a licence. One call succeeded, one failed, and every lookup ran once. When its lease ran out the platform picked the run up from the step it had reached: it finished without starting again from the top." |
| 2:45 | Index F6, "Open in explorer" | "The document webhook came twice. One delivery, one duplicate, and the case moved on once." |
| 3:30 | Index F10, "Open in explorer" | "The routing table changed while a case was running. The new case uses the new table; the old case keeps the version its release pinned." |
| 4:15 | Index F3, "Open in explorer" | "A deploy replaced the tool after a request was approved. The approval was bound to the old release, so it went stale with `manifest_changed`." |
| 4:45 | Back to the index | "Every failure has a beat and a record. What you have not seen, F8, F9, F11 and F12, you can make happen on the beat itself." |

## If you have another minute

- **The review packet.** Sign in as `kenji@example.com`, a committee member, and click "Open the approval"
  on beat 2: the packet shows the credential, the tool and the release the request would run on.

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
