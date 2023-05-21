(* This module provide function to calculate dominators.
 * D[n] indicates blocks that dominate block n, in other 
 * words, every path from entry point to block n must
 * pass block D[n]. It is calculated as below:
 *
 * D[n] = {n} Union {Inter_{p belongs to pred(n) D[p]}}
 *
 * D[n] will be calculated iteratedly, complexity O(n^2e)
 * if intersection and unions are calculated in vector bit, 
 * which is O(1). n is number of blocks and e is edges in graph.
 *
 * strict dominator is dominator except it self, calculated as 
 *
 * sD[n] = D[n] - {n}
 *
 * Immediate dominator is the first dominator that dominate n.
 *
 * iD[n] = iD[n] - U_{d belongs to iD[n]} (sD[n])
 *
 * For more details and explanations, check 
 * https://www.cs.cmu.edu/afs/cs/academic/class/15411-f20/www/lec/05-ssa.pdf
 * 
 * Author: Tianbo Hao<tianboh@alumni.cmu.edu>
 *)
module T = Tree
module Label = Util.Label
open Core

type block =
  { body : T.stm list
  ; no : int
  ; succ : Int.Set.t
  }

let rec group_stm
    (stms : T.stm list)
    (acc_stms_rev : T.stm list)
    (acc_blks_rev : T.stm list list)
    (label_map : int Label.Map.t)
    : T.stm list list * int Label.Map.t
  =
  match stms with
  | [] ->
    let last_blk = List.rev acc_stms_rev in
    let blks_rev =
      if List.is_empty last_blk then acc_blks_rev else last_blk :: acc_blks_rev
    in
    let blks = List.rev blks_rev in
    blks, label_map
  | h :: t ->
    (match h with
    | Label label ->
      let blk = List.rev acc_stms_rev in
      let acc_blks_rev =
        if List.is_empty blk then acc_blks_rev else blk :: acc_blks_rev
      in
      let label_no = List.length acc_blks_rev in
      let label_map = Label.Map.add_exn label_map ~key:label ~data:label_no in
      group_stm t [ T.Label label ] acc_blks_rev label_map
    | Move move -> group_stm t (T.Move move :: acc_stms_rev) acc_blks_rev label_map
    | Return ret -> group_stm t (T.Return ret :: acc_stms_rev) acc_blks_rev label_map
    | Jump jp -> group_stm t (T.Jump jp :: acc_stms_rev) acc_blks_rev label_map
    | CJump cjp -> group_stm t (T.CJump cjp :: acc_stms_rev) acc_blks_rev label_map
    | Effect eft -> group_stm t (T.Effect eft :: acc_stms_rev) acc_blks_rev label_map
    | Nop -> group_stm t acc_stms_rev acc_blks_rev label_map)
;;

(* entry block(empty) is -2. exit block(empty) is -1. 
 * return a hash table from block_no to block *)
