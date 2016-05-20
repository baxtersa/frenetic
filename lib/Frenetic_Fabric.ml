open Core.Std
open Frenetic_Network
open Frenetic_OpenFlow

module Compiler = Frenetic_NetKAT_Compiler
module FDK = Frenetic_Fdd.FDK

type policy = Frenetic_NetKAT.policy
type fabric = (switchId, Frenetic_OpenFlow.flowTable) Hashtbl.t
type stream = (policy * policy)
type loc = (switchId * portId)
type correlation =
  | Exact
  | Adjacent of portId * portId
  | SinkOnly of portId
  | SourceOnly of portId
  | Uncorrelated

exception NonFilterNode of policy
exception ClashException of string
exception CorrelationException of string

let strip_vlan = 0xffff

let compile_local =
  let open Compiler in
  compile_local ~options:{ default_compiler_options with cache_prepare = `Keep }

let mk_flow (pat:Pattern.t) (actions:group) : flow =
  { pattern = pat
  ; action = actions
  ; cookie = 0L
  ; idle_timeout = Permanent
  ; hard_timeout = Permanent
  }

let drop = mk_flow Pattern.match_all [[[]]]

let vlan_per_port (net:Net.Topology.t) : fabric =
  let open Net.Topology in
  let tags = Hashtbl.Poly.create ~size:(num_vertexes net) () in
  iter_edges (fun edge ->
      let src, port = edge_src edge in
      let label = vertex_to_label net src in
      let pattern = { Pattern.match_all with dlVlan =
                                               Some (Int32.to_int_exn port)} in
      let actions = [ [ [ Modify(SetVlan (Some strip_vlan)); Output (Physical port) ] ] ] in
      let flow = mk_flow pattern actions in
      match Node.device label with
      | Node.Switch ->
        Hashtbl.Poly.change tags (Node.id label)
          ~f:(fun table -> match table with
              | Some flows -> Some( flow::flows )
              | None -> Some [flow; drop] )
      | _ -> ()) net;
  tags

let shortest_path (net:Net.Topology.t)
    (ingress:switchId list) (egress:switchId list) : fabric =
  let open Net.Topology in
  let vertexes = vertexes net in
  let vertex_from_id swid =
    let vopt = VertexSet.find vertexes (fun v ->
      (Node.id (vertex_to_label net v)) = swid) in
    match vopt with
    | Some v -> v
    | None -> failwith (Printf.sprintf "No vertex for switch id: %Ld" swid )
  in

  let mk_flow_mod (tag:int) (port:int32) : flow =
    let pattern = { Pattern.match_all with dlVlan = Some tag } in
    let actions = [[[ Output (Physical port) ]]] in
    mk_flow pattern actions
  in


  let table = Hashtbl.Poly.create ~size:(num_vertexes net) () in
  let tag = ref 10 in
  List.iter ingress ~f:(fun swin ->
    let src = vertex_from_id swin in
    List.iter egress ~f:(fun swout ->
      if swin = swout then ()
      else
        let dst = vertex_from_id swout in
        tag := !tag + 1;
        match Net.UnitPath.shortest_path net src dst with
        | None -> ()
        | Some p ->
          List.iter p ~f:(fun edge ->
            let src, port = edge_src edge in
            let label = vertex_to_label net src in
            let flow_mod = mk_flow_mod !tag port in
            match Node.device label with
            | Node.Switch ->
              Hashtbl.Poly.change table (Node.id label)
                ~f:(fun table -> match table with
                | Some flow_mods -> Some( flow_mod::flow_mods )
                | None -> Some [flow_mod; drop] )
            | _ -> ())));
  table

let of_local_policy (pol:policy) (sws:switchId list) : fabric =
  let fabric = Hashtbl.Poly.create ~size:(List.length sws) () in
  let compiled = compile_local pol in
  List.iter sws ~f:(fun swid ->
      let table = (Compiler.to_table swid compiled) in
      match Hashtbl.Poly.add fabric ~key:swid ~data:table with
      | `Ok -> ()
      | `Duplicate -> printf "Duplicate table for switch %Ld\n" swid
    ) ;
  fabric


let of_global_policy (pol:policy) (sws:switchId list) : fabric =
  let fabric = Hashtbl.Poly.create ~size:(List.length sws) () in
  let compiled = Compiler.compile_global pol in
  List.iter sws ~f:(fun swid ->
      let table = (Compiler.to_table swid compiled) in
      match Hashtbl.Poly.add fabric ~key:swid ~data:table with
      | `Ok -> ()
      | `Duplicate -> printf "Duplicate table for switch %Ld\n" swid
    ) ;
  fabric

let to_string (fab:fabric) : string =
  let buf = Buffer.create (Hashtbl.length fab * 100) in
  Hashtbl.Poly.iteri fab ~f:(fun ~key:swid ~data:mods ->
      Buffer.add_string buf (
        Frenetic_OpenFlow.string_of_flowTable
          ~label:(sprintf "Switch %Ld |\n" swid)
          mods)) ;
  Buffer.contents buf


let rec remove_dups (pol:policy) : policy =
  let open Frenetic_NetKAT in
  let at_location sw pt =
    let sw_test = Test (Switch sw) in
    let pt_test = Test (Location (Physical pt)) in
    let loc_test = Frenetic_NetKAT_Optimize.mk_and sw_test pt_test in
    Filter loc_test in
  let to_location sw pt =
    let sw_mod = Mod (Switch sw) in
    let pt_mod = Mod (Location (Physical pt)) in
    Seq ( sw_mod, pt_mod ) in
  match pol with
  | Filter a    -> Filter a
  | Mod hv      -> Mod hv
  | Union (p,q) -> Union(remove_dups p, remove_dups q)
  | Seq (p,q)   -> Seq(remove_dups p, remove_dups q)
  | Star p      -> Star(remove_dups p)
  | Link (s1,p1,s2,p2) ->
    Seq (at_location s1 p1, to_location s2 p2)
  | VLink _ -> failwith "Fabric: Cannot remove Dups from a policy with VLink"

let extract (pol:policy) : (policy * policy) list =
  let open FDK in
  let module NK = Frenetic_NetKAT in

  (* This returns a list of paths, where the each path is a list of
     policies. The head of each path is the policy form of the leaf node action
     and the remainder is a list of predicates that need to be true to perform
     the action. *)
  let rec get_paths id path =
    let node = unget id in
    match node with
    | Branch ((v,l), t, f) ->
      let true_pred   = NK.Test (Frenetic_Fdd.Pattern.to_hv (v, l)) in
      let true_paths  = get_paths t ( (NK.Filter true_pred)::path ) in
      let false_pred  = NK.Neg true_pred in
      let false_paths = get_paths f ( (NK.Filter false_pred)::path ) in
      List.unordered_append true_paths false_paths
    | Leaf r -> [ (Frenetic_Fdd.Action.to_policy r)::path ]
  in

  let rec mk_big_and (pols:NK.policy list) = match pols with
    | [] -> NK.True
    | (NK.Filter pred)::[] -> pred
    | (NK.Filter pred)::tail -> NK.And(pred, mk_big_and tail)
    | p::tail -> raise (NonFilterNode p) in

  (* Partition a path through the FDD into the condition and the
     action. TODO(basus): add checks for either component. *)
  let partition (path: NK.policy list) = match path with
    | head::tail ->
      let action = head in
      let condition = NK.Filter (mk_big_and tail) in
      (* let condition = Frenetic_NetKAT_Optimize.mk_big_seq tail in *)
      (condition, action)
    | _ -> failwith "Path through FDD not long enough to paritition"
  in
  let deduped = remove_dups pol in
  let fdd = compile_local deduped in
  let paths = get_paths fdd [] in
  List.map paths ~f:partition

let string_of_stream (cond, act) =
  sprintf "Condition: %s\nAction: %s\n" (Frenetic_NetKAT_Pretty.string_of_policy cond)
    (Frenetic_NetKAT_Pretty.string_of_policy act)

let string_of_located_stream ((sw,pt),(sw',pt'),stream) =
  let src = sprintf "Source: Switch: %Ld Port:%ld" sw pt in
  let sink = sprintf "Sink: Switch: %Ld Port:%ld" sw' pt' in
  let stream = string_of_stream stream in
  String.concat ~sep:"\n" [src; sink; stream]

let assemble (pol:policy) (topo:policy) ings egs : policy =
  let open Frenetic_NetKAT in
  let union = Frenetic_NetKAT_Optimize.mk_big_union in
  let seq = Frenetic_NetKAT_Optimize.mk_big_seq in
  let to_filter (sw,pt) = Filter( And( Test(Switch sw),
                                       Test(Location (Physical pt)))) in
  let ingresses = union (List.map ings ~f:to_filter) in
  let egresses  = union (List.map egs ~f:to_filter) in
  seq [ ingresses;
        Star(Seq(pol, topo)); pol;
        egresses ]

let find_predecessors (topo:policy) =
  let open Frenetic_NetKAT in
  let switch_table = Hashtbl.Poly.create () in
  let loc_table = Hashtbl.Poly.create () in
  let rec populate pol = match pol with
    | Union(p1, p2) ->
      populate p1;
      populate p2
    | Link (s1,p1,s2,p2) ->
      Hashtbl.Poly.add_exn loc_table (s2,p2) (s1,p1);
      Hashtbl.Poly.add_multi switch_table s2 (s1,p1,p2);
    | p -> failwith (sprintf "Unexpected construct in policy: %s\n"
                       (Frenetic_NetKAT_Pretty.string_of_policy p)) in
  populate topo;
  (switch_table, loc_table)

let find_successors (topo:policy) =
  let open Frenetic_NetKAT in
  let switch_table = Hashtbl.Poly.create () in
  let loc_table = Hashtbl.Poly.create () in
  let rec populate pol = match pol with
    | Union(p1, p2) ->
      populate p1;
      populate p2
    | Link (s1,p1,s2,p2) ->
      Hashtbl.Poly.add_exn loc_table (s1,p1) (s2,p2);
      Hashtbl.Poly.add_multi switch_table s1 (s2,p2,p1);
    | p -> failwith (sprintf "Unexpected construct in policy: %s\n"
                       (Frenetic_NetKAT_Pretty.string_of_policy p)) in
  populate topo;
  (switch_table, loc_table)

let precedes tbl (sw,_) (sw',pt') =
  match Hashtbl.Poly.find tbl (sw',pt') with
  | Some (pre_sw,pre_pt) -> if pre_sw = sw then Some pre_pt else None
  | None -> None

let succeeds tbl (sw,_) (sw',pt') =
  match Hashtbl.Poly.find tbl (sw',pt') with
  | Some (post_sw, post_pt) -> if post_sw = sw then Some post_pt else None
  | None -> None

let combine_locations ?(hdr="Clash detected") p1 p2 = match p1, p2 with
  | (None    , None    ), (None,    None) ->
    (None, None)
  | (Some sw , None    ), (None,    Some pt)
  | (None    , Some pt ), (Some sw, None)
  | (Some sw , Some pt ), (None,    None)
  | (None    , None    ), (Some sw, Some pt) ->
    (Some sw, Some pt)
  | (Some sw , None    ), (None,    None)
  | (None    , None    ), (Some sw, None) ->
    (Some sw, None)
  | (None    , Some pt ), (None, None)
  | (None    , None    ), (None, Some pt) ->
    (None, Some pt)
  | (sw,pt), (sw',pt') ->
    let reason = begin match sw, pt, sw', pt' with
      | Some sw, _, Some sw', _ -> sprintf "Clashing switches %Ld and %Ld." sw sw'
      | _, Some pt, _, Some pt' -> sprintf "Clashing switches %ld and %ld." pt pt'
      | _ -> sprintf "No clash. Bug in code." end in
    let msg = String.concat ~sep:" " [hdr; reason] in
    raise (ClashException msg)

let locate_from_options (swopt, ptopt) : (loc, string) Result.t =
  match swopt, ptopt with
  | Some sw, Some pt -> Ok (sw,pt)
  | Some sw, None    -> Error (sprintf "No port specified for switch %Ld" sw)
  | None, Some pt    -> Error (sprintf "No switch specified for port %ld" pt)
  | None, None       -> Error "No switch or port specified"

let locate_from_header hv =
  let open Frenetic_NetKAT in
  match hv with
  | Switch sw -> (Some sw, None)
  | Location (Physical pt) -> (None, Some pt)
  | _ -> (None, None)

let locate_from_sink policy : (loc,string) Result.t =
  let open Frenetic_NetKAT in
  let hdr = "Clash in sinks" in
  let rec aux policy = match policy with
  | Mod hv         -> locate_from_header hv
  | Union (p1, p2) -> combine_locations ~hdr:hdr (aux p1) (aux p2)
  | Seq (p1, p2)   -> combine_locations ~hdr:hdr (aux p1) (aux p2)
  | Star p         -> aux p
  | _ -> (None, None) in
  locate_from_options (aux policy)

let locate_from_source policy =
  let open Frenetic_NetKAT in
  let hdr = "Clash in source" in
  let rec locate_from_filter f = match f with
    | Test hv -> locate_from_header hv
    | True | False | Neg _ -> (None, None)
    | And(p1, p2) -> combine_locations ~hdr:hdr (locate_from_filter p1) (locate_from_filter p2)
    | Or (p1, p2) -> combine_locations ~hdr:hdr (locate_from_filter p1) (locate_from_filter p2) in
  let rec aux policy = match policy with
  | Filter f       -> locate_from_filter f
  | Union (p1, p2) -> combine_locations ~hdr:hdr (aux p1) (aux p2)
  | Seq (p1, p2)   -> combine_locations ~hdr:hdr (aux p1) (aux p2)
  | Star p         -> aux p
  | _              -> (None, None) in
  locate_from_options (aux policy)

let locate_endpoints ((pol, pol'):stream) =
  let src = locate_from_source pol in
  let sink = locate_from_sink pol' in
  match src, sink with
  | Ok s, Ok s' -> Ok (s,s')
  | Ok _, Error s -> Error s
  | Error s, Ok _ -> Error s
  | Error s, Error s' -> Error (String.concat ~sep:"\n" [s;s'])

let locate ((pol,pol'):stream) =
  let locs = locate_endpoints (pol,pol') in
  match locs with
  | Ok (src,sink) -> Ok (src, sink, (pol, pol'))
  | Error e -> Error e

let locate_or_drop (located, dropped) stream =
  let cond, act = stream in
  if act = Frenetic_NetKAT.drop then (located, stream::dropped)
  else try match locate stream with
    | Ok l -> (l::located,dropped)
    | Error e ->
      (located, dropped)
    with ClashException e ->
      let msg = sprintf "Exception |%s| in alpha-beta pair: %s%!" e
          (string_of_stream stream) in
      print_endline msg;
      (located,dropped)

let correlate ideal_src ideal_sink fab_src fab_sink
  precedes succeeds =
  if fab_src = ideal_src && fab_sink = ideal_sink then Exact
  else match (precedes ideal_src fab_src, succeeds ideal_sink fab_sink) with
    | Some pt, Some pt' -> Adjacent(pt, pt')
    | _, Some pt -> SinkOnly pt
    | Some pt, _ -> SourceOnly pt
    | None, None -> Uncorrelated

let imprint ideal fabric precedes succeeds =
 let open Frenetic_NetKAT in
 let rec remove_switch policy = match policy with
 | Union (p, Mod(Switch _)) -> p
 | Union (Mod(Switch _), p) -> p
 | Seq (p, Mod(Switch _))   -> p
 | Seq (Mod(Switch _), p)   -> p
 | Star p                   -> Star (remove_switch p)
 | p                        -> p in

  let seq = Frenetic_NetKAT_Optimize.mk_big_seq in
  let ingress,egress,_ = List.fold ideal ~init:([], [],1) ~f:(fun acc ideal ->
      let ideal_src,ideal_sink,ideal_stream = ideal in
      List.fold fabric ~init:acc ~f:(fun (ins,outs,tag) fab ->
          let fab_src,fab_sink,fab_stream = fab in
          match correlate ideal_src ideal_sink fab_src fab_sink precedes succeeds with
          | Exact ->
            ((fst fab_stream::ins), (snd fab_stream::outs), tag)
          | Adjacent(in_pt, out_pt) ->
            let ingress = seq [ (fst ideal_stream);
                                Mod( Vlan tag);
                                Mod( Location( Physical in_pt)) ] in
            let test_location = And( Test( Switch (fst ideal_sink)),
                                     Test( Location (Physical out_pt))) in
            let egress = seq [ Filter( And( Test(Vlan tag),
                                            test_location));
                               Mod( Vlan strip_vlan);
                               remove_switch (snd ideal_stream) ] in
            (ingress::ins, egress::outs, tag+1)
          | _ -> (ins,outs,tag)
        )) in
  (ingress,egress)

let retarget (ideal:stream list) (fabric: stream list) (topo:policy) =
  let ideal_located,ideal_dropped = List.fold ideal ~init:([],[]) ~f:locate_or_drop in
  let fabric_located,fabric_dropped = List.fold fabric ~init:([],[])
      ~f:locate_or_drop in
  let switch_preds, loc_preds = find_predecessors topo in
  let switch_succs, loc_succs = find_successors topo in
  let precedes = precedes loc_preds in
  let succeeds = succeeds loc_succs in
  imprint ideal_located fabric_located precedes succeeds
