(* L2 liveness analysis
 * Given a pseudo assembly code, liveness analysis
 * uses dataflow analysis to generate live-out set
 * for each instruction. This information will be 
 * used for reg_alloc_info.
 *
 * Author: Tianbo Hao <tianboh@alumni.cmu.edu>
 *)
open Core
module Dfana_info = Json_reader.Lab2_checkpoint
module AS = Inst.Pseudo
module Temp = Var.Temp
module Register = Var.X86_reg
module Dfana = Flow.Dfana
module Label = Util.Label

let print_line (line : Dfana_info.line) =
  let () = printf "\n{gen: " in
  let () = List.iter ~f:(fun x -> printf "%d" x) line.gen in
  let () = printf "\nkill: " in
  let () = List.iter ~f:(fun x -> printf "%d" x) line.kill in
  let () = printf "\nsucc: " in
  let () = List.iter ~f:(fun x -> printf "%d" x) line.succ in
  let () = printf "\nis_label: %b" line.is_label in
  printf "\nline_number: %d}\n" line.line_number
;;

let print_df_info df_info = List.iter df_info ~f:(fun line -> print_line line)

(* map is from is a hash table with key : Temp.t and value Int.Set.t 
 * The value corresponds line number that define this variable. *)
let rec gen_def_info (inst_list : AS.instr list) (line_no : int) map =
  match inst_list with
  | [] -> map
  | h :: t ->
    (match h with
    | AS.Binop binop ->
      let map = update_map binop.dest line_no map in
      gen_def_info t (line_no + 1) map
    | AS.Mov mov ->
      let map = update_map mov.dest line_no map in
      gen_def_info t (line_no + 1) map
    | AS.Jump _ | AS.CJump _ | AS.Ret _ | AS.Label _ -> gen_def_info t (line_no + 1) map
    | AS.Directive _ | AS.Comment _ -> gen_def_info t line_no map)

and update_map dest line_no map =
  match dest with
  | AS.Imm _ -> map
  | AS.Temp tmp ->
    let cur_line_set =
      if Temp.Map.mem map tmp then Temp.Map.find_exn map tmp else Int.Set.empty
    in
    let new_line_set = Int.Set.add cur_line_set line_no in
    Temp.Map.set map ~key:tmp ~data:new_line_set
;;

(* map is a hash table from label to line number *)
let rec gen_succ (inst_list : AS.instr list) (line_no : int) map =
  match inst_list with
  | [] -> map
  | h :: t ->
    (match h with
    | AS.Label l ->
      let map = Label.Map.set map ~key:l ~data:line_no in
      gen_succ t (line_no + 1) map
    | AS.Jump _ | AS.CJump _ | AS.Ret _ | AS.Mov _ | AS.Binop _ ->
      gen_succ t (line_no + 1) map
    | AS.Directive _ | AS.Comment _ -> gen_succ t line_no map)
;;

let _gen_df_info_rev_helper dest line_no def_map =
  let gen, kill =
    match dest with
    | AS.Temp t ->
      let kill_set = Temp.Map.find_exn def_map t in
      let kill_set = Int.Set.diff kill_set (Int.Set.of_list [ line_no ]) in
      [ line_no ], Int.Set.to_list kill_set
    | AS.Imm _ -> failwith "binop dest should not be imm."
  in
  let succ = [ line_no + 1 ] in
  let is_label = false in
  ({ gen; kill; succ; is_label; line_number = line_no } : Dfana_info.line)
;;

let rec _gen_df_info_rev (inst_list : AS.instr list) line_no def_map label_map res =
  match inst_list with
  | [] -> res
  | h :: t ->
    let line =
      match h with
      | AS.Binop binop -> Some (_gen_df_info_rev_helper binop.dest line_no def_map)
      | AS.Mov mov -> Some (_gen_df_info_rev_helper mov.dest line_no def_map)
      | Jump jp ->
        let target_line_no = Label.Map.find_exn label_map jp.target in
        Some
          ({ gen = []
           ; kill = []
           ; succ = [ target_line_no ]
           ; is_label = false
           ; line_number = line_no
           }
            : Dfana_info.line)
      | CJump cjp ->
        let cond_target_line_no = Label.Map.find_exn label_map cjp.target in
        Some
          ({ gen = []
           ; kill = []
           ; succ = [ line_no + 1; cond_target_line_no ]
           ; is_label = false
           ; line_number = line_no
           }
            : Dfana_info.line)
      | Ret _ ->
        Some
          ({ gen = []; kill = []; succ = []; is_label = false; line_number = line_no }
            : Dfana_info.line)
      | Label _ ->
        Some
          ({ gen = []
           ; kill = []
           ; succ = [ line_no + 1 ]
           ; is_label = true
           ; line_number = line_no
           }
            : Dfana_info.line)
      | Directive _ | Comment _ -> None
    in
    (match line with
    | None -> _gen_df_info_rev t line_no def_map label_map res
    | Some line_s -> _gen_df_info_rev t (line_no + 1) def_map label_map (line_s :: res))
;;

let gen_df_info (inst_list : AS.instr list) : Dfana_info.line list =
  let def_map = Temp.Map.empty in
  let def_map = gen_def_info inst_list 0 def_map in
  let label_map = Label.Map.empty in
  let label_map = gen_succ inst_list 0 label_map in
  let res_rev = _gen_df_info_rev inst_list 0 def_map label_map [] in
  List.rev res_rev
;;

let rec gen_temp (inst_list : AS.instr list) line_no map =
  match inst_list with
  | [] -> map
  | h :: t ->
    (match h with
    | AS.Binop binop ->
      let map = Int.Map.set map ~key:line_no ~data:binop.dest in
      gen_temp t (line_no + 1) map
    | AS.Mov mov ->
      let map = Int.Map.set map ~key:line_no ~data:mov.dest in
      gen_temp t (line_no + 1) map
    | AS.Jump _ | AS.CJump _ | AS.Ret _ | AS.Label _ -> gen_temp t (line_no + 1) map
    | AS.Directive _ | AS.Comment _ -> gen_temp t line_no map)
;;

(* Transform liveness information from int to temp. 
 * lo_int is the dataflow analysis result.
 * tmp_map is map from line_number to temporary *)
let rec trans_liveness lo_int tmp_map res =
  match lo_int with
  | [] -> res
  | h :: t ->
    let _, out_int_list, line_no = h in
    let liveout =
      List.fold out_int_list ~init:Temp.Set.empty ~f:(fun acc x ->
          match Int.Map.find tmp_map x with
          | None ->
            let err_msg = sprintf "cannot find temporary def at line %d" x in
            failwith err_msg
          | Some s ->
            (match s with
            | AS.Imm _ -> failwith "liveout should not be immediate"
            | AS.Temp t -> Temp.Set.add acc t))
    in
    let res = Int.Map.set res ~key:line_no ~data:liveout in
    trans_liveness t tmp_map res
;;

let gen_liveness (inst_list : AS.instr list) =
  let df_info = gen_df_info inst_list in
  (* let () = print_df_info df_info in *)
  let lo_int = Dfana.dfana df_info Args.Df_analysis.Backward_may in
  let tmp_map = gen_temp inst_list 0 Int.Map.empty in
  trans_liveness lo_int tmp_map Int.Map.empty
;;
