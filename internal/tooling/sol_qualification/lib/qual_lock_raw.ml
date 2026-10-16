(* Open-file-description locking avoids lockf's process-wide ownership, including
   two recorder handles in the same process. No credential or payload crosses FFI. *)
external try_lock : Unix.file_descr -> bool = "sol_qual_try_lock"
