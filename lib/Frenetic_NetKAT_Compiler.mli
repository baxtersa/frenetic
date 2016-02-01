open Core.Std
open Frenetic_NetKAT
open Frenetic_NetKAT_Semantics
open Frenetic_OpenFlow

module Field = Frenetic_Fdd.Field
module Value = Frenetic_Fdd.Value
module Action = Frenetic_Fdd.Action
module Par = Action.Par
module Seq = Action.Seq
module FDK : sig
  include module type of Frenetic_Fdd.FDK
  val of_pred : pred -> t
  val of_mod : header_val -> t
  val union : t -> t -> t
  val seq : t -> t -> t
  val star : t -> t
  val of_local_pol : policy -> t
  val dedup : t -> t
end

type order
  = [ `Default
    | `Static of Field.t list
    | `Heuristic ]

type t = FDK.t
(** The type of the intermediate compiler representation (FDD). *)

val compare : t -> t -> int
val drop : t
val id : t
val of_pred : pred -> t
val of_mod : header_val -> t

type cache
  = [ `Keep
    | `Empty
    | `Preserve of t ]

type adherence
  = [ `Strict
    | `Sloppy ]

type compiler_options = {
    cache_prepare: cache;
    field_order: order;
    remove_tail_drops: bool;
    dedup_flows: bool;
    optimize: bool;
    openflow_adherence: adherence;
}

(* TODO: delete *)
val prepare_compilation : options:compiler_options -> policy -> unit

(** {2 Compilation} *)

exception Non_local
(** The exception that's thrown when the local compiler is given a policy with a
    [Link] term in it. To compile policies with [Link] terms, invoke global
    compiler. *)

val default_compiler_options : compiler_options

val compile_local : ?options:compiler_options -> policy -> t
(** [compile_local p] returns the intermediate representation of the local policy [p].
    You can generate a flowtable from [t] by passing it to the {!to_table}
    function below.
 *)

val compile_global : ?options:compiler_options -> policy -> t

val restrict : header_val -> t -> t
(** [restrict hv t] returns the fragment of [t] that applies when the assignment
    [hv] is true. The result will no longer make any reference to the header
    named in [hv]. This is equivalent to traversing the original NetKAT
    syntax tree and replacing all occurrences of [Test(hv)] with [True].

    This function is called by {!to_table} to restrict [t] to the portion that
    should run on a single switch. *)

val to_table : ?options:compiler_options
            -> ?group_tbl:Frenetic_GroupTable0x04.t -> switchId -> t
            -> flow list
(** [to_table sw t] returns a flowtable that implements [t] for switch [sw]. *)

val to_table' : ?options:compiler_options
             -> ?group_tbl:Frenetic_GroupTable0x04.t -> switchId -> t
             -> (flow * string list) list

(** {2 Composition} *)

val seq : t -> t -> t
(** [seq p q] returns the sequential composotion of the two intermediate
    representations [p] and [q]. The result is semantically equivalent to the
    seqential composition of the two policies from which [p] and [q] were
    derived. *)

val union : t -> t -> t
(** [union p q] returns the parallel composition of the two intermediate
    representations [p] and [q]. The result is semantically equivalent to the
    parallel composition of the two policies from which [p] and [q] were
    derived. *)

val star : t -> t
(** [star p] returns the star of the intermediate representation [p]. The result
    is semantically equivalent to the star of the policy from which [p] was
    derived. *)


(** {2 Utilities} *)

val dedup : t -> t

val pipes : t -> string list
(** [pipes t] returns the list of pipe names that occur in [t]. *)

val queries : t -> (string * pred) list
(** [queries t] returns the list of queries that occur in [t] along with the
    predicates associated with the query. Packet and byte counts of flows that
    match the predicate should count towards its associated query. *)

val equal : t -> t -> bool
(** [equal a b] returns whether or not the two intermediate representations are
    structurally equal.

    If the two representations are structurally equal, then the policies they
    derived from are semantically equivalent. However, if the two
    representations are not equal, the policies they were derived from may still
    be semantically equivalent. *)

val size : t -> int
(** [size t] returns the size of [t]. *)

(* compressed_size / uncompressed_size *)
val compression_ratio : t -> int * int

val to_local_pol : t -> policy
(** [to_local_pol t] returns a NetKAT policy that is semantically equivalent to
    [t]. If was generated from compiling a policy [p], it is not guarateed that
    [to_local_pol t] will be identical to [p]. *)

val to_string : t -> string
(** [to_string t] returns a string representation of [t]. This will be a
    representation of the Vlr diagram from the tdk package. *)

(** {2 Interpreter} *)

val eval : packet -> t -> PacketSet.t
(** [eval pkt t] returns a [PacketSet.t] that is the result of the packet [pkt]
    being run through the policy represented by [t]. *)

val eval_pipes : packet -> t -> (string * packet) list * (string * packet) list * packet list
(** [eval_pipes pkt t] returns the result of running the packet [pkt] through
    the policy represented by [t], with packets grouped according to the type of
    location to which the policy assigns them. The result is a triple whose
    first component is a list of packets and corresponding pipe location, whose
    second is a list of packets and corresponding query location, and whose
    third is a list of packets that are at physical locations. *)

val to_dotfile : t -> string -> unit

val field_order_from_string : string -> order

val field_order_to_string : order -> string

(** [options_from_json_string s] returns a compiler_options type suitable.  Mostly for HTTP servers *)
val options_from_json_string : string -> compiler_options

val options_to_json_string : compiler_options -> string

(* multitable support *)

(* Each list of fields represents the fields one flow table can match on *)
type flow_layout = Field.t list list with sexp

(* Each flow table row has a table location, and a meta value on that table *)
type tableId = int with sexp
type metaId = int with sexp
type flowId = tableId * metaId with sexp

(* OpenFlow 1.3+ instruction types *)
type instruction =
  [ `Action of Frenetic_OpenFlow.group
  | `GotoTable of flowId ]
with sexp

(* A flow table row, with multitable support. If goto has a Some value
 * then the 0x04 row instruction is GotoTable. *)
type multitable_flow = {
  pattern      : Frenetic_OpenFlow.Pattern.t;
  cookie       : int64;
  idle_timeout : Frenetic_OpenFlow.timeout;
  hard_timeout : Frenetic_OpenFlow.timeout;
  instruction  : instruction;
  flowId       : flowId;
} with sexp

val layout_to_string : flow_layout -> string

(* Produce a list of flow table entries for a multitable setup *)
val to_multitable : ?options:compiler_options
                  -> switchId
                  -> flow_layout
                  -> t
                  -> (multitable_flow list * Frenetic_GroupTable0x04.t)