let rec _build_block blks label_map res : block Int.Map.t =
  match blks with
  | [] -> res
  | h :: t ->
    let body = h in
    let no = Int.Map.length res in
    let succ_init =
      match List.last_exn h with
      | T.Label _ | T.Move _ | T.Effect _ | T.Nop ->
        let succ_no = if List.is_empty t then -1 else no + 1 in
        [ succ_no ]
      | T.Return _ ->
        let succ_no = if List.is_empty t then -1 else no + 1 in
        [ -1; succ_no ]
      | T.Jump jp ->
        let succ_no = Label.Map.find_exn label_map jp in
        [ succ_no ]
      | T.CJump cjp ->
        let succ_no = Label.Map.find_exn label_map cjp.target_stm in
        let succ_no' = if List.is_empty t then -1 else no + 1 in
        [ succ_no; succ_no' ]
    in
    let body_wo_tail = List.sub h ~pos:0 ~len:(List.length h - 1) in
    let succ_l =
      List.fold body_wo_tail ~init:succ_init ~f:(fun acc stm ->
          match stm with
          | T.Label _ | T.Move _ | T.Effect _ | T.Nop -> acc
          | T.Return _ -> -1 :: acc
          | T.Jump jp ->
            let succ_no = Label.Map.find_exn label_map jp in
            succ_no :: acc
          | T.CJump cjp ->
            let succ_no = Label.Map.find_exn label_map cjp.target_stm in
            succ_no :: acc)
    in
    let succ = Int.Set.of_list succ_l in
    let block = { body; no; succ } in
    let res = Int.Map.add_exn res ~key:no ~data:block in
    _build_block t label_map res
;;

let build_block (f_body : T.stm list) =
  let blks, label_map = group_stm f_body [] [] Label.Map.empty in
  let blk_map = _build_block blks label_map Int.Map.empty in
  let entry_blk = { body = []; no = -2; succ = Int.Set.of_list [ 0 ] } in
  let exit_blk = { body = []; no = -1; succ = Int.Set.empty } in
  let blk_map = Int.Map.set blk_map ~key:(-1) ~data:exit_blk in
  let blk_map = Int.Map.set blk_map ~key:(-2) ~data:entry_blk in
  blk_map
;;

let rec _build_pred blks res =
  match blks with
  | [] -> res
  | h :: t ->
    let res =
      Int.Set.fold h.succ ~init:res ~f:(fun acc v ->
          let pred_v =
            match Int.Map.find res v with
            | None -> Int.Set.empty
            | Some s -> s
          in
          let pred = Int.Set.add pred_v h.no in
          Int.Map.set acc ~key:v ~data:pred)
    in
    _build_pred t res
;;

(* Return a predecessor map from int to int set. *)
let build_pred (blk_map : block Int.Map.t) : Int.Set.t Int.Map.t =
  let blks = Int.Map.data blk_map in
  let res = Int.Map.empty in
  _build_pred blks res
;;

(* Use dfs to calculate postorder
 * return postorder, visited_set, and dfs_map
 * dfs_map: blk_no -> dfs leave no. *)
let rec postorder visited blk_no blk_map (order : int list) (dfs_map : int Int.Map.t)
    : int list * Int.Set.t * int Int.Map.t
  =
  let visited = Int.Set.add visited blk_no in
  let blk = Int.Map.find_exn blk_map blk_no in
  let ret =
    (* if Int.Set.is_subset blk.succ ~of_:visited *)
    let order, visited, dfs_map =
      Int.Set.fold blk.succ ~init:(order, visited, dfs_map) ~f:(fun acc succ ->
          let acc_order, acc_visited, acc_dfs_map = acc in
          if Int.Set.mem acc_visited succ
          then acc
          else postorder acc_visited succ blk_map acc_order acc_dfs_map)
    in
    let order = order @ [ blk.no ] in
    let dfs_map = Int.Map.set dfs_map ~key:blk.no ~data:(List.length order) in
    order, visited, dfs_map
  in
  ret
;;

(* Find nearest common root for both b1 and b2. *)
let rec intersect
    (b1 : int)
    (b2 : int)
    (idom_map : int Int.Map.t)
    (dfs_map : int Int.Map.t)
  =
  (* printf "intersect %d %d, " b1 b2; *)
  if b1 = -2 || b2 = -2
  then -2
  else if b1 = b2
  then b1
  else (
    let b1_dfs_no, b2_dfs_no = Int.Map.find_exn dfs_map b1, Int.Map.find_exn dfs_map b2 in
    if b1_dfs_no < b2_dfs_no
    then (
      let b1 =
        match Int.Map.find idom_map b1 with
        | Some s -> s
        | None -> failwith (sprintf "intersect b1 %d fail" b1)
      in
      intersect b1 b2 idom_map dfs_map)
    else (
      let b2 =
        match Int.Map.find idom_map b2 with
        | Some s -> s
        | None -> failwith (sprintf "intersect b2 %d fail" b2)
      in
      intersect b1 b2 idom_map dfs_map))
;;

(* idom is the immediate dominator of pred_list. it is a integer *)
let rec _idom_trav_par pred_list idom (idom_map : int Int.Map.t) dfs_map =
  match pred_list with
  | [] -> idom
  | h :: t ->
    (match Int.Map.find idom_map h with
    | None -> _idom_trav_par t idom idom_map dfs_map
    | Some s ->
      let new_idom = intersect s idom idom_map dfs_map in
      (* printf ", new idom %d\n" new_idom; *)
      _idom_trav_par t new_idom idom_map dfs_map)
;;

(* idom_map is the immediate dominators across all blocks. it is a map *)
let rec _idom (idom_map : int Int.Map.t) changed pred_map order dfs_map =
  match changed with
  | true ->
    let changed = false in
    let changed, idom_map =
      List.fold order ~init:(changed, idom_map) ~f:(fun acc node ->
          (* printf "finding idom of node %d\n" node; *)
          let acc_changed, acc_idom_map = acc in
          let pred =
            match Int.Map.find pred_map node with
            | None -> []
            | Some s -> Int.Set.to_list s
          in
          let new_idom = List.nth_exn pred 0 in
          let pred' = List.sub pred ~pos:1 ~len:(List.length pred - 1) in
          let new_idom = _idom_trav_par pred' new_idom idom_map dfs_map in
          match Int.Map.find acc_idom_map node with
          | None ->
            let acc_idom_map = Int.Map.set acc_idom_map ~key:node ~data:new_idom in
            let acc_changed = true in
            acc_changed, acc_idom_map
          | Some s ->
            if phys_equal s new_idom
            then acc_changed, acc_idom_map
            else (
              let acc_idom_map = Int.Map.set acc_idom_map ~key:node ~data:new_idom in
              let acc_changed = true in
              acc_changed, acc_idom_map))
    in
    _idom idom_map changed pred_map order dfs_map
  | false -> idom_map
;;

(* Calculate immediate dominator id[n] for each block
 * Algorithm: https://www.cs.rice.edu/~keith/EMBED/dom.pdf Figure 3
 *)
let idom blk_map pred_map =
  let idom_map = Int.Map.empty in
  let changed = true in
  let post_order, _, dfs_map = postorder Int.Set.empty (-2) blk_map [] Int.Map.empty in
  let rev_post_order = List.rev post_order in
  (* remove entry block(empty) in reverse postorder *)
  let order =
    match rev_post_order with
    | [] -> []
    | _ :: t -> t
  in
  (* List.iter order ~f:(fun x -> printf "%d " x); *)
  (* printf "\n"; *)
  _idom idom_map changed pred_map order dfs_map
;;

(* traverse dominate tree from bottom to up till found idom_node. *)
let rec _build_DF_while node runner idom_node idom_map df : Int.Set.t Int.Map.t =
  if phys_equal runner idom_node
  then df
  else (
    let df_runner =
      match Int.Map.find df runner with
      | None -> Int.Set.empty
      | Some s -> s
    in
    let df_runner = Int.Set.add df_runner node in
    let df = Int.Map.set df ~key:runner ~data:df_runner in
    let runner = Int.Map.find_exn idom_map runner in
    _build_DF_while node runner idom_node idom_map df)
;;

(* update dominance frontier for walk start from
 * node to its immediate dominator *)
let _build_DF node preds idom_map df : Int.Set.t Int.Map.t =
  Int.Set.fold preds ~init:df ~f:(fun df_acc pred ->
      let idom_node = Int.Map.find_exn idom_map node in
      let runner = pred in
      _build_DF_while node runner idom_node idom_map df_acc)
;;

(* build dominance frontier based on idom *)
let build_DF blk_map pred_map idom =
  let nodes = Int.Map.keys blk_map in
  let df = Int.Map.empty in
  let df =
    List.fold nodes ~init:df ~f:(fun df_acc node ->
        (* For entry and exit block, they doesn't have dominance frontier
         * For unreachable block like .afterlife, it doesn't either. *)
        if node < 0 || not (Int.Map.mem pred_map node)
        then Int.Map.set df_acc ~key:node ~data:Int.Set.empty
        else (
          let preds = Int.Map.find_exn pred_map node in
          if Int.Set.length preds >= 2 then _build_DF node preds idom df_acc else df_acc))
  in
  (* Fill up blocks that are not frontier of any blocks *)
  Int.Map.mapi blk_map ~f:(fun ~key:k ~data:_ ->
      if Int.Map.mem df k then Int.Map.find_exn df k else Int.Set.empty)
;;

(* build dominance tree, which is reverse of idom *)
let build_DT idom =
  Int.Map.fold idom ~init:Int.Map.empty ~f:(fun ~key:child ~data:parent acc ->
      let children =
        match Int.Map.find acc parent with
        | None -> Int.Set.empty
        | Some s -> s
      in
      let children = Int.Set.add children child in
      Int.Map.set acc ~key:parent ~data:children)
;;

module Print = struct
  let pp_idom idom =
    Int.Map.iteri idom ~f:(fun ~key:k ~data:d -> printf "block %d idom is %d\n" k d)
  ;;

  let pp_df df =
    Int.Map.iteri df ~f:(fun ~key:k ~data:d ->
        let df_k =
          Int.Set.to_list d
          |> List.map ~f:(fun x -> Int.to_string x)
          |> String.concat ~sep:", "
        in
        printf "block %d dominance frontier is %s\n" k df_k)
  ;;

  let pp_dt dt =
    Int.Map.iteri dt ~f:(fun ~key:k ~data:d ->
        let df_k =
          Int.Set.to_list d
          |> List.map ~f:(fun x -> Int.to_string x)
          |> String.concat ~sep:", "
        in
        printf "block %d dominance tree is %s\n" k df_k)
  ;;

  let pp_int_set s =
    let l = Int.Set.fold s ~init:[] ~f:(fun acc t -> Int.to_string t :: acc) in
    String.concat l ~sep:", "
  ;;

  let pp_blk blk_map =
    let keys = Int.Map.keys blk_map in
    let sorted_key = List.sort keys ~compare:Int.compare in
    List.iter sorted_key ~f:(fun blk_no ->
        let blk = Int.Map.find_exn blk_map blk_no in
        printf "block %d\n%s\n" blk_no (T.Print.pp_program blk.body);
        printf "block %d succ %s\n" blk_no (pp_int_set blk.succ))
  ;;
end

(* Return dominance frontier, dominate tree, pred_map and blk_map *)
let run (f_body : T.stm list) =
  let blk_map = build_block f_body in
  let pred_map = build_pred blk_map in
  let idom = idom blk_map pred_map in
  (* pp_blk blk_map;
  pp_idom idom; *)
  let df = build_DF blk_map pred_map idom in
  (* pp_df df; *)
  let dt = build_DT idom in
  (* pp_dt dt; *)
  df, dt, pred_map, blk_map
;;
