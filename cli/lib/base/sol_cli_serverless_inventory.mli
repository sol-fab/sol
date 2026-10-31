type entry =
  { service : string
  ; record : string
  }

val load : target:string -> (entry list, string) result
val add : target:string -> service:string -> record:string -> (unit, string) result
val remove : target:string -> service:string -> (unit, string) result
