(* L1 Compiler
 * Temporaries
 * Author: Kaustuv Chaudhuri <kaustuv+@cs.cmu.edu>
 * Modified: Alex Vaynberg <alv@andrew.cmu.edu>
 * Modified: Frank Pfenning <fp@cs.cmu.edu>
 * Converted to OCaml by Michael Duggan <md5i@cs.cmu.edu>
 * Modified: Alice Rao <alrao@andrew.cmu.edu>
 *)

open Core

type t [@@deriving compare, sexp, hash]
(* include Hashtbl.S with type t := t *)
include Comparable.S with type t := t
(* resets temp numbering *)
val reset : unit -> unit
(* returns a unique new temp *)
val create : unit -> t
val create_no : int -> t
val create_no_t : int -> t -> t
(* returns the name of a temp *)
val name : t -> string
val value : t -> int
val is_reg : t -> bool