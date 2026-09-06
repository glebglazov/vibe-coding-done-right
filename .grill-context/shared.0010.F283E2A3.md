---
fragment: F283E2A3
generation: 0010
branch: master
---

+ Record File Stamp
  What a Sync Pass remembers about a Record File it has already merged: the filename, the modification date and the size. A pass skips a file whose stamp is unchanged, and never opens it. The stamp is the Replication Window's bound, because arriving does not change a file's stamp while a clock cutoff would drop a record that arrives late.
  avoid: file hash, etag, sync token, cursor
  under: Local Storage and Sync
