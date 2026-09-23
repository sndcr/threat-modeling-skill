---
type: llm
focus: { source: file, path: docs/threat-modelling/note_read/THREAT-MODEL.md }
---

PASS if the threat model reports that GET /notes/<id> returns any note by id without checking that it belongs to the requesting user (IDOR / missing object-level authorization).
FAIL if that weakness is missing, or only mentioned as already mitigated.
